#pragma once
#include "common/String.h"
#include "simulation/MenuSection.h"
#include <vector>
#include <map>

// A SubCategory is a contiguous band of Tool::MenuSort values within one
// menu section. Menu::AddTool already keeps each section's tool list sorted
// by MenuSort, so grouping is just "which band does this tool's MenuSort
// fall into" -- no change to how tools are stored or sorted, only to how
// GameModel::GetActiveMenuToolList() filters what it returns.
//
// One unified set of themed bands per section, defined in multiples of 10
// (see D:\powder-toy\bridge_src\95_menusort.lua). Stock and custom elements
// of the same theme (e.g. "Metals") share the same band -- there used to be
// a second numeric range reserved purely for custom elements, which just
// produced two near-duplicate chips per theme ("Inert & Cold" next to
// "Noble & Inert", "Fissile Fuel" next to "Fuel", etc). Gone now; a theme
// gets exactly one chip regardless of which table in the Lua file assigns it.
struct SubCategory
{
	String label;
	int sortMin;
	int sortMax;
};

inline const std::map<int, std::vector<SubCategory>> &GetSubCategories()
{
	static const std::map<int, std::vector<SubCategory>> table = {
		{ SC_SOLIDS, {
			{ "Metals",                  10, 19 },
			{ "Alkali Metals",           20, 29 },
			{ "Minerals, Ceramics & Glass", 30, 39 },
			{ "Ice & Cold",              40, 49 },
			{ "Organic & Life",          50, 59 },
			{ "Structural & Signal",     60, 69 },
			{ "Reactive & Bizarre",      70, 79 },
			{ "Novel Mechanics",         80, 89 },
			{ "Timber & Polymers",       90, 99 },
		}},
		{ SC_LIQUID, {
			{ "Water & Variants",        10, 19 },
			{ "Fuels, Oils & Solvents",  20, 29 },
			{ "Acids & Corrosives",      30, 39 },
			{ "Cryogenic",               40, 49 },
			{ "Special & Utility",       50, 59 },
			{ "Reactor Coolants",        60, 69 },
		}},
		{ SC_GAS, {
			{ "Combustible & Fuel",      10, 19 },
			{ "Toxic & Reactive",        20, 29 },
			{ "Noble & Inert",           30, 39 },
			{ "Vapors & Effects",        40, 49 },
		}},
		{ SC_POWDERS, {
			{ "Minerals & Sand",         10, 19 },
			{ "Broken & Debris",         20, 29 },
			{ "Explosive & Reactive",    30, 39 },
			{ "Organic Dust",            40, 49 },
			{ "Special Effects",         50, 59 },
		}},
		{ SC_NUCLEAR, {
			{ "Fuel",                    10, 19 },
			{ "Radioactive Decay",       20, 29 },
			{ "Particles",               30, 39 },
			{ "Exotic Physics",          40, 49 },
			{ "Control & Shielding",     50, 59 },
			{ "Sources",                 60, 69 },
		}},
		{ SC_POWERED, {
			{ "Pipes & Storage",         10, 19 },
			{ "Switches & Signals",      20, 29 },
			{ "Generators",              30, 39 },
			{ "Sensors & Converters",    40, 49 },
		}},
		{ SC_ELEC, {
			{ "Conductors & Insulators", 10, 19 },
			{ "Silicon & Logic",         20, 29 },
			{ "Signal & Power",          30, 39 },
			{ "Rays & Special",          40, 49 },
			{ "Superconductors & Electronics", 50, 59 },
		}},
		{ SC_LIFE, {
			{ "Cellular Automata",       10, 19 },
			{ "Colony System",           20, 29 },
		}},
		{ SC_EXPLOSIVE, {
			{ "Primary Explosives",      10, 19 },
			{ "Slow Burn & Fuses",       20, 29 },
			{ "Fire & Heat",             30, 39 },
			{ "Electric & Light",        40, 49 },
		}},
		{ SC_FORCE, {
			{ "Movers",                  10, 19 },
			{ "Fields",                  20, 29 },
			{ "Destructive",             30, 39 },
			{ "Mechanisms & Signal",     40, 49 },
		}},
		{ SC_SENSOR, {
			{ "Detectors",               10, 19 },
			{ "Property Sensors",        20, 29 },
			{ "Optical",                 30, 39 },
		}},
		{ SC_SPECIAL, {
			{ "Duplication & Conversion", 10, 19 },
			{ "Portals & Voids",         20, 29 },
			{ "Stickmen & AI",           30, 39 },
			{ "Novelty & Meta",          40, 49 },
		}},
	};
	return table;
}
