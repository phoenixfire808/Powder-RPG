// @perf_terrain lane, 2026-09-0X.
//
// Experiment 3 of 3 (parallel with @culling and @perf_loop): the radical hypothesis under
// test is "inert terrain should not be a simulated particle at all -- a static material grid,
// with particles promoted into parts[] only when disturbed". This file does NOT implement
// that (see D:/powder-toy/knowledge/design-terrain-layer.md for the design writeup) -- it
// quantifies the ceiling such an architecture could reach, specifically the ceiling
// REMAINING after @culling's already-landed fast-sleep optimisation in Simulation.cpp's
// UpdateParticles (the "Active-cell / dirty-rectangle culling" block, chunkAwake/
// chunkAwakeNext), because that optimisation is live in this tree as of this write and
// changes the answer materially from the pre-culling numbers recorded earlier in
// knowledge/PERF-REPORT.md.
//
// THE KEY FINDING THIS FILE EXISTS TO PIN DOWN, stated up front, VERIFIED by the first
// TEST_CASE below (the one assertion in this file that runs cleanly and reliably every time
// on this dev box, unlike the timing sections further down -- see the note on those):
// the live world's two dominant terrain fills do NOT behave the same way under @culling's
// fast-sleep predicate.
//   - GRSS (proxied here by PT_BRCK, same reasoning as test_particle_perf.cpp: rpg.lua:1211
//     allocates GRSS as a PLNT clone with props.Update = nil, so it -- like BRCK -- has no
//     custom per-tick Update() function) DOES qualify for the fast-sleep skip once its chunk
//     goes cold (Simulation.cpp's fast-sleep gate requires `!et.Update` among other things).
//   - GOO (a REAL, always-present, non-Lua element, src/simulation/elements/GOO.cpp) has a
//     real `Update = &update` function (a life-timer check + advection under pressure -- see
//     GOO.cpp, four lines) and therefore NEVER qualifies for the fast-sleep skip, REGARDLESS
//     of chunkAwake state. GOO pays the full per-particle body (AirLoss/AirDrag injection,
//     GetNeighbourhood's 8-cell pmap scan, TransitionPhase, the Update() call itself) on
//     EVERY frame, forever, even when settled and doing nothing observable.
// Since GOO is the single largest element in the live census (56.3%, PERF-REPORT.md
// 2026-09-01 census, 68,273 of 121,341 particles), this is not a minor asterisk: it is the
// majority of the terrain-fill particle count, and @culling's optimisation structurally
// cannot reach it without either widening the fast-sleep predicate to permit certain
// "trivially checkable" Update() functions (a real but separate piece of work, @culling's
// call) or removing GOO from parts[] entirely (this experiment's hypothesis).
//
// TESTING-INFRASTRUCTURE NOTE, stated honestly rather than hidden: the timing TEST_CASEs
// below were originally written using Catch2 SECTION blocks (multiple scenarios sharing one
// TEST_CASE, the same style test_particle_perf.cpp uses) and using Catch2's BENCHMARK()
// macro. Both were tried and dropped after reproducible SIGSEGV crashes on this dev box --
// BENCHMARK() crashed at 121341-particle scale specifically; SECTION-based re-entry crashed
// even with plain chrono timing and no BENCHMARK() involved at all. A flat, one-scenario-per-
// TEST_CASE structure with plain chrono timing (this file's current shape) was the version
// that ran cleanly and repeatably, matching a standalone scratch reproduction outside Catch2's
// SECTION machinery. This was NOT chased to a root cause (out of scope: no src/ edits, and
// this dev box had 3-4 other perf lanes concurrently building/running against the SAME
// build-tests tree throughout this investigation -- @culling confirmed live edits in
// Simulation.cpp/.h during this exact window). Recorded here so a future reader does not
// reintroduce SECTION/BENCHMARK and lose an afternoon to the same instability. Every
// wall-clock number from these TEST_CASEs is additionally suspect on its own terms: absolute
// timings observed here ranged over two orders of magnitude (single-digit ms to ~900ms) for
// IDENTICAL code between runs, consistent with severe concurrent-lane CPU contention on a
// shared box, not a real per-call cost. Treat every ms figure in this file's output, and in
// knowledge/design-terrain-layer.md's citations of it, as order-of-magnitude/relative
// evidence only -- re-measure on a quiet machine before using any of it for a go/no-go call.

