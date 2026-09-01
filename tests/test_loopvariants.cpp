// @perf_loop lane, 2026-09-0X. Experiment 1 of 3 (parallel, same benchmark, comparable
// results): "the generic per-particle loop body can be made materially cheaper per particle."
//
// SCOPE NOTE, read first: this lane owns tests/ only and must not edit src/ (another lane,
// @culling, owns src/ and is actively editing SimulationImpl::UpdateParticles concurrently).
// All findings below are delivered as a measured patch spec for @lead to land, not as source
// edits from this lane.
//
// IMPORTANT DISCOVERY that changes this experiment's baseline: the brief's quoted numbers
// (~16-19ms/call, ~130-150ns/particle, "regardless of element type") describe the loop BEFORE
// @culling's work landed. Reading the live src/simulation/Simulation.cpp on this pass found
// @culling has ALREADY landed (uncommitted, in-flight) a "fast-sleep" early-out plus a
// chunkAwake/chunkAwakeNext dirty-chunk map and a per-particle `Defer wakeOnChange(...)`
// wake-bookkeeping closure, gated on:
//   !et.Update && et.Falldown==0 && et.Gravity==0 && !et.NewtonianGravity && et.Advection==0 &&
//   et.HotAir==0 && et.Diffusion==0 && parts[i].vx==0 && parts[i].vy==0
//   && !nearTransition (fresh pv/temp-vs-threshold check)
//   && (et.HeatConduct==0 || !chunkAwake[cy][cx])
// This is architecturally exactly the "early-out ordering" angle this experiment was asked to
// explore -- so this lane's job narrows to: (a) measure what that already covers and does not
// cover, since it changes what "the residual generic cost" even means today, and (b) look for
// further, non-overlapping wins in what's left. This file does NOT re-propose chunk culling;
// it treats @culling's mechanism as a given, live fact and measures around it.
//
// Key fact driving this file's design: PT_GOO (56.3% of the live world's particles) has a real
// Update() function (GOO.cpp), so `!et.Update` is false for GOO and it NEVER takes the
// fast-sleep path, regardless of chunkAwake. GOO is therefore the correct stand-in for "the
// generic loop body cost that @culling's mechanism cannot remove" -- exactly this lane's target.
// PT_BRCK (no Update, HeatConduct=251) fast-sleeps only once its chunk goes quiet
// (chunkAwake[cy][cx]==0). PT_INSL (no Update, HeatConduct=0, verified in INSL.cpp) fast-sleeps
// UNCONDITIONALLY once vx==vy==0, regardless of chunkAwake, because HeatConduct==0 short-
// circuits the OR before chunkAwake is even read -- it is the "best case, always culled"
// reference point. All three facts are pinned by REQUIRE below so this file breaks loudly if
// any of them is ever no longer true (e.g. someone gives GOO's Update a fast path, or changes
// INSL's HeatConduct).
//
// Method notes shared by every TEST_CASE in this file:
//  - Simulation::Factory() + a contiguous block via FillBlock, air->airMode = AIR_NOUPDATE
//    (isolates particle cost from air cost, same as test_air_perf.cpp / test_particle_perf.cpp).
//  - "forced-awake" variants memset chunkAwake to 1 immediately before every timed
//    UpdateParticles call, to measure this CURRENT tree's cost with @culling's fast-sleep gate
//    defeated (a stand-in for "as if this particle's chunk were never allowed to go quiet",
//    which is the closest reachable approximation to the pre-culling baseline this experiment's
//    brief was written against -- NOT a literal reproduction of the pre-culling code, since the
//    Defer/wake-bookkeeping overhead @culling added is still present and paid either way; see
//    TEST_CASE "forced-awake overhead is not free either" below, which quantifies exactly that
//    caveat instead of hand-waving it).
//  - All wall-clock, shared dev box, 30 warmed-up reps unless stated -- same honesty standard as
//    the existing perf test files in this directory.
//  - Every TEST_CASE that calls Simulation::Factory() constructs a local `SimulationData sd;`
//    FIRST, before Factory(). This is REQUIRED, not decorative: SimulationData derives from
//    ExplicitSingleton<SimulationData>, and Simulation::Factory()/create_part()/
//    UpdateParticles() reach SimulationData::CRef() internally, which dereferences whatever
//    instance is currently alive -- it does not lazily construct one. Omitting this crashed
//    with a deterministic, reproducible-in-isolation SIGSEGV inside FillBlockFrom's first
//    create_part() call on this pass (root-caused by bisection: reproduced with plain PT_BRCK,
//    ruled out concurrent-build/ABI-mismatch theories by confirming test_particle_perf.cpp's
//    own BRCK/ICEI cases still passed in the same binary, then fixed by moving/adding the
//    `SimulationData sd;` line before Factory() -- not a bug in @culling's in-flight code, not
//    an ABI mismatch, just a missing bootstrap line in this file's first draft). Recorded here
//    so the next perf test author in this codebase does not lose the same time to it.

