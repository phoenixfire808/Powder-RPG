-- RPG plugin: items.lua - weapons & gadgets that live in hotbar slots 6-0 as pseudo items.
-- Craft at anvil/workbench (see R.RECIPES below), hold LEFT mouse to use. Real TPT particles/physics throughout:
-- METL/BRMT slugs with velocity, a real BOMB that arcs and explodes, real FIRE/WATR/ACID/LN2 streams, real LIGH bolts,
-- real PHOT beam. Right-click (place) is a no-op for these - see the `place` hook below.
local R = PBX.state.rpg
local TAG = "items"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local eid, nameOf, has, say, inv, give = R.eid, R.nameOf, R.has, R.say, R.inv, R.give
local floor, sqrt, random = math.floor, math.sqrt, math.random

-- ================================================================ weapon/gadget definitions
local WEAPONS = {
  MUSKET    = { col={100, 90, 80},  cd=16, ammo="METL", cost=1, txt="Musket", alts="KINETIC",
                desc="Fires a real METL slug at the cursor - punches a crater, hurts enemies. Ammo: METL (1/shot)" },
  SHOTGUN   = { col={70, 70, 85},   cd=32, ammo="METL", cost=4, txt="Shotgun", alts="KINETIC",
                desc="Blasts 6 red-hot pellets in a spread - short range, heavy knockback. Ammo: METL (4/shot)" },
  GRENADE   = { col={95, 115, 45},  cd=40, ammo="COAL", cost=3, txt="Grenade Launcher",
                desc="Lobs a real bomb that arcs under gravity and explodes on impact. Ammo: COAL (3/shot)" },
  LIGHTGUN  = { col={230, 220, 140}, cd=30, ammo="GOLD", cost=2, txt="Lightning Rod Gun",
                desc="Launches a crackling real lightning bolt in a straight line. Ammo: GOLD (2/shot)" },
  TPWAND    = { col={180, 80, 220}, cd=90, ammo="GOLD", cost=3, txt="Teleport Wand",
                desc="Blinks you to the cursor in a flash of light - long cooldown. Ammo: GOLD (3/use)" },
  FLAMETH   = { col={230, 90, 30},  cd=2, ammo="COAL", ammoEvery=6, continuous=true, txt="Flamethrower",
                desc="Hold to spray real burning fire - ignites wood, coal and oil. Ammo: COAL (drains while held)" },
  WATERGUN  = { col={60, 140, 220}, cd=2, ammo="WATR", ammoEvery=2, continuous=true, txt="Water Cannon",
                desc="Jets real water - douses fire, floods pits, knocks enemies back. Ammo: WATR (drains while held)" },
  ACIDGUN   = { col={130, 210, 40}, cd=3, ammo="ACID", ammoEvery=3, continuous=true, txt="Acid Sprayer",
                desc="Sprays corrosive acid that eats through almost any block. Ammo: ACID vials (craft at furnace)" },
  FREEZERAY = { col={150, 225, 255}, cd=2, ammo="WATR", ammoEvery=3, continuous=true, txt="Freeze Ray",
                desc="Sprays liquid nitrogen - freezes water to ice, chills enemies. Ammo: WATR (drains while held)" },
  LASERGUN  = { col={255, 70, 70}, cd=1, ammo="QRTZ", ammoEvery=5, continuous=true, txt="Laser Rifle",
                desc="Instant beam of photons that melts soft rock, no travel time. Ammo: QRTZ (drains while held)" },
  DRILL     = { col={205, 205, 215}, cd=3, txt="Power Drill",
                desc="Automatic high-speed mining straight toward the cursor. No ammo, just a short cooldown" },
  JETPACK   = { col={195, 90, 40}, cd=1, ammo="COAL", ammoEvery=8, continuous=true, txt="Jetpack",
                desc="Equip it, then hold W/Space in the air to fly - burns COAL for real fire and gas thrust. Left mouse stays free for your other tool" },
  -- ===== round 2 (the player 16:00 "I want way more items") =====
  NAILGUN     = { col={180, 150, 90},  cd=6,  ammo="METL", cost=1, txt="Steam Nail Gun", alts="KINETIC",
                  desc="Rapid-fire steam-pressure nails - weaker than the musket but fires much faster. Ammo: METL (1/shot)" },
  RAILGUN     = { col={90, 180, 255},  cd=60, ammo="METL", cost=3, txt="Rail Gun", alts="KINETIC",
                  desc="An instant hyper-velocity slug that punches straight through blocks and enemies in a line. Ammo: METL (3/shot)" },
  PLASMATORCH = { col={255, 140, 255}, cd=1,  ammo="COAL", ammoEvery=4, continuous=true, txt="Plasma Torch",
                  desc="Short-range arc of real superheated plasma - vaporizes rock in its path, heavy melee damage. Ammo: COAL (drains while held)" },
  CRYOGRENADE = { col={170, 220, 255}, cd=50, ammo="COAL", cost=2, txt="Cryo Grenade",
                  desc="Lobs a real chunk of ice that bursts into liquid nitrogen on impact, flash-freezing the area. Ammo: COAL (2/shot)" },
  C4CHARGE    = { col={200, 60, 60},   cd=20, ammo="C-4", cost=1, txt="C4 Charge",
                  desc="Places a real C-4 charge (LEFT mouse) - right-click to remotely detonate every charge you've placed. Ammo: C-4" },
  STICKYBOMB  = { col={140, 110, 70},  cd=45, ammo="COAL", cost=2, txt="Sticky Bomb",
                  desc="Lobs a bomb that sticks wherever it lands, then detonates on a 1.5s fuse. Ammo: COAL (2/shot)" },
  BOW         = { col={150, 110, 60},  cd=14, ammo="ARROW", cost=1, txt="Bow",
                  desc="Fires a real arrow on a gravity arc, lit on release so it ignites what it hits. Ammo: Arrows (1/shot)" },
  BOOMERANG   = { col={200, 150, 60},  cd=45, txt="Boomerang",
                  desc="Thrown weapon that flies out, hits everything in its path, then flies back to your hand. No ammo" },
  HARPOON     = { col={160, 160, 170}, cd=40, ammo="METL", cost=2, txt="Harpoon",
                  desc="Fires a real barbed slug that yanks whatever it hits back toward you. Ammo: METL (2/shot)" },
  LAVABUCKET  = { col={255, 110, 40},  cd=6,  txt="Lava Bucket",
                  desc="Scoops real molten lava (only safe with the Lava Charm) and pours it back out. No ammo" },
  DYNAMITE    = { col={180, 40, 30},   cd=70, ammo="COAL", cost=6, txt="Dynamite Bundle",
                  desc="Lobs a cluster of real bombs that chain-explode together for a much bigger crater. Ammo: COAL (6/shot)" },
  SMOKEBOMB   = { col={130, 130, 140}, cd=50, ammo="COAL", cost=2, txt="Smoke Bomb",
                  desc="Lobs a real cloud of smoke that blocks sight and fouls the air - don't linger in your own cloud. Ammo: COAL (2/shot)" },
  MAGNET      = { col={200, 50, 50},   cd=4,  continuous=true, txt="Magnet",
                  desc="Hold near loose ore/powder to pull it toward you with a real magnetic tug. No ammo" },
  OXYTANK     = { col={90, 150, 200},  txt="Oxygen Tank", passive=true,
                  desc="Worn passively (no need to select it). Vents real oxygen around your head when air drops below 40%, on a rechargeable tank" },
  DIVEHELMET  = { col={200, 200, 80},  txt="Diving Helmet", passive=true,
                  desc="Worn passively. Clears a real air pocket around your head whenever you're underwater - breathe indefinitely" },
  GASMASK     = { col={110, 140, 90},  txt="Gas Mask", passive=true,
                  desc="Worn passively. Filters real smoke/toxic gas around your head on land - does not help underwater" },
  CLIMBGLOVES = { col={150, 90, 60},   txt="Climbing Gloves", passive=true,
                  desc="Worn passively. Press toward a wall in mid-air to grip and slide down slowly instead of falling" },
  BALLOON     = { col={230, 90, 140},  txt="Balloon", passive=true,
                  desc="Worn passively. Caps your fall speed to a gentle float whenever you're airborne" },
  -- ===== round 3: weapons (real element mechanisms, see knowledge/design-arsenal-2026-08-31.md) =====
  THERMLANCE  = { col={255, 200, 90},  cd=2,  ammo="IRON", ammoEvery=5, continuous=true, txt="Thermite Lance",
                  desc="Sprays real thermite - burns far hotter than fire and cuts through metal and rock that shrugs off a flamethrower. Ammo: Iron ore (drains while held)" },
  TUNGSNIPER  = { col={110, 100, 95},  cd=75, ammo="TUNG", cost=2, txt="Tungsten Sniper",
                  desc="A single hyper-dense tungsten slug at extreme velocity - punches clean through several blocks in a line. Ammo: Tungsten (2/shot)" },
  TESLAARC    = { col={120, 200, 255}, cd=22, ammo="CU", cost=1, txt="Tesla Arc",
                  desc="Throws real lightning that chains between nearby conductive targets instead of stopping at the first. Ammo: Copper (1/shot)" },
  GRAVWELL    = { col={140, 60, 200},  cd=110, ammo="GOLD", cost=4, txt="Gravity Well Grenade",
                  desc="Lobs a real gravitational well that drags loose matter and enemies inward, then collapses. Ammo: Gold (4/shot)" },
  EMPCHARGE   = { col={90, 220, 200},  cd=90, ammo="CU", cost=3, txt="EMP Charge",
                  desc="Bursts a real electromagnetic pulse - kills sparks and powered machinery in radius without touching the terrain. Ammo: Copper (3/shot)" },
  FOAMGUN     = { col={225, 225, 240}, cd=3,  ammo="GLAS", ammoEvery=4, continuous=true, txt="Aerogel Foam Gun",
                  desc="Sprays real aerogel - sets into a lightweight solid you can bridge gaps, plug leaks and insulate with. Ammo: Glass (drains while held)" },
  DISINT      = { col={40, 40, 50},    cd=4,  ammo="QRTZ", ammoEvery=8, continuous=true, txt="Disintegrator",
                  desc="A void beam that deletes matter outright instead of blasting it - no crater, no debris, no shockwave. Ammo: Quartz (drains while held)" },
  -- ===== round 3: armor (passive, counters the real survival accumulators) =====
  PADHARNESS  = { col={150, 110, 70},  txt="Padded Harness", passive=true, armor="caver",
                  desc="Worn passively. Absorbs landing impact - heavy falls that would break your legs merely hurt. Deep Caver set piece" },
  LAMPHELM    = { col={230, 210, 120}, txt="Miner's Lamp Helm", passive=true, armor="caver",
                  desc="Worn passively. Sheds real light around your head so you can see what you're mining. Deep Caver set piece" },
  LEADVEST    = { col={90, 90, 105},   txt="Lead-Lined Vest", passive=true, armor="reactor",
                  desc="Worn passively. Real lead shielding - steadily bleeds off accumulated radiation dose instead of letting it build. Reactor Engineer set piece" },
  ZIRCPLATE   = { col={190, 200, 210}, txt="Zirconium Faceplate", passive=true, armor="reactor",
                  desc="Worn passively. Reactor-grade heat shielding - sheds the geothermal heat load that cooks you at depth. Reactor Engineer set piece" },
  SEALSUIT    = { col={120, 170, 190}, txt="Sealed Pressure Suit", passive=true, armor="diver",
                  desc="Worn passively. Fully sealed - keeps a real breathable pocket at your head in gas AND underwater, not just one or the other. Void Diver set piece" },
}
local WEAPON_ORDER = { "MUSKET", "SHOTGUN", "GRENADE", "LIGHTGUN", "TPWAND", "FLAMETH", "WATERGUN", "ACIDGUN", "FREEZERAY", "LASERGUN", "DRILL", "JETPACK",
  "NAILGUN", "RAILGUN", "PLASMATORCH", "CRYOGRENADE", "C4CHARGE", "STICKYBOMB", "BOW", "BOOMERANG", "HARPOON", "LAVABUCKET", "DYNAMITE", "SMOKEBOMB", "MAGNET",
  "OXYTANK", "DIVEHELMET", "GASMASK", "CLIMBGLOVES", "BALLOON",
  "THERMLANCE", "TUNGSNIPER", "TESLAARC", "GRAVWELL", "EMPCHARGE", "FOAMGUN", "DISINT",
  "PADHARNESS", "LAMPHELM", "LEADVEST", "ZIRCPLATE", "SEALSUIT" }

for _, k in ipairs(WEAPON_ORDER) do R.ITEMS[k] = { col = WEAPONS[k].col, desc = WEAPONS[k].desc } end

