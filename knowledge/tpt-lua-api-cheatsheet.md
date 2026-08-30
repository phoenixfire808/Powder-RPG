# TPT Lua API cheat-sheet (verified against The-Powder-Toy master src/lua/*.cpp by research fork, 2026-08-25)

**Caveat:** our binary reports `tpt.version` 100.x and still exposes legacy `tpt.set_pause`; the master-branch list below is authoritative for new code, but test on our build (see the live checks in knowledge/experiments-*.jsonl).

## simulation.*
- partCreate(newID,x,y,type[,v]) -> id (newID=-1 first free) · partProperty(id,prop[,value]) · partPosition(id[,x,y]) -> x,y · partID(x,y) -> id|nil · partKill(id) · partExists(id) · partChangeType(id,type) · partNeighbors(x,y,r[,type]) -> {ids} (spelled Neighbors) · neighbors(x,y[,r,type]) iterator (id,x,y) · photons(x,y) · pmap(x,y) · partCount() · elementCount([el])
- field maps, get = (x,y), set = (x,y,v) or block (x,y,w,h,v): pressure, velocityX, velocityY, ambientHeat, gravityMask, gravityMass, wallMap, elecMap; gravityField(x,y) -> fx,fy (get only)
- stamps: saveStamp([x,y,w,h,includePressure]) -> filename · loadStamp(id_or_filename[,x,y,hflip,rotation,includePressure]) -> 1 | nil,err (**id first**) · listStamps() · deleteStamp(id)
- online: loadSave(saveID[,instant]) opens the save-preview UI (NOT a local load — this is why the bridge hung) · reloadSave() · getSaveID() -> id,version
- control: **paused([bool]) -> bool** (real pause API) · **frameRender([n]) -> queued** (deterministic frame step: set N, poll until 0, or count in event.aftersim) · clearSim() · clearRect(x,y,w,h) · resetTemp([onlyConductors]) · resetPressure([x,y,w,h]) · resetVelocity([x,y,w,h]) · resetSpark() · takeSnapshot() · historyRestore() · historyForward() · edgeMode · gravityMode · customGravity([gx,gy]) · airMode · waterEqualization · ambientAirTemp · edgePressure · edgeVelocity · vorticityCoeff · convectionMode · randomSeed · hash · ensureDeterminism · temperatureScale
- drawing: createParts, createLine, createBox, floodParts, createWalls, createWallLine, createWallBox, floodWalls, toolBrush/Line/Box, decoBrush/Line/Box, decoColor, floodDeco, brush, adjustCoords, replaceModeFlags

## elements.*
allocate(group,name) -> id · element(id[,table]) · property(id,name[,value[,mode]]) · free(id) · loadDefault([id]) · getByName(name) -> id

## event.*
register(eventType, fn) -> fn; types: textinput, textediting, keypress, keyrelease, mousedown, mouseup, mousemove, mousewheel, tick, blur, close, beforesim, aftersim, beforesimdraw, aftersimdraw (aftersim fires once per simulated frame — use for exact frame counting)

## tpt.* / graphics.*
tpt.screenshot([captureUI 0|1, fileType 0|1]) -> filename — the only render-to-disk path · tpt.debug · tpt.fpsCap(n>=2) · tpt.installScriptManager · tpt.log. graphics.* is draw-only (textSize, drawText, drawPixel, drawLine, drawRect, fillRect, drawCircle, fillCircle, getColors, getHexColor, setClipRect) — no pixel readback.

## Canonical build→verify loop
sim.paused(true) → draw → sim.paused(false); sim.frameRender(N); poll sim.frameRender()==0 → sim.paused(true) → census (partID/partProperty/pmap/elementCount) → tpt.screenshot() → sim.saveStamp() checkpoint.
