#pragma once
#include "gui/interface/Point.h"
#include "simulation/ElementGraphics.h"
#include "simulation/ElementDefs.h"
#include "FindingElement.h"
#include <cstdint>
#include <optional>
#include <variant>

struct HdispLimitExplicit
{
	float value;
};
struct HdispLimitAuto
{
};
using HdispLimit = std::variant<
	HdispLimitExplicit,
	HdispLimitAuto
>;

struct RendererSettings
{
	uint32_t renderMode = RENDER_BASC | RENDER_FIRE | RENDER_SPRK | RENDER_EFFE;
	uint32_t displayMode = 0;
	uint32_t colorMode = COLOUR_DEFAULT;
	std::optional<FindingElement> findingElement;
	bool gravityZonesEnabled = false;
	bool gravityFieldEnabled = false;
	enum DecorationLevel
	{
		decorationDisabled,
		decorationEnabled,
		decorationAntiClickbait,
	};
	DecorationLevel decorationLevel = decorationEnabled;
	bool debugLines = false;
	ui::Point mousePos = { 0, 0 };
	int gridSize = 0;
	bool gridCheckerboard = false;
	// 0x000000 (pure black) by default -- matches the old hardcoded fill.
	// Some near-black elements (carbon nanotube, graphene-family materials)
	// are hard to make out against pure black; a lighter background makes
	// dark elements visible without having to recolor every one of them.
	uint32_t backgroundColour = 0;
	float fireIntensity = 1;
	HdispLimit wantHdispLimitMin = HdispLimitExplicit{ MIN_TEMP };
	HdispLimit wantHdispLimitMax = HdispLimitExplicit{ MAX_TEMP };
	Rect<int> autoHdispLimitArea = RES.OriginRect();
};