-- recipes: strip our own tagged recipes first (reload-safe), then re-add
for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._tag == TAG then table.remove(R.RECIPES, i) end end
local function addRecipe(out, n, need, st, txt, desc)
  R.RECIPES[#R.RECIPES + 1] = { out = out, n = n, need = need, st = st, txt = txt, desc = desc, _tag = TAG }
  -- Same bug class machines2.lua already fixed at its BASE2_RECIPES loop: a recipe whose `out` has no
  -- R.ITEMS entry is invisible to classMap()/the catalog and silently refuses to craft (R.craft requires
  -- `out` to resolve to R.ITEMS or a real element). WEAPON_ORDER above covers every weapon/gadget code, but
  -- ammo materials like ARROW/ACID/C-4 were never in WEAPONS, so they fell through. Auto-register from the
  -- recipe itself so no future addRecipe call here can reopen this gap - station colour matches machines2.lua.
  if not R.ITEMS[out] then
    R.ITEMS[out] = { col = (st == "anvil") and { 150, 155, 165 } or (st == "workbench") and { 150, 115, 70 }
                     or (st == "furnace") and { 200, 120, 60 } or { 190, 185, 175 }, desc = desc }
  end
end
addRecipe("MUSKET", 1, { METL=6, WOOD=3 }, "anvil", "Musket", WEAPONS.MUSKET.desc)
addRecipe("SHOTGUN", 1, { METL=10, WOOD=2 }, "anvil", "Shotgun", WEAPONS.SHOTGUN.desc)
addRecipe("GRENADE", 1, { STEL=6, GOLD=2 }, "anvil", "Grenade Launcher", WEAPONS.GRENADE.desc)
addRecipe("LIGHTGUN", 1, { CU=4, GOLD=2 }, "anvil", "Lightning Rod Gun", WEAPONS.LIGHTGUN.desc)
addRecipe("FLAMETH", 1, { STEL=4, CU=2 }, "anvil", "Flamethrower", WEAPONS.FLAMETH.desc)
addRecipe("WATERGUN", 1, { CU=3, GLAS=2 }, "workbench", "Water Cannon", WEAPONS.WATERGUN.desc)
addRecipe("ACIDGUN", 1, { GLAS=4, CU=2 }, "anvil", "Acid Sprayer", WEAPONS.ACIDGUN.desc)
addRecipe("ACID", 3, { GOO=4, COAL=1 }, "furnace", "Acid vial", "Bottled corrosive acid - ammo for the Acid Sprayer")
addRecipe("FREEZERAY", 1, { STEL=4, QRTZ=2 }, "anvil", "Freeze Ray", WEAPONS.FREEZERAY.desc)
addRecipe("LASERGUN", 1, { QRTZ=4, GOLD=3, STEL=2 }, "anvil", "Laser Rifle", WEAPONS.LASERGUN.desc)
addRecipe("DRILL", 1, { STEL=8, METL=4 }, "anvil", "Power Drill", WEAPONS.DRILL.desc)
addRecipe("JETPACK", 1, { STEL=6, GOLD=2, CU=2 }, "anvil", "Jetpack", WEAPONS.JETPACK.desc)
-- round 2 ammo materials
addRecipe("ARROW", 8, { WOOD=2 }, "workbench", "Arrows", "Simple wooden arrows - ammo for the Bow")
addRecipe("C-4", 2, { GOLD=2, COAL=3, CU=1 }, "anvil", "C4 charge", "Plastic explosive, stable until sparked - ammo for the C4 Charge")
-- round 2 weapons/gadgets
addRecipe("NAILGUN", 1, { METL=5, WOOD=2 }, "workbench", "Steam Nail Gun", WEAPONS.NAILGUN.desc)
addRecipe("RAILGUN", 1, { STEL=10, CU=4, GOLD=2 }, "anvil", "Rail Gun", WEAPONS.RAILGUN.desc)
addRecipe("PLASMATORCH", 1, { STEL=6, QRTZ=3, CU=2 }, "anvil", "Plasma Torch", WEAPONS.PLASMATORCH.desc)
addRecipe("CRYOGRENADE", 1, { STEL=5, QRTZ=2 }, "anvil", "Cryo Grenade", WEAPONS.CRYOGRENADE.desc)
addRecipe("C4CHARGE", 1, { STEL=4, GOLD=1 }, "anvil", "C4 Charge", WEAPONS.C4CHARGE.desc)
addRecipe("STICKYBOMB", 1, { STEL=4, GOO=6 }, "anvil", "Sticky Bomb", WEAPONS.STICKYBOMB.desc)
addRecipe("BOW", 1, { WOOD=10, METL=2 }, "workbench", "Bow", WEAPONS.BOW.desc)
addRecipe("BOOMERANG", 1, { WOOD=6, METL=4 }, "workbench", "Boomerang", WEAPONS.BOOMERANG.desc)
addRecipe("HARPOON", 1, { STEL=6, METL=4 }, "anvil", "Harpoon", WEAPONS.HARPOON.desc)
addRecipe("LAVABUCKET", 1, { STEL=5 }, "anvil", "Lava Bucket", WEAPONS.LAVABUCKET.desc)
addRecipe("DYNAMITE", 1, { STEL=8, GOLD=3 }, "anvil", "Dynamite Bundle", WEAPONS.DYNAMITE.desc)
addRecipe("SMOKEBOMB", 1, { COAL=8, GOO=4 }, "workbench", "Smoke Bomb", WEAPONS.SMOKEBOMB.desc)
addRecipe("MAGNET", 1, { IRON=6, CU=2 }, "workbench", "Magnet", WEAPONS.MAGNET.desc)
-- round 2 passive gear
addRecipe("OXYTANK", 1, { STEL=6, CU=3, GLAS=2 }, "anvil", "Oxygen Tank", WEAPONS.OXYTANK.desc)
addRecipe("DIVEHELMET", 1, { GLAS=6, STEL=4 }, "anvil", "Diving Helmet", WEAPONS.DIVEHELMET.desc)
addRecipe("GASMASK", 1, { GLAS=4, CU=2, COAL=2 }, "workbench", "Gas Mask", WEAPONS.GASMASK.desc)
addRecipe("CLIMBGLOVES", 1, { WOOD=4, METL=2 }, "workbench", "Climbing Gloves", WEAPONS.CLIMBGLOVES.desc)
addRecipe("BALLOON", 1, { GLAS=3, WOOD=2 }, "workbench", "Balloon", WEAPONS.BALLOON.desc)
-- round 3 weapons
addRecipe("THERMLANCE", 1, { STEL=6, IRON=8, CU=2 }, "anvil", "Thermite Lance", WEAPONS.THERMLANCE.desc)
-- ADDED 2026-09-02 (@deadlock, GAME-FLOW.md S10 finding #2): TUNG ("Tungsten") is a real
-- stock TPT element (src/simulation/elements/TUNG.cpp, TYPE_SOLID, Falldown=0 -- verified
-- safe per DEVELOPMENT.md rule 4; also the exact particle type fireTungsten() below spawns for
-- the "hyper-dense slug punches through several blocks" mechanic, so it's not just an
-- inventory token here) but had zero sources anywhere in this fork: not mined, not crafted,
-- not looted. It was BOTH the build cost (6xTUNG) and the ammo (2/shot) for TUNGSNIPER --
-- permanently unbuildable, and unfireable even if it somehow existed. Gave it a real furnace
-- recipe (refined from Steel at extreme heat) instead of a worldgen placement, since the
-- weapon's own physics already depend on real TUNG particles and a crafted route is the
-- smaller, same-file fix -- matches the tier/pattern of ACID (also crafted ammo, furnace).
addRecipe("TUNG", 2, { STEL=2, COAL=3 }, "furnace", "Tungsten", "Refined from steel at extreme heat -- dense, brittle, very heat-resistant. Ammo for the Tungsten Sniper")
addRecipe("TUNGSNIPER", 1, { TUNG=6, STEL=8, GOLD=2 }, "anvil", "Tungsten Sniper", WEAPONS.TUNGSNIPER.desc)
-- ADDED 2026-09-02 (@matimpl, design-material-progression.md S0/S4 chain 4): THRM ("Thermite") and
-- NITR ("Nitroglycerin") are real stock TPT elements already wired as kinetic-weapon ammo
-- (KINETIC_AMMO above, both in KINETIC_ORDER) but had zero acquisition route anywhere in this fork --
-- no recipe, no R.MINEABLE entry, no quest reward. Confirmed by grep against every R.give/R.MINEABLE/
-- recipe `out=` in the whole tree before this fix: zero matches for either. Exact same bug shape as the
-- historic NSCN/TUNG deadlocks fixed just above -- a real, live deadlock (the player could select THRM/NITR
-- rounds in a kinetic gun's ammo cycle but could never actually hold one). Gave both a furnace recipe
-- matching their own in-game descriptions: THRM "burns into extremely hot molten metal" (iron bar + coal
-- at extreme furnace heat, same station/tier as the TUNG fix above); NITR is native TPT's own "mix with
-- CLST to make TNT" precursor, built here from GOO heated in the furnace (GOO is unlimited-supply topsoil).
addRecipe("THRM", 2, { METL=3, COAL=4 }, "furnace", "Thermite", "Iron bar and coal, fired to extreme heat -- burns into white-hot molten metal, cutting through what a flamethrower can't. Ammo for kinetic weapons (incendiary rounds)")
addRecipe("NITR", 2, { GOO=6 }, "furnace", "Nitroglycerin", "Pressure-sensitive explosive liquid, rendered from dirt at high furnace heat -- mixes with Clay dust for TNT. Ammo for kinetic weapons (explosive rounds)")
addRecipe("TESLAARC", 1, { CU=10, GOLD=3, QRTZ=2 }, "anvil", "Tesla Arc", WEAPONS.TESLAARC.desc)
addRecipe("EMPCHARGE", 1, { CU=8, GOLD=2, QRTZ=3 }, "research", "EMP Charge", WEAPONS.EMPCHARGE.desc)
addRecipe("FOAMGUN", 1, { GLAS=8, STEL=4, CU=2 }, "anvil", "Aerogel Foam Gun", WEAPONS.FOAMGUN.desc)
-- round 3 armor
addRecipe("PADHARNESS", 1, { WOOD=6, GOO=8 }, "workbench", "Padded Harness", WEAPONS.PADHARNESS.desc)
addRecipe("LAMPHELM", 1, { METL=4, GLAS=3, COAL=2 }, "workbench", "Miner's Lamp Helm", WEAPONS.LAMPHELM.desc)
addRecipe("LEADVEST", 1, { LEAD=10, STEL=4 }, "anvil", "Lead-Lined Vest", WEAPONS.LEADVEST.desc)
addRecipe("ZIRCPLATE", 1, { ZIRC=6, STEL=4, GLAS=2 }, "research", "Zirconium Faceplate", WEAPONS.ZIRCPLATE.desc)
addRecipe("SEALSUIT", 1, { STEL=8, GLAS=6, CU=3 }, "anvil", "Sealed Pressure Suit", WEAPONS.SEALSUIT.desc)

-- ================================================================ DMND-gated recipes (@progression,
-- fixing knowledge/audit-natural-pathways.md s9's "DMND is bootstrap-critical, with exactly zero
-- margin" finding, reproduced live by scripts/check_natural.py's own BOOTSTRAP-CRITICAL check).
-- TPWAND/GRAVWELL/DISINT are the only items.lua recipes that spend DMND itself. DMND's entire
-- deterministic one-time supply is 3 (two quest rewards, rpg.lua) and the diamond pick's own
-- recipe needs exactly 3 -- the pick is what raises pick power to DMND's own R.MINEABLE tier 6,
-- so DMND only becomes renewably mineable AFTER the pick exists. A player who spends the one-time
-- 3 on one of these three FIRST, before ever crafting the pick, permanently loses the deterministic
-- route to the pick (and to any more DMND at all) -- a silent, no-warning, order-dependent trap,
-- not a hard deadlock (a probabilistic loot-chest pick bypass still exists) but exactly the shape
-- PhoenixFire808's bar rejects. Fix: don't OFFER these three recipes in the crafting UI until the
-- diamond pick is already owned -- same "gate a recipe tier behind a prerequisite, poll cheaply via
-- R.hooks.tick, install once" pattern rpg_plugins/fieldtools.lua's own REACTOR_RECIPES/R.tech.reactor
-- gate already uses (not a new mechanic). Costs are unchanged; this only reorders WHEN the recipe
-- becomes selectable, so the deterministic 3-DMND route to the pick can never be spent on
-- anything else first. Reload-safe: `dmndRecipesInstalled` resets on every hot-reload/newworld, so
-- if the pick is already owned the very next tick re-installs these three immediately.
local dmndRecipesInstalled = false
local function hasDiamondPick() return R.stats and R.stats.crafted and R.stats.crafted["diamond pick"] end
local function installDmndGatedRecipes()
  addRecipe("TPWAND", 1, { GOLD=4, QRTZ=4, DMND=1 }, "anvil", "Teleport Wand", WEAPONS.TPWAND.desc)
  addRecipe("GRAVWELL", 1, { GOLD=8, DMND=1, QRTZ=4 }, "research", "Gravity Well Grenade", WEAPONS.GRAVWELL.desc)
  addRecipe("DISINT", 1, { DMND=2, QRTZ=8, GOLD=4 }, "advlab", "Disintegrator", WEAPONS.DISINT.desc)
end
hook(R.hooks.tick, function()
  if not dmndRecipesInstalled and hasDiamondPick() then
    dmndRecipesInstalled = true
    installDmndGatedRecipes()
  end
end)
hook(R.hooks.newworld, function() dmndRecipesInstalled = false end)
hook(R.hooks.sandbox, function()
  if not dmndRecipesInstalled then dmndRecipesInstalled = true; installDmndGatedRecipes() end
end)

-- ================================================================ shared state (persists across reload)
R.itemsCD = R.itemsCD or {}              -- name -> frame last fired
R.itemsProj = R.itemsProj or {}          -- tracked flying projectiles: {id, kind, born, dmg, kb, r, lastx, lasty}
R.itemsFireCounter = R.itemsFireCounter or {}
R.itemsFlash = R.itemsFlash or nil
R.itemsJetHold = R.itemsJetHold or 0     -- consecutive frames W/Space held with the jetpack equipped
R.itemsC4 = R.itemsC4 or {}              -- placed C4 charges: {x, y} world coords, remote-detonated via right-click
R.itemsO2Charge = R.itemsO2Charge or 400 -- Oxygen Tank reserve (0..400)
R.itemsBeams = R.itemsBeams or {}        -- instant-hit weapons (rail gun/laser): {x1,y1,x2,y2,frame,col}
R.itemsHeat = R.itemsHeat or {}          -- laser/plasma torch heat targets: partID -> {nm, accum, touch}
R.itemsLastHp = R.itemsLastHp or R.hp    -- previous-tick HP, for the muzzle-blast grace-period check below

local SOFT = { GRSS=1, SAND=1, SNOW=1, ICE=1, PLNT=1, WOOD=1, CLST=1, GOO=1, BCOL=1, COAL=1, GRNT=1, BRCK=1, GLAS=1 }

-- hand anchor: the exact point drawHeldWeapon() draws the gun's grip at, so the aim vector, the drawn barrel and
-- the projectile spawn point are all the same anchor - "shooting doesn't come out of the gun accurately" fix
local function handAnchor()
  local face = R.P.face or 1
  return floor(R.P.x) - R.cam.x + (face > 0 and 3 or -4), floor(R.P.y) - R.cam.y - 8
end
local playerCanvas = handAnchor  -- kept as an alias: a few effects (teleport flash, etc.) just want "near the player"
local function aimAt(mx, my)
  local cx, cy = handAnchor()
  local dx, dy = mx - cx, my - cy
  local d = sqrt(dx * dx + dy * dy)
  if d < 1 then dx, dy, d = (R.P.face or 1), 0, 1 end
  return dx / d, dy / d, cx, cy, d
end
local function dealDamage(wx, wy, radius, dmg, kb)
  if type(R.damageEnemiesAt) == "function" then pcall(R.damageEnemiesAt, wx, wy, radius, dmg, kb) end
end
local function crater(cx, cy, r)
  for y = cy - r, cy + r do for x = cx - r, cx + r do
    if (x - cx) ^ 2 + (y - cy) ^ 2 <= r * r + 1 then
      local p = sim.partID(x, y)
      if p then local nm = nameOf(sim.partProperty(p, "type")); if SOFT[nm] then sim.partKill(p) end end
    end
  end end
  if type(R.crumble) == "function" then pcall(R.crumble, cx, cy, r + 2) end  -- the player 17:58: collapse leftover micro-specks into real rubble
end
-- ================================================================ impact FX
-- ONE helper driven by a per-weapon `fx` style, rather than bespoke effect code in every fire
-- function. Everything it emits is a REAL particle obeying real physics - the spectacle IS the
-- simulation, not an overlay painted on top of it.
-- ponytail: styles are a flat if-chain; fine at this size, make it a lookup table past ~10.
local function impactFX(x, y, style, ux, uy)
  if not style then return end
  local function put(el, n, spd, life, temp)
    local t = eid(el); if not t then return end
    for _ = 1, n do
      local a = random() * math.pi * 2
      local px, py = floor(x + math.cos(a) * 2), floor(y + math.sin(a) * 2)
      if not sim.partID(px, py) then
        local id = sim.partCreate(-1, px, py, t)
        if id and id >= 0 then
          sim.partProperty(id, "vx", math.cos(a) * spd); sim.partProperty(id, "vy", math.sin(a) * spd)
          if life then sim.partProperty(id, "life", life) end
          if temp then sim.partProperty(id, "temp", temp) end
        end
      end
    end
  end
  if style == "burn" then       put("FIRE", 5, 1.6, 14, 1200); put("SMKE", 3, 0.8, 20)
  elseif style == "spark" then  put("SPRK", 3, 2.2, 6); put("PHOT", 4, 3.0, 8)
  elseif style == "frost" then  put("LN2", 5, 1.2, nil, 60)
  elseif style == "plasma" then put("PLSM", 4, 1.8, 10, 4000); put("SMKE", 2, 0.7, 16)
  elseif style == "void" then   put("PHOT", 6, 2.4, 10)
  elseif style == "blast" then
    put("FIRE", 6, 2.2, 12, 1400); put("SMKE", 4, 1.0, 24)
    -- real thrown debris: rubble with genuine outward velocity, so a hit visibly scatters ground
    local dt = eid("STNE") or eid("BRMT")
    if dt then for _ = 1, 6 do
      local a = random() * math.pi * 2; local s = 1.5 + random() * 2
      local px, py = floor(x + math.cos(a) * 3), floor(y + math.sin(a) * 3)
      if not sim.partID(px, py) then
        local id = sim.partCreate(-1, px, py, dt)
        if id and id >= 0 then sim.partProperty(id, "vx", math.cos(a) * s); sim.partProperty(id, "vy", math.sin(a) * s - 1) end
      end
    end end
  elseif style == "pierce" then
    -- directional: sparks spray back along the entry line, so a punch-through reads as one
    local t = eid("SPRK")
    if t and ux then for _ = 1, 5 do
      local j = (random() - 0.5) * 0.8
      local px, py = floor(x - ux * 2), floor(y - uy * 2)
      if not sim.partID(px, py) then
        local id = sim.partCreate(-1, px, py, t)
        if id and id >= 0 then sim.partProperty(id, "vx", (-ux + j) * 2.5); sim.partProperty(id, "vy", (-uy + j) * 2.5); sim.partProperty(id, "life", 6) end
      end
    end end
    put("SMKE", 2, 0.6, 14)
  end
end
R.itemsImpactFX = impactFX  -- exported like R.itemsDispatch: lets a bridge test render an
-- impact in open air to prove the effect works, without firing a destructive round through terrain.
local function ready(name, w) return (R.frame - (R.itemsCD[name] or -9999)) >= w.cd end
local function fired(name) R.itemsCD[name] = R.frame end
local function flash(x, y)  -- muzzle flash marker + a small real smoke puff, per the player 17:22
  R.itemsFlash = { x = x, y = y, frame = R.frame }
  local st = eid("SMKE")
  if st and not sim.partID(x, y) then
    local id = sim.partCreate(-1, x, y, st)
    if id and id >= 0 then sim.partProperty(id, "life", 10); sim.partProperty(id, "vy", -0.3) end
  end
end
local function recoil(ux, uy, mag) R.P.vx = R.P.vx - ux * mag end
local function addBeam(x1, y1, x2, y2, col) R.itemsBeams[#R.itemsBeams + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, frame = R.frame, col = col } end
local function canAmmo(w) if not w.ammo then return true end; return inv(w.ammo) >= (w.cost or 1) end
local function spendAmmo(w) if w.ammo then R.inventory[w.ammo] = inv(w.ammo) - (w.cost or 1) end end
local function ammoOk(w) return (not w.ammo) or inv(w.ammo) >= 1 end
-- ================================================================ ammo as a modifier
-- Load a different real element into a kinetic gun and it genuinely behaves differently, because
-- the projectile IS that element and TPT's own physics does the rest - NITR really detonates,
-- THRM really burns what it hits, LEAD is really denser. One shared table drives every kinetic
-- gun, and the values are MULTIPLIERS so each weapon keeps the balance it already had.
-- GUNPOWDER/BCOL added 2026-09-0X (@progression, fixing the documented DEAD-END class: machines2.lua's
-- POWDERMILLKIT->GUNPOWDER and machines.lua's CRUSHERKIT->BCOL both produced a real inventory item
-- with zero consumer anywhere in the game -- "a player spends real resources on a machine that does
-- nothing" -- per this file's own header/acq_forage.lua's DEAD ENDS note. GUNPOWDER's own R.ITEMS
-- description already calls it out as "a crafting reagent for future ammo" (machines2.lua:1009) --
-- this is that ammo, wired the identical way THRM/NITR closed the same bug shape just above (a real
-- element loaded into a kinetic gun, TPT's own physics driving the difference). BCOL keeps its
-- existing mine-remap (picking it up off the ground still folds into COAL, unchanged -- see the
-- nm=="BCOL" checks throughout this file) but the Crusher's own R.give("BCOL",2) (machines.lua) puts
-- literal BCOL in inventory, bypassing that remap by design (a genuinely finer, purpose-milled dust,
-- not lump coal) -- giving it a real use here closes the dead end without touching machines.lua.
local KINETIC_AMMO = {
  METL      = { el = "BMTL", v = 1.00, dmg = 1.00, label = "standard",    fx = "spark" },
  LEAD      = { el = "LEAD", v = 0.80, dmg = 1.55, label = "dense",       fx = "pierce" },
  THRM      = { el = "THRM", v = 0.95, dmg = 0.85, temp = 2500, label = "incendiary", fx = "burn"  },
  NITR      = { el = "NITR", v = 0.90, dmg = 1.20, temp = 500,  label = "explosive",  fx = "blast" },
  GUNPOWDER = { el = "BCOL", v = 1.05, dmg = 1.15, temp = 400,  label = "black-powder", fx = "spark" },
  BCOL      = { el = "BCOL", v = 0.90, dmg = 0.80, temp = 400,  label = "dust round",   fx = "spark" },
}
-- Exotic rounds are preferred over plain METL, so what you carry is how you "load" a gun.
-- ponytail: inventory IS the ammo selector; add a cycle key if carrying both and choosing matters.
-- GUNPOWDER (a deliberately milled, higher-quality dust) outranks the Crusher's raw BCOL byproduct;
-- both still rank below the three original exotic rounds and above plain METL.
local KINETIC_ORDER = { "THRM", "NITR", "LEAD", "GUNPOWDER", "BCOL", "METL" }
-- WEAPONS is declared above this point, so guns opt in with the string "KINETIC" and it is
-- resolved to the real table here, once, instead of duplicating the table on every weapon.
for _, wdef in pairs(WEAPONS) do if wdef.alts == "KINETIC" then wdef.alts = KINETIC_AMMO end end
-- AMMO CONSUMER INDEX (added 2026-09-02 @lead, spec by @acq_discover).
-- The guide's "what is this used for?" reverse lookup could see R.RECIPES but NOT weapon ammo,
-- because the ammo tables are file-locals here. @acq_discover correctly refused to hand-copy them
-- into guide.lua -- that is the hardcoded-list antipattern that let ~90 craftables silently rot
-- into one bucket before v1.15.98. Publishing the real data on R instead keeps one source of truth.
-- Built once at load. guide.lua reads R.AMMO_CONSUMERS[code] defensively, so the two can ship
-- independently in either order.
R.AMMO_CONSUMERS = {}
for wk, w in pairs(WEAPONS) do
  local codes = {}
  if w.alts then
    for a in pairs(w.alts) do codes[#codes + 1] = a end
  elseif w.ammo then
    codes[1] = w.ammo
  end
  for _, code in ipairs(codes) do
    local list = R.AMMO_CONSUMERS[code]
    if not list then list = {}; R.AMMO_CONSUMERS[code] = list end
    list[#list + 1] = { weapon = wk, cost = w.cost or 1, continuous = w.continuous or false }
  end
end
local function pickAmmo(w)
  if not w.alts then return w.ammo, nil end
  local cost = w.cost or 1
  for _, a in ipairs(KINETIC_ORDER) do
    if w.alts[a] and inv(a) >= cost then return a, w.alts[a] end
  end
  return w.ammo, nil   -- nothing carried: the caller's shortfall hint path reports it
end
local function spendPicked(a, w) R.inventory[a] = inv(a) - (w.cost or 1) end
R.itemsPickAmmo = function(k) local w = WEAPONS[k]; if not w then return nil end; return pickAmmo(w) end
-- exported like R.itemsDispatch: lets a bridge test confirm which round a gun would load WITHOUT
-- firing it, so selection logic is verifiable without putting real projectiles in a live world.
local function anyAmmo(w)  -- true if ANY accepted round is carried, not just the default
  if not w.alts then return canAmmo(w) end
  local cost = w.cost or 1
  for a in pairs(w.alts) do if inv(a) >= cost then return true end end
  return false
end
local function ammoTick(name, w)  -- continuous weapons: consume 1 ammo every ammoEvery calls, only when ammo available
  if not w.ammo then return true end
  R.itemsFireCounter[name] = (R.itemsFireCounter[name] or 0) + 1
  if R.itemsFireCounter[name] % w.ammoEvery == 0 then R.inventory[w.ammo] = inv(w.ammo) - 1 end
  return true
end
-- default muzzle/beam-start distance if a weapon has no SHAPES entry; real weapons shadow this per-function with
-- their own SHAPES[key].len right after calling aimAt(), so the spawn point is exactly the drawn barrel tip.
-- Whatever the length, it must clear the player's own hurtbox (BOXT=-10..0, BOXL=-2..BOXR=1 in rpg.lua) in every
-- aim direction or the weapon cooks its own wielder - verified safe at len>=13 from the hand anchor (see hub log)
local MUZZLE = 9

-- ================================================================ held-weapon sprites (drawn in drawHUD, on top of the
-- player's arm - R.hooks.draw runs BEFORE the core player sprite, so a gun drawn there would be hidden behind the body)
local SHAPES = {
  MUSKET    = { len = 14 },
  SHOTGUN   = { len = 9,  thick = true },
  GRENADE   = { len = 8,  thick = true,  tank = { 150, 170, 80 } },
  LIGHTGUN  = { len = 8,  coil = true },
  TPWAND    = { len = 6,  coil = true },
  FLAMETH   = { len = 13, tank = { 200, 70, 20 } },
  WATERGUN  = { len = 10, tank = { 50, 120, 200 } },
  ACIDGUN   = { len = 13, tank = { 110, 190, 30 } },
  FREEZERAY = { len = 11, coil = true },
  LASERGUN  = { len = 13, coil = true },
  DRILL     = { len = 7,  thick = true, spin = true },
  NAILGUN     = { len = 10 },
  RAILGUN     = { len = 15, thick = true },
  PLASMATORCH = { len = 13, coil = true },
  CRYOGRENADE = { len = 8,  thick = true, tank = { 150, 200, 230 } },
  C4CHARGE    = { len = 6,  coil = true },
  STICKYBOMB  = { len = 7,  thick = true },
  BOW         = { len = 12 },
  BOOMERANG   = { len = 9,  thick = true },
  HARPOON     = { len = 13 },
  LAVABUCKET  = { len = 7,  tank = { 255, 120, 40 } },
  DYNAMITE    = { len = 9,  thick = true, tank = { 180, 40, 30 } },
  SMOKEBOMB   = { len = 7,  thick = true },
  MAGNET      = { len = 8,  coil = true },
  THERMLANCE  = { len = 15, coil = true,  tank = { 255, 190, 80 } },
  TUNGSNIPER  = { len = 18, thick = true },
  TESLAARC    = { len = 10, coil = true },
  GRAVWELL    = { len = 8,  thick = true, tank = { 140, 60, 200 } },
  EMPCHARGE   = { len = 8,  coil = true },
  FOAMGUN     = { len = 12, tank = { 225, 225, 240 } },
  DISINT      = { len = 14, coil = true },
}

-- ================================================================ single-shot weapons (real projectile particles)
local function fireMusket(mx, my)
  local w = WEAPONS.MUSKET; if not ready("MUSKET", w) then return end
  if not anyAmmo(w) then R.hint = "Musket needs " .. R.nice("METL"); return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.MUSKET.len
  local an, mod = pickAmmo(w)
  fired("MUSKET"); spendPicked(an, w)
  local t = eid(mod and mod.el or "BMTL")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    local sp = 6 * (mod and mod.v or 1)
    sim.partProperty(id, "vx", ux * sp); sim.partProperty(id, "vy", uy * sp)
    if mod and mod.temp then sim.partProperty(id, "temp", mod.temp) end
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "musket", fx = (mod and mod.fx) or "spark", ux = ux, uy = uy, born = R.frame, dmg = floor(28 * (mod and mod.dmg or 1)), kb = 6, r = 2, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 0.5)
  R.hint = "Musket (" .. (mod and mod.label or "standard") .. ") - " .. R.nice(an) .. " x" .. inv(an)
end
local function fireShotgun(mx, my)
  local w = WEAPONS.SHOTGUN; if not ready("SHOTGUN", w) then return end
  if not anyAmmo(w) then R.hint = "Shotgun needs " .. R.nice("METL") .. " x4"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.SHOTGUN.len
  local an, mod = pickAmmo(w)
  fired("SHOTGUN"); spendPicked(an, w)
  local t = eid(mod and mod.el or "BRMT")
  for _ = 1, 6 do
    local a = (random() - 0.5) * 0.5; local ca, sa = math.cos(a), math.sin(a)
    local pux, puy = ux * ca - uy * sa, ux * sa + uy * ca
    local sx, sy = floor(cx + pux * MUZZLE), floor(cy + puy * MUZZLE)
    local id = t and sim.partCreate(-1, sx, sy, t)
    if id and id >= 0 then
      local sp = 11 * (mod and mod.v or 1)
      sim.partProperty(id, "vx", pux * sp); sim.partProperty(id, "vy", puy * sp)
      if mod and mod.temp then sim.partProperty(id, "temp", mod.temp) end
      R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "pellet", fx = (mod and mod.fx) or "spark", ux = ux, uy = uy, born = R.frame, dmg = floor(10 * (mod and mod.dmg or 1)), kb = 10, r = 1, life = 220, lastx = sx, lasty = sy }
    end
  end
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); recoil(ux, uy, 1.1)
  R.hint = "Shotgun (" .. (mod and mod.label or "standard") .. ") - " .. R.nice(an) .. " x" .. inv(an)
end
local function fireGrenade(mx, my)
  local w = WEAPONS.GRENADE; if not ready("GRENADE", w) then return end
  if not canAmmo(w) then R.hint = "Grenade Launcher needs " .. R.nice("COAL") .. " x3"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.GRENADE.len
  fired("GRENADE"); spendAmmo(w)
  local t = eid("BOMB")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5 - 2.2)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "grenade", fx = "blast", born = R.frame, dmg = 90, kb = 14, r = 22, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 1.4); R.hint = "Grenade away! - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function fireLightning(mx, my)
  local w = WEAPONS.LIGHTGUN; if not ready("LIGHTGUN", w) then return end
  if not canAmmo(w) then R.hint = "Lightning Rod Gun needs " .. R.nice("GOLD") .. " x2"; return end
  fired("LIGHTGUN"); spendAmmo(w)
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.LIGHTGUN.len
  local range = 70; local lastx, lasty = floor(cx), floor(cy); local fg = eid("FIGH")
  for st = MUZZLE, range, 2 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st); lastx, lasty = x, y
    local p = sim.partID(x, y)
    if p then local ty = sim.partProperty(p, "type"); local nm = nameOf(ty)
      if (fg and ty == fg) or R.MINEABLE[nm] then break end end
  end
  local lt = eid("LIGH")
  if lt then for st = MUZZLE, range, 4 do local x, y = floor(cx + ux * st), floor(cy + uy * st)
    if (x - cx) * ux + (y - cy) * uy <= (lastx - cx) * ux + (lasty - cy) * uy + 2 and not sim.partID(x, y) then
      local id = sim.partCreate(-1, x, y, lt); if id and id >= 0 then sim.partProperty(id, "vx", ux * 3); sim.partProperty(id, "vy", uy * 3); sim.partProperty(id, "life", 4) end end
  end end
  dealDamage(lastx + R.cam.x, lasty + R.cam.y, 10, 45, 14)
  flash(lastx, lasty); recoil(ux, uy, 0.3); R.hint = "Lightning! - " .. R.nice("GOLD") .. " x" .. inv("GOLD")
end
local function fireTeleport(mx, my)
  local w = WEAPONS.TPWAND; if not ready("TPWAND", w) then return end
  if not canAmmo(w) then R.hint = "Teleport Wand needs " .. R.nice("GOLD") .. " x3"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.TPWAND.len
  local tx, ty, ok = nil, nil, false
  for st = 90, 10, -2 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st)
    if x > 5 and x < R.W - 5 and y > 5 and y < R.H - 5 and not sim.partID(x, y) and not sim.partID(x, y + 1) then tx, ty, ok = x, y, true; break end
  end
  if not ok then R.hint = "Teleport Wand: no clear spot that way"; return end
  fired("TPWAND"); spendAmmo(w)
  local pt = eid("PHOT")
  if pt then for _ = 1, 6 do local id = sim.partCreate(-1, floor(cx + (random() - 0.5) * 6), floor(cy + (random() - 0.5) * 6), pt); if id and id >= 0 then sim.partProperty(id, "life", 6) end end end
  R.P.x, R.P.y, R.P.vx, R.P.vy = tx + R.cam.x, ty + R.cam.y, 0, 0
  if pt then for _ = 1, 6 do local id = sim.partCreate(-1, floor(tx + (random() - 0.5) * 6), floor(ty + (random() - 0.5) * 6), pt); if id and id >= 0 then sim.partProperty(id, "life", 6) end end end
  R.hint = "Blink! - " .. R.nice("GOLD") .. " x" .. inv("GOLD")
end

-- ================================================================ continuous stream weapons / gadgets
local function streamFlamethrower(mx, my)
  local w = WEAPONS.FLAMETH; if not ready("FLAMETH", w) then return end
  if not ammoOk(w) then R.hint = "Flamethrower needs " .. R.nice("COAL"); return end
  fired("FLAMETH"); ammoTick("FLAMETH", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("FIRE")
  local MUZZLE = SHAPES.FLAMETH.len
  for _ = 1, 2 do
    local j = (random() - 0.5) * 0.3; local jx, jy = ux + j, uy + j
    local sx, sy = floor(cx + jx * MUZZLE), floor(cy + jy * MUZZLE)
    local id = t and sim.partCreate(-1, sx, sy, t)
    if id and id >= 0 then sim.partProperty(id, "vx", jx * 4); sim.partProperty(id, "vy", jy * 4); sim.partProperty(id, "temp", 1000) end
  end
  dealDamage(cx + R.cam.x + ux * 20, cy + R.cam.y + uy * 20, 10, 2, 2)
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); R.hint = "Flamethrower - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function streamWatergun(mx, my)
  local w = WEAPONS.WATERGUN; if not ready("WATERGUN", w) then return end
  if not ammoOk(w) then R.hint = "Water Cannon needs " .. R.nice("WATR"); return end
  fired("WATERGUN"); ammoTick("WATERGUN", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("WATR")
  local MUZZLE = SHAPES.WATERGUN.len
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then sim.partProperty(id, "vx", ux * 6); sim.partProperty(id, "vy", uy * 6) end
  dealDamage(cx + R.cam.x + ux * 24, cy + R.cam.y + uy * 24, 10, 1, 10)
  flash(sx, sy); R.hint = "Water Cannon - " .. R.nice("WATR") .. " x" .. inv("WATR")
end
local function streamAcid(mx, my)
  local w = WEAPONS.ACIDGUN; if not ready("ACIDGUN", w) then return end
  if not ammoOk(w) then R.hint = "Acid Sprayer needs " .. R.nice("ACID") .. " vials"; return end
  fired("ACIDGUN"); ammoTick("ACIDGUN", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("ACID")
  local MUZZLE = SHAPES.ACIDGUN.len
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5) end
  dealDamage(cx + R.cam.x + ux * 22, cy + R.cam.y + uy * 22, 9, 4, 4)
  if type(R.crumble) == "function" then pcall(R.crumble, floor(cx + ux * 22), floor(cy + uy * 22), 5) end
  flash(sx, sy); R.hint = "Acid Sprayer - " .. R.nice("ACID") .. " x" .. inv("ACID")
end
local function streamFreeze(mx, my)
  local w = WEAPONS.FREEZERAY; if not ready("FREEZERAY", w) then return end
  if not ammoOk(w) then R.hint = "Freeze Ray needs " .. R.nice("WATR"); return end
  fired("FREEZERAY"); ammoTick("FREEZERAY", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("LN2")
  local MUZZLE = SHAPES.FREEZERAY.len
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5); sim.partProperty(id, "temp", 60) end
  local tx, ty = floor(cx + ux * 20), floor(cy + uy * 20); local fg = eid("FIGH")
  if fg then local p = sim.partID(tx, ty); if p and sim.partProperty(p, "type") == fg then sim.partProperty(p, "vx", 0); sim.partProperty(p, "vy", 0) end end
  dealDamage(tx + R.cam.x, ty + R.cam.y, 8, 1, 0)
  flash(sx, sy); R.hint = "Freeze Ray - " .. R.nice("WATR") .. " x" .. inv("WATR")
end
-- ================================================================ laser/plasma torch: real heat, not instant delete
-- (the player 17:53) - add real temp to the hit block every tick (rate scaled inverse to R.HARD, so soft stuff like ice/
-- sand cooks fast and granite/titanium take a while), bleed a little into neighbours so a glowing pocket forms and
-- widens, and let TPT's own HighTemperature transition do the melting/igniting/vaporising. A few materials (dirt,
-- coal, diamond) have no real high-temp transition in this build (HighTemperature==10000, i.e. "never") - those get
-- a manual vaporize-and-credit fallback once accumulated heat crosses a threshold, so the laser can still cut them.
-- per the player 18:05 / lead's measured-live numbers: one-shot heating decays back down within ~1s because TPT averages
-- temperature across neighbours (ambient heat sim is off, so it stays in the rock rather than leaking to air, but
-- still needs SUSTAINED per-tick input to climb). R.addHeat(cx,cy,rad,K/tick,cap) is core's helper for this -
-- R.addHeat(x,y,3,260) every tick was measured to melt granite (HT 1523) to LAVA in ~1-2s of held beam.
-- Base rate is granite's own proven number (260K/tick at hardness 3); other materials scale inversely with R.HARD,
-- so ice/sand cook much faster and titanium/diamond much slower, using the *same* real per-tick call every frame.
local function laserHeat(x, y, rateMul)
  local p = sim.partID(x, y); if not p then return nil end
  local ty = sim.partProperty(p, "type"); local nm = nameOf(ty)
  if not R.MINEABLE[nm] then return nm end  -- not a block (open air / enemy / passable gas) - nothing to heat
  local okht, ht = pcall(elem.property, ty, "HighTemperature")
  if okht and ht and ht >= 9000 then
    -- no real melting point (dirt/coal/diamond etc.) - destroy directly on a short hit-count instead of simulating heat
    local rec = R.itemsHeat[p]
    if not rec or rec.nm ~= nm then rec = { nm = nm, accum = 0, direct = true }; R.itemsHeat[p] = rec end
    rec.accum = rec.accum + 1; rec.touch = R.frame; rec.x, rec.y = x, y
    if rec.accum >= 3 then
      sim.partKill(p); R.itemsHeat[p] = nil
      if type(R.crumble) == "function" then pcall(R.crumble, x, y, 4) end
      give(nm == "BCOL" and "COAL" or nm, 1); R.hint = "Cut through " .. R.nice(nm)
      return nm, true, rec.accum
    end
    return nm, false, rec.accum
  end
  local rec = R.itemsHeat[p]
  if not rec or rec.nm ~= nm then rec = { nm = nm, accum = 0 }; R.itemsHeat[p] = rec end
  local hard = R.HARD[nm] or 3
  local k = (260 * 3 / hard) * (rateMul or 1)
  if type(R.addHeat) == "function" then pcall(R.addHeat, x, y, 3, k, 4000) end
  rec.accum = rec.accum + k; rec.touch = R.frame; rec.x, rec.y = x, y
  -- occasional sparks/steam/smoke at the hit point as it heats up
  if R.frame % 4 == 0 then
    local sp = eid("SPRK"); if sp and not sim.partID(x, y - 1) then local id = sim.partCreate(-1, x, y - 1, sp); if id and id >= 0 then sim.partProperty(id, "life", 3) end end
    local wt = eid("WTRV"); if wt and rec.accum > 1200 and not sim.partID(x + (random() > 0.5 and 1 or -1), y - 1) then local id = sim.partCreate(-1, x + (random() > 0.5 and 1 or -1), y - 1, wt); if id and id >= 0 then sim.partProperty(id, "life", 20) end end
  end
  return nm, false, rec.accum
end
local function streamLaser(mx, my)
  local w = WEAPONS.LASERGUN; if not ready("LASERGUN", w) then return end
  if not ammoOk(w) then R.hint = "Laser Rifle needs " .. R.nice("QRTZ"); return end
  fired("LASERGUN"); ammoTick("LASERGUN", w)
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.LASERGUN.len
  local range = 120; local fg = eid("FIGH")
  local lastx, lasty = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local hitNm = nil
  for st = MUZZLE, range, 2 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st)
    local p = sim.partID(x, y)
    if p then
      local ty = sim.partProperty(p, "type"); local nm = nameOf(ty)
      if (fg and ty == fg) or R.MINEABLE[nm] then lastx, lasty = x, y; hitNm = nm; break end
      -- passable gas/fire etc: the beam shines straight through, keep tracing
    else lastx, lasty = x, y end
  end
  local accum = 0
  if hitNm then
    local fgty = fg and sim.partID(lastx, lasty)
    if fg and fgty and sim.partProperty(fgty, "type") == fg then
      dealDamage(lastx + R.cam.x, lasty + R.cam.y, 6, 6, 3)  -- enemies still take direct damage, no heat mechanic needed there
    else
      local _, _, a = laserHeat(lastx, lasty, 1.0); accum = a or 0
    end
  end
  -- flicker: the beam colour jitters slightly in brightness each tick instead of being perfectly static
  local flick = 235 + floor(random() * 20)
  addBeam(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE), lastx, lasty, { flick, 60 + floor(random() * 30), 60 })
  -- white-hot impact dot that grows with accumulated heat
  R.itemsLaserHot = { x = lastx, y = lasty, r = math.min(4, 1 + accum / 250), frame = R.frame }
  flash(lastx, lasty); R.hint = "Laser Rifle - " .. R.nice("QRTZ") .. " x" .. inv("QRTZ")
end
local function jetpackThrust()
  local w = WEAPONS.JETPACK; if not ready("JETPACK", w) then return end
  if not ammoOk(w) then R.hint = "Jetpack needs " .. R.nice("COAL"); return end
  fired("JETPACK"); ammoTick("JETPACK", w)
  local P = R.P; P.vy = math.max(-2.3, P.vy - 0.5); P.flame = R.frame
  P.apex = P.y  -- thrusting resets the core fall-height tracker so braking with the jetpack avoids landing damage
  local cx, cy = P.x - R.cam.x, P.y - R.cam.y
  local ft, gt = eid("FIRE"), eid("GAS")
  local sx, sy = floor(cx + (random() - 0.5) * 2), floor(cy + 2)
  if ft and not sim.partID(sx, sy) then local id = sim.partCreate(-1, sx, sy, ft); if id and id >= 0 then sim.partProperty(id, "vy", 1.5); sim.partProperty(id, "temp", 900) end end
  if gt and not sim.partID(sx, sy + 1) then local id = sim.partCreate(-1, sx, sy + 1, gt); if id and id >= 0 then sim.partProperty(id, "vy", 1.0) end end
  R.hint = "Jetpack - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function drillMine(mx, my)
  local w = WEAPONS.DRILL; if not ready("DRILL", w) then return end
  fired("DRILL")
  local tx, ty = R.smartTarget(mx, my, 34, nil, 5)
  if not tx then R.hint = "Drill: nothing to bore that way"; return end
  local r = 1; local got = {}
  for y = ty - r, ty + r do for x = tx - r, tx + r do
    local p = sim.partID(x, y)
    if p and (x - tx) ^ 2 + (y - ty) ^ 2 <= r * r + 1 then
      local nm = nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
      if tier and tier <= 5 then
        local hits = (R.blockHits[p] or 0) + 1
        local need = math.max(1, floor((R.HARD[nm] or 3) / 2))
        if hits >= need then R.blockHits[p] = nil; sim.partKill(p); local item = (nm == "BCOL") and "COAL" or nm; give(item, 1); got[item] = (got[item] or 0) + 1
        else R.blockHits[p] = hits end
      end
    end
  end end
  local t = {}; for k, v in pairs(got) do t[#t + 1] = "+" .. v .. " " .. k end
  R.hint = #t > 0 and table.concat(t, " ") or "drilling..."
  R.lastHitAt = R.frame
end

-- ================================================================ round 2 weapons/gadgets
local function fireNailgun(mx, my)
  local w = WEAPONS.NAILGUN; if not ready("NAILGUN", w) then return end
  if not anyAmmo(w) then R.hint = "Steam Nail Gun needs " .. R.nice("METL"); return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.NAILGUN.len
  local an, mod = pickAmmo(w)
  fired("NAILGUN"); spendPicked(an, w)
  local t = eid(mod and mod.el or "BMTL")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    local sp = 7 * (mod and mod.v or 1)
    sim.partProperty(id, "vx", ux * sp); sim.partProperty(id, "vy", uy * sp)
    if mod and mod.temp then sim.partProperty(id, "temp", mod.temp) end
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "nail", fx = (mod and mod.fx) or "spark", ux = ux, uy = uy, born = R.frame, dmg = floor(10 * (mod and mod.dmg or 1)), kb = 3, r = 1, lastx = sx, lasty = sy }
  end
  flash(sx, sy)
  R.hint = "Nail gun (" .. (mod and mod.label or "standard") .. ") - " .. R.nice(an) .. " x" .. inv(an)
end
local function fireRailgun(mx, my)
  local w = WEAPONS.RAILGUN; if not ready("RAILGUN", w) then return end
  if not anyAmmo(w) then R.hint = "Rail Gun needs " .. R.nice("METL") .. " x3"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.RAILGUN.len
  local an, mod = pickAmmo(w)
  fired("RAILGUN"); spendPicked(an, w)
  -- hitscan: there is no projectile particle to swap, so the loaded round scales the hit instead
  local railDmg = floor(55 * (mod and mod.dmg or 1))
  local range = 260; local fg = eid("FIGH"); local hits = 0
  local lastx, lasty = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  for st = MUZZLE, range, 3 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st); lastx, lasty = x, y
    local p = sim.partID(x, y)
    if p then
      local ty = sim.partProperty(p, "type"); local nm = nameOf(ty)
      if (fg and ty == fg) or R.MINEABLE[nm] then
        if R.MINEABLE[nm] and (R.HARD[nm] or 3) <= 6 then
          sim.partKill(p)  -- pierces anything short of the hardest ores/bedrock
          if type(R.crumble) == "function" then pcall(R.crumble, x, y, 4) end
        end
        dealDamage(x + R.cam.x, y + R.cam.y, 6, railDmg, 10); hits = hits + 1
        impactFX(x, y, (mod and mod.fx) or "pierce", ux, uy)
        if not (R.MINEABLE[nm] and (R.HARD[nm] or 3) <= 6) then break end
      end
    end
  end
  -- hitscan weapon: no persistent trail particles (they'd just sit there as leftover slugs) - the drawn beam is the
  -- entire visual, per the player 18:02 "rail gun leaves behind a bunch of leftover particles"
  addBeam(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE), lastx, lasty, { 140, 210, 255 })
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); recoil(ux, uy, 1.6)
  R.hint = "Rail Gun (" .. (mod and mod.label or "standard") .. ") - pierced " .. hits .. " - " .. R.nice(an) .. " x" .. inv(an)
