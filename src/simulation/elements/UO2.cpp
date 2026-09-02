#include "simulation/ElementCommon.h"

// Uranium dioxide fuel. Port of the "emitter" kind in bridge_src/20_behaviors.lua:
// every 120 frames (phase-shifted by particle index) emit one NEUT into a free
// N8 cell, scanning from a random start.

static int update(UPDATE_FUNC_ARGS);

void Element::Element_UO2()
{
	Identifier = "DEFAULT_PT_UO2";
	Name = "UO2";
	Colour = 0x2B2B30_rgb;
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
	Hardness = 90;

	Weight = 100;

	DefaultProperties.temp = 293.15f;
	HeatConduct = 30;
	Description = "Uranium dioxide fuel. Slowly emits neutrons.";

	Properties = TYPE_SOLID | PROP_NEUTPENETRATE | PROP_RADIOACTIVE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 3138.15f;
	HighTemperatureTransition = PT_LAVA;

	Update = &update;
}

static int update(UPDATE_FUNC_ARGS)
{
	static const int N8[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	if ((sim->frameCount + i) % 120 != 0)
		return 0;
	int start = sim->rng.between(0, 7);
	for (int k = 0; k < 8; k++)
	{
		auto &d = N8[(start + k) % 8];
		int nx = x + d[0], ny = y + d[1];
		if (!pmap[ny][nx])
		{
			sim->create_part(-1, nx, ny, PT_NEUT);
			break;
		}
	}
	return 0;
}