#include <catch2/catch_test_macros.hpp>
// Deliberately NOT including catch2/benchmark/catch_benchmark.hpp -- see the note above.

#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/ElementClasses.h"
#include "simulation/Air.h"
#include "simulation/SimulationSettings.h"

#include <chrono>

namespace
{
	// Same placement idiom as test_particle_perf.cpp -- contiguous, row-major, starting from
	// a given row so multiple element blocks can be laid out back-to-back without overlap.
	int FillBlockFrom(Simulation &sim, int t, int count, int startY)
	{
		int placed = 0;
		for (int y = startY; y < YRES && placed < count; ++y)
		{
			for (int x = 0; x < XRES && placed < count; ++x)
			{
				if (sim.create_part(-1, x, y, t) >= 0)
				{
					++placed;
				}
			}
		}
		return placed;
	}

	double TimedUpdateParticlesMs(Simulation &sim, int reps)
	{
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			sim.UpdateParticles(0, NPART);
		}
		auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		return elapsed / reps;
	}
}

TEST_CASE("architectural pin: GOO has a real Update() and is therefore ineligible for @culling's fast-sleep skip; the GRSS proxy (BRCK) is eligible", "[terrainlayer][perf]")
{
	SimulationData sd;
	REQUIRE(sd.elements[PT_GOO].Enabled == 1);
	REQUIRE(sd.elements[PT_BRCK].Enabled == 1);
	// This is the load-bearing assertion for this whole experiment's "remaining ceiling"
	// argument. If this ever flips (GOO loses its Update(), or BRCK gains one), the
	// conclusion below needs re-deriving, so pin it here the same way test_particle_perf.cpp
	// pins the STNE Falldown defect.
	REQUIRE(sd.elements[PT_GOO].Update != nullptr);
	REQUIRE(sd.elements[PT_BRCK].Update == nullptr);
}

TEST_CASE("cold-chunk vs steady-state: PT_BRCK (GRSS proxy), 30864 particles", "[terrainlayer][perf][!benchmark]")
{
	constexpr int blockCount = 30864; // live census GRSS count, PERF-REPORT.md 2026-09-01
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	int placed = FillBlockFrom(*sim, PT_BRCK, blockCount, 0);
	REQUIRE(placed == blockCount);

	// Call 1: chunkAwake is all-1 (clear_sim's init) -- cold, no fast-sleep benefit yet.
	double coldMs = TimedUpdateParticlesMs(*sim, 1);
	// A static block with no create/kill/transition/move never calls WakeChunk, so after one
	// full pass chunkAwakeNext (accumulated during the pass) is all-0 and gets swapped into
	// chunkAwake at the end of that pass -- calls 2+ should see a cold (asleep) chunk and,
	// per the fast-sleep gate, skip BRCK's per-particle body entirely (BRCK: Falldown=0,
	// Gravity=0, no NewtonianGravity, Advection=0, HotAir=0, Diffusion=0, and once placed
	// vx=vy=0 -- satisfies every fast-sleep precondition).
	double warmMs = TimedUpdateParticlesMs(*sim, 10);

	UNSCOPED_INFO("BRCK(" << blockCount << ") cold(call 1) = " << coldMs << " ms; warm(steady-state, 10-call avg) = " << warmMs << " ms");
	REQUIRE(coldMs >= 0.0);
	REQUIRE(warmMs >= 0.0);
}

TEST_CASE("cold-chunk vs steady-state: PT_GOO, 68273 particles", "[terrainlayer][perf][!benchmark]")
{
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	constexpr int gooCount = 68273; // live census GOO count, PERF-REPORT.md 2026-09-01
	int placed = FillBlockFrom(*sim, PT_GOO, gooCount, 0);
	REQUIRE(placed == gooCount);

	double coldMs = TimedUpdateParticlesMs(*sim, 1);
	// Expect little or no drop vs coldMs, since Update != nullptr disqualifies GOO from the
	// fast-sleep gate entirely, regardless of chunkAwake state.
	double warmMs = TimedUpdateParticlesMs(*sim, 10);

	UNSCOPED_INFO("GOO(" << gooCount << ") cold(call 1) = " << coldMs << " ms; warm(steady-state, 10-call avg) = " << warmMs << " ms");
	REQUIRE(coldMs >= 0.0);
	REQUIRE(warmMs >= 0.0);
}