#include <catch2/catch_test_macros.hpp>
#include <catch2/benchmark/catch_benchmark.hpp>

#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/ElementClasses.h"
#include "simulation/Air.h"
#include "simulation/SimulationSettings.h"

#include <chrono>
#include <cstring>
#include <iostream>

namespace
{
	int FillBlockFrom(Simulation &sim, int t, int count, int startY = 0)
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
		sim.UpdateParticles(0, NPART); // warm-up
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			sim.UpdateParticles(0, NPART);
		}
		return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / reps;
	}

	// Forces every chunk awake immediately before each call, defeating @culling's fast-sleep
	// gate for any element whose HeatConduct != 0 (elements with HeatConduct==0, e.g. INSL,
	// bypass the chunkAwake check entirely and are unaffected by this -- that is itself one of
	// this file's findings, not an oversight).
	double TimedUpdateParticlesMsForcedAwake(Simulation &sim, int reps)
	{
		auto forceAwake = [&]() { std::memset(sim.chunkAwake, 1, sizeof(sim.chunkAwake)); };
		forceAwake();
		sim.UpdateParticles(0, NPART); // warm-up
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			forceAwake();
			sim.UpdateParticles(0, NPART);
		}
		return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / reps;
	}

	double TimedMemsetChunkAwakeMs(Simulation &sim, int reps)
	{
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			std::memset(sim.chunkAwake, 1, sizeof(sim.chunkAwake));
		}
		return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / reps;
	}
}

TEST_CASE("pinned facts this file's design depends on", "[particles][perf][loopvariants]")
{
	SimulationData sd;
	// GOO must keep an Update function for this file's "GOO is uncullable" framing to hold.
	REQUIRE(sd.elements[PT_GOO].Update != nullptr);
	REQUIRE(sd.elements[PT_GOO].Falldown == 0);
	REQUIRE(bool(sd.elements[PT_GOO].Properties & TYPE_SOLID));
	// BRCK: no Update, but HeatConduct != 0, so it needs chunkAwake==0 to fast-sleep.
	REQUIRE(sd.elements[PT_BRCK].Update == nullptr);
	REQUIRE(sd.elements[PT_BRCK].HeatConduct != 0);
	REQUIRE(sd.elements[PT_BRCK].Falldown == 0);
	// INSL: no Update, HeatConduct == 0, so it fast-sleeps unconditionally (chunkAwake-immune).
	REQUIRE(sd.elements[PT_INSL].Update == nullptr);
	REQUIRE(sd.elements[PT_INSL].HeatConduct == 0);
	REQUIRE(sd.elements[PT_INSL].Falldown == 0);
	REQUIRE(sd.elements[PT_INSL].Gravity == 0.0f);
	REQUIRE(bool(sd.elements[PT_INSL].Properties & TYPE_SOLID));

	INFO("sizeof(Particle) = " << sizeof(Particle) << " bytes");
	std::cerr << "[loopvariants] sizeof(Particle) = " << sizeof(Particle) << " bytes\n";
}

