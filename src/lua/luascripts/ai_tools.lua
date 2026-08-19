--[[
  AI Tools for The Powder Toy - PhoenixFire808 Fork
  
  Procedural generation tools that create complex structures using 
  the official TPT Lua API (createBox, createLine, floodParts).
  
  Usage:
    gen_circuit(200, 200, 50, 50)      -- CPU layout around cursor
    gen_terrain(200, 100, 40, 60)       -- Layered geological terrain
    gen_crystal(200, 200, 15, 42)       -- Hexagonal crystal cluster
    gen_dna(200, 300, 100, 8, 77)       -- DNA double helix
    gen_fractal_firefly(200, 200, 40, 800, 42) -- Lissajous energy art
]]

local seed = os.time()

-- Seeded pseudo-random for reproducibility
function seeded_rng(s)
    if s then seed = s end
    local v = math.sin(seed * 9301 + 49297 + 0x12345678)
    return v - math.floor(v)
end

-- =========================================================================
-- gen_circuit(cx, cy, hw, hh)
-- Generates a miniature CPU-like structure with bus lines and components
-- =========================================================================
function gen_circuit(cx, cy, hw, hh)
    -- Processor core block
    sim:createBox(sim.PT_HEAC, cx - 5, cy - 5, cx + 5, cy + 5, 0)
    
    -- Bus lines (horizontal)
    for col = cx - hw, cx + hw, 2 do
        local x1, y1 = col, cy - hh
        local x2, y2 = col, cy + hh
        sim:createLine(x1, y1, x2, y2, sim.PT_CWLP, 1, 1, BRUSH_SQUARE, 0)
    end
    
    -- Vertical connections every 8 rows
    for row = cy - hh, cy + hh, 8 do
        for col = cx - hw, cx + hw do
            local cell = sim.pmap(col, row)
            if not cell or cell == 0 then
                sim:createBox(sim.PT_WIRE, col, row, col, row, 0)
            end
        end
    end
    
    -- Capacitor banks near processor
    for bx = -1, 1 do
        sim:createBox(sim.PT_BTRY, cx + bx * 40 - 5, cy + 40 - 2, cx + bx * 40 + 5, cy + 40 + 2, 0)
    end
    
    print("Circuit generated around (" .. cx .. "," .. cy .. ")")
end

-- =========================================================================
-- gen_terrain(cx, cy, hw, hh, seed)
-- Creates layered geological formations using value noise
-- =========================================================================
function gen_terrain(cx, cy, hw, hh, _seed)
    if _seed then seed = _seed end
    seeded_rng(seed)
    
    function noise(x, y, z)
        local v = math.sin((x + 0.5) * 12.9898 + (y + 0.5) * 78.233 + z * 45.164)
        v = v - math.floor(v)
        return v
    end
    
    for x = cx - hw, cx + hw do
        for y = cy, cy + hh do
            nx = x / hw; ny = (y - cy) / hh
            
            l1 = noise(nx * 3, ny * 3, 0.5)
            l2 = noise(nx * 6, ny * 6, 1.0)
            l3 = noise(nx * 12, ny * 12, 2.0)
            
            elev = l1 * 0.5 + l2 * 0.3 + l3 * 0.2
            
            if elev > 0.7 then
                sim:createBox(sim.PT_ROCK, x, y, x, y, 0)
            elseif elev > 0.5 then
                sim:createBox(sim.PT_SAND, x, y, x, y, 0)
            elseif elev > 0.3 then
                sim:createBox(sim.PT_SALT, x, y, x, y, 0)
            end
        end
    end
    
    -- Water fill at bottom
    for x = cx - hw, cx + hw do
        for y = cy + hh - 5, cy + hh do
            cell = sim.pmap(x, y)
            if not cell or cell == 0 then
                sim:createBox(sim.PT_WATR, x, y, x, y, 0)
            end
        end
    end
    
    -- Vegetation on rock surfaces
    for x = cx - hw, cx + hw do
        for y = cy, cy + 3 do
            cell = sim.pmap(x, y)
            t = bit.band(cell, 0xFFFFFF)
            if t == sim.PT_ROCK and seeded_rng(x * 17 + y * 31 + seed) > 0.7 then
                sim:createBox(sim.PT_PLNT, x, y, x, y, 0)
            end
        end
    end
    
    print("Terrain generated at (" .. cx .. "," .. cy .. ") seed=" .. seed)
end

-- =========================================================================
-- gen_crystal(cx, cy, radius, depth, seed)
-- Grows hexagonal crystal cluster from center via recursive frontier
-- =========================================================================
function gen_crystal(cx, cy, radius, depth, _seed)
    if _seed then seed = _seed end
    seeded_rng(seed)
    
    frontier = { {cx, cy} }
    visited = {}
    visited[tostring(cx)..","..tostring(cy)] = true
    local count = 0
    
    for d = 1, depth or 20 do
        new_frontier = {}
        
        for _, pos in ipairs(frontier) do
            px = pos[1]; py = pos[2]
            
            -- Try branches in 6 directions
            for angle = 0, 5 do
                dx = math.cos(angle * math.pi / 3)
                dy = math.sin(angle * math.pi / 3)
                nx = math.floor(px + dx)
                ny = math.floor(py + dy)
                
                key = tostring(nx) .. "," .. tostring(ny)
                if not visited[key] and seeded_rng(px * 100 + py + d * 17) > 0.3 then
                    visited[key] = true
                    
                    -- Determine element type
                    shift = seeded_rng(nx * 7 + ny * 13)
                    if shift > 0.8 then
                        elem = sim.PT_QRTZ
                    else
                        elem = sim.PT_GLAS
                    end
                    
                    sim:createBox(elem, nx, ny, nx, ny, 0)
                    table.insert(new_frontier, {nx, ny})
                    count = count + 1
                end
            end
        end
        
        frontier = new_frontier
        if #frontier == 0 then break end
    end
    
    print("Crystal grown: " .. count .. " particles, depth=" .. (depth or 20))
