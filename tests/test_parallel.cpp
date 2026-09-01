// @perf_thread lane, experiment 2/3, dated per this repo's documentation convention.
//
// Hypothesis under test: SimulationImpl::UpdateParticles (Simulation.cpp:2306, ~16-19ms/call
// for 126,290 particles per knowledge/PERF-REPORT.md) can be parallelised across the host's
// 8 cores / 16 threads (AMD Ryzen 7 3800X).
//
// HARD CONSTRAINT this file honours throughout: no edits to src/. Only Simulation's PUBLIC
// surface is usable from here. That surface was read directly (src/simulation/Simulation.h)
// before writing a line of this file:
//   - virtual void UpdateParticles(int start, int end) -- the ONLY entry point into the
//     per-particle loop. It dispatches over an ARRAY-INDEX range [start, end), not a spatial
//     region.
//   - parts (Parts: data[NPART], active), pmap[YRES][XRES], bmap/vx/vy/pv[YCELLS][XCELLS] are
//     public (RenderableSimulation base), so this file CAN read/seed/inspect them directly.
//   - GetNeighbourhood / TransitionPhase / MovementPhase, i.e. the actual loop body, are
//     private members of `SimulationImpl`, a class defined and closed entirely inside
//     Simulation.cpp (confirmed: `class SimulationImpl` at Simulation.cpp:~20-40, never
//     forward-declared in any header) -- NOT reachable from any translation unit outside that
//     one file. There is no way to call the per-particle body at finer-than-UpdateParticles
//     granularity from tests/.
//
// This is the load-bearing fact for every finding below: the only lever available from outside
// src/ is calling UpdateParticles with different index ranges, concurrently, on the SAME
// Simulation instance. That is exactly the "naive parallel_for over particles" the brief warns
// is wrong. This file measures it, proves precisely why it is wrong with reproducible numbers,
// and states plainly what a real fix would require (which is a src/ change, out of scope here).
//
// RESULTS SUMMARY (full numbers and methodology in each TEST_CASE below and in
// knowledge/PERF-REPORT.md's dated entry -- this is the short version):
//   1. SPEED: naive index-range dispatch shows NO measurable speedup at 4, 8, or 16 threads
//      over threads=1, on this 8-core/16-thread Ryzen 3800X. At 16 threads it is consistently
//      flat-to-slightly-worse than threads=1, not better -- there is no "knee" to report other
//      than "immediately, at the first thread added". Caveat: this workload's own serial cost is
//      only ~2-4ms once system contention from other concurrently-running lanes/processes on
//      this shared box is controlled for (confirmed by cross-checking against Catch2's own
//      BENCHMARK harness on the same object in the same process) -- std::thread spawn/join
//      overhead alone is plausibly comparable in size to the workload itself at this scale, so
//      this result should NOT be read as "the underlying work has no parallelism to extract",
//      only as "this specific naive per-call-spawn dispatch extracts none".
//   2. CORRECTNESS, static/non-moving particles: the coarse per-CELL vx/vy/pv accumulator write
//      (`vx[cell] = vx[cell]*AirLoss + ...`) is a genuine unsynchronized concurrent
//      read-modify-write whenever a CELL's particles straddle a thread's index-partition
//      boundary (confirmed by construction: BRCK.cpp's AirLoss=0.90 make it an exact,
//      checkable closed-form multiply) -- but in EVERY run actually sampled here, it did not
//      produce an observably wrong number, likely because the race window is narrow relative to
//      this machine's thread-scheduling granularity. This is reported as a genuine but
//      NOT-EMPIRICALLY-DEMONSTRATED-WRONG race: still real undefined behaviour by the C++
//      memory model and still a live bug given different hardware/load/scheduling, but this
//      file's own measurements did not catch it red-handed on the static-particle case, which is
//      itself worth knowing (a quick benchmark of naive dispatch can look completely clean).
//   3. CORRECTNESS, moving particles (PT_SAND, real gravity/collision/pmap writes): DID catch it
//      red-handed. With sim->rng seeded identically across every run, the threads=1 serial
//      control reproduces the EXACT SAME final live-particle count on every separate process
//      launch (verified across >=3 launches), while threads=4/8/16 produce a DIFFERENT final
//      count on repeated launches of the byte-for-byte identical seeded scenario. This is
//      concrete, reproducible, non-speculative proof of nondeterminism caused specifically by
//      the parallel dispatch, not by SAND's own physics (which the fixed-seed control rules
//      out). Root cause by source inspection: MovementPhase's pmap writes, kill_part's
//      manipulation of Parts' free-list, and Parts::active are all unsynchronized shared mutable
//      state reachable from whichever thread happens to own a particle that moves into another
//      thread's territory -- there is no locking or atomicity anywhere in this path.
//
// BOTTOM LINE: the ONLY lever reachable from outside src/ (index-range dispatch of
// UpdateParticles) is unsafe -- proven, not just asserted -- and delivers no speed benefit even
// before considering safety. A genuine fix requires a src/ change: real spatial (not
// index-range) partitioning inside UpdateParticles itself, most plausibly built on
// @culling's already-in-progress chunkAwake/WakeChunk infrastructure (Simulation.h, read but not
// modified by this lane) since that is already a CELL-granularity active/inactive bookkeeping
// layer -- extending it to also gate which CELLs are safe to process on which thread this frame
// would need a proper 4-colour (2x2 phase) partitioning, not a simple 2-colour checkerboard: this
// file's own GetNeighbourhood read (Simulation.cpp) confirmed the dependency is a full
// Moore/8-connected neighbourhood, and a plain black/white checkerboard's same-colour cells are
// still diagonally adjacent to each other, which a Moore neighbourhood treats as a real
// dependency. That work is out of scope here (src/ is off-limits to this lane) and is reported to
// the orchestrator as a patch-spec recommendation, not implemented.
//
// File-ownership note (orchestrator correction, same session): this lane owns exactly ONE file
// in tests/, this one. A second file (test_parallel_danger.cpp, the MOVING-particle crash probe)
// was folded back in below rather than kept separate, and tests/meson.build was reverted to its
// pre-this-lane state -- that shared file belongs to @culling; the one-line source addition this
// lane needs (`'test_parallel.cpp',` in engine_tests_exe's sources list) is reported to the
// orchestrator to land, not applied here.

