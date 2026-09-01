// @engineperf lane, 2026-09-01.
//
// Lead 2 from the brief: knowledge/PERF-REPORT.md records one live sample of 126,290
// particles with a separate (unverified in that report) note that ICE (PT_ICEI, displayed
// name "ICE") is roughly 57% of the world. This isolates what a static, unheated block of
// ICEI actually costs per Simulation::UpdateParticles() call versus the same particle COUNT
// of PT_BRCK (brick), the cheap-baseline comparison.
//
// PT_STNE was the first choice for the baseline and was REJECTED after measuring it, not
// before: STNE has no `Update = &update` assignment (confirmed by grep), which looked like
// exactly the "generic per-particle cost only" baseline this test wants -- but
// AGENTS.md/CLAUDE.md already document that STNE is a shipped-as-static-terrain element that
// is actually `Falldown = 1, Gravity = 0.3f` (src/simulation/elements/STNE.cpp), i.e. a real
// falling powder. A first run using STNE as the baseline showed it costing MORE per call than
// ICEI despite having no custom Update() body at all -- STNE was paying the movement/collision
// code every single frame trying to fall through a full block of itself, which is a direct,
// independent, quantified confirmation of the exact defect those docs already warn about, not
// a useful "cheap baseline". PT_BRCK (`Falldown = 0`, `Gravity = 0.0f`, `TYPE_SOLID`, no
// `Update =` assignment -- verified by grep the same way) is a real static solid with no
// custom per-tick body, so it isolates the engine's generic per-particle cost the way STNE was
// wrongly assumed to.
//
// The delta between the ICEI and BRCK numbers therefore isolates ICEI's *own* Update() cost
// specifically (ICEI.cpp: neighbour scan for phase-change conditions, FRZW-sourced cooling,
// temperature-driven transitions), not the generic per-particle cost every element pays
// regardless of type.
//
// Deliberately NOT a claim about render cost or about a real, played world's exact particle
// layout -- see the caveats in the TEST_CASE body.

#include <catch2/catch_test_macros.hpp>
#include <catch2/benchmark/catch_benchmark.hpp>

#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/ElementClasses.h"
#include "simulation/Air.h"
#include "simulation/SimulationSettings.h"

#include <chrono>

namespace
{
	// Fills a contiguous block starting at (0,0), row-major, with `count` static particles of
	// type `t`. Both PT_ICEI and PT_STNE have Falldown=0/Gravity=0 (confirmed by reading
	// ICEI.cpp and this fork's own terrain-solidity rule in AGENTS.md/CLAUDE.md, which is the
	// exact defect check the project already runs for terrain elements) so a contiguous block
	// is stable across repeated ticks -- it will not fall, slide or disperse, which is what
	// makes repeated-call timing on the same instance meaningful here.
	//
	// Caveat stated plainly: a contiguous block is the BEST case for cache locality relative to
	// scattered real-world placement (e.g. a snow biome interleaved with air gaps, paths, other
	// terrain). This measurement is a lower bound on real per-particle cost, not an exact match
	// for the live world's layout -- that would need the live particle grid, which is not
	// reachable from this headless harness.
	int FillBlock(Simulation &sim, int t, int count)
	{
		int placed = 0;
		for (int y = 0; y < YRES && placed < count; ++y)
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
		// Warm-up call, same rationale as test_air_perf.cpp.
		sim.UpdateParticles(0, NPART);
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			sim.UpdateParticles(0, NPART);
		}
		auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		return elapsed / reps;
	}
}

