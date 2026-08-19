--[[
  AI Elements for The Powder Toy - PhoenixFire808 Fork
  
  Defines new particle types via the official TPT Lua element API.
  Load into-game via Console (backtick key) or place in scripts/ folder.
  
  API reference:
    elements.allocate("NAME", parent_or_0)           -> returns int type id
    elements.element(id, {Name, Identifier, Colour, Category, Update, Graphics, DefaultProperties, ...})
    elements.property(id, "Field", value)             -> change runtime property
    elements.exists(id)                               -> boolean
    elements.loadDefault(id)                          -> resets element
    elements.getByName("NAME")                        -> returns int type id
    
    Particle helpers:
    sim.pmap(x, y)                                    -> reads grid cell (packed int)
    bit.band(cell, 0xFFFFFF)                          -> extracts element type
    bit.rshift(cell, 24)                              -> extracts particle ID
    sim.createBox(type, x1, y1, x2, y2, flags)        -> fill rectangle
    sim.createLine(x1,y1,x2,y2,type,flags)            -> draw line
    sim.floodParts(x, y, type, mode)                  -> flood fill
    sim.partCreate(-2, x, y, type[, velocity])        -> spawn one particle
    sim.partKill(pidx)                                -> remove particle by index
    sim.partChangeType(pidx, newtype)                 -> change particle type
    sim.partProperty(pidx, "Field", val)              -> set particle field
    sim.partNeighbors(x, y, radius[, type_filter])    -> return nearby IDs table
]]

local function register_element(name, defn)
    local id = elements.allocate(name, 0)
    if id > 0 then
        elements.element(id, defn)
        return id
    else
        print("FAIL: Could not allocate " .. name)
        return -1
    end
end

-- =========================================================================
-- WEBB — Neural Network Neuron Node
-- Fires light signal when receiving enough electric input from neighbors
-- =========================================================================
register_element("WEBB", {
    Name          = "WEBB",
    Identifier    = "DEFAULT_PT_WEBB",
    Colour        = { R = 120, G = 80, B = 255 },
    Category      = "electronics",
    MenuVisible   = 1,
    Description   = "Neural neuron node. Fires LIGH output when stimulated by ELEC/LIGH/FIRE.",
    Properties    = { TYPE_PART = 1, Hardness = 50, Weight = 100, HeatCapacity = 50, Loss = 0.0 },
    Update = function(pid, x, y)
        local signal = 0
        local count  = 0
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local cell  = sim.pmap(x + dx, y + dy)
                    local t     = bit.band(cell, 0xFFFFFF)
                    if t == sim.PT_ELEC or t == sim.PT_LIGH or t == sim.PT_FIRE then
                        signal = signal + 10
                    elseif t == webb_id then
                        signal = signal + 2
                    end
                    count = count + 1
                end
            end
        end
        if signal > 8 and count >= 3 and math.random() < 0.3 then
            sim.partChangeType(pid, sim.PT_LIGH)
        end
    end,
    CreateAllowed = function(pid, x, y)
        return true
    end
})
webb_id = elements.getByName("WEBB")

-- =========================================================================
-- SYNAP — Synaptic Bridge
-- Transmits neural signals upward with random delay & decay; dies after Life ticks
-- =========================================================================
register_element("SYNAP", {
    Name          = "SYNAP",
    Identifier    = "DEFAULT_PT_SYNAP",
    Colour        = { R = 255, G = 200, B = 100 },
    Category      = "electronics",
    MenuVisible   = 1,
    Description   = "Synapse bridge. Emits sparks while decaying; connects neurons.",
    Properties    = { TYPE_PART = 1, Advection = 0.3, Gravity = 0.2, Hardness = 10, Meltable = 20, Weight = 50, Life = 200, Falldown = 1 },
    Update = function(pid, x, y)
        local life_val = sim.partProperty(pid, "Life") or 0
        if life_val > 1 then
            sim.partProperty(pid, "Life", life_val - 1)
        end
        if life_val <= 50 and math.random() < 0.1 then
            sim.partCreate(-2, x, y - 1, sim.PT_SPRK)
        end
    end
})