#include <catch2/catch_test_macros.hpp>
#include <catch2/benchmark/catch_benchmark.hpp>

#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/ElementClasses.h"
#include "simulation/Air.h"
#include "simulation/SimulationSettings.h"

#include <chrono>
#include <thread>
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace
{
	// Same helper as test_particle_perf.cpp (duplicated, not shared, per that file's own
	// pattern of self-contained TEST_CASE files). Row-major fill starting at (0,0): particle
	// array index i, for a freshly-cleared sim, is assigned sequentially by Parts::Alloc(), so
	// index i == placement order == (x=i%XRES, y=i/XRES). This is the BEST CASE for "does
	// index-range correlate with spatial region" -- deliberately chosen so the naive-parallel
	// approach gets its fairest possible hearing before being shown to still be unsafe.
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

	// Splits [0, active) into `threads` near-equal contiguous index ranges and calls
	// Simulation::UpdateParticles -- the ONLY public entry point into the per-particle loop --
	// concurrently across std::thread workers, all operating on the SAME Simulation instance
	// (same shared pmap/bmap/vx/vy/pv/parts arrays). This is the naive approach under test.
	void NaiveParallelUpdateParticles(Simulation &sim, int threads)
	{
		int active = sim.parts.active;
		if (threads <= 1)
		{
			sim.UpdateParticles(0, active);
			return;
		}
		std::vector<std::thread> workers;
		int chunk = (active + threads - 1) / threads;
		for (int t = 0; t < threads; ++t)
		{
			int start = t * chunk;
			int end = std::min(active, start + chunk);
			if (start >= end)
			{
				break;
			}
			workers.emplace_back([&sim, start, end] { sim.UpdateParticles(start, end); });
		}
		for (auto &w : workers)
		{
			w.join();
		}
	}

	double TimedNaiveParallelMs(Simulation &sim, int threads, int reps)
	{
		// Warm-up, same rationale as test_particle_perf.cpp / test_air_perf.cpp.
		NaiveParallelUpdateParticles(sim, threads);
		auto start = std::chrono::steady_clock::now();
		for (int i = 0; i < reps; ++i)
		{
			NaiveParallelUpdateParticles(sim, threads);
		}
		auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		return elapsed / reps;
	}

	// FNV-1a over the entire coarse air/pressure grid (vx, vy, pv -- YCELLS x XCELLS floats
	// each). Used as an exact-bytes determinism fingerprint: two runs of an IDENTICAL scenario
	// that disagree on this hash took different code paths somewhere, which for a fixed,
	// seeded, single-call scenario can only mean write-ordering differed -- i.e. a real data
	// race, not benchmark noise.
	uint64_t HashField(const Simulation &sim)
	{
		uint64_t h = 1469598103934665603ull;
		auto mix = [&](const void *p, size_t n)
		{
			auto bytes = static_cast<const unsigned char *>(p);
			for (size_t i = 0; i < n; ++i)
			{
				h ^= bytes[i];
				h *= 1099511628211ull;
			}
		};
		mix(sim.vx, sizeof(sim.vx));
		mix(sim.vy, sizeof(sim.vy));
		mix(sim.pv, sizeof(sim.pv));
		return h;
	}

	// Counts CELL-grid cells whose vx value does not equal the value a purely serial call would
	// have produced there. Every BRCK particle in a cell multiplies that cell's vx by AirLoss
	// (BRCK.cpp: AirDrag=0, AirLoss=0.90, so the per-particle write is exactly
	// `vx[cell] = vx[cell] * 0.90`, a classic unsynchronized read-modify-write). For a full CELL
	// (4x4 = 16 co-located particles, guaranteed for a block placed on a CELL-aligned origin),
	// the serially-correct result from a seeded vx0 is `vx0 * pow(0.90, 16)`. Any cell whose
	// final value differs from that closed form lost or duplicated at least one update --
	// direct, quantifiable proof of a lost-update race, not just "the number moved".
	struct FieldDivergence
	{
		int cellsChecked = 0;
		int cellsDiverged = 0;
	};

	FieldDivergence CheckVxAgainstSerialClosedForm(const Simulation &sim, float vx0, int cellsWide, int cellsHigh, int perCellCount)
	{
		FieldDivergence d;
		float expected = vx0;
		for (int k = 0; k < perCellCount; ++k)
		{
			expected *= 0.90f;
		}
		for (int cy = 0; cy < cellsHigh; ++cy)
		{
			for (int cx = 0; cx < cellsWide; ++cx)
			{
				++d.cellsChecked;
				// Small float tolerance for legitimate FP non-associativity of *serial*
				// re-ordering (there is none here -- BRCK's write is a pure scalar multiply
				// applied 16 times in a fixed serial order every time, so this is an exact
				// comparison, not a fuzzy one), kept anyway to avoid false positives from
				// unrelated float noise.
				if (std::abs(sim.vx[cy][cx] - expected) > 1e-6f * std::abs(expected))
				{
					++d.cellsDiverged;
				}
			}
		}
		return d;
	}
}

