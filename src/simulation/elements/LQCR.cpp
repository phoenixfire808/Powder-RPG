#include "simulation/ElementCommon.h"

// Generic "state carrier" -- see PWCR.cpp for the full explanation of how
// ctype gets set (via the packed v from the placing tool) and why physics
// stays generic instead of replicating the source element exactly.
static void create(ELEMENT_CREATE_FUNC_ARGS);
static int graphics(GRAPHICS_FUNC_ARGS);
static int update(UPDATE_FUNC_ARGS);

void Element::Element_LQCR()
{
	Identifier = "DEFAULT_PT_LQCR";
	Name = "LQCR";
	Colour = 0xC0C0C0_rgb;
	MenuVisible = 0;
	MenuSection = SC_LIQUID;
	Enabled = 1;

	// Matched to real stock WATR.cpp, not guessed -- same diagnostic pass
	// that fixed GSCR's chaos (compare against the real reference element
	// instead of tuning blind). Collision was -0.1 (a small bounce-back on
	// wall/blocked-cell hits) where every real stock liquid uses 0.0 (dead
	// stop, no bounce); Gravity was 0.2, double WATR's 0.1. Neither is huge
	// alone, but both push in the same direction (more residual velocity,
	// applied harder), and compound with newly-created particles landing
	// in/near an existing pool.
	Advection = 0.6f;
	AirDrag = 0.01f * CFDS;
	AirLoss = 0.98f;
	Loss = 0.95f;
	Collision = 0.0f;
	Gravity = 0.1f;
	Diffusion = 0.00f;
	HotAir = 0.000f * CFDS;
	Falldown = 2;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 0;

	Weight = 30;

	HeatConduct = 60;
	Description = "Molten/liquid form of another material.";

	Properties = TYPE_LIQUID;
	CarriesTypeIn = 1U << FIELD_CTYPE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	// ITH forces the generic transition gate to always enter the t==PT_LQCR
	// special case in Simulation.cpp, which reads the real tagged element's
	// own melting point to decide whether it's cooled enough to revert
	// straight to that real element ("mix back into their true form").
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
		// Spawn genuinely molten, not at the generic room-temp default --
		// otherwise a freshly-placed "molten X" starts out BELOW X's real
		// melting point and the cool-below-melting-point-reverts-to-solid
		// transition (Simulation.cpp's t==PT_LQCR case) flips it straight
		// back to solid within a tick or two, before it's ever seen molten.
		// +450K above the real threshold -- the owner asked twice for more
		// headroom after +200K still wasn't hot enough to pour easily
		// ("that way we can pour it into something a lot easier"). Not
		// arbitrary: for a representative metal like GOLD (real melting
		// point 1337K) that lands at ~1787K, right in line with how hot
		// stock LAVA itself spawns (room + 1500K =~ 1795K) -- his original
		// reference point for how hot molten stuff should feel. HotAir=0
		// still means temp never feeds pressure, and there's no temp->
		// weight/density coupling anywhere in this codebase, so there's no
		// known mechanism by which spawning hotter causes problems.
		auto &sd = SimulationData::CRef();
		auto &elements = sd.elements;
		if (elements[v].Enabled && elements[v].HighTemperatureTransition != NT && elements[v].HighTemperatureTransition != ST)
			sim->parts[i].temp = restrict_flt(elements[v].HighTemperature + 450.0f, MIN_TEMP, MAX_TEMP);
	}
}

// Delegates to the REAL tagged element's own Update() for a small,
// explicitly hand-verified allowlist (see PWCR.cpp for the full reasoning
// on why this isn't blanket delegation) -- e.g. molten acid still dissolves
// things.
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
		// Real incandescent material's look is dominated by the heat glow
		// itself, not its cold-state pigment -- a dull/dark source colour
		// (e.g. BRMT, broken metal, a muted grey) stayed just as dull after
		// only a 20% nudge toward orange, reading as flat grey "stone lava"
		// instead of visibly molten. Flipped to weight the glow more
		// heavily than the source, so anything molten reads as clearly hot
		// regardless of how dull its solid form is, while the source colour
		// still tints it enough that different materials look different
		// from each other.
		float r = c.Red   * 0.45f + 255 * 0.55f;
		float g = c.Green * 0.45f + 140 * 0.55f;
		float b = c.Blue  * 0.45f +  30 * 0.55f;
		*colr = uint8_t(r > 255.f ? 255.f : r);
		*colg = uint8_t(g > 255.f ? 255.f : g);
		*colb = uint8_t(b > 255.f ? 255.f : b);
	}
	return 0;
}
