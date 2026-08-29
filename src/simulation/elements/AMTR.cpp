#include "simulation/ElementCommon.h"

static int update(UPDATE_FUNC_ARGS);
static int graphics(GRAPHICS_FUNC_ARGS);

void Element::Element_AMTR()
{
	Identifier = "DEFAULT_PT_AMTR";
	Name = "AMTR";
	Colour = 0x808080_rgb;
	MenuVisible = 1;
	MenuSection = SC_NUCLEAR;
	Enabled = 1;

	Advection = 0.7f;
	AirDrag = 0.02f * CFDS;
	AirLoss = 0.96f;
	Loss = 0.80f;
	Collision = 0.00f;
	Gravity = 0.10f;
	Diffusion = 1.00f;
	HotAir = 0.0000f * CFDS;
	Falldown = 0;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 0;

	Weight = 100;

	HeatConduct = 70;
	Description = "Anti-Matter, annihilates on contact releasing its full mass as heat, light and a shockwave. Safe inside a live EMGT field.";

	Properties = TYPE_GAS;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = ITH;
	HighTemperatureTransition = NT;

	Update = &update;
	Graphics = &graphics;
}

static int update(UPDATE_FUNC_ARGS)
{
	for (auto rx = -1; rx <= 1; rx++)
	{
		for (auto ry = -1; ry <= 1; ry++)
		{
			if (rx || ry)
			{
				auto r = pmap[y+ry][x+rx];
				if (!r)
					continue;
				auto rt = TYP(r);
				// A live magnet field (see MGNT.cpp) confines antimatter like any
				// other charged particle instead of letting it touch the coil --
				// a real Penning trap: kill the field and containment fails.
				bool trapped = rt==PT_MGNT && parts[ID(r)].tmp3==1;
				if (!trapped && rt!=PT_AMTR && rt!=PT_DMND && rt!=PT_CLNE && rt!=PT_PCLN && rt!=PT_VOID && rt!=PT_BHOL && rt!=PT_NBHL && rt!=PT_PRTI && rt!=PT_PRTO)
				{
					parts[i].life++;
					// Annihilation converts the full rest mass of both particles
					// straight to energy (E=mc^2, ~100% efficient, vs a fission
					// bomb's ~1%) -- that's why even a speck of antimatter is
					// devastating. Every hit dumps max heat into the cell and
					// kicks a real shockwave, plus the gamma burst, instead of
					// just quietly deleting matter.
					// The universe we got came from exactly this kind of
					// annihilation being slightly lopsided -- for every ~billion
					// matter/antimatter pairs, one extra matter particle survived
					// (baryon asymmetry / CP violation). Tuned way up from that
					// real ratio so it's actually visible in a sim this small.
					if (!sim->rng.chance(1, 500))
						sim->create_part(ID(r), x+rx, y+ry, PT_PHOT);
					parts[i].temp = MAX_TEMP;
					sim->pv[y/CELL][x/CELL] = restrict_flt(sim->pv[y/CELL][x/CELL] + 15.0f, MIN_PRESSURE, MAX_PRESSURE);
					if (parts[i].life==4)
					{
						sim->kill_part(i);
						return 1;
					}
				}
			}
		}
	}
	return 0;
}

static int graphics(GRAPHICS_FUNC_ARGS)
{
	// don't render AMTR as a gas
	// this function just overrides the default graphics
	return 1;
}
