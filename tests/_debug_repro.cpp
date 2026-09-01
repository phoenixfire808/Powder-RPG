// @perf_terrain scratch diagnostic -- NOT a deliverable. Flagged to @culling (owner of
// tests/meson.build) for removal from the sources list; kept minimal on purpose. Measures
// the FULL-census (GOO+GRSS-proxy+non-terrain, 121341 particles) steady-state UpdateParticles
// cost via plain chrono timing rather than Catch2's BENCHMARK macro, after the BENCHMARK-based
// version in test_terrainlayer.cpp crashed reproducibly (SIGSEGV) at this exact particle
// count/composition while 25 plain sequential UpdateParticles() calls on the identical scene
// completed cleanly -- narrowing the crash to Catch2's benchmark harness at this scale, not to
// UpdateParticles itself. See knowledge/design-terrain-layer.md for how this number is used.
//
// STILL REFERENCED BY tests/meson.build as of this write -- restored after being deleted by
// mistake (this lane does not own meson.build and cannot safely remove its own line there;
// deleting the file while the line remained would have broken every lane's build). @culling:
// please drop the '_debug_repro.cpp' line from sources: files(...) and this file can then be
// deleted safely by anyone.
#include <catch2/catch_test_macros.hpp>
#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/ElementClasses.h"
#include "simulation/Air.h"
#include <cstdio>
#include <chrono>

namespace {
int FillBlockFrom2(Simulation &sim, int t, int count, int startY)
{
	int placed = 0;
	for (int y = startY; y < YRES && placed < count; ++y)
		for (int x = 0; x < XRES && placed < count; ++x)
			if (sim.create_part(-1, x, y, t) >= 0) ++placed;
	return placed;
}
}

TEST_CASE("debug repro full census timed", "[debugrepro]")
{
	SimulationData sd;
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	constexpr int gooCount = 68273;
	constexpr int grssCount = 30864;
	constexpr int remainderCount = 22204;
	int placedGoo = FillBlockFrom2(*sim, PT_GOO, gooCount, 0);
	int startY2 = gooCount / XRES;
	int placedGrss = FillBlockFrom2(*sim, PT_BRCK, grssCount, startY2);
	int startY3 = (gooCount + grssCount) / XRES;
	int placedRem = FillBlockFrom2(*sim, PT_WOOD, remainderCount, startY3);
	fprintf(stderr, "placed goo=%d grss=%d rem=%d total=%d\n", placedGoo, placedGrss, placedRem,
		placedGoo + placedGrss + placedRem);
	fflush(stderr);

	for (int i = 0; i < 3; ++i)
	{
		sim->UpdateParticles(0, NPART);
	}

	constexpr int reps = 20;
	auto start = std::chrono::steady_clock::now();
	for (int i = 0; i < reps; ++i)
	{
		sim->UpdateParticles(0, NPART);
	}
	auto elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	fprintf(stderr, "FULL census (121341), steady-state avg over %d calls: %f ms/call\n", reps, elapsedMs / reps);
	fflush(stderr);

	REQUIRE(true);
}

TEST_CASE("debug repro BRCK-only steady state timed", "[debugrepro]")
{
	SimulationData sd;
	auto sim = Simulation::Factory();
	sim->air->airMode = AIR_NOUPDATE;
	constexpr int grssCount = 30864;
	int placed = FillBlockFrom2(*sim, PT_BRCK, grssCount, 0);
	fprintf(stderr, "placed brck=%d\n", placed);
	fflush(stderr);

	auto c0 = std::chrono::steady_clock::now();
	sim->UpdateParticles(0, NPART);
	auto coldMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - c0).count();
	fprintf(stderr, "BRCK cold (call 1): %f ms\n", coldMs);
	fflush(stderr);

	constexpr int reps = 20;
	auto start = std::chrono::steady_clock::now();
	for (int i = 0; i < reps; ++i)
	{
		sim->UpdateParticles(0, NPART);
	}
	auto elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	fprintf(stderr, "BRCK(%d) warm/steady-state avg over %d calls: %f ms/call\n", grssCount, reps, elapsedMs / reps);
	fflush(stderr);

	REQUIRE(true);
}