TEST_CASE("current tree: fast-sleep culling impact on the generic loop, per element class", "[particles][perf][loopvariants][!benchmark]")
{
	// REQUIRED, not decorative: SimulationData derives from ExplicitSingleton<SimulationData>,
	// and Simulation::Factory()/create_part()/UpdateParticles() reach SimulationData::CRef()
	// internally. CRef() dereferences whatever instance is currently alive -- it does NOT lazily
	// construct one. Found the hard way on this pass: omitting this line crashes with SIGSEGV
	// inside FillBlockFrom's very first create_part() call, reproduced deterministically in
	// isolation (not a fluke of concurrent building) and fixed by adding exactly this line
	// before any Simulation::Factory() call in the test case. Sibling files
	// (test_particle_perf.cpp, test_elements.cpp) already follow this pattern; this file's first
	// draft did not, in the one TEST_CASE where it mattered for this translation unit's static/
	// registration order. See this file's file-level comment for the full writeup.
	SimulationData sd;
	(void)sd;
	constexpr int representativeCount = 126290;

	SECTION("PT_INSL (HeatConduct=0 -- fast-sleeps unconditionally, chunkAwake-immune)")
	{
		auto simNatural = Simulation::Factory();
		simNatural->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simNatural, PT_INSL, representativeCount) == representativeCount);
		auto naturalMs = TimedUpdateParticlesMs(*simNatural, 30);

		auto simForced = Simulation::Factory();
		simForced->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simForced, PT_INSL, representativeCount) == representativeCount);
		auto forcedMs = TimedUpdateParticlesMsForcedAwake(*simForced, 30);

		INFO("INSL natural (culled): " << naturalMs << " ms/call, forced-awake: " << forcedMs << " ms/call");
		std::cerr << "[loopvariants] INSL " << representativeCount << " natural=" << naturalMs
		          << "ms forced-awake=" << forcedMs << "ms\n";

		BENCHMARK("UpdateParticles, 126290x PT_INSL, natural chunkAwake")
		{
			return simNatural->UpdateParticles(0, NPART), 0;
		};
	}

	SECTION("PT_BRCK (HeatConduct=251 -- fast-sleeps only once chunkAwake==0)")
	{
		auto simNatural = Simulation::Factory();
		simNatural->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simNatural, PT_BRCK, representativeCount) == representativeCount);
		auto naturalMs = TimedUpdateParticlesMs(*simNatural, 30);

		auto simForced = Simulation::Factory();
		simForced->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simForced, PT_BRCK, representativeCount) == representativeCount);
		auto forcedMs = TimedUpdateParticlesMsForcedAwake(*simForced, 30);

		INFO("BRCK natural (culled): " << naturalMs << " ms/call, forced-awake: " << forcedMs << " ms/call");
		std::cerr << "[loopvariants] BRCK " << representativeCount << " natural=" << naturalMs
		          << "ms forced-awake=" << forcedMs << "ms\n";
		// The whole point of @culling's mechanism: natural (settled) must be meaningfully
		// cheaper than forced-awake for an element that actually depends on chunkAwake.
		REQUIRE(naturalMs < forcedMs);

		BENCHMARK("UpdateParticles, 126290x PT_BRCK, natural chunkAwake (settles quiet)")
		{
			return simNatural->UpdateParticles(0, NPART), 0;
		};
		BENCHMARK("UpdateParticles, 126290x PT_BRCK, forced-awake every call")
		{
			std::memset(simForced->chunkAwake, 1, sizeof(simForced->chunkAwake));
			return simForced->UpdateParticles(0, NPART), 0;
		};
	}

	SECTION("PT_GOO (has Update -- never takes the fast-sleep path, culling-immune either way)")
	{
		auto simNatural = Simulation::Factory();
		simNatural->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simNatural, PT_GOO, representativeCount) == representativeCount);
		auto naturalMs = TimedUpdateParticlesMs(*simNatural, 30);

		auto simForced = Simulation::Factory();
		simForced->air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(*simForced, PT_GOO, representativeCount) == representativeCount);
		auto forcedMs = TimedUpdateParticlesMsForcedAwake(*simForced, 30);

		INFO("GOO natural: " << naturalMs << " ms/call, forced-awake: " << forcedMs << " ms/call");
		std::cerr << "[loopvariants] GOO " << representativeCount << " natural=" << naturalMs
		          << "ms forced-awake=" << forcedMs << "ms\n";

		BENCHMARK("UpdateParticles, 126290x PT_GOO, natural chunkAwake")
		{
			return simNatural->UpdateParticles(0, NPART), 0;
		};
	}
}

