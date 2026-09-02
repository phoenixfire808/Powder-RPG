#include "simulation/ElementCommon.h"

// Steam turbine. Port of the "turbine" kind in scripts/lua/power_kinds.lua:
// each N8 WTRV neighbour condenses to DSTW (chance 0.25, cooled 60 K), the
// work done accumulates in tmp and sparks every adjacent conductor.

static int update(UPDATE_FUNC_ARGS);

static const int N8[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};

void Element_TRBN_Spark8(Simulation *sim, int x, int y)
{
	auto &sd = SimulationData::CRef();
	auto &elements = sd.elements;
	auto &parts = sim->parts;
	for (auto &d : N8)
	{
		int nx = x + d[0], ny = y + d[1];
		int r = sim->pmap[ny][nx];
		if (!r)
			continue;
		int rt = TYP(r);
		if ((elements[rt].Properties & PROP_CONDUCTS) && !(rt == PT_WATR || rt == PT_SLTW || rt == PT_NTCT || rt == PT_PTCT || rt == PT_INWR) && parts[ID(r)].life == 0)
		{
			parts[ID(r)].life = 4;
			parts[ID(r)].ctype = rt;
			sim->part_change_type(ID(r), nx, ny, PT_SPRK);
		}
	}
}

void Element::Element_TRBN()
{
	Identifier = "DEFAULT_PT_TRBN";
	Name = "TRBN";
	Colour = 0x6E7E90_rgb;
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
	Hardness = 70;

	Weight = 100;

	DefaultProperties.temp = 293.15f;
	HeatConduct = 100;
	Description = "Steam turbine. Condenses adjacent WTRV to DSTW and sparks adjacent conductors.";

	Properties = TYPE_SOLID | PROP_CONDUCTS | PROP_LIFE_DEC;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 1673.15f;
	HighTemperatureTransition = PT_LAVA;

	Update = &update;
}

static int update(UPDATE_FUNC_ARGS)
{
	int work = 0;
	for (auto &d : N8)
	{
		int nx = x + d[0], ny = y + d[1];
		int r = pmap[ny][nx];
		if (r && TYP(r) == PT_WTRV && sim->rng.uniform01() < 0.25f)
		{
			sim->part_change_type(ID(r), nx, ny, PT_DSTW);
			parts[ID(r)].temp = std::max(293.15f, parts[ID(r)].temp - 60.0f);
			work++;
		}
	}
	if (work)
	{
		parts[i].tmp += work;
		Element_TRBN_Spark8(sim, x, y);
	}
	return 0;
}
