#include "simulation/ElementCommon.h"

// Generic "state carrier": placed via the subcategory picker's state selector
// (GameView's element+state UI), not found in the normal menu (MenuVisible=0).
// Its ctype names the real element it's standing in for -- Create() below
// sets ctype from the packed v passed by the tool (see ElementTool::Draw and
// how PT_TESC's radius gets packed the same way), and Graphics() borrows that
// element's colour. Physics stays a plain generic powder rather than trying
// to replicate the source element's exact hardness/flammability -- it needs
// to behave correctly as A powder, not simulate every material perfectly.
static void create(ELEMENT_CREATE_FUNC_ARGS);
static int graphics(GRAPHICS_FUNC_ARGS);
static int update(UPDATE_FUNC_ARGS);

void Element::Element_PWCR()
{
	Identifier = "DEFAULT_PT_PWCR";
	Name = "PWCR";
	Colour = 0xC0C0C0_rgb;
	MenuVisible = 0;
	MenuSection = SC_POWDERS;
	Enabled = 1;

	Advection = 0.7f;
	AirDrag = 0.02f * CFDS;
	AirLoss = 0.96f;
	Loss = 0.80f;
	Collision = 0.0f;
	Gravity = 0.3f;
	Diffusion = 0.00f;
	HotAir = 0.000f	* CFDS;
	Falldown = 1;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 30;

	Weight = 90;

	HeatConduct = 70;
	Description = "Powdered form of another material.";

	Properties = TYPE_PART;
	CarriesTypeIn = 1U << FIELD_CTYPE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	// Not a fixed threshold -- ITL/ITH here just force Simulation.cpp's
	// generic transition gate to always enter the t==PT_PWCR special case
	// (see the HighTemperatureTransition!=NT check there), which then reads
	// the REAL tagged element's own melting point (elements[ctype].
	// HighTemperature) to decide whether/when to become molten (LQCR).
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

// Delegates to the REAL tagged element's own Update() so its signature
// reactions still happen (e.g. powdered/molten/gaseous acid still
// dissolves things) -- but ONLY for a small, explicitly hand-verified
// allowlist, not whatever's tagged. Blanket delegation to an arbitrary
// element's Update() is unsafe: some elements (e.g. FUEL) directly assign
// `parts[i].type = PT_SOMETHING` based on their OWN type/temperature,
// assuming parts[i].type still equals their own id -- which it doesn't for
// a carrier. ACID/BASE were read in full and confirmed safe: both only
// ever touch neighbors by index/type and never check parts[i].type against
// their own PT_ constant, so running their Update() with i pointing at a
// carrier particle behaves correctly. Extend this list only after reading
// the candidate element's Update() the same way.
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
		// Matte/dusty: blend 25% toward mid-grey so powdered X reads
		// visibly different from real X or its molten/gas forms at a
		// glance, without hiding the source colour entirely.
		*colr = uint8_t(c.Red   * 0.75f + 128 * 0.25f);
		*colg = uint8_t(c.Green * 0.75f + 128 * 0.25f);
		*colb = uint8_t(c.Blue  * 0.75f + 128 * 0.25f);
	}
	return 0;
}
