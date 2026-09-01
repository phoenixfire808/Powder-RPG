// Catch2 tests for Graphics::GetCamZoomTransform / CamZoomTransform.
//
// Regression context (Powder RPG, camZoom feature): the sim-image blit
// (GameView::OnDraw), the brush/shape preview overlay, and screen->sim mouse
// mapping (GameModel::ResolveZoomedPoint) each need to agree on exactly where
// the zoomed world is on screen. Before GetCamZoomTransform existed, the blit
// computed this rectangle inline and the other two never computed it at
// all -- the brush cursor and click position silently drifted from the
// magnified view. This is a pure function over Graphics::camZoom/camZoomFocus
// with no rendering or window dependency, so it is tested directly here
// rather than by pixel comparison.

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "graphics/Graphics.h"
#include "graphics/RendererFrame.h"

#include <cmath>
#include <cstdlib>
#include <memory>

TEST_CASE("GetCamZoomTransform is the identity when camZoom is 1 (unzoomed)", "[graphics][camzoom]")
{
	auto g = std::make_unique<Graphics>();
	REQUIRE(g->camZoom == 1.0f);

	auto xform = g->GetCamZoomTransform();
	REQUIRE(xform.z == 1.0f);
	REQUIRE(xform.ox == 0.0f);
	REQUIRE(xform.oy == 0.0f);

	// Every screen point maps straight through to the same sim point and back --
	// this is the "verbatim copy, byte for byte" no-op path the camZoom comment
	// in Graphics.h promises.
	for (auto p : { ui::Point(0, 0), ui::Point(50, 40), ui::Point(RendererFrameSize.X - 1, RendererFrameSize.Y - 1) })
	{
		REQUIRE(xform.ScreenToSim(p) == p);
		REQUIRE(xform.SimToScreen(p) == p);
	}
}

TEST_CASE("GetCamZoomTransform centres on the screen when no focus is set", "[graphics][camzoom]")
{
	auto g = std::make_unique<Graphics>();
	g->camZoom = 2.0f;
	// camZoomFocus defaults to (-1, -1): "use the centre of the screen".
	REQUIRE(g->camZoomFocus == ui::Point(-1, -1));

	auto xform = g->GetCamZoomTransform();
	REQUIRE(xform.z == 2.0f);

	// At 2x, centred, the sampled region is a quarter of the frame (half width,
	// half height) with its top-left a quarter of the way in from each edge.
	float expectedOx = RendererFrameSize.X * 0.25f;
	float expectedOy = RendererFrameSize.Y * 0.25f;
	REQUIRE(xform.ox == Catch::Approx(expectedOx).margin(1.0f));
	REQUIRE(xform.oy == Catch::Approx(expectedOy).margin(1.0f));

	// The screen centre must map back to the sim-space centre (the focus point).
	ui::Point screenCentre(RendererFrameSize.X / 2, RendererFrameSize.Y / 2);
	ui::Point simCentre = xform.ScreenToSim(screenCentre);
	REQUIRE(std::abs(simCentre.X - RendererFrameSize.X / 2) <= 1);
	REQUIRE(std::abs(simCentre.Y - RendererFrameSize.Y / 2) <= 1);
}

TEST_CASE("GetCamZoomTransform round-trips screen points at various zoom levels", "[graphics][camzoom]")
{
	// A brush drawn via SimToScreen after the click position was resolved via
	// ScreenToSim (see GameModel::ResolveZoomedPoint and the brush overlay in
	// GameView::OnDraw) must land back close to where the mouse actually is,
	// or the cursor box drifts from the cursor -- the exact bug reported.
	for (float z : { 1.0f, 1.5f, 2.0f, 3.0f, 4.0f })
	{
		auto g = std::make_unique<Graphics>();
		g->camZoom = z;
		auto xform = g->GetCamZoomTransform();
		REQUIRE(xform.z == z);

		for (auto screenPoint : { ui::Point(10, 10), ui::Point(300, 190), ui::Point(600, 380) })
		{
			ui::Point simPoint = xform.ScreenToSim(screenPoint);
			ui::Point roundTripped = xform.SimToScreen(simPoint);
			// Nearest-neighbor sampling means this isn't exact, but it must stay
			// within a whole zoomed-out pixel of the original click.
			REQUIRE(std::abs(roundTripped.X - screenPoint.X) <= int(z) + 1);
			REQUIRE(std::abs(roundTripped.Y - screenPoint.Y) <= int(z) + 1);
		}
	}
}

TEST_CASE("GetCamZoomTransform clamps the sampled region at the simulation edges", "[graphics][camzoom][edge]")
{
	// Focusing near a map edge must not sample outside the frame -- this is
	// the "test at a map edge, not just centre-screen" case: a naive
	// (unclamped) transform would compute a negative ox/oy here, which would
	// let ScreenToSim return sim coordinates that read outside the sim grid.
	auto g = std::make_unique<Graphics>();
	g->camZoom = 4.0f;
	g->camZoomFocus = ui::Point(0, 0); // pinned to the top-left corner

	auto xform = g->GetCamZoomTransform();
	REQUIRE(xform.ox >= 0.0f);
	REQUIRE(xform.oy >= 0.0f);
	REQUIRE(xform.ox + RendererFrameSize.X / xform.z <= RendererFrameSize.X + 0.01f);
	REQUIRE(xform.oy + RendererFrameSize.Y / xform.z <= RendererFrameSize.Y + 0.01f);

	// Every screen point must resolve to a sim point inside the frame.
	for (auto p : { ui::Point(0, 0), ui::Point(RendererFrameSize.X - 1, RendererFrameSize.Y - 1) })
	{
		ui::Point sim = xform.ScreenToSim(p);
		REQUIRE(sim.X >= 0);
		REQUIRE(sim.Y >= 0);
		REQUIRE(sim.X < RendererFrameSize.X);
		REQUIRE(sim.Y < RendererFrameSize.Y);
	}

	// Same check pinned to the bottom-right corner.
	auto g2 = std::make_unique<Graphics>();
	g2->camZoom = 4.0f;
	g2->camZoomFocus = ui::Point(RendererFrameSize.X - 1, RendererFrameSize.Y - 1);
	auto xform2 = g2->GetCamZoomTransform();
	REQUIRE(xform2.ox + RendererFrameSize.X / xform2.z <= RendererFrameSize.X + 0.01f);
	REQUIRE(xform2.oy + RendererFrameSize.Y / xform2.z <= RendererFrameSize.Y + 0.01f);
	for (auto p : { ui::Point(0, 0), ui::Point(RendererFrameSize.X - 1, RendererFrameSize.Y - 1) })
	{
		ui::Point sim = xform2.ScreenToSim(p);
		REQUIRE(sim.X >= 0);
		REQUIRE(sim.Y >= 0);
		REQUIRE(sim.X < RendererFrameSize.X);
		REQUIRE(sim.Y < RendererFrameSize.Y);
	}
}
