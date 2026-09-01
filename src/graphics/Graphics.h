#pragma once
#include "Icons.h"
#include "gui/interface/Point.h"
#include "common/Plane.h"
#include "SimulationConfig.h"
#include "RasterDrawMethods.h"
#include "RendererFrame.h"
#include <array>

class Graphics: public RasterDrawMethods<Graphics>
{
	PlaneAdapter<std::array<pixel, WINDOW.X * WINDOW.Y>, WINDOW.X, WINDOW.Y> video;
	Rect<int> clipRect = video.Size().OriginRect();

	friend struct RasterDrawMethods<Graphics>;

public:
	Vec2<int> Size() const
	{
		return video.Size();
	}

	pixel const *Data() const
	{
		return video.data();
	}

	pixel *Data()
	{
		return video.data();
	}

	VideoBuffer DumpFrame();

	void draw_icon(int x, int y, Icon icon, unsigned char alpha = 255, bool invert = false);

	void Finalise();

	Graphics();

	void SwapClipRect(Rect<int> &);

	Rect<int> GetClipRect() const
	{
		return clipRect;
	}

	ui::Point zoomWindowPosition = { 0, 0 };
	ui::Point zoomScopePosition = { 0, 0 };
	int zoomScopeSize = 32;
	bool zoomEnabled = false;
	// Separate from zoomEnabled: true only once the user has clicked to fix
	// the zoom window in place. While the zoom tool is active but not yet
	// placed, the window tracks the cursor invisibly instead of drawing a
	// big box that follows the mouse around the screen -- see RenderZoom.
	bool zoomWindowVisible = false;
	int ZFACTOR = 8;
	void RenderZoom();

	// Whole-view camera zoom, distinct from the RenderZoom magnifier box above.
	// The magnifier blits a small scope into a box on top of a 1:1 world; this
	// instead scales the entire simulation image as it is copied into the screen
	// buffer, so the world itself gets bigger. Applied in GameView::OnDraw at the
	// single point the rendered sim frame is copied in -- everything drawn after
	// that (UI, HUD, Lua drawText) lands on top at 1:1 and stays crisp.
	//
	// 1.0 means "copy verbatim" and takes the original code path exactly, so this
	// is inert unless something deliberately raises it.
	float camZoom = 1.0f;
	// Focus point in sim coords that stays put as zoom changes. Negative means
	// "use the centre of the screen", which is where the RPG keeps the player.
	ui::Point camZoomFocus = { -1, -1 };

	// The sampling rectangle camZoom reads from the rendered sim frame: a
	// source region `w` x `h` sim pixels wide, top-left at (ox, oy), stretched
	// to fill the whole frame at scale `z`. Computed once per frame from
	// camZoom/camZoomFocus and shared by everyone who needs to agree on where
	// the zoomed world actually is on screen:
	//  - GameView::OnDraw, copying the rendered sim into the screen buffer
	//  - GameView::OnDraw's brush/shape overlay, so the cursor box and brush
	//    preview land on, and scale with, the same magnified world
	//  - GameModel::ResolveZoomedPoint, mapping mouse clicks back to sim space
	// Before this existed each of those recomputed (or, for the brush and
	// input cases, simply never computed) this rectangle independently, which
	// is how the brush cursor and click position drifted from the zoomed view.
	struct CamZoomTransform
	{
		float z = 1.0f;
		float ox = 0.0f, oy = 0.0f;

		// Raw screen pixel (e.g. a mouse position) -> sim-space point.
		ui::Point ScreenToSim(ui::Point screen) const
		{
			return ui::Point(int(ox + screen.X / z), int(oy + screen.Y / z));
		}

		// Sim-space point (e.g. a brush centre) -> the screen pixel it lands on
		// once the sim frame is copied into the screen buffer.
		ui::Point SimToScreen(ui::Point sim) const
		{
			return ui::Point(int((sim.X - ox) * z + 0.5f), int((sim.Y - oy) * z + 0.5f));
		}
	};

	CamZoomTransform GetCamZoomTransform() const
	{
		CamZoomTransform t;
		if (camZoom <= 1.0f)
		{
			return t; // identity: z == 1, ox == oy == 0, matches the verbatim copy path
		}
		t.z = camZoom;
		constexpr auto srcSize = RendererFrameSize;
		// Focus defaults to screen centre, which is where the RPG parks the player.
		const float fx = camZoomFocus.X >= 0 ? float(camZoomFocus.X) : srcSize.X * 0.5f;
		const float fy = camZoomFocus.Y >= 0 ? float(camZoomFocus.Y) : srcSize.Y * 0.5f;
		// Top-left of the source region that fills the screen, clamped so the view
		// never runs off the simulation and shows garbage at the edges.
		float w = srcSize.X / t.z, h = srcSize.Y / t.z;
		t.ox = fx - w * 0.5f;
		t.oy = fy - h * 0.5f;
		if (t.ox < 0) t.ox = 0; else if (t.ox + w > srcSize.X) t.ox = srcSize.X - w;
		if (t.oy < 0) t.oy = 0; else if (t.oy + h > srcSize.Y) t.oy = srcSize.Y - h;
		return t;
	}
};
