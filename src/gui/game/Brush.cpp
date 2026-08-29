#include "Brush.h"
#include "graphics/Graphics.h"
#include <cmath>

// Nearest-neighbor rotate, sampled by walking each destination pixel and
// inverse-rotating it back into source space -- simplest correct way to
// rotate a binary mask without needing per-shape geometry. dstRadius is
// expected to already be padded large enough (see
// Brush::RecomputeEffectiveRadius) that no source pixel can rotate outside
// it; srcRadius is the original, unpadded box GenerateBitmap() drew into.
static PlaneAdapter<std::vector<unsigned char>> RotateBitmap(const PlaneAdapter<std::vector<unsigned char>> &src, ui::Point srcRadius, ui::Point dstRadius, int rotationDegrees)
{
	ui::Point srcSize = srcRadius * 2 + Vec2{ 1, 1 };
	ui::Point dstSize = dstRadius * 2 + Vec2{ 1, 1 };
	PlaneAdapter<std::vector<unsigned char>> dst(dstSize);
	double rad = -rotationDegrees * 3.14159265358979323846 / 180.0;
	double c = std::cos(rad), s = std::sin(rad);
	for (int y = 0; y < dstSize.Y; y++)
	{
		for (int x = 0; x < dstSize.X; x++)
		{
			double dx = x - dstRadius.X;
			double dy = y - dstRadius.Y;
			int ix = int(std::lround(dx * c - dy * s)) + srcRadius.X;
			int iy = int(std::lround(dx * s + dy * c)) + srcRadius.Y;
			unsigned char value = 0;
			if (ix >= 0 && ix < srcSize.X && iy >= 0 && iy < srcSize.Y)
				value = src[{ ix, iy }];
			dst[{ x, y }] = value;
		}
	}
	return dst;
}

// Rotating a shape that fills its radius-sized box (e.g. a triangle whose
// base spans the full width) needs more room than that box once rotated,
// or its corners get clipped -- looks like "rotates inside an invisible
// square". Pad out to the box's own half-diagonal, which is always enough
// room for any point in the original box to land inside the padded one at
// any rotation angle -- simple and always-correct, if a little generous for
// small angles, rather than a tight per-angle fit.
void Brush::RecomputeEffectiveRadius()
{
	if (!rotation)
	{
		effectiveRadius = radius;
		return;
	}
	int diag = int(std::ceil(std::sqrt(double(radius.X) * radius.X + double(radius.Y) * radius.Y)));
	effectiveRadius = ui::Point(diag, diag);
}

void Brush::InitBitmap()
{
	auto shape = GenerateBitmap();
	if (rotation)
		bitmap = RotateBitmap(shape, radius, effectiveRadius, rotation);
	else
		bitmap = std::move(shape);
}

void Brush::InitOutline()
{
	InitBitmap();
	ui::Point bounds = GetSize();
	outline = PlaneAdapter<std::vector<unsigned char>>(bounds);
	for (int j = 0; j < bounds.Y; j++)
	{
		for (int i = 0; i < bounds.X; i++)
		{
			bool value = false;
			if (bitmap[{ i, j }])
			{
				if (i == 0 || j == 0 || i == bounds.X - 1 || j == bounds.Y - 1)
					value = true;
				else if (!bitmap[{ i + 1, j }])
					value = true;
				else if (!bitmap[{ i - 1, j }])
					value = true;
				else if (!bitmap[{ i, j + 1 }])
					value = true;
				else if (!bitmap[{ i, j - 1 }])
					value = true;
			}
			outline[{ i, j }] = value ? 0xFF : 0;
		}
	}
}

void Brush::SetRadius(ui::Point newRadius)
{
	if (newRadius.X < 0)
		newRadius.X = 0;
	if (newRadius.Y < 0)
		newRadius.Y = 0;
	if (newRadius.X > 200)
		newRadius.X = 200;
	if (newRadius.Y > 200)
		newRadius.Y = 200;
	radius = newRadius;
	RecomputeEffectiveRadius();
	InitOutline();
}

void Brush::AdjustSize(int delta, bool logarithmic, bool keepX, bool keepY, int logStepDivisor)
{
	if (keepX && keepY)
		return;
	if (logStepDivisor < 1)
		logStepDivisor = 1;

	ui::Point newSize(0, 0);
	ui::Point oldSize = GetRadius();
	if (logarithmic)
		newSize = oldSize + ui::Point(delta * std::max(oldSize.X / logStepDivisor, 1), delta * std::max(oldSize.Y / logStepDivisor, 1));
	else
		newSize = oldSize + ui::Point(delta, delta);

	if (keepY)
		SetRadius(ui::Point(newSize.X, oldSize.Y));
	else if (keepX)
		SetRadius(ui::Point(oldSize.X, newSize.Y));
	else
		SetRadius(newSize);
}

void Brush::SetRotation(int degrees)
{
	degrees %= 360;
	if (degrees < 0)
		degrees += 360;
	rotation = degrees;
	RecomputeEffectiveRadius();
	InitOutline();
}

void Brush::AdjustRotation(int deltaDegrees)
{
	SetRotation(rotation + deltaDegrees);
}

void Brush::RenderRect(Graphics *g, ui::Point position1, ui::Point position2) const
{
	int width, height;
	width = position2.X-position1.X;
	height = position2.Y-position1.Y;
	if (height<0)
	{
		position1.Y += height;
		height *= -1;
	}
	if (width<0)
	{
		position1.X += width;
		width *= -1;
	}

	g->XorLine(position1, position1 + Vec2{ width, 0 });
	if (height > 0)
	{
		g->XorLine(position1 + Vec2{ 0, height }, position1 + Vec2{ width, height });
		if (height > 1)
		{
			g->XorLine(position1 + Vec2{ width, 1 }, position1 + Vec2{ width, height - 1 });
			if (width > 0)
			{
				g->XorLine(position1 + Vec2{ 0, 1 }, position1 + Vec2{ 0, height - 1 });
			}
		}
	}
}

void Brush::RenderLine(Graphics *g, ui::Point position1, ui::Point position2) const
{
	g->XorLine(position1, position2);
}

void Brush::RenderPoint(Graphics *g, ui::Point position) const
{
	g->XorImage(outline.data(), RectBetween(position - effectiveRadius, position + effectiveRadius));
}

void Brush::RenderFill(Graphics *g, ui::Point position) const
{
	g->XorLine(position - Vec2{ 5, 0 }, position - Vec2{ 1, 0 });
	g->XorLine(position + Vec2{ 5, 0 }, position + Vec2{ 1, 0 });
	g->XorLine(position - Vec2{ 0, 5 }, position - Vec2{ 0, 1 });
	g->XorLine(position + Vec2{ 0, 5 }, position + Vec2{ 0, 1 });
}
