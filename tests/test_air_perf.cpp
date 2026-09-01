// @engineperf lane, 2026-09-01 (dated per knowledge/PERF-REPORT.md append-only convention).
//
// Verifies (not guesses) two claims from the engine-side perf investigation:
//
//   1. Speed: AIR_OFF (airMode 3, what rpg.lua's R.setFast(true) actually sets) runs the
//      ENTIRE Air::update_air() computation every frame and only zeroes the result at the
//      very end (Air.cpp:467 switch). AIR_NOUPDATE (airMode 4) skips the whole function body
//      (Air.cpp:268 `if (airMode != AIR_NOUPDATE)`). Mode 3 should therefore cost
//      approximately the same as AIR_ON, and mode 4 should be many times cheaper.
//   2. Behaviour: mode 3 does not merely "decay pressure toward the edges" as originally
//      suspected in activeContext.md -- tracing the data flow shows the final loop's
//      per-cell result (dp/dx/dy) is unconditionally forced to 0.0f for AIR_OFF specifically
//      (not for AIR_ON/AIR_PRESSUREOFF/AIR_VELOCITYOFF), and that zeroed result is
//      memcpy'd over the ENTIRE pv/vx/vy grid at the end of every single call. So mode 3
//      hard-resets pressure and velocity to exactly zero, grid-wide, every frame -- it does
//      not preserve or gradually decay whatever pressure existed before that frame. Mode 4
//      (AIR_NOUPDATE) does not touch pv/vx/vy at all, so a value set by e.g. an explosion
//      persists indefinitely across frames once air is off.
//
// This second point matters for the boiler->steam->turbine chain activeContext.md flagged as
// possibly "working *because* air was accidentally on": under mode 3 it cannot be relying on
// carried-over pressure between frames (there isn't any -- it's zeroed every frame), but it
// could still be relying on the same-frame partial pressure propagation that happens in the
// earlier loops (edge mix, velocity-from-pressure, pressure-from-velocity) before the final
// zeroing -- those DO still run and DO mutate pv/vx/vy in place under mode 3. Switching to
// mode 4 skips that same-frame propagation entirely. This test proves the exact zero/no-zero
// mechanism; it does not prove which mechanism (if either) the turbine chain actually depends
// on -- that needs an in-game check after relink, called out in the report this test backs.
//
// No save file is used deliberately: Air::update_air operates on the fixed CELLS grid
// (SimulationConfig.h: 153x96 = 14688 cells) unconditionally, not on however many particles
// or how much of the map is "used" -- so its cost is a pure function of grid size, not world
// content. A "representative scene" is therefore not needed to measure this specific cost
// honestly (unlike per-particle costs, which do depend on what's in the world).

#include <catch2/catch_test_macros.hpp>
#include <catch2/benchmark/catch_benchmark.hpp>

#include "simulation/Simulation.h"
#include "simulation/Air.h"
#include "simulation/SimulationSettings.h"

#include <chrono>

namespace
{
	double TimedCallsMs(Air &air, int mode, int reps)
	{
		air.airMode = mode;
		// Warm up (first call after a mode change may pay cache/branch-predictor cost that
		// isn't representative of the steady-state per-frame cost this is trying to measure).
		air.update_air();
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			air.update_air();
		}
		auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		return elapsed / reps;
	}
}

TEST_CASE("Air::update_air costs the same under AIR_OFF as AIR_ON, and AIR_NOUPDATE is the only mode that actually skips the work", "[air][perf][!benchmark]")
{
	auto sim = Simulation::Factory();
	REQUIRE(sim->air);

	auto onMs = TimedCallsMs(*sim->air, AIR_ON, 200);
	auto offMs = TimedCallsMs(*sim->air, AIR_OFF, 200);
	auto noUpdateMs = TimedCallsMs(*sim->air, AIR_NOUPDATE, 200);

	INFO("AIR_ON        ms/call: " << onMs);
	INFO("AIR_OFF       ms/call: " << offMs);
	INFO("AIR_NOUPDATE  ms/call: " << noUpdateMs);

	// AIR_OFF must not be meaningfully cheaper than AIR_ON -- if this ever regresses (i.e.
	// someone adds a real early-out for AIR_OFF), that's a genuine speedup and this assertion
	// should be loosened; today it is the documented, verified status quo. Generous margin
	// (50%) because this is real wall-clock timing on a shared CI/dev box, not a controlled
	// microarchitecture benchmark -- the point being asserted is "same order of magnitude",
	// not "identical to the microsecond".
	REQUIRE(offMs > onMs * 0.5);

	// AIR_NOUPDATE is the only mode with a real early-out (Air.cpp:268) and must be
	// substantially cheaper -- this is the actual, verifiable claim behind "mode 4 is the
	// cheap win, mode 3 is not".
	REQUIRE(noUpdateMs < offMs * 0.5);

	BENCHMARK("Air::update_air, airMode=AIR_ON")
	{
		sim->air->airMode = AIR_ON;
		return sim->air->update_air(), 0;
	};
	BENCHMARK("Air::update_air, airMode=AIR_OFF (rpg.lua R.setFast(true) today)")
	{
		sim->air->airMode = AIR_OFF;
		return sim->air->update_air(), 0;
	};
	BENCHMARK("Air::update_air, airMode=AIR_NOUPDATE (the mode that actually skips work)")
	{
		sim->air->airMode = AIR_NOUPDATE;
		return sim->air->update_air(), 0;
	};
}

TEST_CASE("AIR_OFF hard-resets pressure and velocity to zero every call; AIR_NOUPDATE leaves them untouched", "[air][behaviour]")
{
	auto sim = Simulation::Factory();
	auto &air = *sim->air;

	// A nonzero pressure/velocity value anywhere in the grid, as if an explosion or a
	// machine had just written one (this is exactly what the earlier in-place loops inside
	// update_air itself do before the final zeroing, and what elements do outside update_air
	// entirely, e.g. TNT/pressure-emitting elements writing sim.pv directly).
	sim->pv[10][10] = 5.0f;
	sim->vx[10][10] = 2.0f;
	sim->vy[10][10] = 2.0f;

	SECTION("AIR_OFF (mode 3)")
	{
		air.airMode = AIR_OFF;
		air.update_air();
		// Forced to exactly 0.0f by the switch at Air.cpp:479 (case AIR_OFF), then
		// memcpy'd over the whole grid -- not a decay, not "close to zero", exactly zero.
		REQUIRE(sim->pv[10][10] == 0.0f);
		REQUIRE(sim->vx[10][10] == 0.0f);
		REQUIRE(sim->vy[10][10] == 0.0f);
	}

	SECTION("AIR_NOUPDATE (mode 4)")
	{
		air.airMode = AIR_NOUPDATE;
		air.update_air();
		// The entire function body is skipped (Air.cpp:268), so nothing touches pv/vx/vy.
		REQUIRE(sim->pv[10][10] == 5.0f);
		REQUIRE(sim->vx[10][10] == 2.0f);
		REQUIRE(sim->vy[10][10] == 2.0f);
	}
}