TEST_CASE("naive index-range parallel UpdateParticles: speed at 1/4/8/16 threads, static solid block, best-case index/spatial correlation", "[parallel][perf][!benchmark]")
{
	SimulationData sd;
	REQUIRE(sd.elements[PT_BRCK].Enabled == 1);
	REQUIRE(sd.elements[PT_BRCK].Falldown == 0);
	REQUIRE(sd.elements[PT_BRCK].Gravity == 0.0f);

	constexpr int representativeCount = 126290; // PERF-REPORT.md's live sample, same as test_particle_perf.cpp
	unsigned hw = std::thread::hardware_concurrency();
	INFO("std::thread::hardware_concurrency() reports: " << hw);

	for (int threads : { 1, 4, 8, 16 })
	{
		auto sim = Simulation::Factory();
		sim->air->airMode = AIR_NOUPDATE;
		int placed = FillBlock(*sim, PT_BRCK, representativeCount);
		REQUIRE(placed == representativeCount);
		REQUIRE(sim->parts.active == representativeCount);

		auto ms = TimedNaiveParallelMs(*sim, threads, 15);
		auto nsPerParticle = (ms * 1e6) / representativeCount;
		WARN("threads=" << threads << ": " << ms << " ms/call, " << nsPerParticle << " ns/particle ("
			<< representativeCount << " particles)");

		// Cross-check threads=1 against Catch2's OWN benchmark harness (the exact mechanism
		// test_particle_perf.cpp's headline ~16-19ms/call figures came from) on the SAME sim
		// object, same process, same moment -- this hand-rolled std::chrono loop reported a much
		// lower number than that file's harness-measured figures, and this resolves which one (or
		// whether both, under different system load) is real rather than reporting either
		// unreconciled.
		if (threads == 1)
		{
			BENCHMARK("cross-check: Catch2 harness, same sim object, threads=1 equivalent")
			{
				return sim->UpdateParticles(0, NPART), 0;
			};
		}
	}
}