TEST_CASE("current tree: real live composition (GOO 56.3% + Update-nil-class solid 25.4%), culled vs forced-awake", "[particles][perf][loopvariants][!benchmark]")
{
	// See the ExplicitSingleton note in the previous TEST_CASE -- required here too.
	SimulationData sd;
	(void)sd;

	// Same real census as test_particle_perf.cpp's corresponding test: GOO 68273, GRSS-class
	// (here BRCK, since GRSS is a Lua-side clone unavailable in this headless harness) 30864.
	constexpr int gooCount = 68273;
	constexpr int brckAsGrssCount = 30864;

	// Built and torn down as two entirely separate, non-overlapping Simulation instances
	// (not concurrently mutated) -- simForced is only constructed after simNatural's timing
	// pass has fully completed, same lifetime pattern as the existing SECTION-based tests in
	// this directory just without the SECTION re-entry.
	auto buildScene = [&](Simulation &sim) {
		sim.air->airMode = AIR_NOUPDATE;
		REQUIRE(FillBlockFrom(sim, PT_GOO, gooCount) == gooCount);
		REQUIRE(FillBlockFrom(sim, PT_BRCK, brckAsGrssCount, gooCount / XRES) == brckAsGrssCount);
	};

	auto simNatural = Simulation::Factory();
	buildScene(*simNatural);
	auto naturalMs = TimedUpdateParticlesMs(*simNatural, 30);

	auto simForced = Simulation::Factory();
	buildScene(*simForced);
	auto forcedMs = TimedUpdateParticlesMsForcedAwake(*simForced, 30);

	auto totalCount = gooCount + brckAsGrssCount;
	INFO("real composition natural (culled): " << naturalMs << " ms/call ("
	     << (naturalMs * 1e6 / totalCount) << " ns/particle), forced-awake: " << forcedMs
	     << " ms/call (" << (forcedMs * 1e6 / totalCount) << " ns/particle)");
	std::cerr << "[loopvariants] real-composition " << totalCount << " natural=" << naturalMs
	          << "ms (" << (naturalMs * 1e6 / totalCount) << "ns/particle) forced-awake=" << forcedMs
	          << "ms (" << (forcedMs * 1e6 / totalCount) << "ns/particle)\n";

	BENCHMARK("UpdateParticles, real composition, natural chunkAwake")
	{
		return simNatural->UpdateParticles(0, NPART), 0;
	};
	BENCHMARK("UpdateParticles, real composition, forced-awake every call")
	{
		std::memset(simForced->chunkAwake, 1, sizeof(simForced->chunkAwake));
		return simForced->UpdateParticles(0, NPART), 0;
	};
}

TEST_CASE("forced-awake overhead is not free either: the memset itself, isolated", "[particles][perf][loopvariants][!benchmark]")
{
	// Quantifies the caveat stated in this file's header: TimedUpdateParticlesMsForcedAwake's
	// numbers include a std::memset(chunkAwake, 1, sizeof(chunkAwake)) per call, so this test
	// measures that memset ALONE (no UpdateParticles at all) to show it is negligible against
	// the multi-millisecond figures above, not to hide it.
	// (ExplicitSingleton bootstrap -- see the note in the fast-sleep-culling-impact TEST_CASE.)
	SimulationData sdGuard;
	(void)sdGuard;
	auto sim = Simulation::Factory();
	auto ms = TimedMemsetChunkAwakeMs(*sim, 1000);
	INFO("memset(chunkAwake, sizeof=" << sizeof(sim->chunkAwake) << " bytes): " << ms << " ms/call ("
	     << ms * 1e6 << " ns/call)");
	std::cerr << "[loopvariants] memset(chunkAwake) alone: " << ms << "ms/call (" << ms * 1e6 << "ns)\n";
	// sizeof(chunkAwake) is XCELLS*YCELLS = 153*96 = 14688 bytes -- expect low-microsecond cost,
	// nowhere near the millisecond range of a real UpdateParticles call.
	REQUIRE(ms < 0.05);
}

