#include "simulation/ElementCommon.h"

// Thermoelectric generator. Port of the "teg" kind in scripts/lua/power_kinds.lua:
// above 373.15 K it counts frames in tmp2 and every 20th frame drops 2 K and
// sparks adjacent conductors. (Lua used life as the counter; life is engine-owned
// for PROP_CONDUCTS|PROP_LIFE_DEC elements, so tmp2 is used here.)

static int update(UPDATE_FUNC_ARGS);
void Element_TRBN_Spark8(Simulation *sim, int x, int y);

void Element::Element_TEG()
{
	Identifier = "DEFAULT_PT_TEG";
	Name = "TEG";
	Colour = 0x3FAA6A_rgb;
	MenuVisible = 1;
	MenuSection = SC_POWERED;
	Enabled = 1;

	Advection = 0.0f;
	AirDrag = 0.00f * CFDS;
	AirLoss = 0.90f;
	Loss = 0.00f;
	Collision = 0.0f;
	Gravity = 0.0f;
	Diffusion = 0.00f;
	HotAir = 0.000f * CFDS;
	Falldown = 0;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 40;

	Weight = 100;

	DefaultProperties.temp = 293.15f;
	HeatConduct = 80;
	Description = "Thermoelectric generator. Above 100C it cools itself slowly and sparks adjacent conductors.";

	Properties = TYPE_SOLID | PROP_CONDUCTS | PROP_LIFE_DEC;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 858.15f;
	HighTemperatureTransition = PT_BMTL;

	Update = &update;
}

static int update(UPDATE_FUNC_ARGS)
{
	if (parts[i].temp < 373.15f)
		return 0;
	if (++parts[i].tmp2 < 20)
		return 0;
	parts[i].tmp2 = 0;
	parts[i].temp -= 2.0f;
	Element_TRBN_Spark8(sim, x, y);
	return 0;
}
