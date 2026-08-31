#pragma once
#include "gui/interface/Point.h"
#include "common/Plane.h"
#include <memory>
#include <vector>

class Graphics;
class Brush
{
private:
	// 2D arrays indexed by coordinates from [-effectiveRadius.X, effectiveRadius.X]
	// by [-effectiveRadius.Y, effectiveRadius.Y] -- see effectiveRadius below.
	PlaneAdapter<std::vector<unsigned char>> bitmap;
	PlaneAdapter<std::vector<unsigned char>> outline;

	// Equal to radius when rotation is 0. When rotated, a shape generated to
	// exactly fill a radius-sized box (e.g. a triangle whose base spans the
	// full width) needs more room than that same box once rotated, or its
	// corners get clipped by the box edges -- looks like "rotates inside an
	// invisible square." Padded out to the box's own half-diagonal
	// (RecomputeEffectiveRadius) so nothing is ever clipped at any angle.
	// GenerateBitmap() itself still draws the shape at the true `radius`
	// size -- only the surrounding storage/iteration bounds grow.
	ui::Point effectiveRadius{ 0, 0 };
	void RecomputeEffectiveRadius();

	void InitBitmap();
	void InitOutline();

	struct iterator
	{
		Brush const &parent;
		int x, y;

		iterator &operator++()
		{
			auto radius = parent.effectiveRadius;
			do
			{
				if (++x > radius.X)
				{
					--y;
					x = -radius.X;
				}
			} while (y >= -radius.Y && !parent.bitmap[radius + Vec2<int>{ x, y }]);
			return *this;
		}

		ui::Point operator*() const
		{
			return ui::Point(x, y);
		}

		bool operator!=(iterator other) const
		{
			return x != other.x || y != other.y;
		}

		using difference_type = void;
		using value_type = ui::Point;
		using pointer = void;
		using reference = void;
		using iterator_category = std::forward_iterator_tag;
	};

protected:
	ui::Point radius{ 0, 0 };
	// Degrees, normalized to [0, 360). Applied as a post-process over
	// whatever GenerateBitmap() produces (see InitBitmap), so every brush
	// shape gets rotation for free instead of each subclass hand-rotating
	// its own containment formula.
	int rotation = 0;

	virtual PlaneAdapter<std::vector<unsigned char>> GenerateBitmap() const = 0;

public:
	virtual ~Brush() = default;
	virtual void AdjustSize(int delta, bool logarithmic, bool keepX, bool keepY, int logStepDivisor = 5);
	void AdjustRotation(int deltaDegrees);
	void SetRotation(int degrees);
	int GetRotation() const { return rotation; }
	virtual std::unique_ptr<Brush> Clone() const = 0;
	// RTTI is compiled out for this project (/GR-), so dynamic_cast can't be
	// used to tell brush shapes apart -- this predicate is what
	// ElementTool::DrawRect checks to pick a rectangle vs. ellipse fill.
	virtual bool IsEllipseShaped() const { return false; }
	// Whether a dragged region fill should be forced to a true circle
	// (radius equal in both directions) instead of stretched to fit
	// whatever rectangle was actually dragged -- mirrors the existing
	// Circle-vs-Ellipse brush choice used for stroke painting.
	virtual bool IsPerfectCircle() const { return false; }

	ui::Point GetSize() const
	{
		return effectiveRadius * 2 + Vec2{ 1, 1 };
	}

	// Deliberately still returns the true user-set radius, not the padded
	// effectiveRadius -- resize UI/step calculations should see the size
	// The owner actually set, not an implementation detail of how rotation
	// avoids clipping.
	ui::Point GetRadius() const
	{
		return radius;
	}

	iterator begin() const
	{
		// bottom to top is the preferred order for Simulation::CreateParts
		return ++iterator{*this, effectiveRadius.X, effectiveRadius.Y + 1};
	}

	iterator end() const
	{
		return iterator{*this, -effectiveRadius.X, -effectiveRadius.Y - 1};
	}

	// Virtual so EllipseBrush can preview an ellipse outline instead of a
	// rectangle for the Ctrl+drag region-fill tool (see ElementTool::DrawRect,
	// which fills the matching shape).
	virtual void RenderRect(Graphics *g, ui::Point position1, ui::Point position2) const;
	void RenderLine(Graphics *g, ui::Point position1, ui::Point position2) const;
	void RenderPoint(Graphics *g, ui::Point position) const;
	void RenderFill(Graphics *g, ui::Point position) const;

	void SetRadius(ui::Point newRadius);
};