namespace
{
	// Verbatim-logic duplicate of SimulationImpl::GetNeighbourhood's 8-lookup pmap scan
	// (Simulation.cpp:2318-2345, read on this pass), reproduced here as a free function
	// because GetNeighbourhood is a private, non-virtual member of the file-local
	// SimulationImpl class and cannot be called from outside Simulation.cpp. This is used
	// ONLY to isolate and quantify the cost of the 8-neighbour pmap scan itself, in
	// controlled variants -- it is not proposed as a replacement for the real function, and
	// it deliberately skips the GetGravityField call (irrelevant for TYPE_SOLID particles,
	// which is what every scene in this file uses).
	struct NeighbourhoodCounts
	{
		int surround_space = 0;
		int nt = 0;
	};

	NeighbourhoodCounts ScanNeighbourhoodEager(const int pmap[YRES][XRES], int t, int x, int y)
	{
		NeighbourhoodCounts n;
		for (auto nx = -1; nx < 2; nx++)
		{
			for (auto ny = -1; ny < 2; ny++)
			{
				if (nx || ny)
				{
					auto r = pmap[y + ny][x + nx];
					n.surround_space += !TYP(r);
					n.nt += (TYP(r) != t);
				}
			}
		}
		return n;
	}

	// Branch-eliminated variant: same 8 offsets, same aggregate result (surround_space/nt are
	// order-independent sums, and every real consumer of the surround array either sums over
	// it (surround_space/nt) or applies identical logic to each of the 8 entries regardless of
	// position (TransitionPhase's heat-conduct loop) -- so visiting the 8 neighbours in a
	// different fixed order changes nothing observable). Removes the `if (nx || ny)` branch
	// (9 iterations with 1 always-skipped, per particle) by unrolling to exactly 8 explicit
	// lookups. Brief's own angle: "branch elimination / predictability in the hot path."
	NeighbourhoodCounts ScanNeighbourhoodUnrolled(const int pmap[YRES][XRES], int t, int x, int y)
	{
		NeighbourhoodCounts n;
		const int offsets[8][2] = { {-1,-1}, {-1,0}, {-1,1}, {0,-1}, {0,1}, {1,-1}, {1,0}, {1,1} };
		for (auto &o : offsets)
		{
			auto r = pmap[y + o[1]][x + o[0]];
			n.surround_space += !TYP(r);
			n.nt += (TYP(r) != t);
		}
		return n;
	}
}

