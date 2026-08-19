# Repository Guidelines

## Project Overview

**The Powder Toy** — a free (GPLv3) real-time particle physics sandbox game. Simulates air pressure, velocity, heat, gravity, and hundreds of interactions between virtual substances. Users paint particles on a 2D grid and watch emergent physics unfold: liquids flow, gases expand, fires burn, circuits conduct, stickmen fight, and nuclear reactions cascade.

Also known as "falling sand" or "pixel physics" genre. Over 5,000 stars on GitHub. Available on Steam and as native desktop app (Windows/Linux/macOS), Android, and WebAssembly.

**Key facts**: 427+ C++ source files, 55K lines, C++20, no STL containers for hot paths (flat arrays only). ~150 built-in elements spanning powders, liquids, gases, metals, explosives, electronics, life forms, and exotic matter.

---

## Architecture & Data Flow

### Core Loop

```
main() → Client::Initialize() → initSDL() → loop:
  ├─ handle_events()        ← keyboard, mouse, joystick, window
  ├─ process_sim()          ← Controller updates simulation step
  │   └─ SimulationImpl::UpdateParticles(start, end)  [grid sweep left→right, top→bottom]
  ├─ draw_game_view()       ← Renderer paints pixels from simulation state
  └─ swap_buffers()         ← present frame
```

**Simulation pipeline** (per tick):
1. `BeforeSim()` — pre-pass (gravity recalculation, EMP decorations, gol toggles)
2. `MovementPhase(i)` — each particle tries to move based on gravity, advection, collisions
3. `TransitionPhase(i)` — type changes based on neighbors (phase transitions, chemical reactions)
4. `AfterSim()` — post-pass (pressure map cleanup, population counting)

### Architecture Diagram

```
┌──────────────────────────────────────────────────────┐
│                    SDL2 Window                       │
│                                                      │
│  ┌──────────────────┬──────────────────────────────┐ │
│  │     Menu Bar     │     Quick Options            │ │
│  │  (Search, Tabs)  │     (Scale, Brush Size)      │ │
│  ├──────────────────┼──────────────────────────────┤ │
│  │                  │                              │ │
│  │   GameView       │    HUD                       │ │
│  │   (Renderer)     │    (FPS, Part count)         │ │
│  │                  │                              │ │
│  │                  │                              │ │
│  ├──────────────────┴──────────────────────────────┤ │
│  │     Tool Bar (Brush Types, Elements)             │ │
│  └──────────────────────────────────────────────────┘ │
│                                                      │
│  ┌──────────────────────────────────────────────────┐ │
│  │     Console / Lua Input                          │ │
│  └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘

GameModel (state) ── GameController (input handling)
                      ── GameView (rendering)
                      ── Controller base class hierarchy

Controller ── Client (network/auth/save management)
              ── GameController (gameplay input + menu logic)
              ── LoginController (user authentication)
              ── OptionsController (settings)
              ── ...etc (gui/* subdirectories)
```

### Key Design Patterns

**Retained-mode GUI**: UI uses a Component → Window hierarchy maintained across frames. GameView extends `ui::Window`. Controllers manage MVC triplets per screen with separate Model/View layers.

**Flat-array simulation**: Core data stored as raw 2D arrays (`pmap[YRES][XRES]`), never heap-allocated during sim. Memory pool allocator (`Parts`) for particle objects. Cache-friendly row-major sweeps.

**Virtual dispatch minimal**: Hot path uses static inline functions; virtual only at layer boundaries (Simulation subclass, controller).

**Lua sandbox**: Full Lua 5.x/LuaJIT embedded with custom API surface. Scripts run within simulation context — can modify elements, spawn particles, create UI windows.

---

## Key Directories