TEST_CASE("naive index-range parallel UpdateParticles is NOT determinism-safe: same scenario, same thread count, two independent runs disagree", "[parallel][correctness][!benchmark]")
{
	// SimulationData is an ExplicitSingleton (src/common/ExplicitSingleton.h): its constructor
	// asserts no other instance is alive, and CRef()/Ref() dereference a raw pointer that is
	// null until exactly one instance exists. Constructing it here, once, for this TEST_CASE's
	// whole lifetime (matching test_particle_perf.cpp's and this file's speed TEST_CASE's own
	// pattern) is required before ANY create_part/element-property call -- omitting it is not a
	// threading bug, it is a null-pointer dereference, and this file's first draft made exactly
	// that mistake in this TEST_CASE and the boundary one below (caught via a fprintf/fflush
	// diagnostic bisection after an unexplained SIGSEGV that reproduced even at threads=1, i.e.
	// with no thread ever spawned -- proof it was never a race in the first place).
	SimulationData sd;
	// Seed every CELL the block will occupy with a nonzero vx so the per-particle write
	// (`vx[cell] = vx[cell]*0.90`) has something real to corrupt -- BRCK particles are created
	// with vx=0 by default, so without this seed every particle's own contribution is a no-op
	// multiply-by-zero and no race would be observable regardless of thread count.
	constexpr int representativeCount = 126290;
	constexpr float seedVx = 1.0f;
	constexpr int cellsWide = XCELLS; // block spans the full row width (612px / 4 = 153 cells)
	int fullRows = representativeCount / XRES; // rows entirely filled by the block
	int cellsHigh = fullRows / CELL; // only check fully-covered, fully-16-particle cells

	for (int threads : { 1, 4, 8, 16 })
	{
		auto simA = Simulation::Factory();
		auto simB = Simulation::Factory();
		for (auto *sim : { simA.get(), simB.get() })
		{
			sim->air->airMode = AIR_NOUPDATE;
			int placed = FillBlock(*sim, PT_BRCK, representativeCount);
			REQUIRE(placed == representativeCount);
			for (int cy = 0; cy < YCELLS; ++cy)
			{
				for (int cx = 0; cx < XCELLS; ++cx)
				{
					sim->vx[cy][cx] = seedVx;
				}
			}
		}

		NaiveParallelUpdateParticles(*simA, threads);
		NaiveParallelUpdateParticles(*simB, threads);

		auto hashA = HashField(*simA);
		auto hashB = HashField(*simB);

		// NOTE: an earlier draft of this TEST_CASE also compared each run against a hand-derived
		// closed form (vx0 * 0.90^16) and asserted zero divergence from it at threads=1. That
		// assertion was WRONG even for a pure single-threaded call -- the closed form didn't
		// account for UpdateParticles legitimately killing (not decaying) any particle within
		// CELL px of the grid edge, which this block's placement at origin (0,0) triggers for its
		// outermost cells regardless of threading. See the "races are localised to thread
		// partition boundaries" TEST_CASE below for the corrected version of that check (diffed
		// against an ACTUAL freshly-computed serial reference grid instead of a formula). This
		// TEST_CASE keeps only the hash-based A==B comparison below, which has no such flaw since
		// both sides go through identical code and only need to agree with EACH OTHER.
		WARN("threads=" << threads
			<< ": runA hash=" << hashA << " runB hash=" << hashB
			<< " | A==B: " << (hashA == hashB ? "yes" : "NO (nondeterministic)"));

		if (threads == 1)
		{
			// Single-thread dispatch is just a direct serial call -- must be bit-exact. This is
			// the control.
			REQUIRE(hashA == hashB);
		}
		else
		{
			// NOT asserting failure here (REQUIRE(divA.cellsDiverged > 0) would make this test
			// itself flaky if scheduling happens to avoid a boundary race on a given run) --
			// the point of this test is to OBSERVE and report divergence honestly, which the
			// WARN above does unconditionally. See this file's accompanying report entry in
			// knowledge/PERF-REPORT.md for the actual counts observed when this was run.
		}
	}
}

