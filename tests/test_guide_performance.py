"""Offline regressions using the game's Lua 5.1 library, never a live save.

Run: python -m unittest discover -s tests -p test_guide_performance.py
Set POWDER_LUA_LIBRARY if lua51.dll is not in build/.
Set POWDER_GUIDE_SOURCE_ROOT to test an untouched baseline copy.
"""
import ctypes
import os
import unittest
from pathlib import Path

ROOT = Path(os.environ.get('POWDER_GUIDE_SOURCE_ROOT', Path(__file__).resolve().parents[1]))
LIB = Path(os.environ.get('POWDER_LUA_LIBRARY', Path(__file__).resolve().parents[1] / 'build/lua51.dll'))


class GuidePerformanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LIB.is_file():
            raise RuntimeError('Lua library missing. Set POWDER_LUA_LIBRARY to the game Lua 5.1 library.')
        if hasattr(os, 'add_dll_directory'):
            cls.dll_dir = os.add_dll_directory(str(LIB.parent))
        cls.lua = ctypes.CDLL(str(LIB))
        for name, args, result in [
            ('luaL_newstate', [], ctypes.c_void_p),
            ('luaL_openlibs', [ctypes.c_void_p], None),
            ('luaL_loadstring', [ctypes.c_void_p, ctypes.c_char_p], ctypes.c_int),
            ('lua_pcall', [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int], ctypes.c_int),
            ('lua_tolstring', [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p], ctypes.c_char_p),
            ('lua_close', [ctypes.c_void_p], None),
        ]:
            fn = getattr(cls.lua, name)
            fn.argtypes, fn.restype = args, result

    def run_lua(self, code):
        state = self.lua.luaL_newstate()
        self.assertTrue(state)
        try:
            self.lua.luaL_openlibs(state)
            status = self.lua.luaL_loadstring(state, code.encode())
            if status == 0:
                status = self.lua.lua_pcall(state, 0, 0, 0)
            error = self.lua.lua_tolstring(state, -1, None) if status else b''
            self.assertEqual(status, 0, error.decode(errors='replace'))
        finally:
            self.lua.lua_close(state)

    def lookup_code(self):
        source = (ROOT / 'scripts/lua/rpg.lua').read_text(encoding='utf-8')
        # Include both original and repaired ordering so baseline tests really execute
        # the original defect rather than failing to locate their subject.
        start = min(source.index('local function id(name)'), source.index('local idcache ='))
        return source[start:source.index('local namecache =')]

    def test_catalogue_lookup_is_linear_not_one_scan_per_name(self):
        self.run_lua('''
local R, calls = {}, 0
local sim = { PMAPBITS = 13 }
local elem = { property = function(i, field) calls = calls + 1; return 'E' .. i end }
''' + self.lookup_code() + '''
for i = 0, 499 do assert(eid('E' .. i) == i) end
for i = 1, 500 do assert(eid('MISSING' .. i) == nil) end
assert(calls <= 8192, 'catalogue lookup rescanned slots: ' .. calls)
''')

    def test_lookup_invalidation_finds_new_elements_and_preserves_aliases(self):
        self.run_lua('''
local R, names = {}, { [2]='DUP', [7]='DUP', [8]='STOCK' }
local sim = { PMAPBITS = 4 }
local elem = { DEFAULT_PT_ALIAS=8, property=function(i) return names[i] end }
''' + self.lookup_code() + '''
assert(eid('DUP') == 2)
assert(eid('ALIAS') == 8)
assert(eid('NEW') == nil)
names[10] = 'NEW'
R.clearIdCache()
assert(eid('NEW') == 10)
assert(eid('DUP') == 2)
assert(eid('ALIAS') == 8)
''')

    def guide_code(self):
        return (ROOT / 'scripts/lua/rpg_plugins/guide.lua').read_text(encoding='utf-8')

    def test_entire_guide_compiles_and_registers(self):
        self.run_lua('''
local R = {hooks={key={},mousedown={},mouseup={},tick={},wheel={},newworld={},drawHUD={}}}
PBX = {state={rpg=R}}
''' + self.guide_code() + '''
assert(#R.hooks.drawHUD == 1)
assert(#R.hooks.tick == 1)
assert(type(R.openGuide) == 'function')
''')

    def test_page_reuses_cache_refreshes_and_wraps_links(self):
        self.run_lua('''
local time, builds = 0, 0
os.clock = function() return time end
local R = {hooks={key={},mousedown={},mouseup={},tick={},wheel={},newworld={},drawHUD={}},
 RECIPES={}, NAMES={}, ITEMS={}, MINEABLE={}, HARD={}, PICKS={}, SWORDS={}, STATIONS={},
 TOOLS={pick={power=1,name='test'}}, guide={cat='controls',id='move'}}
PBX = {state={rpg=R}}
graphics={textSize=function(s) return #s*6, 10 end}
''' + self.guide_code() + '''
assert(type(R.guidePageLines)=='function', 'guide has no cached page path')
local a=R.guidePageLines()
for i=1,100 do assert(R.guidePageLines()==a, 'unchanged page rebuilt') end
time=0.3
local b=R.guidePageLines(); assert(b~=a, 'live page never refreshed')
R.guide.id='sandbox'
local c=R.guidePageLines(); assert(c~=b, 'navigation returned stale page')
for _,line in ipairs(c) do
 local width=0; for _,seg in ipairs(line) do width=width+graphics.textSize(seg.t) end
 assert(width<=COL3W-SBW-2, 'text exceeds guide column: '..width)
end
R.guide.cat,R.guide.id='progression','overview'
R.tech={}; R.stations={}; R.ITEMS.WORKBENCH={}; R.STATIONS.workbench='Workbench'
local linked=R.guidePageLines(); local found=false
for _,line in ipairs(linked) do for _,seg in ipairs(line) do
 if seg.link then assert(seg.link.id=='WORKBENCH'); found=true end
end end
assert(found, 'layout lost clickable link')
''')

    def test_terrain_sampling_is_bounded_complete_and_shared(self):
        self.run_lua('''
local calls=0
local R = {hooks={key={},mousedown={},mouseup={},tick={},wheel={},newworld={},drawHUD={}},
 DEPTH=100, seed=42, gen=function(x,y) calls=calls+1; return y>20 and 'COAL' or 'WATR' end,
 surfaceAt=function() return 10 end, biomeAt=function() return 'forest' end}
PBX={state={rpg=R}}
''' + self.guide_code() + '''
local first=sampleLocation('COAL')
assert(first.pending and calls==0, 'draw path synchronously generated terrain')
advanceWorldSample(); assert(calls>0 and calls<=8, 'unbounded terrain tick')
for i=1,100 do advanceWorldSample() end
local done=sampleLocation('COAL')
assert(done.found and done.minDepth==12 and done.maxDepth==84 and done.biome=='forest')
local completed=calls
assert(sampleLocation('WATR').found)
assert(not sampleLocation('ABSENT').found)
assert(calls==completed, 'different ore regenerated the same world')
R.seed=43
assert(sampleLocation('COAL').pending, 'new world reused old locations')
''')


if __name__ == '__main__':
    unittest.main()
