#include "simulation/ElementCommon.h"

static int update(UPDATE_FUNC_ARGS);

void Element::Element_CLNE()
{
	Identifier = "DEFAULT_PT_CLNE";
	Name = "CLNE";
	Colour = 0xFFD010_rgb;
	MenuVisible = 1;
	MenuSection = SC_SPECIAL;
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
	Hardness = 1;

	Weight = 100;

	HeatConduct = 251;
	Description = "Clone. Duplicates any particles it touches.";

	Properties = TYPE_SOLID | PROP_PHOTPASS | PROP_NOCTYPEDRAW;
	CarriesTypeIn = 1U << FIELD_CTYPE;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = ITH;
	HighTemperatureTransition = NT;

	Update = &update;
	CtypeDraw = &Element::ctypeDrawVInTmp;
}

// Also true for our 4 state carriers (PWCR/LQCR/GSCR/SDCR), not just LAVA --
// all of them use ctype the same way LAVA does (which real element this
// particle represents), so cloning "molten gold" etc should reproduce that
// specific material, not a plain, untagged carrier particle.
static bool CarriesSubMaterial(int t)
{
	return t == PT_LAVA || t == PT_PWCR || t == PT_LQCR || t == PT_GSCR || t == PT_SDCR;
}

static int update(UPDATE_FUNC_ARGS)
{
	auto &sd = SimulationData::CRef();
	auto &elements = sd.elements;
	if (parts[i].ctype<=0 || parts[i].ctype>=PT_NUM || !elements[parts[i].ctype].Enabled)
	{
		for (auto rx = -1; rx <= 1; rx++)
		{
			for (auto ry = -1; ry <= 1; ry++)
			{
				auto r = sim->photons[y+ry][x+rx];
				if (!r)
					r = pmap[y+ry][x+rx];
				if (!r)
					continue;
				auto rt = TYP(r);
				if (rt!=PT_CLNE && rt!=PT_PCLN &&
				    rt!=PT_BCLN && rt!=PT_STKM &&
				    rt!=PT_PBCN && rt!=PT_STKM2 &&
				    rt<PT_NUM)
				{
					parts[i].ctype = rt;
					if (rt==PT_LIFE || CarriesSubMaterial(rt))
						parts[i].tmp = parts[ID(r)].ctype;
					// The owner asked for this specifically: a clone that
					// touched something molten/liquefied should reproduce
					// it at the same heat, not room temperature -- which
					// for a state carrier especially matters since cold
					// enough can revert it straight back to the real solid
					// (see Simulation.cpp's carrier cooling transition).
					if (CarriesSubMaterial(rt))
						parts[i].tmp2 = int(parts[ID(r)].temp);
				}
			}
		}
	}
	else
	{
		if (parts[i].ctype==PT_LIFE) sim->create_part(-1, x + sim->rng.between(-1, 1), y + sim->rng.between(-1, 1), PT_LIFE, parts[i].tmp);
		else if (parts[i].ctype!=PT_LIGH || sim->rng.chance(1, 30))
		{
			int np = sim->create_part(-1, x + sim->rng.between(-1, 1), y + sim->rng.between(-1, 1), TYP(parts[i].ctype));
			if (np>=0)
			{
				if (parts[i].ctype==PT_LAVA && parts[i].tmp>0 && parts[i].tmp<PT_NUM && elements[parts[i].tmp].HighTemperatureTransition==PT_LAVA)
					parts[np].ctype = parts[i].tmp;
				else if (CarriesSubMaterial(parts[i].ctype) && parts[i].tmp>0 && parts[i].tmp<PT_NUM && elements[parts[i].tmp].Enabled)
					parts[np].ctype = parts[i].tmp;
				if (CarriesSubMaterial(parts[i].ctype) && parts[i].tmp2 > 0)
					parts[np].temp = restrict_flt(float(parts[i].tmp2), MIN_TEMP, MAX_TEMP);
			}
		}
	}
	return 0;
}
