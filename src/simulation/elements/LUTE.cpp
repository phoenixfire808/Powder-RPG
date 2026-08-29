#include "simulation/ElementCommon.h"

void Element::Element_LUTE()
{
	Identifier = "DEFAULT_PT_LUTE";
	Name = "LUTE";
	Colour = 0xD6D2C6_rgb;
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
	Hardness = 55;

	// Weight isn't a real-density proxy in this fork (IRON and TTAN both use
	// 100 despite a 75% real density difference) -- 100 is the standard
	// value for "heavy solid metal, doesn't float."
	Weight = 100;

	HeatConduct = 170;
	Description = "Lutetium. Densest and hardest rare earth metal; used in PET scanner crystals.";

	Properties = TYPE_SOLID|PROP_CONDUCTS|PROP_HOT_GLOW;

	LowPressure = IPL;
	LowPressureTransition = NT;
	HighPressure = IPH;
	HighPressureTransition = NT;
	LowTemperature = ITL;
	LowTemperatureTransition = NT;
	HighTemperature = 1925.0f; // real melting point, 1652 C
	HighTemperatureTransition = PT_LAVA; //@ LUTE -> LAVA(LUTE)
}