TEST_CASE("naive index-range parallel UpdateParticles with a MOVING powder block (PT_SAND, real gravity/collision/pmap writes)", "[parallel][correctness][.parallelmove]")
{
	// Folded in from this lane's former test_parallel_danger.cpp (see file-ownership note at the
	// top of this file). Everything above this TEST_CASE races only the coarse vx/vy/pv
	// accumulator on a STATIC (Falldown=0, Gravity=0.0f) block that never calls MovementPhase.
	// This is the case the brief calls out by name: "two particles racing for the same
	// destination cell" -- particles that actually MOVE, so MovementPhase and kill_part's
	// free-list/parts.active bookkeeping are exercised too.
	//
	// RESULT (see knowledge/PERF-REPORT.md for the full writeup): this did not crash in any run
	// observed, but it IS reproducibly non-deterministic -- with sim->rng seeded identically
	// across every run below, the threads=1 CONTROL produces the exact same final particle count
	// on every one of several separate process launches, while threads=4/8/16 produce a
	// DIFFERENT final count on every launch of the byte-for-byte identical scenario. That is the
	// concrete, reproducible proof this file set out to find: the parallel dispatch is not merely
	// theoretically racy, it observably diverges from run to run, which a single benchmark/smoke
	// run would not catch.
	//
	// Originally kept behind a hidden tag (`[.parallelmove]`, distinct from the `!benchmark`
	// reserved tag used elsewhere) anticipating a possible crash from kill_part/pmap corruption
	// under real movement; no crash occurred in this lane's testing, but the tag is left in place
	// since the risk described (unsynchronized kill_part free-list / parts.active / pmap writes,
	// all cited below) is real by source inspection even though this file's own runs didn't hit a
	// crash from it. A bare default run and the `[!benchmark]`-filtered run both still skip it;
	// select it explicitly with a `[parallelmove]` (or `[parallel]`) filter. Particle count kept
	// SMALL (5,000, not 126,290) to bound this experiment's own time/risk budget.
	SimulationData sd;
	REQUIRE(sd.elements[PT_SAND].Enabled == 1);
	REQUIRE(sd.elements[PT_SAND].Falldown == 1); // confirms this element actually moves, unlike BRCK

	constexpr int count = 5000;
	constexpr int ticks = 20;

	auto countLive = [](const Simulation &s)
	{
		int n = 0;
		for (int i = 0; i < s.parts.active; ++i)
		{
			if (s.parts[i].type != PT_NONE)
			{
				++n;
			}
		}
		return n;
	};

	// threads=1 is the CONTROL -- a plain serial run of the identical scenario (same seed count,
	// same placement, same tick count), so any particle-count change seen at threads>1 below can
	// be attributed to the parallel dispatch specifically, not to SAND's ordinary fall/settle
	// behaviour losing particles on its own (e.g. off-grid kill at a boundary it wanders into).
	for (int threads : { 1, 4, 8, 16 })
	{
		auto sim = Simulation::Factory();
		// Fixed seed, identical across every thread count -- Simulation's RNG is otherwise seeded
		// per-instance (not fixed), which independently confounds any before/after comparison
		// across separately-constructed sims (SAND's own movement math consumes rng draws), so
		// without this line a delta difference between threads=1 and threads>1 cannot be
		// attributed to the parallel dispatch specifically. Caught by re-running this file twice
		// and observing the threads=1 CONTROL itself reporting a different delta each process
		// launch before this fix.
		sim->rng.seed(12345);
		sim->air->airMode = AIR_NOUPDATE;
		// Placed away from the grid's own edges (100,100) so no particle starts within a kill zone
		// (UpdateParticles kills particles within CELL px of the grid edge), isolating the scenario
		// to movement/collision-driven kills, not edge artifacts.
		int placed = 0;
		{
			int originX = 100, originY = 100;
			for (int y = originY; y < YRES && placed < count; ++y)
			{
				for (int x = originX; x < XRES && placed < count; ++x)
				{
					if (sim->create_part(-1, x, y, PT_SAND) >= 0)
					{
						++placed;
					}
				}
			}
		}
		REQUIRE(placed == count);

		int before = countLive(*sim);

		for (int tick = 0; tick < ticks; ++tick)
		{
			NaiveParallelUpdateParticles(*sim, threads);
		}

		int after = countLive(*sim);
		WARN("threads=" << threads << ": live particles before=" << before << " after " << ticks
			<< " ticks: after=" << after << " (delta=" << (after - before) << ")"
			<< (threads == 1 ? " [CONTROL -- serial]" : ""));

		// Not a REQUIRE on the delta being zero at threads>1 -- SAND piling up can legitimately
		// leave the count unchanged even seriall, so any DIFFERENCE from the threads=1 control is
		// what matters, reported via WARN unconditionally. Whether this loop iteration is even
		// reached at all (vs the process crashing first) is itself part of the finding, captured
		// by this test binary's own exit code when invoked standalone.
	}
	SUCCEED("reached end of test without the process crashing (see WARN above for whether particle count also stayed sane at each thread count)");
}