| Directory | Purpose | Files | Key Pattern |
|-----------|---------|-------|-------------|
| `src/simulation/` | Core physics engine, particle types, element behaviors, tools | ~60 files | **One `.cpp` per element**; update/gfx functions registered via `Element::Element_XX()` |
| `src/simulation/elements/` | All individual element implementations | ~150 .cpp | See "Adding an Element" below |
| `src/simulation/gravity/` | Gravity computation (FFT-based N-body, null implementation) | 4 files | Strategy pattern for gravity modes |
| `src/simulation/simtools/` | Global simulation tools (heat, cool, wind, vacuum, cyclone) | 10 files | Modify region properties directly |
| `src/gui/` | Complete immediate-mode UI framework + controllers | ~130 files | MVC-style: `*Controller`, `*Model`, `*View` trio per screen |
| `src/gui/game/` | Main gameplay screen, tool buttons, brush rendering | 15 files | Entry point for user interaction |
| `src/gui/interface/` | Reusable widgets (buttons, panels, sliders, dropdowns) | 20+ files | Inheritance hierarchy: `Component → Button/Separator/etc.` |
| `src/lua/` | Embedded Lua host + API bindings | ~40 files | Socket, HTTP, filesystem, graphics, element manipulation exposed |
| `src/client/` | Online features: auth, saves, comments, ratings, tags | 25 files | HTTP request/response model; login/session management |
| `src/common/` | Platform abstraction, clipboard, string utils, random | 15 files | Thin wrapper around OS APIs |
| `src/debug/` | Debug tools (air velocity visualization, element population stats) | 7 files | Toggleable via debug mode |
| `src/graphics/` | Raster drawing pipeline, font rendering, gradient system | 8 files | Pixel-level direct framebuffer manipulation |
| `src/prefs/` | User preference storage (XML config files) | 1 file | Persistent settings synced via cloud account |

---

## Development Commands

### Build (local)

```bash
# Configure (auto-detects platform, needs SDL2, FFmpeg, bzip2, libpng, jsoncpp, libcurl, lua/luajit)
meson setup build

# Build
ninja -C build

# On Windows with MSVC (uses tpt-libs-prebuilt subprojects)
# Dependencies auto-downloaded from https://github.com/the-powder-toy/tpt-libs-prebuilt

# On Linux (Ubuntu example):
sudo apt install libsdl2-dev libfftw3-float-dev libpng-dev libbz2-dev \
  libjsoncpp-dev libcurl4-openssl-dev libluajit-5.1-dev
meson setup build --buildtype=release
ninja -C build
```

### Run

```bash
ninja -C build run           # Runs the built binary
./build/powder               # Direct execution
./build/powder --debug       # With console output on Windows
```

### Build options (configure flags)

```bash
-Dstatic=prebuilt    # Use prebuilt libraries (default on Windows)
-Dstatic=system      # Find deps on system
-Dlto=true           # Link-time optimization
-Dbeta=true          # Mark as beta build
-Dlua=luajit         # Lua variant: none/lua5.1/lua5.2/luajit/auto
-Dserver="localhost" # Override server URL for dev
-Dapp_name="MyMod"   # Custom app name for mods
-Dmod_id=123         # Enable mod ID support (for starcatcher.us updates)
-Dclang_tidy=true    # Enable clang-tidy linting (dev only)
-Dx86_sse=avx2       # Override SSE level for x86 builds
```

### Lint

```bash
ninja -C build clang-tidy    # Requires run-clang-tidy script installed
```

No test suite exists. Code quality enforced via `.clang-tidy` rules + manual PR review.

---

## Adding a New Element (Pattern)

Each element is a single `.cpp` file named `<ID>.cpp` in `src/simulation/elements/`. Convention: uppercase 3-4 letter abbreviation.

