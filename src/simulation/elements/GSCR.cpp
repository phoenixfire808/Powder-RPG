#include "simulation/ElementCommon.h"

// Generic "state carrier" -- see PWCR.cpp for the full explanation.
static void create(ELEMENT_CREATE_FUNC_ARGS);
static int graphics(GRAPHICS_FUNC_ARGS);
static int update(UPDATE_FUNC_ARGS);

void Element::Element_GSCR()
{
	Identifier = "DEFAULT_PT_GSCR";
	Name = "GSCR";
	Colour = 0xC0C0C0_rgb;
	MenuVisible = 0;
	MenuSection = SC_GAS;
	Enabled = 1;

	// Matched to real stock GAS.cpp, not guessed -- this element's original
	// values (Advection 2.0, AirDrag 0.04, Loss 0.97) were roughly double a
	// real gas's, and with Loss that high almost no velocity ever damps out
	// between ticks. Fine while inert (0 gravity), but adding gravity to
	// make it visibly rise gave that undamped velocity something to
	// compound against every tick, which read as "sprang in every
	// direction" chaotic scatter instead of a smooth rise. Neutral gravity
	// (matches real GAS, not WTRV's rising-steam special case -- GSCR
	// stands in for any material's gas form, not specifically steam) plus
	// real damping is what actually reads as "a gas" instead of an
	// explosion.
	Advection = 1.0f;
	AirDrag = 0.01f * CFDS;
	AirLoss = 0.99f;
	Loss = 0.30f;
	Collision = -0.1f;
	Gravity = 0.0f;
	Diffusion = 0.75f;
	HotAir = 0.000f * CFDS;
	Falldown = 0;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 0;

	Weight = 1;

	HeatConduct = 30;
	Description = "Gaseous/vapourised form of another material.";

	Properties = TYPE_GAS;
	CarriesTypeIn = 1U << FIELD_CTYPE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	// See LQCR.cpp -- ITH forces the generic transition gate to always enter
	// the t==PT_GSCR special case, which reads the real tagged element's own
	// melting point to decide whether it's cooled enough to condense
	// straight back into that real element.
	LowTemperature = ITH;
	LowTemperatureTransition = ST;
	HighTemperature = ITH;
	HighTemperatureTransition = NT;

	Create = &create;
	Graphics = &graphics;
	Update = &update;
}

static void create(ELEMENT_CREATE_FUNC_ARGS)
{
	if (v > 0 && v < PT_NUM)
	{
		sim->parts[i].ctype = v;
		// Root cause of "gases... now I can't" (confirmed by reading the
		// code, not guessed): Simulation.cpp's t==PT_GSCR low-temperature
		// case reverts straight back to the real tagged element once
		// ctempl < elements[ct].HighTemperature (its real melting point).
		// This element never set a spawn temperature -- a freshly-placed
		// "gaseous gold" spawned at plain ambient (~295K), which is BELOW
		// virtually every real element's melting point, so that check
		// fired and reverted it to solid on literally the first tick,
		// every time. LQCR.cpp got this fix already; GSCR never did.
		// Same +450K margin, same reasoning (see LQCR.cpp's create()).
		auto &sd = SimulationData::CRef();
		auto &elements = sd.elements;
		if (elements[v].Enabled && elements[v].HighTemperatureTransition != NT && elements[v].HighTemperatureTransition != ST)
			sim->parts[i].temp = restrict_flt(elements[v].HighTemperature + 450.0f, MIN_TEMP, MAX_TEMP);
	}
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
		// Hazy/washed out: blend 40% toward white so a vapourised form
		// reads visibly different from the powder/liquid/real forms of the
		// same material, without hiding the source colour entirely.
		*colr = uint8_t(c.Red   * 0.60f + 255 * 0.40f);
		*colg = uint8_t(c.Green * 0.60f + 255 * 0.40f);
		*colb = uint8_t(c.Blue  * 0.60f + 255 * 0.40f);
	}
	return 0;
}
