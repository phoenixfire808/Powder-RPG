#pragma once
#include "Icons.h"
#include "gui/interface/Point.h"
#include "common/Plane.h"
#include "SimulationConfig.h"
#include "RasterDrawMethods.h"
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
};