end
local function streamPlasma(mx, my)
  local w = WEAPONS.PLASMATORCH; if not ready("PLASMATORCH", w) then return end
  if not ammoOk(w) then R.hint = "Plasma Torch needs " .. R.nice("COAL"); return end
  fired("PLASMATORCH"); ammoTick("PLASMATORCH", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("PLSM")
  local MUZZLE = SHAPES.PLASMATORCH.len
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then sim.partProperty(id, "vx", ux * 2); sim.partProperty(id, "vy", uy * 2); sim.partProperty(id, "temp", 3000) end
  local range = 20; local lastx, lasty = sx, sy; local hitNm = nil
  for st = MUZZLE, MUZZLE + range, 2 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st)
    local p = sim.partID(x, y)
    if p then local nm = nameOf(sim.partProperty(p, "type")); if R.MINEABLE[nm] then lastx, lasty = x, y; hitNm = nm; break end
    else lastx, lasty = x, y end
  end
  local accum = 0
  if hitNm then local _, _, a = laserHeat(lastx, lasty, 1.6); accum = a or 0 end  -- plasma runs hotter than the laser
  dealDamage(cx + R.cam.x + ux * 16, cy + R.cam.y + uy * 16, 8, 5, 3)
  R.itemsLaserHot = { x = lastx, y = lasty, r = math.min(4, 1 + accum / 200), frame = R.frame }
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); R.hint = "Plasma Torch - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function fireCryo(mx, my)
  local w = WEAPONS.CRYOGRENADE; if not ready("CRYOGRENADE", w) then return end
  if not canAmmo(w) then R.hint = "Cryo Grenade needs " .. R.nice("COAL") .. " x2"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.CRYOGRENADE.len
  fired("CRYOGRENADE"); spendAmmo(w)
  local t = eid("ICEI")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5 - 1.5)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "cryo", fx = "frost", born = R.frame, dmg = 15, kb = 4, r = 3, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 0.8); R.hint = "Cryo Grenade - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function placeC4(mx, my)
  local w = WEAPONS.C4CHARGE; if not ready("C4CHARGE", w) then return end
  if not canAmmo(w) then R.hint = "C4 Charge needs " .. R.nice("C-4"); return end
  local px, py = playerCanvas()
  local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2); if d > 60 then R.hint = "C4 Charge: out of reach"; return end
  local t = eid("C-4"); if not t or sim.partID(mx, my) then R.hint = "C4 Charge: no room there"; return end
  local id = sim.partCreate(-1, mx, my, t); if not id or id < 0 then return end
  fired("C4CHARGE"); spendAmmo(w)
  R.itemsC4[#R.itemsC4 + 1] = { x = mx + R.cam.x, y = my + R.cam.y }
  R.hint = "C4 placed (" .. #R.itemsC4 .. " armed) - right-click to detonate - " .. R.nice("C-4") .. " x" .. inv("C-4")
end
local function detonateC4()
  local st = eid("SPRK"); local n = 0
  for i = #R.itemsC4, 1, -1 do
    local c = R.itemsC4[i]; local x, y = c.x - R.cam.x, c.y - R.cam.y
    if x >= R.M and x < R.W - R.M and y >= R.M and y < R.H - R.M then
      local p = sim.partID(x, y)
      if p and nameOf(sim.partProperty(p, "type")) == "C-4" then
        if st then local s = sim.partCreate(-1, x, y, st); if s and s >= 0 then sim.partProperty(s, "life", 4) end end
        n = n + 1
      end
      table.remove(R.itemsC4, i)  -- either triggered or the spot no longer holds a charge - stop tracking either way
    end
  end
  R.hint = n > 0 and ("Detonated " .. n .. " charge" .. (n > 1 and "s" or "")) or "No charges in range to trigger (they must be on-screen)"
end
local function fireSticky(mx, my)
  local w = WEAPONS.STICKYBOMB; if not ready("STICKYBOMB", w) then return end
  if not canAmmo(w) then R.hint = "Sticky Bomb needs " .. R.nice("COAL") .. " x2"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.STICKYBOMB.len
  fired("STICKYBOMB"); spendAmmo(w)
  local t = eid("BCOL") or eid("COAL")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5 - 1)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "sticky", fx = "blast", born = R.frame, dmg = 80, kb = 12, r = 16, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 1.0); R.hint = "Sticky Bomb thrown - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function fireBow(mx, my)
  local w = WEAPONS.BOW; if not ready("BOW", w) then return end
  if not canAmmo(w) then R.hint = "Bow needs Arrows"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.BOW.len
  fired("BOW"); spendAmmo(w)
  local t = eid("BRMT")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 6); sim.partProperty(id, "vy", uy * 6); sim.partProperty(id, "temp", 700)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "arrow", fx = "burn", born = R.frame, dmg = 20, kb = 5, r = 1, lastx = sx, lasty = sy }
  end
  flash(sx, sy); R.hint = "Arrow loosed - " .. R.nice("ARROW") .. " x" .. inv("ARROW")