TEST_CASE("naive index-range parallel UpdateParticles races are localised to thread partition boundaries, not spread across the whole grid", "[parallel][correctness][!benchmark]")
{
	// See the determinism TEST_CASE above for why this line is required (ExplicitSingleton;
	// without it every create_part/element-property call below null-derefs SimulationData::CRef()).
	SimulationData sd;
	// Directly answers "how bad is it" -- most CELL groups (16 co-located particles) fall
	// entirely within one thread's contiguous index range and are therefore untouched by any
	// race; only cells whose 16 particles straddle a `start`/`end` partition boundary between
	// two threads can lose an update.
	//
	// FIRST DRAFT of this test compared against a hand-derived closed form (vx0 * 0.90^16) and
	// found the SAME divergence count (253 cells) at threads=1 (pure serial, no race possible at
	// all) as at threads=4/8/16 -- proving the closed form itself was wrong, not that races don't
	// localise. Root cause, confirmed by hand: UpdateParticles kills any particle within CELL
	// (4px) of the grid edge (Simulation.cpp's `x<CELL || y<CELL || x>=XRES-CELL || y>=YRES-CELL`
	// check) BEFORE it can execute its own `vx[cell]*=0.90` write, and this block is placed
	// starting at (0,0) -- so cy=0 (top edge) and the leftmost/rightmost cell columns are killed,
	// not decayed, on the very first call, identically regardless of thread count. 153+51+51-2=253
	// (top row + left column + right column, minus the two corners counted twice) is exactly the
	// observed number -- a real, correct, non-race effect that a closed-form guess without
	// accounting for it will misreport as "no extra divergence anywhere", which is itself
	// misleading (it doesn't mean boundaries are safe, it means this test wasn't checking the
	// right cells: mid-block, the actual index/612-per-row arithmetic put the real thread
	// boundaries around cell-row ~51, outside the first draft's checked cellsHigh=51 range
	// entirely).
	//
	// REWRITTEN to compare against an ACTUAL freshly-computed threads=1 reference grid (not a
	// hand-derived formula), so edge-kill and every other legitimate non-race effect is
	// automatically identical between reference and test and cancels out -- any remaining
	// difference is attributable to the parallel dispatch specifically.
	constexpr int representativeCount = 126290;
	constexpr float seedVx = 1.0f;

	auto buildSeededSim = [&]
	{
		auto sim = Simulation::Factory();
		sim->air->airMode = AIR_NOUPDATE;
		int placed = FillBlock(*sim, PT_BRCK, representativeCount);
		REQUIRE(placed == representativeCount);
		for (int cy = 0; cy < YCELLS; ++cy)
		{
			for (int cx = 0; cx < XCELLS; ++cx)
			{
				sim->vx[cy][cx] = seedVx;
			}
		}
		return sim;
	};

	auto reference = buildSeededSim();
	NaiveParallelUpdateParticles(*reference, 1); // pure serial -- the ground truth to diff against

	for (int threads : { 4, 8, 16 })
	{
		// Report exactly where this thread count's partition boundaries land, in (x,y) pixel
		// coords, so a divergent cell can be cross-checked against them directly instead of by an
		// inferred count.
		int chunk = (representativeCount + threads - 1) / threads;
		std::string boundaries;
		for (int t = 1; t < threads; ++t)
		{
			int idx = std::min(representativeCount, t * chunk);
			if (idx >= representativeCount) break;
			int bx = idx % XRES, by = idx / XRES;
			boundaries += " (" + std::to_string(bx) + "," + std::to_string(by) + ")";
		}

		auto sim = buildSeededSim();
		NaiveParallelUpdateParticles(*sim, threads);

		int diverged = 0, checked = 0;
		std::string sample;
		for (int cy = 0; cy < YCELLS; ++cy)
		{
			for (int cx = 0; cx < XCELLS; ++cx)
			{
				++checked;
				if (std::abs(sim->vx[cy][cx] - reference->vx[cy][cx]) > 1e-6f)
				{
					++diverged;
					if (sample.size() < 200)
					{
						sample += " (" + std::to_string(cx * CELL) + "," + std::to_string(cy * CELL) + ")";
					}
				}
			}
		}

		WARN("threads=" << threads << ": diverged cells vs true serial reference=" << diverged << "/" << checked
			<< " | partition boundaries at (x,y)=" << boundaries
			<< " | first diverged cell origins:" << sample);
	}
}
