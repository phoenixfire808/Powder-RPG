#include "simulation/ElementCommon.h"

// Boron carbide neutron absorber. Port of the "absorber" kind in
// scripts/lua/power_kinds.lua: each N8 NEUT is absorbed with chance 0.9,
// heating the block 4 K per hit and counting hits in tmp.

static int update(UPDATE_FUNC_ARGS);

void Element::Element_B4C()
{
	Identifier = "DEFAULT_PT_B4C";
	Name = "B4C";
	Colour = 0x1C1C2E_rgb;
	MenuVisible = 1;
	MenuSection = SC_NUCLEAR;
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
	Hardness = 85;

	Weight = 100;

	DefaultProperties.temp = 293.15f;
	HeatConduct = 40;
	Description = "Boron carbide. Absorbs neutrons, heating up with each hit.";

	Properties = TYPE_SOLID;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 3036.15f;
	HighTemperatureTransition = PT_LAVA;

	Update = &update;
}

static int update(UPDATE_FUNC_ARGS)
{
	static const int N8[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	int hits = 0;
	for (auto &d : N8)
	{
		int r = sim->photons[y + d[1]][x + d[0]];
		if (r && TYP(r) == PT_NEUT && sim->rng.uniform01() < 0.9f)
		{
			sim->kill_part(ID(r));
			hits++;
		}
	}
	if (hits)
	{
		parts[i].temp += 4.0f * hits;
		parts[i].tmp += hits;
	}
	return 0;
}