end
local function fireBoomerang(mx, my)
  local w = WEAPONS.BOOMERANG; if not ready("BOOMERANG", w) then return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.BOOMERANG.len
  fired("BOOMERANG")
  local t = eid("BRMT")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 7); sim.partProperty(id, "vy", uy * 7)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "boomerang", phase = "out", born = R.frame, lastx = sx, lasty = sy }
  end
  flash(sx, sy); R.hint = "Boomerang thrown"
end
local function fireHarpoon(mx, my)
  local w = WEAPONS.HARPOON; if not ready("HARPOON", w) then return end
  if not canAmmo(w) then R.hint = "Harpoon needs " .. R.nice("METL") .. " x2"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.HARPOON.len
  fired("HARPOON"); spendAmmo(w)
  local t = eid("STEL") or eid("BMTL")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 10); sim.partProperty(id, "vy", uy * 10)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "harpoon", fx = "pierce", born = R.frame, dmg = 20, kb = 10, r = 1, ux = ux, uy = uy, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 0.6); R.hint = "Harpoon fired - " .. R.nice("METL") .. " x" .. inv("METL")
end
local function useLavaBucket(mx, my)
  local w = WEAPONS.LAVABUCKET; if not ready("LAVABUCKET", w) then return end
  fired("LAVABUCKET")
  if inv("LAVA") > 0 then
    if sim.partID(mx, my) then R.hint = "Lava Bucket: no room to pour there"; return end
    local t = eid("LAVA"); local id = t and sim.partCreate(-1, mx, my, t)
    if id and id >= 0 then sim.partProperty(id, "temp", 1500); R.inventory.LAVA = inv("LAVA") - 1; R.hint = "Poured lava - " .. R.nice("LAVA") .. " x" .. inv("LAVA") end
    return
  end
  local px, py = playerCanvas(); if sqrt((mx - px) ^ 2 + (my - py) ^ 2) > 56 then R.hint = "Lava Bucket: out of reach"; return end
  local p = sim.partID(mx, my)
  if not (p and nameOf(sim.partProperty(p, "type")) == "LAVA") then R.hint = "Lava Bucket: aim at real lava"; return end
  if not R.accOn("lava") then
    R.hp = math.max(0, R.hp - 8); R.hurt = R.frame; R.hint = "Ouch - too hot to scoop without the Lava Charm!"; return
  end
  local n = 0
  for y = my - 2, my + 2 do for x = mx - 2, mx + 2 do local q = sim.partID(x, y)
    if q and nameOf(sim.partProperty(q, "type")) == "LAVA" then sim.partKill(q); n = n + 1 end end end
  give("LAVA", n); R.hint = "Scooped lava safely - " .. R.nice("LAVA") .. " x" .. inv("LAVA")
