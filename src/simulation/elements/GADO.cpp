#include "simulation/ElementCommon.h"
#include <cmath>

static int update(UPDATE_FUNC_ARGS);

void Element::Element_GADO()
{
	Identifier = "DEFAULT_PT_GADO";
	Name = "GADO";
	Colour = 0xC9C6D8_rgb;
	MenuVisible = 1;
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
	Hardness = 20;

	Weight = 100; // standard heavy-solid-metal value used throughout this fork

	HeatConduct = 180;
	Description = "Gadolinium. A real permanent ferromagnet below ~20 C (its Curie point) -- pulls in iron-group metal, loses it above that.";

	Properties = TYPE_SOLID|PROP_CONDUCTS|PROP_HOT_GLOW;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 1585.0f; // real melting point, 1312 C
	HighTemperatureTransition = PT_LAVA; //@ GADO -> LAVA(GADO)

	Update = &update;
}

// Real gadolinium's Curie point is 293.4 K (20.3 C) -- right around room
// temperature, which is exactly what makes the element famous: cool a piece
// slightly and it's a genuine ferromagnet, warm that same piece slightly and
// it stops attracting iron. Unlike MGNT.cpp's electromagnet (which sparks
// nearby metal to represent induction from a *changing* field, needs
// external SPRK power, and treats TUNG/GOLD as "magnetic" for gameplay
// reasons even though neither really is), this is a real static permanent
// magnet: a static field induces nothing (no induction without a change in
// flux), so it just pulls -- and only on iron/steel-group metal, since gold
// and tungsten genuinely aren't ferromagnetic.
constexpr float GADOLINIUM_CURIE_POINT = 293.4f;

static int update(UPDATE_FUNC_ARGS)
{
	if (parts[i].temp >= GADOLINIUM_CURIE_POINT)
		return 0; // paramagnetic up here -- real field is negligible

	for (auto rx = -4; rx <= 4; rx++)
	{
		for (auto ry = -4; ry <= 4; ry++)
		{
			if (!rx && !ry)
				continue;
			auto r = pmap[y + ry][x + rx];
			if (!r)
				r = sim->photons[y + ry][x + rx];
			if (!r)
				continue;
			switch (TYP(r))
			{
			case PT_IRON:
			case PT_METL:
			case PT_BMTL:
			{
				auto id = ID(r);
				float dx = float(x - parts[id].x);
				float dy = float(y - parts[id].y);
				float dist = std::sqrt(dx * dx + dy * dy);
				if (dist > 0.5f)
				{
					parts[id].vx += dx / dist * 0.1f;
					parts[id].vy += dy / dist * 0.1f;
				}
				break;
			}
			default:
				break;
			}
		}
	}
	return 0;
}