TEST_CASE("isolating the 8-neighbour pmap scan cost (diagnostic only, not a proposed change)", "[particles][perf][loopvariants][!benchmark]")
{
	// Brief's own angle: "Redundant work per particle: repeated pmap lookups, recomputed
	// indices." This measures what the scan itself costs in isolation, against a real filled
	// pmap grid, to answer: is this scan a meaningful fraction of GOO's residual (uncullable)
	// per-particle cost, or noise next to it?
	//
	// NEGATIVE FINDING, reasoned from reading the code (not re-litigated here as a live
	// microbenchmark of "lazy" evaluation): making this scan lazy (e.g. "only scan if the
	// element's own Update() consults surround_space/nt, or if the heat-conduct RNG gate
	// fires") does NOT save the scan's cost for the general case, because MovementPhase
	// (Simulation.cpp, `neighbourhood.nt` / `neighbourhood.surround_space` used in the
	// stagnant/clear-space check) and many elements' own Update() functions consume
	// surround_space/nt directly, and those aggregate counts can only be produced by doing
	// the same 8 pmap reads that would need to happen anyway -- there is no cheaper way to
	// know "how many empty/foreign neighbours does this particle have" than reading all 8
	// neighbour cells. The only per-particle-movable element (GOO can gain velocity from
	// ambient air inside its OWN Update(), read directly, not inferred) needs this eagerly,
	// before Update() runs, because whether Update() will impart velocity isn't known in
	// advance. So this scan is real, unavoidable work for GOO-class elements today, not
	// currently-wasted work -- reported honestly instead of proposing a change that reading
	// the surrounding code shows would not be correct.
	// (ExplicitSingleton bootstrap -- see the note in the fast-sleep-culling-impact TEST_CASE.
	// Constructed BEFORE Simulation::Factory(), not after, which is what this file's first
	// draft got wrong in its other TEST_CASEs and is pinned here as the fix.)
	SimulationData sd;
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	constexpr int count = 126290;
	REQUIRE(FillBlockFrom(*sim, PT_GOO, count) == count);

	auto &elements = sd.elements;

	// One full pass equivalent to what GetNeighbourhood does per particle, timed directly
	// against the real filled pmap -- gives an ns/particle figure for JUST this piece.
	constexpr int reps = 30;
	auto start = std::chrono::steady_clock::now();
	volatile int sink = 0;
	for (int r = 0; r < reps; ++r)
	{
		for (int i = 0; i < sim->parts.active; ++i)
		{
			auto t = sim->parts[i].type;
			if (!t)
			{
				continue;
			}
			auto x = int(sim->parts[i].x + 0.5f);
			auto y = int(sim->parts[i].y + 0.5f);
			auto n = ScanNeighbourhoodEager(sim->pmap, t, x, y);
			sink += n.surround_space + n.nt;
		}
	}
	auto elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / reps;
	INFO("8-neighbour pmap scan only, " << count << " particles: " << elapsedMs << " ms/call ("
	     << (elapsedMs * 1e6 / count) << " ns/particle), sink=" << sink);
	std::cerr << "[loopvariants] neighbourhood-scan-only " << count << " particles: " << elapsedMs
	          << "ms/call (" << (elapsedMs * 1e6 / count) << "ns/particle)\n";
	(void)elements;

	// Unrolled variant, timed the same way, to check whether removing the branch is worth
	// proposing as a change to GetNeighbourhood's real implementation.
	auto start2 = std::chrono::steady_clock::now();
	volatile int sink2 = 0;
	for (int r = 0; r < reps; ++r)
	{
		for (int i = 0; i < sim->parts.active; ++i)
		{
			auto t = sim->parts[i].type;
			if (!t)
			{
				continue;
			}
			auto x = int(sim->parts[i].x + 0.5f);
			auto y = int(sim->parts[i].y + 0.5f);
			auto n = ScanNeighbourhoodUnrolled(sim->pmap, t, x, y);
			sink2 += n.surround_space + n.nt;
		}
	}
	auto elapsedMs2 = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start2).count() / reps;
	INFO("8-neighbour pmap scan, UNROLLED (no branch), " << count << " particles: " << elapsedMs2
	     << " ms/call (" << (elapsedMs2 * 1e6 / count) << " ns/particle), sink=" << sink2);
	std::cerr << "[loopvariants] neighbourhood-scan-unrolled " << count << " particles: " << elapsedMs2
	          << "ms/call (" << (elapsedMs2 * 1e6 / count) << "ns/particle)\n";

	BENCHMARK("8-neighbour pmap scan only, EAGER (branchy), 126290x static GOO block")
	{
		volatile int localSink = 0;
		for (int i = 0; i < sim->parts.active; ++i)
		{
			auto t = sim->parts[i].type;
			if (!t) continue;
			auto x = int(sim->parts[i].x + 0.5f);
			auto y = int(sim->parts[i].y + 0.5f);
			auto n = ScanNeighbourhoodEager(sim->pmap, t, x, y);
			localSink += n.surround_space + n.nt;
		}
		return localSink;
	};
	BENCHMARK("8-neighbour pmap scan only, UNROLLED (no branch), 126290x static GOO block")
	{
		volatile int localSink = 0;
		for (int i = 0; i < sim->parts.active; ++i)
		{
			auto t = sim->parts[i].type;
			if (!t) continue;
			auto x = int(sim->parts[i].x + 0.5f);
			auto y = int(sim->parts[i].y + 0.5f);
			auto n = ScanNeighbourhoodUnrolled(sim->pmap, t, x, y);
			localSink += n.surround_space + n.nt;
		}
		return localSink;
	};
}