end
local function fireDynamite(mx, my)
  local w = WEAPONS.DYNAMITE; if not ready("DYNAMITE", w) then return end
  if not canAmmo(w) then R.hint = "Dynamite Bundle needs " .. R.nice("COAL") .. " x6"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.DYNAMITE.len
  fired("DYNAMITE"); spendAmmo(w)
  local t = eid("BOMB")
  for k = 1, 3 do
    local jx, jy = (random() - 0.5) * 2, (random() - 0.5) * 2
    local sx, sy = floor(cx + ux * MUZZLE + jx), floor(cy + uy * MUZZLE + jy)
    local id = t and not sim.partID(sx, sy) and sim.partCreate(-1, sx, sy, t)
    if id and id >= 0 then
      sim.partProperty(id, "vx", ux * 4.5 + jx * 0.3); sim.partProperty(id, "vy", uy * 4.5 - 2 + jy * 0.3)
      R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "grenade", fx = "blast", born = R.frame, dmg = 70, kb = 16, r = 18, lastx = sx, lasty = sy }
    end
  end
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); recoil(ux, uy, 2.0); R.hint = "Dynamite thrown - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local function fireSmoke(mx, my)
  local w = WEAPONS.SMOKEBOMB; if not ready("SMOKEBOMB", w) then return end
  if not canAmmo(w) then R.hint = "Smoke Bomb needs " .. R.nice("COAL") .. " x2"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.SMOKEBOMB.len
  fired("SMOKEBOMB"); spendAmmo(w)
  local t = eid("BCOL") or eid("COAL")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5 - 1)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "smoke", born = R.frame, dmg = 0, kb = 0, r = 2, lastx = sx, lasty = sy }
  end
  flash(sx, sy); R.hint = "Smoke Bomb thrown - " .. R.nice("COAL") .. " x" .. inv("COAL")
