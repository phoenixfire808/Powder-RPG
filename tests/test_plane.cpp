// Catch2 tests for engine primitives.
//
// Targets chosen deliberately: PlaneAdapter is the row-major grid abstraction the
// simulation is built on, and String::ToNumber is a real engine error path. Both are
// header-only, so this test links without dragging in the renderer or the sim.
//
// Covers the three things the workflow doc asks for:
//   * BDD macros        - SCENARIO / GIVEN / WHEN / THEN
//   * BENCHMARK         - with an asserted bar, so a regression FAILS
//   * REQUIRE_THROWS_AS - error-path validation

#include <catch2/catch_test_macros.hpp>
#include <catch2/benchmark/catch_benchmark.hpp>

#include <chrono>
#include <numeric>
#include <stdexcept>
#include <vector>

#include "common/Plane.h"
#include "common/String.h"
#include "graphics/Graphics.h"

#include <memory>

using Grid = PlaneAdapter<std::vector<int>>;

// ---------------------------------------------------------------- BDD

SCENARIO("a grid stores cells in row-major order", "[plane][bdd]")
{
	GIVEN("a 4x3 grid filled with zeroes")
	{
		Grid grid(Vec2<int>(4, 3), 0);

		REQUIRE(grid.Size() == Vec2<int>(4, 3));

		WHEN("a cell in the middle is written")
		{
			grid[Vec2<int>(2, 1)] = 7;

			THEN("only that cell changes")
			{
				REQUIRE(grid[Vec2<int>(2, 1)] == 7);
				REQUIRE(grid[Vec2<int>(1, 1)] == 0);
				REQUIRE(grid[Vec2<int>(2, 0)] == 0);
			}

			THEN("it lands at index x + y*width in the flat backing store")
			{
				// This is the cache-coherency contract the simulation depends on.
				// If the layout ever stops being row-major, every hot loop regresses.
				REQUIRE(grid.data()[2 + 1 * 4] == 7);
			}
		}

		WHEN("the grid is resized")
		{
			grid.SetSize(Vec2<int>(2, 6));

			THEN("the reported size follows and the cell count is preserved")
			{
				REQUIRE(grid.Size() == Vec2<int>(2, 6));
				REQUIRE(grid.Base.size() == 12u);
			}
		}
	}
}

SCENARIO("temperatures parse from strings", "[string][bdd]")
{
	GIVEN("a numeric string")
	{
		String s = String("451");

		WHEN("it is converted to a number")
		{
			int v = s.ToNumber<int>();

			THEN("the value round-trips")
			{
				REQUIRE(v == 451);
			}
		}
	}
}

// ------------------------------------------------- error paths (throws)

TEST_CASE("String::ToNumber rejects non-numeric input", "[string][throws]")
{
	// Real engine error path: parsing user/save-supplied text.
	REQUIRE_THROWS_AS(String("not-a-number").ToNumber<int>(), std::runtime_error);
	REQUIRE_THROWS_AS(String("").ToNumber<int>(), std::runtime_error);

	// The noThrow overload must NOT throw - it is the guarded path callers rely on.
	REQUIRE_NOTHROW(String("not-a-number").ToNumber<int>(true));
	REQUIRE(String("not-a-number").ToNumber<int>(true) == 0);
}

TEST_CASE("vector-backed grid bounds are checked via at()", "[plane][throws]")
{
	Grid grid(Vec2<int>(4, 3), 0);
	// operator[] is deliberately unchecked on the hot path; .at() on the backing
	// store is the checked accessor, and it must still guard the real extent.
	REQUIRE_NOTHROW(grid.Base.at(11));
	REQUIRE_THROWS_AS(grid.Base.at(12), std::out_of_range);
}

// ------------------------------------------------------------ benchmark

TEST_CASE("row-major traversal meets its performance bar", "[plane][!benchmark]")
{
	constexpr int W = 512, H = 512;
	Grid grid(Vec2<int>(W, H), 1);

	// Assert the bar, rather than merely printing a number. Row-major traversal of
	// 262k ints must stay well under a 60fps frame budget (16.6ms). Measured ~3.5ms on
	// this dev box; the bar is 8ms so a loaded CI runner will not flake, while a
	// catastrophic regression (column-major layout, bounds checks on the hot path,
	// accidental debug build) is 2-10x and still trips it.
	// ponytail: wall-clock bar, not a statistical model. Catch2's BENCHMARK below tracks the real number.
	auto sumRowMajor = [&]
	{
		long long acc = 0;
		for (int y = 0; y < H; ++y)
			for (int x = 0; x < W; ++x)
				acc += grid[Vec2<int>(x, y)];
		return acc;
	};

	REQUIRE(sumRowMajor() == static_cast<long long>(W) * H);

	auto start = std::chrono::steady_clock::now();
	constexpr int reps = 20;
	long long guard = 0;
	for (int i = 0; i < reps; ++i) guard += sumRowMajor();
	auto elapsedMs = std::chrono::duration<double, std::milli>(
		std::chrono::steady_clock::now() - start).count() / reps;

	REQUIRE(guard > 0); // keep the loop from being optimised away
	INFO("row-major traversal averaged " << elapsedMs << " ms/pass over " << reps << " passes");
	REQUIRE(elapsedMs < 8.0);

	// Catch2's own micro-benchmark, for tracking the number over time.
	BENCHMARK("row-major 512x512 sum")
	{
		return sumRowMajor();
	};
}

// -------------------------------------------------- RenderZoom OOB regression

TEST_CASE("RenderZoom does not walk its scaling loop past the video buffer", "[graphics][zoom][throws]")
{
	// Regression test for the crash in Graphics::RenderZoom (crash.log:
	// "Memory read/write error" in RenderZoom+0x5da, called from GameView::OnDraw).
	//
	// zoomWindowPosition and ZFACTOR are persisted across restarts (GameModel::LoadPrefs)
	// and each gets clamped independently -- position to the screen edges, ZFACTOR to
	// [1,200] -- with no relation to the other. zoomScopeSize is NOT persisted, so it
	// resets to its compiled-in default (32) on every launch. A ZFACTOR saved from a
	// session that used a small zoomScopeSize therefore combines, on the next launch,
	// with a zoomWindowPosition that was only ever valid for a much smaller box.
	//
	// The old loop wrote straight into `video[]` with no bounds check, so
	// boxSide = zoomScopeSize * ZFACTOR could put the destination index millions of
	// pixels past the end of the buffer.
	auto g = std::make_unique<Graphics>();
	g->zoomEnabled = true;
	g->zoomWindowVisible = true;
	g->zoomScopeSize = 32;             // fresh-launch default, not persisted
	g->ZFACTOR = 200;                  // max value the prefs-load clamp (GameModel.cpp) allows
	g->zoomWindowPosition = { 0, 0 };  // perfectly in-bounds for a small box
	g->zoomScopePosition = { 0, 0 };

	int boxSide = g->zoomScopeSize * g->ZFACTOR;
	REQUIRE(boxSide == 6400);
	// The far corner of the (unclamped) box lands nowhere near the WINDOW.X x WINDOW.Y
	// buffer this reads and writes through -- this is the actual overflow.
	REQUIRE(g->zoomWindowPosition.X + boxSide > g->Size().X);
	REQUIRE(g->zoomWindowPosition.Y + boxSide > g->Size().Y);

	// Must complete without corrupting memory or crashing the process.
	REQUIRE_NOTHROW(g->RenderZoom());
}