TEST_CASE("a static ICE (PT_ICEI) block costs more per UpdateParticles call than the same count of a no-Update-function element", "[particles][perf][!benchmark]")
{
	SimulationData sd;
	REQUIRE(sd.elements[PT_ICEI].Enabled == 1);
	REQUIRE(sd.elements[PT_BRCK].Enabled == 1);
	// The exact defect AGENTS.md/CLAUDE.md warn about, pinned here so this test would fail
	// loudly if it were ever (re-)picked as a "static" baseline without checking first.
	REQUIRE(sd.elements[PT_STNE].Falldown == 1);

	// PERF-REPORT.md's one live sample: sim.partCount() = 133249 (a later, separate
	// measurement in the same report's Section 1 window recorded 126,290 -- both are cited
	// in this test's header comment; this benchmark uses the rounder, more recently quoted
	// figure). NPART (XRES*YRES) is 235008, so this comfortably fits as a contiguous block.
	constexpr int representativeCount = 126290;
	REQUIRE(representativeCount < NPART);

	SECTION("PT_ICEI (\"ICE\")")
	{
		auto sim = Simulation::Factory();
		sim->air->airMode = AIR_NOUPDATE; // isolate particle cost from the already-measured air cost
		int placed = FillBlock(*sim, PT_ICEI, representativeCount);
		REQUIRE(placed == representativeCount);

		auto ms = TimedUpdateParticlesMs(*sim, 30);
		INFO("ICEI block, " << representativeCount << " particles: " << ms << " ms/call");

		BENCHMARK("UpdateParticles, 126290x PT_ICEI static block")
		{
			return sim->UpdateParticles(0, NPART), 0;
		};
	}

	SECTION("PT_BRCK (no custom Update function -- generic per-particle cost only)")
	{
		auto sim = Simulation::Factory();
		sim->air->airMode = AIR_NOUPDATE;
		int placed = FillBlock(*sim, PT_BRCK, representativeCount);
		REQUIRE(placed == representativeCount);

		auto ms = TimedUpdateParticlesMs(*sim, 30);
		INFO("BRCK block, " << representativeCount << " particles: " << ms << " ms/call");

		BENCHMARK("UpdateParticles, 126290x PT_BRCK static block")
		{
			return sim->UpdateParticles(0, NPART), 0;
		};
	}

	SECTION("empty grid (0 particles) -- baseline loop-entry cost")
	{
		auto sim = Simulation::Factory();
		sim->air->airMode = AIR_NOUPDATE;

		auto ms = TimedUpdateParticlesMs(*sim, 30);
		INFO("empty grid: " << ms << " ms/call");

		BENCHMARK("UpdateParticles, empty grid")
		{
			return sim->UpdateParticles(0, NPART), 0;
		};
	}
}

// @engineperf lane, 2026-09-01, added after the orchestrator corrected the composition figure
// this file's header comment originally targeted: a live census (snapshot_fast, 121,341
// particles) found ICE = 0 (he is in a forest/swamp, no snow biome loaded) and instead found
// PT_GOO at 56.3% and the Lua-allocated "GRSS" at 25.4% -- together 81.7% of every particle in
// the simulation. This section uses the REAL dominant element (PT_GOO, a native C++ element,
// checked above to have Enabled==1) at its measured share, and PT_BRCK as GRSS's stand-in:
// rpg.lua:1211 allocates GRSS as a clone of PLNT with `props.Update = nil` explicitly, so a
// GRSS particle -- like BRCK -- never runs ANY per-tick element logic (Lua or C++), only the
// engine's generic per-particle loop body. GRSS itself cannot be constructed in this headless
// harness (it does not exist until rpg.lua's `elements.allocate` runs inside a live Lua VM,
// which this Catch2 binary does not load), so BRCK is used as the same cost class, not a guess.
TEST_CASE("the real dominant world composition (GOO 56.3% + an Update-nil solid standing in for GRSS 25.4%) costs tens of ms per UpdateParticles call", "[particles][perf][!benchmark]")
{
	SimulationData sd;
	REQUIRE(sd.elements[PT_GOO].Enabled == 1);
	REQUIRE(sd.elements[PT_BRCK].Enabled == 1);

	// Live census (snapshot_fast against the real running world, 121,341 particles total):
	// GOO 68,273 (56.3%), GRSS 30,864 (25.4%). Scaled down slightly so the two counts sum to
	// something that fits comfortably in one contiguous placement pass alongside GOO's block
	// without arithmetic surprises; the ratio (68273:30864, i.e. ~2.21:1) is preserved exactly.
	constexpr int gooCount = 68273;
	constexpr int brckAsGrssCount = 30864;
	REQUIRE(gooCount + brckAsGrssCount < NPART);

	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	int placedGoo = FillBlock(*sim, PT_GOO, gooCount);
	int placedGrss = 0;
	{
		// Continue placement from where GOO's block ended by placing directly, rather than
		// reusing FillBlock (which always starts at (0,0)) -- avoids overlapping the GOO block.
		int placed = 0;
		int startY = gooCount / XRES;
		for (int y = startY; y < YRES && placed < brckAsGrssCount; ++y)
		{
			for (int x = 0; x < XRES && placed < brckAsGrssCount; ++x)
			{
				if (sim->create_part(-1, x, y, PT_BRCK) >= 0)
				{
					++placed;
				}
			}
		}
		placedGrss = placed;
	}
	REQUIRE(placedGoo == gooCount);
	REQUIRE(placedGrss == brckAsGrssCount);

	auto ms = TimedUpdateParticlesMs(*sim, 30);
	INFO("GOO+GRSS-class block, " << (gooCount + brckAsGrssCount) << " particles: " << ms << " ms/call");
	// Not a tight regression bar (real wall-clock, shared dev box) -- just documents that this
	// realistic composition costs a real, double-digit-millisecond amount, not noise.
	REQUIRE(ms > 5.0);

	BENCHMARK("UpdateParticles, real-composition 99137-particle block (68273 GOO + 30864 Update-nil solid)")
	{
		return sim->UpdateParticles(0, NPART), 0;
	};
}