end
local MAGNETIC = { SAND=1, COAL=1, BCOL=1, METL=1, GOLD=1, CU=1, DU=1, URAN=1, IRON=1 }
local function magnetPull()
  local w = WEAPONS.MAGNET; if not ready("MAGNET", w) then return end
  fired("MAGNET")
  local px, py = floor(R.P.x) - R.cam.x, floor(R.P.y) - R.cam.y
  local r = 55; local n = 0
  for i in sim.parts() do
    local x, y = sim.partPosition(i)
    if x >= px - r and x <= px + r and y >= py - r and y <= py + r then
      local d2 = (x - px) ^ 2 + (y - py) ^ 2
      if d2 <= r * r and d2 > 16 then
        local nm = nameOf(sim.partProperty(i, "type"))
        if MAGNETIC[nm] then
          local d = sqrt(d2); local pull = 0.5
          sim.partProperty(i, "vx", (sim.partProperty(i, "vx") or 0) + (px - x) / d * pull)
          sim.partProperty(i, "vy", (sim.partProperty(i, "vy") or 0) + (py - y) / d * pull)
          n = n + 1
        end
      end
    end
  end
  R.hint = n > 0 and ("Magnet pulling " .. n .. " particle" .. (n > 1 and "s" or "")) or "Magnet: nothing loose nearby"
end

-- ================================================================ round 3 weapons
-- Every one of these is a real element doing its real job; none of them apply a scripted damage
-- number without a matching particle actually existing in the sim.
local function streamThermite(mx, my)
  local w = WEAPONS.THERMLANCE; if not ready("THERMLANCE", w) then return end
  if not ammoOk(w) then R.hint = "Thermite Lance needs " .. R.nice("IRON"); return end
  fired("THERMLANCE"); ammoTick("THERMLANCE", w)
  local ux, uy, cx, cy = aimAt(mx, my); local t = eid("THRM")
  local MUZZLE = SHAPES.THERMLANCE.len
  -- real THRM, spawned already hot so it lights immediately instead of falling as inert powder
  for _ = 1, 2 do
    local j = (random() - 0.5) * 0.22
    local jx, jy = ux + j, uy + j
    local sx, sy = floor(cx + jx * MUZZLE), floor(cy + jy * MUZZLE)
    local id = t and sim.partCreate(-1, sx, sy, t)
    if id and id >= 0 then
      sim.partProperty(id, "vx", jx * 3); sim.partProperty(id, "vy", jy * 3)
      sim.partProperty(id, "temp", 2500)
    end
  end
  dealDamage(cx + R.cam.x + ux * 18, cy + R.cam.y + uy * 18, 10, 3, 2)
  if R.frame % 4 == 0 then impactFX(floor(cx + ux * 20), floor(cy + uy * 20), "burn", ux, uy) end
  flash(floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)); R.hint = "Thermite Lance - " .. R.nice("IRON") .. " x" .. inv("IRON")
end
local function fireTungsten(mx, my)
  local w = WEAPONS.TUNGSNIPER; if not ready("TUNGSNIPER", w) then return end
  if not canAmmo(w) then R.hint = "Tungsten Sniper needs " .. R.nice("TUNG") .. " x2"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.TUNGSNIPER.len
  fired("TUNGSNIPER"); spendAmmo(w)
  local t = eid("TUNG")
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    -- genuinely hyper-velocity: real TUNG is dense enough to keep going through several cells
    sim.partProperty(id, "vx", ux * 26); sim.partProperty(id, "vy", uy * 26)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "musket", fx = "pierce", ux = ux, uy = uy, born = R.frame, dmg = 85, kb = 12, r = 2, lastx = sx, lasty = sy }
  end
  flash(sx, sy); recoil(ux, uy, 2.2); R.hint = "Tungsten Sniper - " .. R.nice("TUNG") .. " x" .. inv("TUNG")
end
local function fireTesla(mx, my)
  local w = WEAPONS.TESLAARC; if not ready("TESLAARC", w) then return end
  if not canAmmo(w) then R.hint = "Tesla Arc needs " .. R.nice("CU"); return end
  local ux, uy, cx, cy = aimAt(mx, my)
  fired("TESLAARC"); spendAmmo(w)
  local lt = eid("LIGH")
  -- chain: each link starts where the last ended, bending toward the nearest live enemy
  local px, py = cx + ux * SHAPES.TESLAARC.len, cy + uy * SHAPES.TESLAARC.len
  local dx, dy = ux, uy
  for link = 1, 4 do
    local nx, ny = px + dx * 26, py + dy * 26
    if lt then
      local id = sim.partCreate(-1, floor(px), floor(py), lt)
      if id and id >= 0 then sim.partProperty(id, "vx", dx * 9); sim.partProperty(id, "vy", dy * 9); sim.partProperty(id, "life", 12) end
    end
    addBeam(px, py, nx, ny, { 140, 210, 255 })
    dealDamage(nx + R.cam.x, ny + R.cam.y, 16, 20, 3)
    -- steer the next link toward the closest enemy in range, else keep going straight
    local best, bx, by = 90 * 90, nil, nil
    if R.enemyList then
      for _, e in ipairs(R.enemyList()) do
        if not e.dead then
          local ex, ey = e.x - R.cam.x, e.y - R.cam.y
          local d2 = (ex - nx) ^ 2 + (ey - ny) ^ 2
          if d2 < best then best, bx, by = d2, ex, ey end
        end
      end
    end
    px, py = nx, ny
    if bx then
      local len = math.max(0.001, sqrt((bx - px) ^ 2 + (by - py) ^ 2))
      dx, dy = (bx - px) / len, (by - py) / len
    end
  end
  flash(floor(cx + ux * 10), floor(cy + uy * 10)); R.hint = "Tesla Arc - " .. R.nice("CU") .. " x" .. inv("CU")