end

-- =========================================================================
-- gen_maze(cx, cy, cols, rows, wall_elem)
-- Perfect maze via recursive backtracking algorithm
-- =========================================================================
function gen_maze(cx, cy, cols, rows, wall_elem)
    wall_elem = wall_elem or sim.PT_BRCK
    cols = cols or 15; rows = rows or 15
    
    grid_visited = {}
    walls_down = {}
    walls_right = {}
    
    for r = 1, rows do
        for c = 1, cols do
            k = r .. "_" .. c
            grid_visited[k] = false
            walls_down[r .. "_" .. c] = true
            walls_right[r .. "_" .. c] = true
        end
    end
    
    stack = {{1, 1}}
    grid_visited["1_1"] = true
    cells_done = 0
    total = cols * rows
    
    while cells_done < total do
        cr, cc = stack[#stack][1], stack[#stack][2]
        
        options = {}
        if cr > 1 and not grid_visited[(cr-1) .. "_" .. cc] then
            table.insert(options, {cr-1, cc, "down"})
        end
        if cc < cols and not grid_visited[cr .. "_" .. (cc+1)] then
            table.insert(options, {cr, cc+1, "right"})
        end
        
        if #options > 0 then
            idx = math.random(#options)
            nr = options[idx][1]; nc = options[idx][2]; dir = options[idx][3]
            
            grid_visited[nr .. "_" .. nc] = true
            cells_done = cells_done + 1
            
            if dir == "down" then
                walls_down[cr .. "_" .. cc] = false
            else
                walls_right[cr .. "_" .. cc] = false
            end
            
            stack[#stack+1] = {nr, nc}
        else
            table.remove(stack)
        end
    end
    
    -- Render maze as walls
    for r = 1, rows do
        for c = 1, cols do
            mx = cx + (c - cols // 2) * 4
            my = cy + (r - rows // 2) * 4
            
            -- Draw passage floor
            sim:createBox(sim.PT_SAND, mx - 1, my - 1, mx + 1, my + 1, 0)
            
            -- Draw walls where needed
            if walls_down[r .. "_" .. c] then
                sim:createBox(wall_elem, mx, my + 2, mx + 2, my + 2, 0)
            end
            if walls_right[r .. "_" .. c] then
                sim:createBox(wall_elem, mx + 3, my, mx + 3, my + 2, 0)
            end
        end
    end
    
    print("Maze rendered: " .. cols .. "x" .. rows .. " cells")
end

-- =========================================================================
-- gen_fractal_firefly(cx, cy, amplitude, iterations, seed)
-- Lissajous-based energy art — beautiful looping patterns
-- =========================================================================
function gen_fractal_firefly(cx, cy, amplitude, iterations, _seed)
    if _seed then seed = _seed end
    seeded_rng(seed)
    
    colors = {sim.PT_ELEC, sim.PT_LIGH, sim.PT_SPRK, sim.PT_GLOW}
    
    for step = 1, iterations do
        t = step * 0.02
        x = cx + math.floor(amplitude * math.sin(3 * t))
        y = cy + math.floor(amplitude * math.cos(2 * t))
        
        if x >= 0 and x < XRES and y >= 0 and y < YRES then
            color_idx = math.floor((t / (math.pi * 2)) * #colors) % #colors + 1
            sim:createBox(colors[color_idx], x, y, x, y, 0)
        end
    end
    
    print("Fractal fireflies rendered: " .. iterations .. " particles seed=" .. seed)
end

-- =========================================================================
-- gen_dna(cx, cy, length, strand_w, seed)
-- DNA double helix backbone with complementary base pairs
-- =========================================================================
function gen_dna(cx, cy, length, strand_w, _seed)
    if _seed then seed = _seed end
    seeded_rng(seed)
    
    bases = {
        {A = sim.PT_AMTR, T = sim.PT_INSL},
        {A = sim.PT_BOYL, T = sim.PT_CBNW},
        {A = sim.PT_PPIP, T = sim.PT_BMTL},
    }
    
    for y = 0, length do
        angle = y * 0.3
        s1x = cx + math.floor(strand_w * math.cos(angle))
        s2x = cx + math.floor(strand_w * math.sin(angle))
        
        -- Backbones
        sim:createBox(sim.PT_IRON, s1x, cy + y, s1x, cy + y, 0)
        sim:createBox(sim.PT_WIRE, s2x, cy + y, s2x, cy + y, 0)
        
        -- Base pair every 3 units
        if y % 3 == 0 then
            pair = bases[((y // 3) % #bases) + 1]
            min_x = math.min(s1x, s2x)
            max_x = math.max(s1x, s2x)
            for x = min_x, max_x do
                cell = sim.pmap(x, cy + y)
                if not cell or cell == 0 then
                    if seeded_rng(x * 17 + cy + y * 31 + seed) > 0.5 then
                        sim:createBox(pair.A, x, cy + y, x, cy + y, 0)
                    else
                        sim:createBox(pair.T, x, cy + y, x, cy + y, 0)
                    end
                end
            end
        end
    end
    
    print("DNA helix generated: " .. length .. " base pairs")
end

print("\nAI Tools loaded:")
print('  gen_circuit(200, 200, 50, 50)')
print('  gen_terrain(200, 100, 40, 60)')
print('  gen_crystal(200, 200, 15, 20)')
print('  gen_maze(200, 200, 20, 20, BRICK)')
print('  gen_fractal_firefly(200, 200, 40, 800)')
print('  gen_dna(200, 300, 100, 8)')
