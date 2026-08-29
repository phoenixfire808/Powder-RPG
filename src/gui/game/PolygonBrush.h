#pragma once
#include "Brush.h"
#include <cmath>
#include <vector>
#include <utility>

// Regular N-gon brush (pentagon, hexagon, ...) parametrized by side count
// instead of a near-duplicate file per shape -- the point-in-polygon math
// doesn't change, only N does. Requested to round out the brush shapes
// after RimWorld's Designator Shapes mod (pentagon/hexagon among its
// shapes; circle/rectangle/triangle/line/fill/undo already existed here).
class PolygonBrush: public Brush
{
	int sides;

public:
	explicit PolygonBrush(int newSides): sides(newSides) {}
	virtual ~PolygonBrush() override = default;

	PlaneAdapter<std::vector<unsigned char>> GenerateBitmap() const override
	{
		ui::Point size = radius * 2 + Vec2{ 1, 1 };
		PlaneAdapter<std::vector<unsigned char>> bitmap(size);

		int rx = radius.X;
		int ry = radius.Y;
		constexpr double pi = 3.14159265358979323846;
		// Vertices of a regular N-gon inscribed in the unit circle, point
		// facing up -- points get normalized into this same unit-circle
		// space below so an elongated (rx != ry) brush still works.
		std::vector<std::pair<double, double>> verts(sides);
		for (int k = 0; k < sides; k++)
		{
			double angle = -pi / 2 + 2 * pi * k / sides;
			verts[k] = { std::cos(angle), std::sin(angle) };
		}

		for (int x = -rx; x <= rx; x++)
		{
			for (int y = -ry; y <= ry; y++)
			{
				double nx = rx ? double(x) / rx : 0.0;
				double ny = ry ? double(y) / ry : 0.0;
				bool inside = true;
				for (int k = 0; k < sides; k++)
				{
					auto &a = verts[k];
					auto &b = verts[(k + 1) % sides];
					double cross = (b.first - a.first) * (ny - a.second) - (b.second - a.second) * (nx - a.first);
					if (cross < 0)
					{
						inside = false;
						break;
					}
				}
				bitmap[{ x + rx, y + ry }] = inside ? 255 : 0;
			}
		}
		return bitmap;
	}

	std::unique_ptr<Brush> Clone() const override
	{
		return std::make_unique<PolygonBrush>(*this);
	}
};