end
local function fireGravWell(mx, my)
  local w = WEAPONS.GRAVWELL; if not ready("GRAVWELL", w) then return end
  if not canAmmo(w) then R.hint = "Gravity Well needs " .. R.nice("GOLD") .. " x4"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  fired("GRAVWELL"); spendAmmo(w)
  local sx, sy = floor(cx + ux * SHAPES.GRAVWELL.len), floor(cy + uy * SHAPES.GRAVWELL.len)
  local t = eid("GOLD")
  local id = t and sim.partCreate(-1, sx, sy, t)
  if id and id >= 0 then
    sim.partProperty(id, "vx", ux * 5); sim.partProperty(id, "vy", uy * 5)
    R.itemsProj[#R.itemsProj + 1] = { id = id, kind = "gravwell", born = R.frame, dmg = 0, kb = 0, r = 2, lastx = sx, lasty = sy }
  end
  flash(sx, sy); R.hint = "Gravity well launched - " .. R.nice("GOLD") .. " x" .. inv("GOLD")
end
local function fireEMP(mx, my)
  local w = WEAPONS.EMPCHARGE; if not ready("EMPCHARGE", w) then return end
  if not canAmmo(w) then R.hint = "EMP Charge needs " .. R.nice("CU") .. " x3"; return end
  local ux, uy, cx, cy = aimAt(mx, my)
  fired("EMPCHARGE"); spendAmmo(w)
  local tx, ty = floor(cx + ux * 40), floor(cy + uy * 40)
  local et = eid("EMP")
  -- real EMP: the element itself does the work on sparks/electronics when it activates
  if et then
    local id = sim.partCreate(-1, tx, ty, et)
    if id and id >= 0 then sim.partProperty(id, "life", 2) end
  end
  -- visible pulse ring, and kill live SPRK in radius so the effect reads immediately
  local sp = eid("SPRK")
  local killed = 0
  if sp then
    for oy = -34, 34, 2 do for ox = -34, 34, 2 do
      if ox * ox + oy * oy <= 34 * 34 then
        local p = sim.partID(tx + ox, ty + oy)
        if p and sim.partProperty(p, "type") == sp then sim.partKill(p); killed = killed + 1 end
      end
    end end
  end
  for a = 0, 11 do
    local ang = a * math.pi / 6
    addBeam(tx, ty, tx + math.cos(ang) * 34, ty + math.sin(ang) * 34, { 90, 220, 200 })
  end
  flash(tx, ty); R.hint = "EMP burst - " .. killed .. " sparks killed"
end
local function streamFoam(mx, my)
  local w = WEAPONS.FOAMGUN; if not ready("FOAMGUN", w) then return end
  if not ammoOk(w) then R.hint = "Foam Gun needs " .. R.nice("GLAS"); return end
  fired("FOAMGUN"); ammoTick("FOAMGUN", w)
  local ux, uy, cx, cy = aimAt(mx, my)
  local t = eid("AERO") or eid("INSL")
  local MUZZLE = SHAPES.FOAMGUN.len
  local sx, sy = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  if t and not sim.partID(sx, sy) then
    local id = sim.partCreate(-1, sx, sy, t)
    if id and id >= 0 then sim.partProperty(id, "vx", ux * 2.5); sim.partProperty(id, "vy", uy * 2.5) end
  end
  R.hint = "Aerogel foam - " .. R.nice("GLAS") .. " x" .. inv("GLAS")
end
local function streamDisint(mx, my)
  local w = WEAPONS.DISINT; if not ready("DISINT", w) then return end
  if not ammoOk(w) then R.hint = "Disintegrator needs " .. R.nice("QRTZ"); return end
  fired("DISINT"); ammoTick("DISINT", w)
  local ux, uy, cx, cy = aimAt(mx, my)
  local MUZZLE = SHAPES.DISINT.len
  -- walk the beam out and delete the first solid it meets - clean removal, no crater, no debris
  local hit = false
  for step = MUZZLE, 70, 2 do
    local sx, sy = floor(cx + ux * step), floor(cy + uy * step)
    local p = sim.partID(sx, sy)
    if p then
      local nm = nameOf(sim.partProperty(p, "type"))
      if R.MINEABLE[nm] then give(nm == "BCOL" and "COAL" or nm, 1) end
      sim.partKill(p); hit = true
      impactFX(sx, sy, "void", ux, uy)
      addBeam(cx + ux * MUZZLE, cy + uy * MUZZLE, sx, sy, { 90, 60, 140 })
      R.hint = "Disintegrated " .. R.nice(nm)
      break
    end
  end
  if not hit then addBeam(cx + ux * MUZZLE, cy + uy * MUZZLE, cx + ux * 70, cy + uy * 70, { 90, 60, 140 }) end
end

local DISPATCH = {
  MUSKET = fireMusket, SHOTGUN = fireShotgun, GRENADE = fireGrenade, LIGHTGUN = fireLightning, TPWAND = fireTeleport,
  THERMLANCE = streamThermite, TUNGSNIPER = fireTungsten, TESLAARC = fireTesla, GRAVWELL = fireGravWell,
  EMPCHARGE = fireEMP, FOAMGUN = streamFoam, DISINT = streamDisint,
  FLAMETH = streamFlamethrower, WATERGUN = streamWatergun, ACIDGUN = streamAcid, FREEZERAY = streamFreeze,
  LASERGUN = streamLaser, DRILL = drillMine,
  -- JETPACK is deliberately absent here: it is not a left-mouse weapon, see the W/Space thrust check in the tick hook
  NAILGUN = fireNailgun, RAILGUN = fireRailgun, PLASMATORCH = streamPlasma, CRYOGRENADE = fireCryo, C4CHARGE = placeC4,
  STICKYBOMB = fireSticky, BOW = fireBow, BOOMERANG = fireBoomerang, HARPOON = fireHarpoon, LAVABUCKET = useLavaBucket,
  DYNAMITE = fireDynamite, SMOKEBOMB = fireSmoke, MAGNET = magnetPull,
  -- OXYTANK/DIVEHELMET/GASMASK/CLIMBGLOVES/BALLOON are passive gear (see passiveGearTick) - no left-click action
}
R.itemsDispatch = DISPATCH  -- exported for live/bridge testing: lets a test call a weapon's fire function synchronously
                            -- (in the same execute_lua round trip as a screenshot) instead of racing the real tick loop

local function drawHeldWeapon(key)
  local w = WEAPONS[key]; if not w then return end
  local col = w.col
  local face = R.P.face or 1
  local hx = floor(R.P.x) - R.cam.x + (face > 0 and 3 or -4)
  local hy = floor(R.P.y) - R.cam.y - 8
  if key == "JETPACK" then  -- worn on the back, not aimed
    local bx = floor(R.P.x) - R.cam.x - (face > 0 and 3 or -4)
    graphics.fillRect(bx - 1, hy - 3, 3, 6, col[1], col[2], col[3], 255)
    graphics.drawRect(bx - 1, hy - 3, 3, 6, 25, 25, 25, 230)
    if R.P.flame and R.frame - R.P.flame < 4 then graphics.fillCircle(bx, hy + 4, 2, 2, 255, 190, 80, 220) end
    return
  end
  local mx, my = R.mouse.x or hx, R.mouse.y or hy
  local dx, dy = mx - hx, my - hy
  local d = sqrt(dx * dx + dy * dy); if d < 1 then d = 1 end
  local ux, uy = dx / d, dy / d
  local sinceFire = R.frame - (R.itemsCD[key] or -9999)
  local kick = (sinceFire >= 0 and sinceFire < 5) and (5 - sinceFire) * 0.7 or 0
  local bob = (sinceFire > 6) and (math.sin((R.frame or 0) * 0.15) * 0.5) or 0
  local ox, oy = hx - ux * kick, hy - uy * kick + bob
  local shape = SHAPES[key] or { len = 9 }
  local tipx, tipy = ox + ux * shape.len, oy + uy * shape.len
  local pxp, pyp = -uy, ux
  graphics.fillRect(floor(ox - 1), floor(oy - 1), 3, 3, floor(col[1] * 0.65), floor(col[2] * 0.65), floor(col[3] * 0.65), 255)
  graphics.drawLine(floor(ox), floor(oy), floor(tipx), floor(tipy), col[1], col[2], col[3], 255)
  if shape.thick then graphics.drawLine(floor(ox + pxp), floor(oy + pyp), floor(tipx + pxp), floor(tipy + pyp), col[1], col[2], col[3], 255) end
  if shape.tank then
    local tx, ty = ox - ux + pxp * 3, oy - uy + pyp * 3
    graphics.fillRect(floor(tx - 2), floor(ty - 2), 4, 4, shape.tank[1], shape.tank[2], shape.tank[3], 235)
    graphics.drawRect(floor(tx - 2), floor(ty - 2), 4, 4, 20, 20, 20, 200)
  end
  if shape.coil then graphics.drawCircle(floor(tipx), floor(tipy), 2, 2, col[1], col[2], col[3], 230) end
  if shape.spin then
    local a = (R.frame or 0) * 0.9
    graphics.drawLine(floor(tipx + math.cos(a) * 2), floor(tipy + math.sin(a) * 2), floor(tipx - math.cos(a) * 2), floor(tipy - math.sin(a) * 2), col[1], col[2], col[3], 255)
  end
  if R.itemsFlash and R.frame - R.itemsFlash.frame < 2 then graphics.fillCircle(floor(tipx), floor(tipy), 3, 3, 255, 230, 140, 220) end
end

-- ================================================================ bullet visibility (the player 17:22/17:34): every
-- tracked projectile is drawn by us in drawHUD - a dark outline, a fading tracer, and a bright core - so it reads
-- against sand, granite and dark caves alike. Colours match core's own BMTL(yellow)/BRMT(orange) stopgap recolour.
local TRACER_COLOR = {
  musket = { 255, 240, 96 }, nail = { 255, 240, 96 },       -- BMTL-based
  pellet = { 255, 144, 48 }, arrow = { 255, 144, 48 },      -- BRMT-based
  harpoon = { 210, 215, 225 }, grenade = { 190, 225, 130 }, cryo = { 180, 225, 255 },
  sticky = { 210, 175, 110 }, smoke = { 175, 175, 185 }, boomerang = { 230, 190, 90 },
}
local function drawProjectiles()
  for _, pr in ipairs(R.itemsProj) do
    if sim.partExists(pr.id) then
      local x, y = sim.partPosition(pr.id)
      local vx = sim.partProperty(pr.id, "vx") or 0; local vy = sim.partProperty(pr.id, "vy") or 0
      local sp = sqrt(vx * vx + vy * vy); local ux, uy = 0, 0
      if sp > 0.2 then ux, uy = vx / sp, vy / sp end
      local col = TRACER_COLOR[pr.kind] or { 255, 225, 130 }
      local pxp, pyp = -uy, ux
      -- dark outline (either side of the tracer), then a 3-segment fading tracer, then a bright outlined core dot
      graphics.drawLine(floor(x - ux * 8 + pxp), floor(y - uy * 8 + pyp), floor(x + pxp), floor(y + pyp), 12, 12, 12, 210)
      graphics.drawLine(floor(x - ux * 8 - pxp), floor(y - uy * 8 - pyp), floor(x - pxp), floor(y - pyp), 12, 12, 12, 210)
      for seg = 0, 2 do
        local t0, t1 = seg / 3, (seg + 1) / 3
        graphics.drawLine(floor(x - ux * 8 * t0), floor(y - uy * 8 * t0), floor(x - ux * 8 * t1), floor(y - uy * 8 * t1), col[1], col[2], col[3], math.max(50, 220 - seg * 70))
      end
      graphics.fillRect(floor(x) - 1, floor(y) - 1, 2, 2, 255, 255, 255, 255)
      graphics.drawRect(floor(x) - 1, floor(y) - 1, 2, 2, 20, 20, 20, 200)
    end
  end
end
local function drawBeams()
  for _, b in ipairs(R.itemsBeams) do
    if R.frame - b.frame < 2 then
      local col = b.col
      graphics.drawLine(floor(b.x1) + 1, floor(b.y1) + 1, floor(b.x2) + 1, floor(b.y2) + 1, 10, 10, 10, 200)
      graphics.drawLine(floor(b.x1) - 1, floor(b.y1) - 1, floor(b.x2) - 1, floor(b.y2) - 1, 10, 10, 10, 200)
      graphics.drawLine(floor(b.x1), floor(b.y1), floor(b.x2), floor(b.y2), col[1], col[2], col[3], 255)
    end
  end
end

-- ================================================================ passive gear (effect applies whenever OWNED,
-- independent of hotbar selection - "worn", not "wielded"; see the player 16:00 "accessory-like")
local BADGAS = { WATR=1, DSTW=1, SLTW=1, LAVA=1, SMKE=1, CO2=1, H2=1, HYGN=1, NBLE=1, GAS=1, WTRV=1, PLSM=1, FIRE=1, CAUS=1, BOYL=1 }
local WETGAS = { WATR=1, DSTW=1, SLTW=1 }
local TOXGAS = { SMKE=1, CO2=1, H2=1, HYGN=1, NBLE=1, GAS=1, CAUS=1 }
local function clearHeadAir(filterSet, spawnOxy)
  -- mirrors core's own breathing sample grid (rpg.lua movePlayer) exactly, so displacing bad air here is what
  -- actually raises R.o2 on the very next core breathing check - this is not a stat hack, it is real particles
  local x, y = floor(R.P.x), floor(R.P.y)
  local ot = spawnOxy and eid("OXYG"); local n = 0
  for oy = -14, 2, 4 do for ox = -8, 8, 4 do
    local cx, cy = x + ox - R.cam.x, y + oy - R.cam.y
    local p = sim.partID(cx, cy)
    if p then local nm = nameOf(sim.partProperty(p, "type"))
      if filterSet[nm] then
        sim.partKill(p); n = n + 1
        if ot and (ox + oy) % 8 == 0 then local id = sim.partCreate(-1, cx, cy, ot); if id and id >= 0 then sim.partProperty(id, "life", 20) end end
      end
    end
  end end
  return n
end
local function headInWater()
  local p = sim.partID(floor(R.P.x) - R.cam.x, floor(R.P.y) - 5 - R.cam.y)
  return p and WETGAS[nameOf(sim.partProperty(p, "type"))]
end
-- ================================================================ worn oxygen tank (on-body)
-- A real shape on his back whose fill level IS the readout - the resource and its gauge are the
-- same object, so reserve is readable without opening anything.
-- Honest limitation: TPT particles cannot be attached to a moving entity, so the tank does not
-- literally contain loose OXYG particles walking around. What IS real: it is FILLED by consuming
-- real OXYG particles from the air around you, and it VENTS real OXYG back out at your head when
-- you run low. Storage in between is a scalar (R.itemsO2Charge), which is the physically honest
-- version of "holds oxygen" that this engine can actually support.
local function drawBackTank()
  if inv("OXYTANK") <= 0 then return end
  local P = R.P
  local x, y = floor(P.x) - R.cam.x, floor(P.y) - R.cam.y
  local f = P.face or 1
  -- mirror core drawPlayer's walk bob exactly so the tank stays glued to the sprite rather than
  -- floating a pixel off during the walk cycle
  local moving = P.onGround and math.abs(P.vx) > 0.2
  local cyc = moving and floor(((P.anim or 0) / 3) % 4) or 0
  local by = y - ((cyc == 1 or cyc == 3) and 1 or 0)
  local tx = x + (f > 0 and -4 or 3)      -- on the BACK: opposite whichever way he faces
  local ty, TH = by - 9, 6                -- torso spans by-9..by-4 in core's sprite
  graphics.fillRect(tx, ty, 2, TH, 55, 60, 70, 255)                 -- steel cylinder
  local frac = math.max(0, math.min(1, (R.itemsO2Charge or 0) / 400))
  local fh = floor(TH * frac + 0.5)
  if fh > 0 then graphics.fillRect(tx, ty + (TH - fh), 2, fh, 90, 200, 235, 255) end  -- fills bottom-up
  graphics.fillRect(tx, ty - 1, 2, 1, 150, 155, 165, 255)           -- valve cap
  graphics.drawLine(tx + (f > 0 and 2 or 0), ty + 1, x + (f > 0 and -1 or 1), by - 12, 140, 150, 160, 200)  -- hose to the mask
end
local function passiveGearTick()
  if inv("DIVEHELMET") > 0 and headInWater() then clearHeadAir(WETGAS, false) end
  if inv("GASMASK") > 0 and not headInWater() then clearHeadAir(TOXGAS, false) end
  if inv("OXYTANK") > 0 then
    if (R.o2 or 100) < 40 and R.itemsO2Charge > 0 then
      if clearHeadAir(BADGAS, true) > 0 then R.itemsO2Charge = math.max(0, R.itemsO2Charge - 2) end
    elseif (R.o2 or 100) >= 80 and R.itemsO2Charge < 400 then
      -- Fill from REAL oxygen: consume an actual OXYG particle from the air around you and bank
      -- it. Deliberately NO free fallback - if there is no real oxygen nearby the tank does not
      -- fill, which is the whole point. Refilling is therefore something you do somewhere with
      -- genuinely breathable air, not a number that ticks up for free.
      local ot = eid("OXYG")
      if ot then
        local px, py = floor(R.P.x) - R.cam.x, floor(R.P.y) - R.cam.y
        local done = false
        for oy = -14, 2, 4 do
          if done then break end
          for ox = -10, 10, 5 do
            local p = sim.partID(px + ox, py + oy)
            if p and sim.partProperty(p, "type") == ot then
              sim.partKill(p)
              R.itemsO2Charge = math.min(400, R.itemsO2Charge + 12)
              done = true; break
            end
          end
        end
      end
    end
  end
  if inv("BALLOON") > 0 and not R.P.onGround and R.P.vy > 1.2 then R.P.vy = 1.2; R.P.apex = R.P.y end
  if inv("CLIMBGLOVES") > 0 and not R.P.onGround then
    local face = R.P.face or 1
    if (R.keys.a or R.keys.d) and R.solidW(floor(R.P.x) + face * 2, floor(R.P.y) - 4) and R.P.vy > 0.4 then
      R.P.vy = 0.4; R.P.apex = R.P.y
    end
  end
  -- ===== round 3 armor =====
  -- Each piece counters a REAL survival accumulator that core already damages you from, rather
  -- than adding a parallel "defense" number. Set bonuses are just a count of owned pieces, so no
  -- new equip slots or UI are needed - ownership is the equip, same as every other passive here.
  local caver   = (inv("PADHARNESS") > 0 and 1 or 0) + (inv("LAMPHELM") > 0 and 1 or 0)
  local reactor = (inv("LEADVEST") > 0 and 1 or 0) + (inv("ZIRCPLATE") > 0 and 1 or 0)
  local diver   = (inv("SEALSUIT") > 0 and 1 or 0) + (inv("OXYTANK") > 0 and 1 or 0)

  -- Padded Harness: bleed off landing impact. Core's fall damage keys off the fall height it
  -- measured, so softening the descent shortly before touchdown is the honest lever.
  if inv("PADHARNESS") > 0 and not R.P.onGround and R.P.vy > 3.0 then
    if R.solidW(floor(R.P.x), floor(R.P.y) + 3) then R.P.vy = 3.0; R.P.apex = R.P.y end
  end
  -- Miner's Lamp Helm: real GLOW particles at the head, so it genuinely lights the area.
  if inv("LAMPHELM") > 0 and R.frame % 12 == 0 then
    local gt = eid("GLOW")
    if gt then
      local hx, hy = floor(R.P.x) - R.cam.x, floor(R.P.y) - 6 - R.cam.y
      if not sim.partID(hx, hy) then
        local id = sim.partCreate(-1, hx, hy, gt)
        if id and id >= 0 then sim.partProperty(id, "life", 40) end
      end
    end
  end
  -- Lead-Lined Vest: real attenuation - bleeds accumulated dose down instead of blocking a number.
  if inv("LEADVEST") > 0 and (R.radAccum or 0) > 0 and R.frame % 30 == 0 then
    R.radAccum = math.max(0, R.radAccum - (reactor >= 2 and 2.5 or 1.2))
  end
  -- Zirconium Faceplate: sheds the geothermal heat load core builds up at depth.
  if inv("ZIRCPLATE") > 0 and R.gas and (R.gas.heat or 0) > 0 and R.frame % 20 == 0 then
    R.gas.heat = math.max(0, R.gas.heat - (reactor >= 2 and 3.0 or 1.5))
  end
  -- Sealed Pressure Suit: sealed in BOTH mediums - the gap the Gas Mask and Diving Helmet each leave.
  if inv("SEALSUIT") > 0 then clearHeadAir(BADGAS, false) end
  -- Deep Caver set: shaded and padded, so daylight burns you far more slowly.
  if caver >= 2 and (R.uvAccum or 0) > 0 and R.frame % 60 == 0 then
    R.uvAccum = math.max(0, R.uvAccum - 1.5)
  end
  -- Void Diver set: sealed suit + tank keeps the poisonous stuff off your face for real.
  if diver >= 2 and R.gas and R.frame % 45 == 0 then
    R.gas.co  = math.max(0, (R.gas.co  or 0) - 4)
    R.gas.co2 = math.max(0, (R.gas.co2 or 0) - 4)
  end
end

-- ================================================================ hooks
hook(R.hooks.place, function(el)
  if el == "C4CHARGE" then detonateC4(); return true end
  if WEAPONS[el] then
    local w = WEAPONS[el]
    if w.passive then R.hint = w.txt .. ": worn passively - no need to select it, it just works"
    elseif el == "JETPACK" then R.hint = "Jetpack: hold W/Space in the air to fly"
    else R.hint = w.txt .. ": hold LEFT mouse to use it" end
    return true
  end
end)

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 1 or R.invOpen or R.menuOpen then return end
  if R.inZoom and R.inZoom(x, y) then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  local fn = sel and DISPATCH[sel]
  if fn then pcall(fn, x, y) end
  return false  -- never swallow: core still needs to set R.mouse.l = true
end)

