-- ===========================================================================
-- Antimatter physics showcase, built from the Veritasium video the owner asked to
-- have translated into the game ("What happens if you drop 0.125 grams of
-- antimatter?"). Four bays laid out in a 2x2 grid, each one a real, running
-- demonstration of a chapter from that video using the actual sim mechanics
-- added for it this session (AMTR.cpp, MGNT.cpp) plus the PROT+TUNG->AMTR
-- production path that already existed in PROT.cpp.
--
-- Not an MCP tool: the MCP bridge is currently broken end to end (every
-- dispatch branch missing, confirmed via mcp__powder-toy__powder_status), and
-- The owner's standing rule is no synthetic mouse/keyboard input into his game
-- session regardless. This is a plain Lua function the owner runs himself from
-- TPT's in-game console (F2), same as any other bridge-exposed command.
-- ===========================================================================
do
local PBX = _G.PBX
if not PBX then error("85_antimatter_lab.lua: PBX foundation missing (00_util.lua must load first)") end

local partCreate   = sim.partCreate
local partProperty = sim.partProperty
local partKill     = sim.partKill
local pmapAt       = sim.pmap
local photonsAt    = sim.photons

local function clearRect(x0, y0, x1, y1)
    for y = y0, y1 do
        for x = x0, x1 do
            local pi = pmapAt(x, y)
            if pi then partKill(pi) end
            local ph = photonsAt(x, y)
            if ph then partKill(ph) end
        end
    end
end

local function fillRect(x0, y0, x1, y1, elemId)
    for y = y0, y1 do
        for x = x0, x1 do
            partCreate(-1, x, y, elemId)
        end
    end
end

-- Pre-charges a magnet so it's a live Penning-trap wall from tick one instead
-- of slowly warming up through MGNT's own random charge/discharge cycle --
-- see the tmp3 exemption this session added to AMTR.cpp.
local function chargeMagnet(id)
    if not id or id < 0 then return end
    partProperty(id, "tmp", 30)
    partProperty(id, "tmp3", 1)
    partProperty(id, "life", 20)
end

local function magnetRing(cx, cy, radius, count)
    for k = 0, count - 1 do
        local a = (2 * math.pi * k) / count
        local x = math.floor(cx + radius * math.cos(a) + 0.5)
        local y = math.floor(cy + radius * math.sin(a) + 0.5)
        chargeMagnet(partCreate(-1, x, y, elem.DEFAULT_PT_MGNT))
    end
end

local function magnetRails(xLeft, xRight, y0, y1)
    for y = y0, y1 do
        chargeMagnet(partCreate(-1, xLeft, y, elem.DEFAULT_PT_MGNT))
        chargeMagnet(partCreate(-1, xRight, y, elem.DEFAULT_PT_MGNT))
    end
end

function buildAntimatterLab()
    -- BAY 1 (top-left): The Antimatter Factory -- protons into a tungsten
    -- target (PROT.cpp: PROT + TUNG -> AMTR once accumulated collision energy
    -- passes 500000). Two real beams are fired at each other through the
    -- target so you can watch actual proton-proton collision physics run,
    -- but CERN's real antiproton yield is on the order of 1 in 10^5-10^6
    -- protons fired -- a literal beam here would need to run far longer than
    -- anyone's going to wait on a demo, so one seed proton is pre-loaded with
    -- the energy a genuinely successful collision would have produced,
    -- guaranteeing you see the actual yield instead of waiting on statistics.
    clearRect(5, 5, 300, 185)
    fillRect(145, 95, 150, 105, elem.DEFAULT_PT_TUNG)
    local beamL = partCreate(-1, 20, 100, elem.DEFAULT_PT_PROT)
    if beamL and beamL >= 0 then partProperty(beamL, "vx", 20); partProperty(beamL, "vy", 0) end
    local beamR = partCreate(-1, 280, 100, elem.DEFAULT_PT_PROT)
    if beamR and beamR >= 0 then partProperty(beamR, "vx", -20); partProperty(beamR, "vy", 0) end
    local seed = partCreate(-1, 147, 99, elem.DEFAULT_PT_PROT)
    if seed and seed >= 0 then partProperty(seed, "tmp", 600000) end
    -- No trap here on purpose: the antiproton this produces annihilates
    -- against its own tungsten target within a tick or two, which is exactly
    -- CERN's real problem -- freshly made antimatter dies immediately unless
    -- something catches it. That something is bay 2.

    -- BAY 2 (top-right): The Portable Antimatter Trap / how do you store it --
    -- a ring of pre-charged magnets (MGNT.cpp) forming a real Penning-trap
    -- style cage. AMTR is exempted from annihilating against a live magnet
    -- field (AMTR.cpp), so this particle should sit here indefinitely instead
    -- of detonating the instant it's placed.
    clearRect(312, 5, 602, 185)
    magnetRing(457, 95, 40, 14)
    partCreate(-1, 457, 95, elem.DEFAULT_PT_AMTR)

    -- BAY 3 (bottom-left): particle annihilation, the video's core demo --
    -- antimatter dropped onto ordinary matter releases its full rest mass as
    -- heat, light and a shockwave (E=mc^2, ~100% efficient) instead of just
    -- quietly deleting what it touches.
    clearRect(5, 197, 300, 372)
    fillRect(50, 340, 250, 360, elem.DEFAULT_PT_BMTL)
    partCreate(-1, 150, 300, elem.DEFAULT_PT_AMTR)

    -- BAY 4 (bottom-right): does antimatter fall up or down? -- an open
    -- question until CERN's 2023 ALPHA-g result. A magnetically shielded drop
    -- tube keeps the particle off the rails as it falls, so what you're
    -- watching is gravity alone (Gravity = 0.10f in AMTR.cpp) pulling it down
    -- onto the landing plate below, where it leaves the field and annihilates.
    clearRect(312, 197, 602, 372)
    magnetRails(440, 474, 210, 340)
    fillRect(430, 345, 485, 360, elem.DEFAULT_PT_BMTL)
    partCreate(-1, 457, 220, elem.DEFAULT_PT_AMTR)

    PBX.log("antimatter_lab", "built 4-bay antimatter demo: factory, trap, annihilation, gravity drop")
    if tpt and tpt.print then
        pcall(tpt.print, "Antimatter lab built -- factory (top-left), trap (top-right), annihilation (bottom-left), gravity drop (bottom-right)")
    end
end

_G.buildAntimatterLab = buildAntimatterLab
PBX.log("antimatter_lab", "85_antimatter_lab loaded -- run buildAntimatterLab() from the console to build the demo")
end
