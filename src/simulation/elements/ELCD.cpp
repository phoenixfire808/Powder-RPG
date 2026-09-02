#include "simulation/ElementCommon.h"

// Electrolysis electrode (HUB section 7). While energised (life > 0 after a
// SPRK pass) each adjacent WATR/SLTW/DSTW converts with probability ELCD_RATE
// per frame: cathode (tmp == 0) makes HYGN, anode (tmp == 1) makes OXYG at
// half the rate.

static int update(UPDATE_FUNC_ARGS);

constexpr float ELCD_RATE = 0.045f;

void Element::Element_ELCD()
{
	Identifier = "DEFAULT_PT_ELCD";
	Name = "ELCD";
	Colour = 0xB0B8C0_rgb;
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
	Hardness = 50;

	Weight = 100;

	DefaultProperties.temp = 293.15f;
	HeatConduct = 120;
	Description = "Electrode. When sparked, splits adjacent water: tmp=0 cathode makes HYGN, tmp=1 anode makes OXYG.";

	Properties = TYPE_SOLID | PROP_CONDUCTS | PROP_LIFE_DEC;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 1811.15f;
	HighTemperatureTransition = PT_LAVA;

	Update = &update;
}

static int update(UPDATE_FUNC_ARGS)
{
	static const int N8[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	if (parts[i].life <= 0)
		return 0;
	bool anode = parts[i].tmp == 1;
	float rate = anode ? ELCD_RATE / 2 : ELCD_RATE;
	int out = anode ? PT_O2 : PT_H2;
	for (auto &d : N8)
	{
		int nx = x + d[0], ny = y + d[1];
		int r = pmap[ny][nx];
		if (!r)
			continue;
		int rt = TYP(r);
		if ((rt == PT_WATR || rt == PT_SLTW || rt == PT_DSTW) && sim->rng.uniform01() < rate)
			sim->part_change_type(ID(r), nx, ny, out);
	}
	return 0;
}