hook(R.hooks.tick, function()
  -- muzzle-blast grace period: a hazardous continuous weapon (flamethrower/acid/plasma torch) can only spawn its
  -- hot particle at the drawn barrel tip now (see 17:22 fix), so if the player takes real environmental damage
  -- within ~6 frames of firing one, treat it as our own fresh muzzle particle and refund it rather than pushing
  -- the spawn point away from the sprite - core doesn't expose per-particle damage attribution, so this frame-
  -- window heuristic is the closest honest approximation without editing core
  if R.itemsLastHp and R.hp < R.itemsLastHp and R.hurt == R.frame then
    local grace = false
    for _, k in ipairs({ "FLAMETH", "ACIDGUN", "PLASMATORCH" }) do
      if R.frame - (R.itemsCD[k] or -9999) <= 6 then grace = true; break end
    end
    if grace then R.hp = math.min(100, R.itemsLastHp) end
  end
  R.itemsLastHp = R.hp  -- set unconditionally, before any of this hook's early returns below
  for i = #R.itemsBeams, 1, -1 do if R.frame - R.itemsBeams[i].frame >= 2 then table.remove(R.itemsBeams, i) end end
  for pid, rec in pairs(R.itemsHeat) do
    if not sim.partExists(pid) then
      if R.MINEABLE[rec.nm] then
        give(rec.nm == "BCOL" and "COAL" or rec.nm, 1); R.hint = "Laser-cut " .. R.nice(rec.nm)
        if rec.x and type(R.crumble) == "function" then pcall(R.crumble, rec.x, rec.y, 4) end
      end
      R.itemsHeat[pid] = nil
    else
      local curNm = nameOf(sim.partProperty(pid, "type"))
      if curNm ~= rec.nm then
        if R.MINEABLE[rec.nm] then
          give(rec.nm == "BCOL" and "COAL" or rec.nm, 1); R.hint = "Laser-cut " .. R.nice(rec.nm)
          if rec.x and type(R.crumble) == "function" then pcall(R.crumble, rec.x, rec.y, 4) end
        end
        R.itemsHeat[pid] = nil
      elseif R.frame - (rec.touch or 0) > 120 then
        R.itemsHeat[pid] = nil  -- beam moved on before this spot melted - let it cool naturally, stop tracking
      end
    end
  end
  for i = #R.itemsProj, 1, -1 do
    local pr = R.itemsProj[i]
    if pr.kind == "gravwell" then
      -- Real gravitational confinement: while it lives it drags loose matter and enemies inward
      -- by setting real velocities, then collapses. No scripted explosion - the inrush IS the effect.
      if not sim.partExists(pr.id) or R.frame - pr.born > 260 then
        local x, y = pr.lastx, pr.lasty
        pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i)
        if x then for _ = 1, 8 do
          local pt = eid("PHOT"); if pt then local id = sim.partCreate(-1, floor(x + (random() - 0.5) * 10), floor(y + (random() - 0.5) * 10), pt); if id and id >= 0 then sim.partProperty(id, "life", 8) end end
        end end
      else
        local x, y = sim.partPosition(pr.id); pr.lastx, pr.lasty = x, y
        if R.frame - pr.born > 26 then
          sim.partProperty(pr.id, "vx", 0); sim.partProperty(pr.id, "vy", 0)  -- anchored once armed
          local RAD = 48
          for oy = -RAD, RAD, 3 do for ox = -RAD, RAD, 3 do
            local d2 = ox * ox + oy * oy
            if d2 > 16 and d2 <= RAD * RAD then
              local p = sim.partID(x + ox, y + oy)
              if p and p ~= pr.id then
                local d = sqrt(d2)
                local pull = (1 - d / RAD) * 2.4
                sim.partProperty(p, "vx", -ox / d * pull)
                sim.partProperty(p, "vy", -oy / d * pull)
              end
            end
          end end
          if R.frame % 6 == 0 then dealDamage(x + R.cam.x, y + R.cam.y, RAD, 8, 0) end
          if R.frame % 3 == 0 then
            local a = random() * math.pi * 2
            addBeam(x + math.cos(a) * RAD, y + math.sin(a) * RAD, x, y, { 170, 90, 230 })
          end
        end
      end
    elseif pr.kind == "boomerang" then
      if not sim.partExists(pr.id) or R.frame - pr.born > 220 then pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i)
      else
        local x, y = sim.partPosition(pr.id)
        if pr.phase == "out" and R.frame - pr.born > 22 then pr.phase = "return" end
        if pr.phase == "return" then
          local px, py = playerCanvas(); local dx, dy = px - x, py - y; local d = sqrt(dx * dx + dy * dy)
          if d < 10 then pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i); R.hint = "Boomerang caught"
          else
            sim.partProperty(pr.id, "vx", dx / d * 7); sim.partProperty(pr.id, "vy", dy / d * 7)
            if R.frame % 4 == 0 then dealDamage(x + R.cam.x, y + R.cam.y, 10, 18, 4) end
          end
        elseif R.frame % 6 == 0 then dealDamage(x + R.cam.x, y + R.cam.y, 8, 18, 4) end
      end
    elseif pr.kind == "sticky_armed" then
      if not sim.partExists(pr.id) or R.frame >= pr.fuseAt then
        local x, y = pr.lastx, pr.lasty
        if sim.partExists(pr.id) then local px2, py2 = sim.partPosition(pr.id); x, y = floor(px2), floor(py2) end
        crater(x, y, pr.r); dealDamage(x + R.cam.x, y + R.cam.y, pr.r, pr.dmg, pr.kb)
        pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i)
      end
    elseif not sim.partExists(pr.id) then
      if pr.kind == "grenade" then
        dealDamage(pr.lastx + R.cam.x, pr.lasty + R.cam.y, pr.r, pr.dmg, pr.kb)
        if type(R.crumble) == "function" then pcall(R.crumble, pr.lastx, pr.lasty, pr.r) end
      end
      table.remove(R.itemsProj, i)
    elseif R.frame - pr.born > (pr.life or 90) then
      pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i)
    else
      local x, y = sim.partPosition(pr.id); x, y = floor(x), floor(y); pr.lastx, pr.lasty = x, y
      if pr.kind ~= "grenade" then
        local vx = sim.partProperty(pr.id, "vx") or 0; local vy = sim.partProperty(pr.id, "vy") or 0
        local nx, ny = floor(x + (vx >= 0 and 1 or -1)), floor(y + (vy >= 0 and 1 or -1))
        local p2 = sim.partID(nx, ny)
        local nm2 = p2 and p2 ~= pr.id and nameOf(sim.partProperty(p2, "type"))
        local blocked = nm2 and (R.MINEABLE[nm2] or nm2 == "FIGH")
        if blocked or (math.abs(vx) < 0.3 and math.abs(vy) < 0.3) then
          if pr.kind == "sticky" then
            sim.partProperty(pr.id, "vx", 0); sim.partProperty(pr.id, "vy", 0)
            pr.kind = "sticky_armed"; pr.fuseAt = R.frame + 90
          else
            if pr.kind == "cryo" then
              local lt = eid("LN2")
              if lt then for a = 1, 6 do local ang = a * 1.05; local px2, py2 = x + floor(math.cos(ang) * 2), y + floor(math.sin(ang) * 2)
                if not sim.partID(px2, py2) then local id2 = sim.partCreate(-1, px2, py2, lt); if id2 and id2 >= 0 then sim.partProperty(id2, "temp", 60) end end
              end end
            elseif pr.kind == "smoke" then
              local st = eid("SMKE")
              if st then for a = 1, 8 do local ang = a * 0.79; local px2, py2 = x + floor(math.cos(ang) * 3), y + floor(math.sin(ang) * 3)
                if not sim.partID(px2, py2) then sim.partCreate(-1, px2, py2, st) end
              end end
            elseif pr.kind == "arrow" then
              local ft = eid("FIRE")
              if ft and not sim.partID(x, y - 1) then local id2 = sim.partCreate(-1, x, y - 1, ft); if id2 and id2 >= 0 then sim.partProperty(id2, "life", 8) end end
            elseif pr.kind == "harpoon" then
              -- pull: the AoE origin is placed further along the travel line than the target, so "knockback away
              -- from origin" points back toward the player instead of further out
              dealDamage(x + R.cam.x + pr.ux * 50, y + R.cam.y + pr.uy * 50, 14, pr.dmg, pr.kb)
            end
            if pr.kind ~= "smoke" then
              crater(x, y, pr.r); dealDamage(x + R.cam.x, y + R.cam.y, 8, pr.dmg, pr.kb)
              -- every projectile impact funnels through here, so one call covers them all;
              -- pr.fx is set at fire time from the weapon (and from the loaded round, so ammo
              -- choice is visibly different on impact, not just numerically different)
              impactFX(x, y, pr.fx or "spark", pr.ux, pr.uy)
            end
            pcall(sim.partKill, pr.id); table.remove(R.itemsProj, i)
          end
        end
      end
    end
  end
  local okp, errp = pcall(passiveGearTick); if not okp then R.lastErr = tostring(errp) end
  if R.invOpen or R.menuOpen then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  if not sel or not WEAPONS[sel] then R.itemsJetHold = 0; return end
  if sel == "JETPACK" then
    -- jump-key driven, not left mouse: thrust only once the initial jump has crested (or the key's been held a
    -- while), so it doesn't just stack onto the normal jump impulse; left mouse is left free for the other tool
    local held = R.keys.w or R.keys.space
    R.itemsJetHold = held and (R.itemsJetHold + 1) or 0
    if held and not R.P.onGround and (R.itemsJetHold >= 8 or R.P.vy >= 0) then pcall(jetpackThrust) end
  elseif WEAPONS[sel].passive then
    -- no left-click action; effect already applied above via passiveGearTick regardless of selection
  elseif R.mouse.l then
    if R.inZoom and R.inZoom(R.mouse.x, R.mouse.y) then return end
    local fn = DISPATCH[sel]; if fn then pcall(fn, R.mouse.x, R.mouse.y) end
  end
end)

hook(R.hooks.drawHUD, function()
  local okd, errd = pcall(drawBeams); if not okd then R.lastErr = tostring(errd) end
  okd, errd = pcall(drawProjectiles); if not okd then R.lastErr = tostring(errd) end
  if R.itemsLaserHot and R.frame - R.itemsLaserHot.frame < 3 then
    local h = R.itemsLaserHot
    graphics.fillCircle(floor(h.x), floor(h.y), h.r + 1, h.r + 1, 255, 120, 30, 130)
    graphics.fillCircle(floor(h.x), floor(h.y), h.r, h.r, 255, 245, 220, 255)
  end
  -- Worn oxygen tank, drawn on the player's back with a live fill level. Deliberately drawn
  -- BEFORE the `if not w then return end` below, so it shows whenever the tank is owned rather
  -- than only while it happens to be the selected hotbar slot. Drawn from this plugin's own hook
  -- rather than by editing core's drawPlayer, which keeps the core file (and its scarce top-level
  -- local budget) untouched while several other lanes are working in it.
  local okt, errt = pcall(drawBackTank); if not okt then R.lastErr = tostring(errt) end
  local sel = R.hotbar and R.hotbar[R.sel or 1]; local w = sel and WEAPONS[sel]
  if not w then return end
  graphics.fillRect(4, R.H - 42, 230, 13, 0, 0, 0, 170)
  if w.passive then
    local extra = (sel == "OXYTANK") and ("  tank " .. math.floor(R.itemsO2Charge / 4) .. "%") or ""
    graphics.drawText(8, R.H - 40, w.txt .. " - worn passively, always active" .. extra, 200, 220, 200, 255)
    return
  end
  if not R.invOpen and not R.menuOpen then local ok, err = pcall(drawHeldWeapon, sel); if not ok then R.lastErr = tostring(err) end end
  local ammoTxt = w.ammo and (R.nice(w.ammo) .. " x" .. inv(w.ammo)) or "no ammo needed"
  local cdLeft = math.max(0, w.cd - (R.frame - (R.itemsCD[sel] or -9999)))
  graphics.drawText(8, R.H - 40, w.txt .. "  " .. ammoTxt .. (cdLeft > 0 and ("  cd " .. cdLeft) or ""), cdLeft > 0 and 160 or 210, cdLeft > 0 and 160 or 230, cdLeft > 0 and 160 or 255, 255)
end)

local DEEP_ORES = { DU = 1, URAN = 1, DMND = 1, TTAN = 1 }
hook(R.hooks.mine, function(el)
  if not DEEP_ORES[el] then return end
  if random() > 0.035 then return end
  local pool = {}
  for _, k in ipairs(WEAPON_ORDER) do if inv(k) <= 0 then pool[#pool + 1] = k end end
  if #pool == 0 then return end
  local k = pool[1 + floor(random() * #pool)]
  give(k, 1); R.rebuildHotbar(); say("Rare find while mining: a " .. WEAPONS[k].txt .. "!")
end)