TEST_CASE("division-caching microbenchmark: does the compiler already CSE repeated x/CELL, y/CELL?", "[particles][perf][loopvariants][!benchmark]")
{
	// Brief's own angle: "Redundant work per particle... recomputed indices the compiler
	// cannot hoist." The real loop computes bmap[y/CELL][x/CELL] (and friends) up to 8+ times
	// per particle across the kill/wall/STASIS/DETECT checks with x and y unchanged in
	// between. Division by a compile-time constant (CELL=4) compiles to a shift, and x/y are
	// not mutated between those checks, so a competent optimizer should CSE this for free.
	// This is a synthetic, Simulation-independent microbenchmark (plain arrays, not sim
	// internals) built ONLY to check whether that assumption holds on the actual compiler and
	// flags this project builds with, per the brief's "measure, do not assume" instruction --
	// not a proposed source change either way.
	constexpr int N = 126290;
	std::vector<int> xs(N), ys(N);
	std::vector<unsigned char> bmap(YCELLS * XCELLS);
	for (int i = 0; i < N; ++i)
	{
		xs[i] = (i % (XRES - 2 * CELL)) + CELL;
		ys[i] = ((i / (XRES - 2 * CELL)) % (YRES - 2 * CELL)) + CELL;
	}
	for (auto &b : bmap) b = 0;

	constexpr int reps = 200;
	volatile unsigned sinkUncached = 0, sinkCached = 0;

	auto start1 = std::chrono::steady_clock::now();
	for (int r = 0; r < reps; ++r)
	{
		unsigned acc = 0;
		for (int i = 0; i < N; ++i)
		{
			int x = xs[i], y = ys[i];
			// 8 repeated divisions, matching the real loop's repeated bmap[y/CELL][x/CELL]
			// checks (kill-offscreen is a separate branch; this models the wall/STASIS/DETECT
			// block's repeated indexing specifically).
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
		}
		sinkUncached += acc;
	}
	auto uncachedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start1).count() / reps;

	auto start2 = std::chrono::steady_clock::now();
	for (int r = 0; r < reps; ++r)
	{
		unsigned acc = 0;
		for (int i = 0; i < N; ++i)
		{
			int x = xs[i], y = ys[i];
			int cx = x / CELL, cy = y / CELL;
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
		}
		sinkCached += acc;
	}
	auto cachedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start2).count() / reps;

	INFO("uncached (repeated /CELL): " << uncachedMs << " ms/pass, cached (hoisted): " << cachedMs
	     << " ms/pass, sinks=" << sinkUncached << "/" << sinkCached);
	std::cerr << "[loopvariants] division-cache uncached=" << uncachedMs << "ms cached=" << cachedMs
	          << "ms (N=" << N << ", 8 accesses/particle, " << reps << " reps)\n";

	BENCHMARK("8x bmap[y/CELL][x/CELL], uncached division")
	{
		unsigned acc = 0;
		for (int i = 0; i < N; ++i)
		{
			int x = xs[i], y = ys[i];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
			acc += bmap[(y / CELL) * XCELLS + (x / CELL)];
		}
		return acc;
	};
	BENCHMARK("8x bmap[cy][cx], hoisted division")
	{
		unsigned acc = 0;
		for (int i = 0; i < N; ++i)
		{
			int x = xs[i], y = ys[i];
			int cx = x / CELL, cy = y / CELL;
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
			acc += bmap[cy * XCELLS + cx];
		}
		return acc;
	};
}
