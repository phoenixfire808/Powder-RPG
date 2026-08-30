"""POWDER RPG v3 launcher (Terraria-style survival on TPT physics; infinite chunked world, sprite player).

  python scripts/rpg.py start [--seed 7]   # load scripts/lua/rpg.lua, generate a world, spawn the player, unpause
  python scripts/rpg.py status             # HP, day, inventory, message
  python scripts/rpg.py stop               # detach the game mode (world stays)
  python scripts/rpg.py screenshot         # tpt.screenshot -> prints the PNG path
Controls: A/D run, W/Space jump, S fast-fall, mouse aim, hold LMB use tool (slots 1-5: pick/axe/sword/torch/bucket),
hold RMB place block (slots 6-0), 1-0 / wheel select, E bag+crafting (click items/recipes), Esc, M minimap, N enemies, H HUD, K save, R respawn, F1 debug.
Walk off either screen edge to stream the next chunk (generated from the seed, edits kept in memory).

  python scripts/rpg.py save                # write knowledge/rpg-save.json (whole world + player state)
  python scripts/rpg.py load                # clear the sim and restore from knowledge/rpg-save.json
"""
import sys, json, argparse, time
sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient


def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=["start", "status", "stop", "screenshot", "save", "load"]); ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args(); c = PowderClient(); L = lambda s: c.execute_lua(s).get("result")
    if a.cmd == "start":
        print(L(open("D:/powder-toy/scripts/lua/rpg.lua", encoding="utf-8").read()))
        print(L(f"local ok,err=pcall(PBX.state.rpg.start,{a.seed}) return tostring(ok)..' '..tostring(err)"))
        time.sleep(1.0)
    if a.cmd in ("start", "status"):
        print(L('local R=PBX.state.rpg if not R then return "rpg not loaded" end local inv={} for k,v in pairs(R.inventory or {}) do inv[#inv+1]=k.."="..v end table.sort(inv) local P=R.P or {} return string.format("active=%s pos=%.0f,%.0f hp=%s day=%s chunk=%s deaths=%s parts=%d err=%s inv[%s] log=%s", tostring(R.active), P.x or -1, P.y or -1, tostring(R.hp), tostring(R.day), tostring(R.cx), tostring(R.deaths or 0), sim.partCount(), tostring(R.lastErr), table.concat(inv,","), tostring(R.log and R.log[1] and R.log[1][1]))'))
    if a.cmd == "stop":
        print(L("return PBX.state.rpg and PBX.state.rpg.stop() or 'rpg not loaded'"))
    if a.cmd == "screenshot":
        print("D:/The-Powder-Toy/build/" + str(L("return tostring(tpt.screenshot(0,0))")))
    if a.cmd == "save":
        print(L('local R=PBX.state.rpg if not R then return "rpg not loaded" end local ok,err=pcall(R.save) return "save "..tostring(ok).." "..tostring(err)'))
    if a.cmd == "load":
        print(L('local R=PBX.state.rpg if not R then return "rpg not loaded" end local ok,n=pcall(R.load, nil, true) return "load "..tostring(ok).." "..tostring(n)'))
    return 0


if __name__ == "__main__":
    sys.exit(main())