-- =========================================================================
-- BRIN — Bionic Tissue
-- Self-repairing material that resists decay when near LIFE particles
-- =========================================================================
register_element("BRIN", {
    Name          = "BRIN",
    Identifier    = "DEFAULT_PT_BRIN",
    Colour        = { R = 180, G = 80, B = 120 },
    Category      = "special",
    MenuVisible   = 1,
    Description   = "Bionic tissue. Near LIFE particles it repairs; isolated it slowly degrades.",
    Properties    = { TYPE_PART = 1, Hardness = 5, Meltable = 0, Flammable = 5, Weight = 80, HeatCapacity = 100 },
    Update = function(pid, x, y)
        local near_life = false
        for dx = -2, 2 do
            for dy = -2, 2 do
                local cell  = sim.pmap(x + dx, y + dy)
                local t     = bit.band(cell, 0xFFFFFF)
                if t == sim.PT_LIFE then
                    near_life = true
                    break
                end
            end
        end
        if near_life then
            sim.partProperty(pid, "Loss", 0.005)
        else
            sim.partProperty(pid, "Loss", 0.02)
        end
    end
})

-- =========================================================================
-- DATA — Flowing Information Stream
-- Gas-like particle that drifts toward electronics; consumed when touching ELEC/LIGH
-- =========================================================================
register_element("DATA", {
    Name          = "DATA",
    Identifier    = "DEFAULT_PT_DATA",
    Colour        = { R = 0, G = 255, B = 0 },
    Category      = "electronics",
    MenuVisible   = 1,
    Description   = "Data stream. Gas-like flow attracted to circuits; consumed by ELEC/LIGH.",
    Properties    = { TYPE_GAS = 1, Life = 300, Advection = 0.9, AirDrag = 0.05, Gravity = 0.1, Falldown = 0, Diffusion = 0.5, HotAir = 0.001 },
    Update = function(pid, x, y)
        local has_target = false
        for r = 1, 2 do
            for angle = 0, 7 do
                local adx = math.floor(math.cos(angle * math.pi / 4) * r)
                local ady = math.floor(math.sin(angle * math.pi / 4) * r)
                local cell  = sim.pmap(x + adx, y + ady)
                local t     = bit.band(cell, 0xFFFFFF)
                if t == sim.PT_WIRE or t == sim.PT_CWRR or t == sim.PT_SWCH or t == sim.PT_CWND then
                    has_target = true
                    break
                end
            end
            if has_target then break end
        end
        
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local cell  = sim.pmap(x + dx, y + dy)
                    local t     = bit.band(cell, 0xFFFFFF)
                    if t == sim.PT_ELEC or t == sim.PT_LIGH then
                        sim.partKill(pid)
                        return
                    end
                end
            end
        end
    end
})

-- =========================================================================
-- QUANT — Quantum Superposition Particle
-- Jitters randomly; when confined by 3+ solid walls, collapses to a definite state
-- =========================================================================
register_element("QUANT", {
    Name          = "QUANT",
    Identifier    = "DEFAULT_PT_QUANT",
    Colour        = { R = 200, G = 200, B = 200 },
    Category      = "special",
    MenuVisible   = 1,
    Description   = "Quantum particle. Flickers between states; collapses on confinement.",
    Properties    = { TYPE_PART = 1, Advection = 0.3, AirDrag = 0.02, Gravity = 0.5, Falldown = 1, Hardness = 1, Loss = 0.0 },
    Update = function(pid, x, y)
        local confining = 0
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local cell  = sim.pmap(x + dx, y + dy)
                    local t     = bit.band(cell, 0xFFFFFF)
                    if t == sim.PT_WALL or t == sim.PT_BRCK or t == sim.PT_CMRE then
                        confining = confining + 1
                    end
                end
            end
        end
        if confining >= 3 and math.random() < 0.1 then
            local roll = math.random(1, 100)
            if roll < 30 then
                sim.partChangeType(pid, sim.PT_IRON)
            elseif roll < 60 then
                sim.partChangeType(pid, sim.PT_GOLD)
            elseif roll < 80 then
                sim.partChangeType(pid, sim.PT_PLUT)
            else
                sim.partChangeType(pid, sim.PT_NBLE)
            end
        end
    end
})

print("AI Elements loaded:")
for _, e_name in ipairs({ "WEBB", "SYNAP", "BRIN", "DATA", "QUANT" }) do
    print("  " .. e_name .. " -> type " .. tostring(elements.getByName(e_name)))
end