**File structure:**
```cpp
#include "simulation/ElementCommon.h"  // ALWAYS include first

void Element::Element_MYEL()
{
    Identifier = "DEFAULT_PT_MYEL";
    Name = "MYEL";
    Colour = 0xFF0000_rgb;             // RGB colour
    MenuVisible = 1;                   // Show in UI
    MenuSection = SC_POWDERS;          // Category (see SC_* enums)
    Enabled = 1;                       // Initially enabled

    // Physics properties
    Advection = 0.4f;                 // Air drag ratio (0=inert, 1=follows air)
    AirDrag = 0.02f * CFDS;           // Horizontal speed decay
    AirLoss = 0.96f;                  // Vertical speed decay
    Loss = 0.95f;                     // Chance to die each tick
    Collision = -0.1f;                // Bounce off walls (-1=stick, 0=bounce, >1=recurse)
    Gravity = 0.6f;                   // Fall speed multiplier
    NewtonianGravity = 0;             // 0=disabled
    Diffusion = 0.0f;                 // Spread factor (liquids use this)
    HotAir = 0.001f * CFDS;           // Buoyancy rise
    Falldown = 1;                     // 0=floating, 1=falls, 2=sinks, 3=liquid
    Flammable = 15;                   // Ignition chance
    Explosive = 0;                    // Explosion strength when ignited
    Meltable = 0;                     // Temperature to melt
    Hardness = 20;                    // Fragmentation resistance
    Weight = 40;                      // Density

    DefaultProperties.temp = R_TEMP + 0.0f + 273.15f;
    // NOTE: Particle has no "health" field — use life for HP tracking instead
    HeatConduct = 70;
    Description = "Description here.";
    Properties = TYPE_PART;           // TYPE_PART | TYPE_LIQUID | TYPE_GAS | etc.

    LowPressure = IPL;
    LowPressureTransition = NT;       // No transition at low pressure
    HighPressure = IPH;
    HighPressureTransition = NT;
    LowTemperature = ITL;
    LowTemperatureTransition = NT;
    HighTemperature = ITH;
    HighTemperatureTransition = NT;

    Update = &update;                 // Per-particle simulation function (REQUIRED)
    Graphics = &graphics;             // Render function (OPTIONAL, uses defaultGraphics if omitted)
}

// Per-frame simulation: called once per particle per tick
static int update(UPDATE_FUNC_ARGS)
{
    // sim = &the current simulation object
    // parts = &array of all active particles
    // i = index of current particle
    // x, y = current coordinates
    // r = pmap[neighbor_y][neighbor_x] of the neighbor being examined
    // ID(r) = particle ID stored in pmap
    // TYP(r) = element type ID stored in pmap
    // parts[ID(r)].temp = neighbor's temperature
    // sim->part_change_type(i, x, y, PT_NEWEL) = change this particle's type
    // sim->kill_part(i) = destroy this particle
    // sim->rng.chance(numerator, denominator) = seeded RNG check
    // rng(-1,1) = random float between -1 and 1

    // Examine neighbors with double loop
    for (auto rx = -2; rx <= 2; rx++) {
        for (auto ry = -1; ry <= 1; ry++) {
            if (rx == 0 && ry == 0) continue;
            auto r = pmap[y+ry][x+rx];
            if (!r) continue;
            if (TYP(r) == PT_FIRE) {
                if (sim->rng.chance(1, 5)) {
                    sim->part_change_type(i, x, y, PT_FIRE);
                    parts[i].life = 40 + sim->rng(5);
                    parts[i].ctype = PT_MYEL;
                }
            }
        }
    }
    return 0;  // 0=normal, -1=skip next frame
}

// Optional: custom rendering
static int graphics(GRAPHICS_FUNC_ARGS)
{
    // Draw at *cptr, size *psz, color *pcol
    // sim = &the current simulation object
    return 0;  // 0=draw, 1=no draw
}
```

**Element categories** (`MenuSection`):
-- `SC_NONE`, `SC_VOID`, `SC_WALLS`, `SC_POWDERS`, `SC_LIQUIDS`, `SC_GASES`, `SC_ELECTRONICS`, `SC_SPECIAL`, `SC_LIFE`, `SC_TOOLS`, `SC_ADMIN`

