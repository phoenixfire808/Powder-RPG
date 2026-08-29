#pragma once
#include "Brush.h"
#include "graphics/Graphics.h"
#include <cmath>
#include <algorithm>

class EllipseBrush: public Brush
{
	bool perfectCircle;

public:
	EllipseBrush(bool newPerfectCircle) :
		perfectCircle(newPerfectCircle)
	{
	}
	virtual ~EllipseBrush() override = default;

	PlaneAdapter<std::vector<unsigned char>> GenerateBitmap() const override
	{
		ui::Point size = radius * 2 + Vec2{ 1, 1 };
		PlaneAdapter<std::vector<unsigned char>> bitmap(size);

		int rx = radius.X;
		int ry = radius.Y;

		if (!rx)
		{
			for (int j = 0; j <= 2*ry; j++)
			{
				bitmap[{ rx, j }] = 255;
			}
		}
		else
		{
			int yTop = ry+1, yBottom, i;
			for (i = 0; i <= rx; i++)
			{
				if (perfectCircle)
				{
					while (pow(i - rx, 2.0) * pow(ry - 0.5, 2.0) + pow(yTop - ry, 2.0) * pow(rx - 0.5, 2.0) <= pow(rx, 2.0) * pow(ry, 2.0))
						yTop++;
				}
				else
				{
					while (pow(i - rx, 2.0) * pow(ry, 2.0) + pow(yTop - ry, 2.0) * pow(rx, 2.0) <= pow(rx, 2.0) * pow(ry, 2.0))
						yTop++;
				}
				yBottom = 2*ry - yTop;
				for (int j = 0; j <= ry*2; j++)
				{
					if (j > yBottom && j < yTop)
					{
						bitmap[{ i, j }] = 255;
						bitmap[{ 2*rx-i, j }] = 255;
					}
					else
					{
						bitmap[{ i, j }] = 0;
						bitmap[{ 2*rx-i, j }] = 0;
					}
				}
			}
			bitmap[{ size.X/2, 0 }] = 255;
			bitmap[{ size.X/2, size.Y-1 }] = 255;
		}
		return bitmap;
	}

	std::unique_ptr<Brush> Clone() const override
	{
		return std::make_unique<EllipseBrush>(*this);
	}

	bool IsEllipseShaped() const override { return true; }
	bool IsPerfectCircle() const override { return perfectCircle; }

	// Ellipse outline preview for the Ctrl+drag region-fill tool, matching
	// the actual ellipse Simulation::CreateEllipse fills -- the base
	// Brush::RenderRect always draws a rectangle, which would preview the
	// wrong shape for this brush.
	void RenderRect(Graphics *g, ui::Point position1, ui::Point position2) const override
	{
		if (perfectCircle)
		{
			// Match Simulation::CreateEllipse: keep position1 (the drag's
			// start point) fixed as a true corner and grow toward
			// position2's direction, instead of recentring on the drag
			// box's midpoint -- see that function for why.
			int dx = position2.X - position1.X;
			int dy = position2.Y - position1.Y;
			int r = std::max(std::abs(dx), std::abs(dy));
			if (r < 1) r = 1;
			position2.X = position1.X + (dx < 0 ? -r : r);
			position2.Y = position1.Y + (dy < 0 ? -r : r);
		}
		int cx = (position1.X + position2.X) / 2;
		int cy = (position1.Y + position2.Y) / 2;
		float rx = std::abs(position2.X - position1.X) / 2.0f;
		float ry = std::abs(position2.Y - position1.Y) / 2.0f;
		constexpr int segments = 48;
		ui::Point prev(cx + int(rx), cy);
		for (int k = 1; k <= segments; k++)
		{
			float angle = 2.0f * 3.14159265f * float(k) / float(segments);
			ui::Point next(cx + int(rx * std::cos(angle)), cy + int(ry * std::sin(angle)));
			g->XorLine(prev, next);
			prev = next;
		}
	}
};