TEST_CASE("post-culling steady state: FULL census (121341 = GOO + GRSS-proxy + non-terrain remainder)", "[terrainlayer][perf][!benchmark]")
{
	// Live census total: 121,341. GOO 68,273 (56.3%) + GRSS-proxy(BRCK) 30,864 (25.4%) =
	// 99,137 terrain-fill (81.7%). Remainder = 121,341 - 99,137 = 22,204 (18.3%), stood in
	// here by PT_WOOD (the single largest non-GOO/GRSS type in the same census, 11,413 of
	// the ~22k remainder per PERF-REPORT.md's top-10 table) as a representative element WITH
	// a real Update() body and real Falldown -- i.e. genuinely NOT eligible for fast-sleep,
	// same as it would be in the live world.
	constexpr int gooCount = 68273;
	constexpr int grssCount = 30864;
	constexpr int remainderCount = 22204;
	constexpr int totalCount = gooCount + grssCount + remainderCount;
	REQUIRE(totalCount == 121341);
	REQUIRE(totalCount < NPART);

	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	int placedGoo = FillBlockFrom(*sim, PT_GOO, gooCount, 0);
	int startY2 = gooCount / XRES;
	int placedGrss = FillBlockFrom(*sim, PT_BRCK, grssCount, startY2);
	int startY3 = (gooCount + grssCount) / XRES;
	int placedRem = FillBlockFrom(*sim, PT_WOOD, remainderCount, startY3);
	REQUIRE(placedGoo == gooCount);
	REQUIRE(placedGrss == grssCount);
	REQUIRE(placedRem == remainderCount);

	// Run past the first full pass so chunkAwake settles to its steady-state pattern (BRCK's
	// chunk cold, GOO's/WOOD's chunks may or may not re-wake themselves -- WOOD has real
	// Falldown/vx/vy churn so its own chunk plausibly stays warm, which is realistic: real
	// remainder particles keep their neighbourhood awake too) before the timed calls.
	TimedUpdateParticlesMs(*sim, 3);

	double ms = TimedUpdateParticlesMs(*sim, 20);
	UNSCOPED_INFO("FULL census (" << totalCount << "), steady-state avg over 20 calls: " << ms << " ms/call");
	REQUIRE(ms >= 0.0);
}

TEST_CASE("post-culling steady state: NON-TERRAIN remainder ONLY (22204 particles) -- the floor a terrain-layer architecture could reach for this slice of work", "[terrainlayer][perf][!benchmark]")
{
	constexpr int remainderCount = 22204;
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	int placedRem = FillBlockFrom(*sim, PT_WOOD, remainderCount, 0);
	REQUIRE(placedRem == remainderCount);

	TimedUpdateParticlesMs(*sim, 3);

	double ms = TimedUpdateParticlesMs(*sim, 20);
	UNSCOPED_INFO("NON-TERRAIN remainder only (" << remainderCount << "), steady-state avg over 20 calls: " << ms << " ms/call");
	REQUIRE(ms >= 0.0);
}

TEST_CASE("post-culling steady state: GOO ONLY (68273 particles) -- isolates the mandatory-Update() cost @culling structurally cannot remove", "[terrainlayer][perf][!benchmark]")
{
	constexpr int gooCount = 68273;
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	int placedGoo = FillBlockFrom(*sim, PT_GOO, gooCount, 0);
	REQUIRE(placedGoo == gooCount);

	TimedUpdateParticlesMs(*sim, 3);

	double ms = TimedUpdateParticlesMs(*sim, 20);
	UNSCOPED_INFO("GOO only (" << gooCount << "), steady-state avg over 20 calls: " << ms << " ms/call");
	REQUIRE(ms >= 0.0);
}