**To register**: 
1. Append entry to `src/simulation/ElementNumbers.template.h`: `name("ID") id,`
2. meson's `configure_file()` generates `ElementNumbers.h` at build time — you NEVER edit it manually
3. Create your `.cpp` element file; it's compiled via wildcard in `src/simulation/meson.build`
4. Run `meson compile -C build` to produce binary with new element

---

## Lua API Surface

Lua is extensively supported. The interface is documented but here are the practical hooks:

### Simulation Control
```lua
-- Access current simulation state
paused()                        -- Get/set pause
partCount()                     -- Total particle count
ambientHeat(true/false)         -- Enable ambient heat
newtonianGravity(true/false)    -- Switch to Newtonian gravity

-- Read/write grid values
velocityX(x, y, width, height, value)  -- Get/set horizontal velocity map
velocityY(x, y, width, height, value)  -- Get/set vertical velocity map
pressure(x, y, w, h, value)
ambientHeat(x, y, w, h, value)
elecMap(x, y, w, h, value)     -- Electric field map
wallMap(x, y, w, h, value)     -- Wall types map
fanVelocityX/Y(...)             -- Fan wind force maps

-- Particle queries  
partID(id)                -- Returns 1 if particle exists (returns lua boolean or int)
partExists(id)             -- Check if a specific particle ID still exists
partNeighbors(x, y, radius[, type]) -- Return table of nearby particle IDs (type optional filter)
```

### Element Creation (in-place new elements)
```lua
element(name)                   -- Create element from table definition
property(element_id, "name", value)  -- Set runtime property
exists(type_id)                 -- Check if element exists
loadDefault(type_id)            -- Reset element to defaults
getByName("NAME")               -- Lookup element type ID by name
```

### Element Definition Table
```lua
element({
    name = "MYELEM",
    colour = { R, G, B },
    category = "powders",        -- or "liquids", "gases", "electronics", "special", "life"
    behavior = BehaviorTable,    -- See simulation behavior format
})
```

### Networking & IO
```lua
http.request(url)               -- HTTP GET
socket.tcp(...)                 -- Raw TCP sockets
fs.write(path, data)
fs.read(path)
```

### UI Components (create in-game menus)
```lua
window.new(w, h, title)
button:setText("OK")
slider:setRange(0, 100)
label:SetText("status")
textbox:GetText()
```

Lua scripts can also define element behaviors declaratively without C++:
```lua
element({
  name = "AI_ELEMENT",
  behavior = {
    DX = 0, DY = 1,
    ON(txp, tpy, sx, sy) = function(state)
      if state[tzp] == FIRE then
        return {state.sx, state.sy} -- spread to fire
      end
    end
  }
})
```

---

## Important Files

| File | Role |
|------|------|
| `src/PowderToy.cpp` | Entry point (Windows: `WinMain`, Unix: `main`) — initializes SDL, creates `Client` instance |
| `src/controller.h` | Abstract `Controller` base class (`Exit()`, `Show()`, `Hide()`) |
| `src/client/Client.cpp` | Application lifecycle: init, event loop, shutdown. Creates controllers |
| `src/Config.h.template` | Compiled configuration (platform defines, version numbers) |
| `meson.build` | Root build file — defines subprojects, dependencies, compiler flags |
| `meson_options.txt` | All build options with descriptions |
| `src/simulation/Element.h` | `Element` base class — every property defined here |
| `src/simulation/ElementClasses.cpp` | Registration: calls `Element_XX()` for each built-in element |
| `src/simulation/elements/*.cpp` | Individual element definitions (~150 files) |
| `src/simulation/Particle.h` | Particle struct — per-particle runtime data |
| `src/simulation/AccessProperty.h/.cpp` | Property lookup helper for dynamic element modification |
| `src/simulation/simtools/*.cpp` | World-affecting tools (HEAT, COOL, CYCL, VAC, WIND, etc.) |
| `src/lua/LuaScriptInterface.cpp` | Lua host initialization and binding |
| `src/lua/LuaSimulation.cpp` | Simulation-exposed Lua functions |
| `src/lua/LuaElements.cpp` | Element creation/manipulation via Lua |
| `src/gui/game/GameController.cpp` | Gameplay input handling (mouse clicks, tool selection) |
| `src/gui/game/GameView.cpp` | Renders the simulation canvas (pixel-perfect drawing) |
| `src/graphics/Renderer.cpp` | Low-level pixel buffer operations |
| `src/graphics/RasterGraphics.cpp` | Raster drawing primitives (lines, circles, fills) |
| `subprojects/` | vendored dependencies (tpt-libs-prebuilt for Windows/Android) |
| `resources/` | App icons, fonts, save templates, desktop integration files |

