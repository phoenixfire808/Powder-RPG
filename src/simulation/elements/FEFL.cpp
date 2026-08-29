#include "simulation/ElementCommon.h"

void Element::Element_FEFL()
{
	Identifier = "DEFAULT_PT_FEFL";
	Name = "FEFL";
	Colour = 0x3C3C3E_rgb;
	MenuVisible = 1;
	MenuSection = SC_POWDERS;
	Enabled = 1;

	// A real movable powder, unlike stock IRON (Falldown=0, Gravity=0 --
	// a static solid block that the physics engine never repositions from
	// velocity alone). Iron filings are exactly what real magnet
	// demonstrations use for a reason: light and loose enough to actually
	// visibly move and clump, unlike a solid iron bar.
	Advection = 0.3f;
	AirDrag = 0.02f * CFDS;
	AirLoss = 0.96f;
	Loss = 0.90f;
	Collision = -0.1f;
	Gravity = 0.2f;
	Diffusion = 0.00f;
	HotAir = 0.000f * CFDS;
	Falldown = 1;

	Flammable = 0;
	Explosive = 0;
	Meltable = 0;
	Hardness = 0;

	Weight = 20;

	HeatConduct = 251;
	Description = "Iron filings. Fine, loose iron dust -- light enough to actually be pulled and clumped by a real magnetic field, unlike a solid iron bar.";

	Properties = TYPE_PART|PROP_CONDUCTS;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 1687.0f; // real iron melting point, same as stock IRON
	HighTemperatureTransition = PT_LAVA; //@ FEFL -> LAVA(FEFL)
}
