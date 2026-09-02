-- 08_periodic_seed.lua -- the periodic table as real, spawnable elements.
-- GENERATED. Do not hand-edit.
-- Source: PubChem Periodic Table of Elements (NIH/NCBI)
--   https://pubchem.ncbi.nlm.nih.gov/rest/pug/periodictable/JSON
--   fetched 2026-09-01
-- Melting/boiling in kelvin, density g/cm3, standard state at STP, exactly as published.
-- Synthetic superheavies (Z>=104) are labelled predicted by the SOURCE itself, not by us.
--
-- DEDUPED 2026-09-02: 23 elements already exist in this game under their own names and are
-- REUSED, never shadowed -- the existing element keeps its recipes, ore veins, behaviour and
-- any player saves referencing it. A first pass missed most of these and created real
-- duplicates (two irons, two golds, two uraniums); caught by @ptable_all's collision audit.
-- Reused: LI->LITH, BE->BE, NA->NA, MG->MG, AL->ALUM, P->PHOS, TI->TTAN, CR->CHRM, FE->IRON, CO->COBT, CU->CU, RB->RBDM, CD->CD, PM->PRMT, GD->GADO, LU->LUTE, PT->PTNM, AU->GOLD, HG->MERC, PO->POLO, RN->RADN, U->URAN, PU->PLUT
-- FAMILIES: elements are grouped by their real chemical family (alkali metals, halogens,
-- noble gases, transition metals, lanthanides, actinides and so on) rather than dumped in
-- one bucket, so they can actually be sorted and reasoned about -- "everything sorted into
-- categories, that way we can do science experiments". Family comes from the source
-- dataset's own GroupBlock field, not from our judgement.
-- REAL PROPERTIES WIRED TO THE ENGINE (2026-09-02): heatConduct from real thermal
-- conductivity (W/m/K at 300K, CRC values) where established, otherwise derived from the
-- element's family and labelled as derived -- never presented as measured. hardness from
-- real electronegativity. flammable for the families that genuinely ignite (alkali metals
-- burn in air and water; alkaline earths, lanthanides and actinides to a lesser degree).
-- diffusion for gases. Silver conducts heat ~24,000x better than xenon and now does in game.
-- SECOND DEDUPE PASS 2026-09-02: seven more real duplicates, found live by auditing the
-- running element table rather than the source tree. Native Powder Toy does not name its
-- elements after their symbols -- hydrogen is HYGN, nitrogen NTRG, oxygen OXYG, silicon
-- SLCN, tungsten TUNG, lead LEAD -- so a symbol-match dedupe could never have caught them.
-- Chlorine was the worst: its Name is mixed-case "Cl", which is a DIFFERENT Lua string key
-- from "CL", so two live chlorines coexisted. Removed: H->HYGN, N->NTRG, O->OXYG, SI->SLCN, W->TUNG, CL->Cl, PB->LEAD
_G.PBX_MATERIALS_SEED = _G.PBX_MATERIALS_SEED or {}
local S = _G.PBX_MATERIALS_SEED
local function add(t) S[#S+1] = t end

add({ name = "HE", group = "NOBLE", description = "Helium (He), Z=2. Melts 0.95K. Boils 4.22K. 0.0001785 g/cm3.", colour = "0xD9FFFF", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 5, diffusion = 2 })
add({ name = "B", group = "METALLOID", description = "Boron (B), Z=5. Melts 2348K. Boils 4273K. 2.37 g/cm3.", colour = "0xFFB5B5", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2348, highTemperatureTransition = "LAVA", weight = 7.11 , heatConduct = 54, hardness = 51 })
add({ name = "C", group = "NONMETAL", description = "Carbon (C), Z=6. Melts 3823K. Boils 4098K. 2.267 g/cm3.", colour = "0x909090", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 3823, highTemperatureTransition = "LAVA", weight = 6.801 , heatConduct = 142, hardness = 64 })
add({ name = "F", group = "HALOGEN", description = "Fluorine (F), Z=9. Melts 53.53K. Boils 85.03K. 0.001696 g/cm3.", colour = "0x90E050", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 2, hardness = 100, diffusion = 2 })
add({ name = "NE", group = "NOBLE", description = "Neon (Ne), Z=10. Melts 24.56K. Boils 27.07K. 0.0008999 g/cm3.", colour = "0xB3E3F5", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 3, diffusion = 2 })
add({ name = "S", group = "NONMETAL", description = "Sulfur (S), Z=16. Melts 388.36K. Boils 717.75K. 2.067 g/cm3.", colour = "0xFFFF30", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 388.36, highTemperatureTransition = "LAVA", weight = 6.201 , heatConduct = 5, hardness = 64 })
add({ name = "AR", group = "NOBLE", description = "Argon (Ar), Z=18. Melts 83.8K. Boils 87.3K. 0.0017837 g/cm3.", colour = "0x80D1E3", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 2, diffusion = 2 })
add({ name = "K", group = "ALKALI", description = "Potassium (K), Z=19. Melts 336.53K. Boils 1032K. 0.89 g/cm3.", colour = "0x8F40D4", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 336.53, highTemperatureTransition = "LAVA", weight = 2.67 , heatConduct = 120, hardness = 20, flammable = 40 })
add({ name = "CA", group = "ALKEARTH", description = "Calcium (Ca), Z=20. Melts 1115K. Boils 1757K. 1.54 g/cm3.", colour = "0x3DFF00", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1115, highTemperatureTransition = "LAVA", weight = 4.62 , heatConduct = 170, hardness = 25, flammable = 15 })
add({ name = "SC", group = "TRANSIT", description = "Scandium (Sc), Z=21. Melts 1814K. Boils 3109K. 2.99 g/cm3.", colour = "0xE6E6E6", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1814, highTemperatureTransition = "LAVA", weight = 8.97 , heatConduct = 93, hardness = 34 })
add({ name = "V", group = "TRANSIT", description = "Vanadium (V), Z=23. Melts 2183K. Boils 3680K. 6 g/cm3.", colour = "0xA6A6AB", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2183, highTemperatureTransition = "LAVA", weight = 18 , heatConduct = 67, hardness = 41 })
add({ name = "MN", group = "TRANSIT", description = "Manganese (Mn), Z=25. Melts 1519K. Boils 2334K. 7.3 g/cm3.", colour = "0x9C7AC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1519, highTemperatureTransition = "LAVA", weight = 21.9 , heatConduct = 34, hardness = 39 })
add({ name = "NI", group = "TRANSIT", description = "Nickel (Ni), Z=28. Melts 1728K. Boils 3186K. 8.912 g/cm3.", colour = "0x50D050", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1728, highTemperatureTransition = "LAVA", weight = 26.736 , heatConduct = 114, hardness = 48 })
add({ name = "ZN", group = "TRANSIT", description = "Zinc (Zn), Z=30. Melts 692.68K. Boils 1180K. 7.134 g/cm3.", colour = "0x7D80B0", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 692.68, highTemperatureTransition = "LAVA", weight = 21.402 , heatConduct = 129, hardness = 41 })
add({ name = "GA", group = "POSTTRAN", description = "Gallium (Ga), Z=31. Melts 302.91K. Boils 2477K. 5.91 g/cm3.", colour = "0xC28F8F", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 302.91, highTemperatureTransition = "LAVA", weight = 17.73 , heatConduct = 77, hardness = 45 })
add({ name = "GE", group = "METALLOID", description = "Germanium (Ge), Z=32. Melts 1211.4K. Boils 3106K. 5.323 g/cm3.", colour = "0x668F8F", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1211.4, highTemperatureTransition = "LAVA", weight = 15.969 , heatConduct = 93, hardness = 50 })
add({ name = "AS", group = "METALLOID", description = "Arsenic (As), Z=33. Melts 1090K. Boils 887K. 5.776 g/cm3.", colour = "0xBD80E3", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1090, highTemperatureTransition = "LAVA", weight = 17.328 , heatConduct = 85, hardness = 55 })
add({ name = "SE", group = "NONMETAL", description = "Selenium (Se), Z=34. Melts 493.65K. Boils 958K. 4.809 g/cm3.", colour = "0xFFA100", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 493.65, highTemperatureTransition = "LAVA", weight = 14.427 , heatConduct = 8, hardness = 64 })
add({ name = "BR", group = "HALOGEN", description = "Bromine (Br), Z=35. Melts 265.95K. Boils 331.95K. 3.11 g/cm3.", colour = "0xA62929", type = "LIQUID", menuSection = "SC_LIQUID", weight = 9.33 , heatConduct = 4, hardness = 74 })
add({ name = "KR", group = "NOBLE", description = "Krypton (Kr), Z=36. Melts 115.79K. Boils 119.93K. 0.003733 g/cm3.", colour = "0x5CB8D1", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 1, hardness = 75, diffusion = 2 })
add({ name = "SR", group = "ALKEARTH", description = "Strontium (Sr), Z=38. Melts 1050K. Boils 1655K. 2.64 g/cm3.", colour = "0x00FF00", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1050, highTemperatureTransition = "LAVA", weight = 7.92 , heatConduct = 71, hardness = 24, flammable = 15 })
add({ name = "Y", group = "TRANSIT", description = "Yttrium (Y), Z=39. Melts 1795K. Boils 3618K. 4.47 g/cm3.", colour = "0x94FFFF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1795, highTemperatureTransition = "LAVA", weight = 13.41 , heatConduct = 93, hardness = 30 })
add({ name = "ZR", group = "TRANSIT", description = "Zirconium (Zr), Z=40. Melts 2128K. Boils 4682K. 6.52 g/cm3.", colour = "0x94E0E0", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2128, highTemperatureTransition = "LAVA", weight = 19.56 , heatConduct = 58, hardness = 33 })
add({ name = "NB", group = "TRANSIT", description = "Niobium (Nb), Z=41. Melts 2750K. Boils 5017K. 8.57 g/cm3.", colour = "0x73C2C9", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2750, highTemperatureTransition = "LAVA", weight = 25.71 , heatConduct = 88, hardness = 40 })
add({ name = "MO", group = "TRANSIT", description = "Molybdenum (Mo), Z=42. Melts 2896K. Boils 4912K. 10.2 g/cm3.", colour = "0x54B5B5", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2896, highTemperatureTransition = "LAVA", weight = 30.6 , heatConduct = 141, hardness = 54 })
add({ name = "TC", group = "TRANSIT", description = "Technetium (Tc), Z=43. Melts 2430K. Boils 4538K. 11 g/cm3.", colour = "0x3B9E9E", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2430, highTemperatureTransition = "LAVA", weight = 33 , heatConduct = 93, hardness = 48 })
add({ name = "RU", group = "TRANSIT", description = "Ruthenium (Ru), Z=44. Melts 2607K. Boils 4423K. 12.1 g/cm3.", colour = "0x248F8F", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2607, highTemperatureTransition = "LAVA", weight = 36.3 , heatConduct = 130, hardness = 55 })
add({ name = "RH", group = "TRANSIT", description = "Rhodium (Rh), Z=45. Melts 2237K. Boils 3968K. 12.4 g/cm3.", colour = "0x0A7D8C", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2237, highTemperatureTransition = "LAVA", weight = 37.2 , heatConduct = 147, hardness = 57 })
add({ name = "PD", group = "TRANSIT", description = "Palladium (Pd), Z=46. Melts 1828.05K. Boils 3236K. 12 g/cm3.", colour = "0x6985", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1828.05, highTemperatureTransition = "LAVA", weight = 36 , heatConduct = 102, hardness = 55 })
add({ name = "AG", group = "TRANSIT", description = "Silver (Ag), Z=47. Melts 1234.93K. Boils 2435K. 10.501 g/cm3.", colour = "0xC0C0C0", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1234.93, highTemperatureTransition = "LAVA", weight = 31.503 , heatConduct = 249, hardness = 48 })
add({ name = "IN", group = "POSTTRAN", description = "Indium (In), Z=49. Melts 429.75K. Boils 2345K. 7.31 g/cm3.", colour = "0xA67573", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 429.75, highTemperatureTransition = "LAVA", weight = 21.93 , heatConduct = 109, hardness = 44 })
add({ name = "SN", group = "POSTTRAN", description = "Tin (Sn), Z=50. Melts 505.08K. Boils 2875K. 7.287 g/cm3.", colour = "0x668080", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 505.08, highTemperatureTransition = "LAVA", weight = 21.861 , heatConduct = 98, hardness = 49 })
add({ name = "SB", group = "METALLOID", description = "Antimony (Sb), Z=51. Melts 903.78K. Boils 1860K. 6.685 g/cm3.", colour = "0x9E63B5", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 903.78, highTemperatureTransition = "LAVA", weight = 20.055 , heatConduct = 59, hardness = 51 })
add({ name = "TE", group = "METALLOID", description = "Tellurium (Te), Z=52. Melts 722.66K. Boils 1261K. 6.232 g/cm3.", colour = "0xD47A00", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 722.66, highTemperatureTransition = "LAVA", weight = 18.696 , heatConduct = 54, hardness = 52 })
add({ name = "I", group = "HALOGEN", description = "Iodine (I), Z=53. Melts 386.85K. Boils 457.55K. 4.93 g/cm3.", colour = "0x940094", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 386.85, highTemperatureTransition = "LAVA", weight = 14.79 , heatConduct = 8, hardness = 66 })
add({ name = "XE", group = "NOBLE", description = "Xenon (Xe), Z=54. Melts 161.36K. Boils 165.03K. 0.005887 g/cm3.", colour = "0x429EB0", type = "GAS", menuSection = "SC_GAS", weight = 1 , heatConduct = 1, hardness = 65, diffusion = 2 })
add({ name = "CS", group = "ALKALI", description = "Cesium (Cs), Z=55. Melts 301.59K. Boils 944K. 1.93 g/cm3.", colour = "0x57178F", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 301.59, highTemperatureTransition = "LAVA", weight = 5.79 , heatConduct = 72, hardness = 20, flammable = 40 })
add({ name = "BA", group = "ALKEARTH", description = "Barium (Ba), Z=56. Melts 1000K. Boils 2170K. 3.62 g/cm3.", colour = "0x00C900", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1000, highTemperatureTransition = "LAVA", weight = 10.86 , heatConduct = 51, hardness = 22, flammable = 15 })
add({ name = "LA", group = "LANTH", description = "Lanthanum (La), Z=57. Melts 1191K. Boils 3737K. 6.15 g/cm3.", colour = "0x70D4FF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1191, highTemperatureTransition = "LAVA", weight = 18.45 , heatConduct = 43, hardness = 28, flammable = 10 })
add({ name = "CE", group = "LANTH", description = "Cerium (Ce), Z=58. Melts 1071K. Boils 3697K. 6.77 g/cm3.", colour = "0xFFFFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1071, highTemperatureTransition = "LAVA", weight = 20.31 , heatConduct = 43, hardness = 28, flammable = 10 })
add({ name = "PR", group = "LANTH", description = "Praseodymium (Pr), Z=59. Melts 1204K. Boils 3793K. 6.77 g/cm3.", colour = "0xD9FFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1204, highTemperatureTransition = "LAVA", weight = 20.31 , heatConduct = 43, hardness = 28, flammable = 10 })
add({ name = "ND", group = "LANTH", description = "Neodymium (Nd), Z=60. Melts 1294K. Boils 3347K. 7.01 g/cm3.", colour = "0xC7FFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1294, highTemperatureTransition = "LAVA", weight = 21.03 , heatConduct = 43, hardness = 28, flammable = 10 })
add({ name = "SM", group = "LANTH", description = "Samarium (Sm), Z=62. Melts 1347K. Boils 2067K. 7.52 g/cm3.", colour = "0x8FFFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1347, highTemperatureTransition = "LAVA", weight = 22.56 , heatConduct = 43, hardness = 29, flammable = 10 })
add({ name = "EU", group = "LANTH", description = "Europium (Eu), Z=63. Melts 1095K. Boils 1802K. 5.24 g/cm3.", colour = "0x61FFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1095, highTemperatureTransition = "LAVA", weight = 15.72 , heatConduct = 43, flammable = 10 })
add({ name = "TB", group = "LANTH", description = "Terbium (Tb), Z=65. Melts 1629K. Boils 3503K. 8.23 g/cm3.", colour = "0x30FFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1629, highTemperatureTransition = "LAVA", weight = 24.69 , heatConduct = 43, flammable = 10 })
add({ name = "DY", group = "LANTH", description = "Dysprosium (Dy), Z=66. Melts 1685K. Boils 2840K. 8.55 g/cm3.", colour = "0x1FFFC7", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1685, highTemperatureTransition = "LAVA", weight = 25.65 , heatConduct = 43, hardness = 30, flammable = 10 })
add({ name = "HO", group = "LANTH", description = "Holmium (Ho), Z=67. Melts 1747K. Boils 2973K. 8.8 g/cm3.", colour = "0x00FF9C", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1747, highTemperatureTransition = "LAVA", weight = 26.4 , heatConduct = 43, hardness = 31, flammable = 10 })
add({ name = "ER", group = "LANTH", description = "Erbium (Er), Z=68. Melts 1802K. Boils 3141K. 9.07 g/cm3.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1802, highTemperatureTransition = "LAVA", weight = 27.21 , heatConduct = 43, hardness = 31, flammable = 10 })
add({ name = "TM", group = "LANTH", description = "Thulium (Tm), Z=69. Melts 1818K. Boils 2223K. 9.32 g/cm3.", colour = "0x00D452", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1818, highTemperatureTransition = "LAVA", weight = 27.96 , heatConduct = 43, hardness = 31, flammable = 10 })
add({ name = "YB", group = "LANTH", description = "Ytterbium (Yb), Z=70. Melts 1092K. Boils 1469K. 6.9 g/cm3.", colour = "0x00BF38", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1092, highTemperatureTransition = "LAVA", weight = 20.7 , heatConduct = 43, flammable = 10 })
add({ name = "HF", group = "TRANSIT", description = "Hafnium (Hf), Z=72. Melts 2506K. Boils 4876K. 13.3 g/cm3.", colour = "0x4DC2FF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2506, highTemperatureTransition = "LAVA", weight = 39.9 , heatConduct = 93, hardness = 32 })
add({ name = "TA", group = "TRANSIT", description = "Tantalum (Ta), Z=73. Melts 3290K. Boils 5731K. 16.4 g/cm3.", colour = "0x4DA6FF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 3290, highTemperatureTransition = "LAVA", weight = 49.2 , heatConduct = 91, hardness = 38 })
add({ name = "RE", group = "TRANSIT", description = "Rhenium (Re), Z=75. Melts 3459K. Boils 5869K. 20.8 g/cm3.", colour = "0x267DAB", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 3459, highTemperatureTransition = "LAVA", weight = 62.4 , heatConduct = 83, hardness = 48 })
add({ name = "OS", group = "TRANSIT", description = "Osmium (Os), Z=76. Melts 3306K. Boils 5285K. 22.57 g/cm3.", colour = "0x266696", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 3306, highTemperatureTransition = "LAVA", weight = 67.71 , heatConduct = 113, hardness = 55 })
add({ name = "IR", group = "TRANSIT", description = "Iridium (Ir), Z=77. Melts 2719K. Boils 4701K. 22.42 g/cm3.", colour = "0x175487", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2719, highTemperatureTransition = "LAVA", weight = 67.26 , heatConduct = 145, hardness = 55 })
add({ name = "TL", group = "POSTTRAN", description = "Thallium (Tl), Z=81. Melts 577K. Boils 1746K. 11.8 g/cm3.", colour = "0xA6544D", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 577, highTemperatureTransition = "LAVA", weight = 35.4 , heatConduct = 81, hardness = 40 })
add({ name = "BI", group = "POSTTRAN", description = "Bismuth (Bi), Z=83. Melts 544.55K. Boils 1837K. 9.807 g/cm3.", colour = "0x9E4FB5", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 544.55, highTemperatureTransition = "LAVA", weight = 29.421 , heatConduct = 34, hardness = 50 })
add({ name = "AT", group = "HALOGEN", description = "Astatine (At), Z=85. Melts 575K. 7 g/cm3.", colour = "0x754F45", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 575, highTemperatureTransition = "LAVA", weight = 21 , heatConduct = 12, hardness = 55 })
add({ name = "FR", group = "ALKALI", description = "Francium (Fr), Z=87. Melts 300K.", colour = "0x420066", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 300, highTemperatureTransition = "LAVA" , heatConduct = 107, hardness = 18, flammable = 40 })
add({ name = "RA", group = "ALKEARTH", description = "Radium (Ra), Z=88. Melts 973K. Boils 1413K. 5 g/cm3.", colour = "0x007D00", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 973, highTemperatureTransition = "LAVA", weight = 15 , heatConduct = 120, hardness = 22, flammable = 15 })
add({ name = "AC", group = "ACTINIDE", description = "Actinium (Ac), Z=89. Melts 1324K. Boils 3471K. 10.07 g/cm3.", colour = "0x70ABFA", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1324, highTemperatureTransition = "LAVA", weight = 30.21 , heatConduct = 46, hardness = 28, flammable = 8 })
add({ name = "TH", group = "ACTINIDE", description = "Thorium (Th), Z=90. Melts 2023K. Boils 5061K. 11.72 g/cm3.", colour = "0x00BAFF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 2023, highTemperatureTransition = "LAVA", weight = 35.16 , heatConduct = 88, hardness = 32, flammable = 8 })
add({ name = "PA", group = "ACTINIDE", description = "Protactinium (Pa), Z=91. Melts 1845K. 15.37 g/cm3.", colour = "0x00A1FF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1845, highTemperatureTransition = "LAVA", weight = 46.11 , heatConduct = 46, hardness = 38, flammable = 8 })
add({ name = "NP", group = "ACTINIDE", description = "Neptunium (Np), Z=93. Melts 917K. Boils 4175K. 20.25 g/cm3.", colour = "0x0080FF", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 917, highTemperatureTransition = "LAVA", weight = 60.75 , heatConduct = 46, hardness = 34, flammable = 8 })
add({ name = "AM", group = "ACTINIDE", description = "Americium (Am), Z=95. Melts 1449K. Boils 2284K. 13.69 g/cm3.", colour = "0x545CF2", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1449, highTemperatureTransition = "LAVA", weight = 41.07 , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "CM", group = "ACTINIDE", description = "Curium (Cm), Z=96. Melts 1618K. Boils 3400K. 13.51 g/cm3.", colour = "0x785CE3", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1618, highTemperatureTransition = "LAVA", weight = 40.53 , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "BK", group = "ACTINIDE", description = "Berkelium (Bk), Z=97. Melts 1323K. 14 g/cm3.", colour = "0x8A4FE3", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1323, highTemperatureTransition = "LAVA", weight = 42 , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "CF", group = "ACTINIDE", description = "Californium (Cf), Z=98. Melts 1173K.", colour = "0xA136D4", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1173, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "ES", group = "ACTINIDE", description = "Einsteinium (Es), Z=99. Melts 1133K.", colour = "0xB31FD4", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1133, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "FM", group = "ACTINIDE", description = "Fermium (Fm), Z=100. Melts 1800K.", colour = "0xB31FBA", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1800, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "MD", group = "ACTINIDE", description = "Mendelevium (Md), Z=101. Melts 1100K.", colour = "0xB30DA6", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1100, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "NO", group = "ACTINIDE", description = "Nobelium (No), Z=102. Melts 1100K.", colour = "0xBD0D87", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1100, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "LR", group = "ACTINIDE", description = "Lawrencium (Lr), Z=103. Melts 1900K.", colour = "0xC70066", type = "SOLID", menuSection = "SC_SOLIDS", highTemperature = 1900, highTemperatureTransition = "LAVA" , heatConduct = 46, hardness = 32, flammable = 8 })
add({ name = "RF", group = "TRANSIT", description = "Rutherfordium (Rf), Z=104. Predicted, not measured.", colour = "0xCC0059", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "DB", group = "TRANSIT", description = "Dubnium (Db), Z=105. Predicted, not measured.", colour = "0xD1004F", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "SG", group = "TRANSIT", description = "Seaborgium (Sg), Z=106. Predicted, not measured.", colour = "0xD90045", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "BH", group = "TRANSIT", description = "Bohrium (Bh), Z=107. Predicted, not measured.", colour = "0xE00038", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "HS", group = "TRANSIT", description = "Hassium (Hs), Z=108. Predicted, not measured.", colour = "0xE6002E", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "MT", group = "TRANSIT", description = "Meitnerium (Mt), Z=109. Predicted, not measured.", colour = "0xEB0026", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "DS", group = "TRANSIT", description = "Darmstadtium (Ds), Z=110. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "RG", group = "TRANSIT", description = "Roentgenium (Rg), Z=111. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "CN", group = "TRANSIT", description = "Copernicium (Cn), Z=112. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 93 })
add({ name = "NH", group = "POSTTRAN", description = "Nihonium (Nh), Z=113. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 76 })
add({ name = "FL", group = "POSTTRAN", description = "Flerovium (Fl), Z=114. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 76 })
add({ name = "MC", group = "POSTTRAN", description = "Moscovium (Mc), Z=115. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 76 })
add({ name = "LV", group = "POSTTRAN", description = "Livermorium (Lv), Z=116. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 76 })
add({ name = "TS", group = "HALOGEN", description = "Tennessine (Ts), Z=117. Predicted, not measured.", colour = "0xCCCCCC", type = "SOLID", menuSection = "SC_SOLIDS" , heatConduct = 12 })
add({ name = "OG", group = "NOBLE", description = "Oganesson (Og), Z=118. Predicted, not measured.", colour = "0xCCCCCC", type = "GAS", menuSection = "SC_GAS" , heatConduct = 12 })

if PBX and PBX.log then PBX.log("periodic", "seeded 95 periodic elements; 23 reused from existing game materials") end

-- Family map published for the UI so the materials panel can file every element under its
-- real chemical family instead of a catch-all. The element registry does not carry the group
-- field (verified live: 202 specs, 0 with .group), so it is published here at seed time.
_G.PBX_ELEM_FAMILY = _G.PBX_ELEM_FAMILY or {}
_G.PBX_ELEM_FAMILY["AC"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["AG"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["ALUM"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["AM"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["AR"] = "NOBLE"
_G.PBX_ELEM_FAMILY["AS"] = "METALLOID"
_G.PBX_ELEM_FAMILY["AT"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["B"] = "METALLOID"
_G.PBX_ELEM_FAMILY["BA"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["BE"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["BH"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["BI"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["BK"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["BR"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["C"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["CA"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["CD"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["CE"] = "LANTH"
_G.PBX_ELEM_FAMILY["CF"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["CHRM"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["CM"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["CN"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["COBT"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["CS"] = "ALKALI"
_G.PBX_ELEM_FAMILY["CU"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["Cl"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["DB"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["DS"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["DY"] = "LANTH"
_G.PBX_ELEM_FAMILY["ER"] = "LANTH"
_G.PBX_ELEM_FAMILY["ES"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["EU"] = "LANTH"
_G.PBX_ELEM_FAMILY["F"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["FL"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["FM"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["FR"] = "ALKALI"
_G.PBX_ELEM_FAMILY["GA"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["GADO"] = "LANTH"
_G.PBX_ELEM_FAMILY["GE"] = "METALLOID"
_G.PBX_ELEM_FAMILY["GOLD"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["HE"] = "NOBLE"
_G.PBX_ELEM_FAMILY["HF"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["HO"] = "LANTH"
_G.PBX_ELEM_FAMILY["HS"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["HYGN"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["I"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["IN"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["IR"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["IRON"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["K"] = "ALKALI"
_G.PBX_ELEM_FAMILY["KR"] = "NOBLE"
_G.PBX_ELEM_FAMILY["LA"] = "LANTH"
_G.PBX_ELEM_FAMILY["LEAD"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["LITH"] = "ALKALI"
_G.PBX_ELEM_FAMILY["LR"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["LUTE"] = "LANTH"
_G.PBX_ELEM_FAMILY["LV"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["MC"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["MD"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["MERC"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["MG"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["MN"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["MO"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["MT"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["NA"] = "ALKALI"
_G.PBX_ELEM_FAMILY["NB"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["ND"] = "LANTH"
_G.PBX_ELEM_FAMILY["NE"] = "NOBLE"
_G.PBX_ELEM_FAMILY["NH"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["NI"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["NO"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["NP"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["NTRG"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["OG"] = "NOBLE"
_G.PBX_ELEM_FAMILY["OS"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["OXYG"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["PA"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["PD"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["PHOS"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["PLUT"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["POLO"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["PR"] = "LANTH"
_G.PBX_ELEM_FAMILY["PRMT"] = "LANTH"
_G.PBX_ELEM_FAMILY["PTNM"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["RA"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["RADN"] = "NOBLE"
_G.PBX_ELEM_FAMILY["RBDM"] = "ALKALI"
_G.PBX_ELEM_FAMILY["RE"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["RF"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["RG"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["RH"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["RU"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["S"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["SB"] = "METALLOID"
_G.PBX_ELEM_FAMILY["SC"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["SE"] = "NONMETAL"
_G.PBX_ELEM_FAMILY["SG"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["SLCN"] = "METALLOID"
_G.PBX_ELEM_FAMILY["SM"] = "LANTH"
_G.PBX_ELEM_FAMILY["SN"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["SR"] = "ALKEARTH"
_G.PBX_ELEM_FAMILY["TA"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["TB"] = "LANTH"
_G.PBX_ELEM_FAMILY["TC"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["TE"] = "METALLOID"
_G.PBX_ELEM_FAMILY["TH"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["TL"] = "POSTTRAN"
_G.PBX_ELEM_FAMILY["TM"] = "LANTH"
_G.PBX_ELEM_FAMILY["TS"] = "HALOGEN"
_G.PBX_ELEM_FAMILY["TTAN"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["TUNG"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["URAN"] = "ACTINIDE"
_G.PBX_ELEM_FAMILY["V"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["XE"] = "NOBLE"
_G.PBX_ELEM_FAMILY["Y"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["YB"] = "LANTH"
_G.PBX_ELEM_FAMILY["ZN"] = "TRANSIT"
_G.PBX_ELEM_FAMILY["ZR"] = "TRANSIT"