---

## Runtime & Tooling Preferences

| Aspect | Requirement |
|--------|-------------|
| **Language** | C++20 (no RTTI, exceptions controlled per-platform) |
| **Build system** | Meson + Ninja (NOT CMake, NOT Make) |
| **GUI toolkit** | SDL2 (not Qt, not ImGui, not Dear ImGui) |
| **Scripting** | Lua 5.1, Lua 5.2, or LuaJIT (configurable at build time) |
| **Dependencies** | SDL2, FFTW3f, libpng, bzip2, jsoncpp, libcurl, mbedtls (optional) |
| **Prebuilt libs** | Windows/Android use prebuilt static libs from `subprojects/tpt-libs-prebuilt-*` |
| **Cross-compilation** | Linux→Windows (MinGW), Mac→arm64, Android NDK, Emscripten/WebAssembly |
| **Editor** | Any editor works; `.clang-tidy` provides linting hints |
| **Platform macros** | `WIN64`/`WIN32`, `LIN64`/`LIN32`, `MACOSARM`, `MACOSX`, `ANDROID`, `EMSCRIPTEN` |

---

## Code Conventions & Common Patterns

### Naming

- **Headers**: PascalCase (`GameController.h`, `Simulation.h`)
- **Implementations**: PascalCase (`GameController.cpp`)
- **Function names**: PascalCase for public APIs, lowercase_with_underscores for internal helpers
- **Struct/enum members**: camelCase (`frameCounter`, `particleHealth`)
- **Constants/enums**: SCREAMING_SNAKE_CASE (`MAX_PARTICLES`, `TYPE_PART`)
- **Member variables**: leading underscore or no prefix (mixed codebase; prefer consistent style locally)
- **Element IDs**: UPPERCASE 3-4 letter abbreviations (`WATR`, `SAND`, `FIRE`, `FUSE`)

### Headers

- Include guards via `#pragma once` everywhere
- Forward declare where possible; avoid circular includes
- Include ordering: project headers → standard library → third-party
- Never include `ElementCommon.h` outside `src/simulation/elements/`

### Error Handling

- No exceptions in hot paths. Use return codes (0=success, negative/error codes)
- `Assert.h` provides lightweight asserts — disabled in release builds
- Blue-screen error handler catches crashes on Windows/Mac/Linux and shows detailed error info
- Lua errors are caught at host boundary — scripts don't crash the game

### Performance Critical Rules

- **NO heap allocation** in `update()` functions (called per particle per tick)
- **NO virtual calls** in movement/transition phases
- **NO `std::vector`, `std::string`** in hot paths — use flat arrays, fixed buffers, ByteString/String view types
- **Cache locality**: iterate Y then X? No — X inner loop (row-major). Particles always swept left-to-right, top-to-bottom for determinism.
- **Loop unrolling**: Neighbourhood checks hard-coded to ±1 or ±2 range — no dynamic bounds
- **SIMD hints**: `-ffast-math`, `-ftree-vectorize`, optional AVX2/AVX-512 compilation flags

### Element Interaction Pattern

