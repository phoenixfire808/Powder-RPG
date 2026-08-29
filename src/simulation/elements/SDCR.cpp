#include "simulation/ElementCommon.h"

// Generic "state carrier" -- see PWCR.cpp for the full explanation.
static void create(ELEMENT_CREATE_FUNC_ARGS);
static int graphics(GRAPHICS_FUNC_ARGS);
static int update(UPDATE_FUNC_ARGS);

void Element::Element_SDCR()
{
	Identifier = "DEFAULT_PT_SDCR";
	Name = "SDCR";
	Colour = 0xC0C0C0_rgb;
	MenuVisible = 0;
	MenuSection = SC_SOLIDS;
	Enabled = 1;

	Advection = 0.0f;
	AirDrag = 0.00f * CFDS;
	AirLoss = 0.90f;
	Loss = 0.00f;
	Collision = 0.0f;
	Gravity = 0.0f;
	Diffusion = 0.00f;
	HotAir = 0.000f	* CFDS;
	Falldown = 0;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 30;

	Weight = 100;

	HeatConduct = 70;
	Description = "Solid, cast form of another material.";

	Properties = TYPE_SOLID;
	CarriesTypeIn = 1U << FIELD_CTYPE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	// See PWCR.cpp -- ITL forces the generic transition gate to always enter
	// the t==PT_SDCR special case, which reads the real tagged element's own
	// melting point to decide whether to become molten (LQCR).
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = ITL;
	HighTemperatureTransition = ST;

	Create = &create;
	Graphics = &graphics;
	Update = &update;
}

static void create(ELEMENT_CREATE_FUNC_ARGS)
{
	if (v > 0 && v < PT_NUM)
		sim->parts[i].ctype = v;
}

// Delegates to the REAL tagged element's own Update() for a small,
// explicitly hand-verified allowlist (see PWCR.cpp for the full reasoning
// on why this isn't blanket delegation).
static int update(UPDATE_FUNC_ARGS)
{
	auto &sd = SimulationData::CRef();
	auto &elements = sd.elements;
	int ct = parts[i].ctype;
	if ((ct == PT_ACID || ct == PT_BASE) && elements[ct].Enabled && elements[ct].Update)
		return (*elements[ct].Update)(sim, i, x, y, surround_space, nt, parts, pmap);
	return 0;
}

static int graphics(GRAPHICS_FUNC_ARGS)
{
	auto &sd = SimulationData::CRef();
	auto &elements = sd.elements;
	int ct = cpart->ctype;
	if (ct > 0 && ct < PT_NUM && elements[ct].Enabled)
	{
		auto c = elements[ct].Colour;
		// Cool cast-metal tint: blend 15% toward pale blue-grey so a
		// solidified/cast form reads visibly different from the real
		// element (and from the other carrier states), while staying the
		// closest to true colour of the four -- it's the one state that's
		// "basically the real material" already.
		*colr = uint8_t(c.Red   * 0.85f + 190 * 0.15f);
		*colg = uint8_t(c.Green * 0.85f + 200 * 0.15f);
		*colb = uint8_t(c.Blue  * 0.85f + 210 * 0.15f);
	}
	return 0;
}