Every element's `update()` function follows this template:
```cpp
static int update(UPDATE_FUNC_ARGS)
{
    // 1. Examine neighboring cells
    for (auto rx = -N; rx <= N; rx++) {
        for (auto ry = -M; ry <= M; ry++) {
            if (rx == 0 && ry == 0) continue;
            auto r = pmap[y + ry][x + rx];
            if (!r) continue; // empty cell
            
            switch (TYP(r)) {
                case PT_FIRE:
                    // Handle fire interaction...
                    break;
                case PT_WATR:
                    // Handle water interaction...
                    break;
                default:
                    break;
            }
        }
    }
    return 0;
}
```

### Comments

- Use `//@` comment annotations for element interactions: e.g., `//@ WATR + SALT -> SLTW`
  These generate the interaction tooltip shown in the game UI when you hover over related elements.

---

## Testing & QA

**There is no automated test suite.** The project relies entirely on:

1. Manual playtesting before submitting patches
2. Community bug reports via GitHub Issues and Discord (#tpt-dev channel)
3. Automated CI builds ensure the code compiles on all target platforms (Windows MSVC, MinGW GCC, macOS Clang, Linux GCC, Android NDK, Emscripten WASM)
4. Clang-Tidy available as `ninja -C build clang-tidy` for development-only static analysis

**Verification checklist before proposing changes:**
- [ ] Builds clean on current platform without warnings
- [ ] Tested manually in-game (not just compile success)
- [ ] No new memory leaks (test: run game for 5+ minutes, check part count stays stable)
- [ ] Deterministic: re-run same scenario and observe identical results
- [ ] Does not break existing elements' interactions
- [ ] Respects original author intent (no unnecessary API changes)

---

## ⚠️ IMPORTANT: Upstream Contribution Policy

**If you plan to submit pull requests to The-Powder-Toy/The-Powder-Toy (upstream):**

The project explicitly **rejects code generated by AI/LLMs**. From their CONTRIBUTING.md:

> *"Code written with AI/LLMs will be declined."*

This means:
- ✅ You may use AI to find bugs, suggest ideas, review your own code
- ❌ You cannot paste AI-generated C++ code into PRs
- ⚠️ This applies only to upstream contributions — **your fork can contain anything**

For your fork, these restrictions do not apply. However, consider learning the patterns above so your additions match the codebase style and pass eventual review if you ever upstream them.

---

## AI Integration Extension Points

Since this is your fork for AI enhancement, here are the highest-impact areas to extend:

### Tier 1 — Lua Plugins (No recompilation needed)
- `/data/scripts/ai_elements.lua` — Define new elements via Lua `element({...})` API
- Modify existing element properties at runtime via `property(ID, "Flammable", 50)`
- Hook into simulation ticks with `SimulateGoL`-style callbacks

### Tier 2 — C++ Elements (Requires rebuild)
- Add AI-themed elements: NEUT (neural net node), BRAI (brain tissue), SYNAP (synapse)
- Integrate with external APIs via Lua's HTTP/socket support
- Create procedural generators via Lua that construct patterns algorithmically

### Tier 3 — External Process Integration
- Spawn Python sidecar process that sends commands via stdin/stdout pipes
- WebSocket server embedded via Lua socket extensions
- Computer vision preprocessing: analyze screenshots, translate to particle commands

### Architecture Hooks Already Present
- `src/lua/LuaHttp.cpp` — HTTP requests already implemented (call OpenAI/Gemini APIs)
- `src/lua/LuaSocketTCPWebsocket.cpp` — WebSocket support already compiled in
- `src/lua/LuaFileSystem.cpp` — Read/write rule files, neural weights, etc.
- `src/lua/LuaSimulation.cpp` — Grid read/write, particle manipulation, pressure/temperature maps

The Lua API surface is rich enough to implement sophisticated AI integrations **without modifying core C++**, making iteration fast and cross-platform compatible.
