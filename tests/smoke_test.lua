require("tests.corona_stub")

local chessMap    = require("modules.chessMap")
local pawnDplyr   = require("modules.pawnDplyr")
local abltMng     = require("modules.abltMng")
local chessUpdtr  = require("modules.chessUpdtr")
local pawnCon     = require("modules.pawnCon")
local sampleLevel = require("data.sampleLevel")

local function line(msg) print("---- " .. msg .. " ----") end

abltMng.registerDefaults()

line("BUILD MAP")
local map = chessMap.new(sampleLevel.rows, { availableWidth = 1000, availableHeight = 654, originX = 10, originY = 46 })
print(string.format("cols=%d rows=%d tileSize=%d spawnPCs=%d spawnEnemies=%d goals=%d",
    map.cols, map.rows, map.tileSize, #map.spawnPCs, #map.spawnEnemies, #map:getGoalTiles()))
assert(map.cols == 20 and map.rows == 15, "map dimensions wrong")
assert(#map.spawnPCs == 3 and #map.spawnEnemies == 3, "spawn counts wrong")

local fakeGroup = display.newGroup()
map:draw(fakeGroup)

line("DEPLOY PAWNS")
local dplyr = pawnDplyr.new(map, fakeGroup)
dplyr:autoDeployFromMap(sampleLevel.assignments)
for _, extra in ipairs(sampleLevel.extras) do dplyr:deploy(extra.kind, extra.col, extra.row) end

local pcs = dplyr:getAllByFaction("pc")
table.sort(pcs, function(a,b) return a.id < b.id end)
local enemies = dplyr:getAllByFaction("enemy")
table.sort(enemies, function(a,b) return a.id < b.id end)
assert(#pcs == 3, "expected 3 PCs")
assert(#enemies == 3, "expected 3 enemies")
for _, p in ipairs(pcs) do print(string.format("PC #%d %s at (%d,%d) hp=%d", p.id, p.name, p.col, p.row, p.hp)) end
for _, e in ipairs(enemies) do print(string.format("EN #%d %s at (%d,%d) hp=%d", e.id, e.name, e.col, e.row, e.hp)) end

local updtr = chessUpdtr.new(map, dplyr)
local boardHit = display.newRect(0,0,0,0)
local con = pawnCon.new(dplyr, map, updtr, boardHit)
for _, p in pairs(dplyr.pawns) do con:registerSelectable(p) end

local knight, mage, guardian = pcs[1], pcs[2], pcs[3]

-- ------------------------------------------------------------- MOVEMENT
line("MOVEMENT")
con:select(knight.id)
assert(con.selectedId == knight.id, "select failed")
local startCol, startRow = knight.col, knight.row
local ok, reason = updtr:requestMove(knight, startCol + 1, startRow)
assert(ok, "knight should be able to move 1 tile onto open floor: " .. tostring(reason))
assert(knight.col == startCol + 1 and knight.row == startRow, "knight position did not update")
assert(dplyr:getAt(startCol, startRow) == nil, "old tile should be vacated")
assert(dplyr:getAt(knight.col, knight.row).id == knight.id, "occupancy grid should show knight at new tile")
print("knight moved to", knight.col, knight.row, "OK")

-- try an out-of-range move (baseline movement is exactly 1 orthogonal tile)
local farOk = updtr:requestMove(knight, knight.col + 2, knight.row)
assert(farOk == false, "moving 2 tiles in one action should fail")
print("2-tile move correctly rejected")

-- try a diagonal move
local diagOk = updtr:requestMove(knight, knight.col + 1, knight.row + 1)
assert(diagOk == false, "diagonal move should fail -- baseline movement is orthogonal only")
print("diagonal move correctly rejected")

-- arrow-key path: requestStep with a direction vector instead of a destination
local stepCol, stepRow = knight.col, knight.row
local stepOk = updtr:requestStep(knight, 0, 1) -- "down"
assert(stepOk, "requestStep should move the knight one tile down onto open floor")
assert(knight.col == stepCol and knight.row == stepRow + 1, "requestStep did not move exactly one tile down")
print("requestStep (arrow-key path) OK: knight now at", knight.col, knight.row)

-- try moving onto a wall -- place the knight directly adjacent to one
-- first, so this genuinely tests wall-blocking (not just non-adjacency)
local wallCol, wallRow = 12, 5 -- one of the interior pillar walls in sampleLevel
assert(map:getTile(wallCol, wallRow).type == chessMap.TILE.WALL, "expected a wall there for the test")
dplyr:moveTo(knight.id, wallCol - 1, wallRow)
local wallMoveOk = updtr:requestStep(knight, 1, 0) -- one step east, straight into the wall
assert(wallMoveOk == false, "moving onto a wall should fail")
assert(knight.col == wallCol - 1, "knight should not have moved into the wall")
print("move onto wall correctly rejected")

-- ------------------------------------------------------------- SWAP
line("SWAP ABILITY")
-- put mage directly adjacent to knight to test swap
dplyr:moveTo(mage.id, knight.col + 1, knight.row)
local mageCol, mageRow = mage.col, mage.row
local knightColBefore, knightRowBefore = knight.col, knight.row
local swapOk = updtr:useAbility(knight, "swap", mage)
assert(swapOk, "swap should succeed on adjacent pawn")
assert(knight.col == mageCol and knight.row == mageRow, "knight should now be where mage was")
assert(mage.col == knightColBefore and mage.row == knightRowBefore, "mage should now be where knight was")
print("swap OK: knight<->mage positions exchanged")

-- ------------------------------------------------------------- PUSH ALL
line("PUSH ALL ABILITY")
-- reposition guardian directly east of knight with open space beyond, then push
dplyr:moveTo(guardian.id, knight.col + 1, knight.row)
local guardStartCol = guardian.col
local pushOk = updtr:useAbility(knight, "push_all", nil)
assert(pushOk, "push_all should succeed")
assert(guardian.col == guardStartCol + 1, "guardian should have been pushed one tile east, got col=" .. guardian.col)
print("push_all OK: guardian pushed from col", guardStartCol, "to", guardian.col)

-- ------------------------------------------------------------- GUARD
line("GUARD ABSORBS A PUSH")
updtr:useAbility(guardian, "guard", nil)
assert(guardian.statuses.guarded == 1, "guard should set guarded status")
local guardedColBefore = guardian.col
-- knight is adjacent (guardian moved next to knight above); push again
dplyr:moveTo(knight.id, guardian.col - 1, guardian.row) -- ensure adjacency regardless of prior moves
local pushOk2 = updtr:useAbility(knight, "push_all", nil)
assert(pushOk2, "push_all call itself should still report success even if one target resisted")
assert(guardian.col == guardedColBefore, "guarded pawn should not have moved")
assert(guardian.statuses.guarded == nil, "guard status should be consumed after absorbing the push")
print("guard OK: push absorbed, status consumed")

-- ------------------------------------------------------------- DRAG
line("DRAG ABILITY")
-- line mage up with guardian for a pull test, 2 tiles apart on same row
dplyr:moveTo(mage.id, 4, 4)
dplyr:moveTo(guardian.id, 6, 4)
local dragOk = updtr:useAbility(mage, "drag", guardian)
assert(dragOk, "drag should succeed on a pawn in a clear line within range")
assert(guardian.col == 5 and guardian.row == 4, "guardian should be pulled one tile toward mage, got (" .. guardian.col .. "," .. guardian.row .. ")")
print("drag OK: guardian pulled to", guardian.col, guardian.row)

-- ------------------------------------------------------------- FIRE BEAM
line("FIRE BEAM ABILITY (enemy)")
local turret = enemies[1]
dplyr:moveTo(turret.id, 3, 9)
dplyr:moveTo(knight.id, 10, 9) -- same row, clear line assumed (row 9 in sample level is open along y=9 mostly)
-- clear any pawns between col 3 and col 10 on row 9 for a clean test line
for c = 4, 9 do
    local occ = dplyr:getAt(c, 9)
    if occ and occ.id ~= turret.id and occ.id ~= knight.id then dplyr:remove(occ.id) end
end
updtr.turn = chessUpdtr.TURN.ENEMY -- fire_beam is an enemy ability; simulate enemy phase directly
local hpBefore = knight.hp
local beamOk = updtr:useAbility(turret, "fire_beam", { col = knight.col, row = knight.row })
assert(beamOk, "fire_beam should succeed")
assert(knight.hp == hpBefore - 2, "knight should take 2 damage from the beam, hp=" .. tostring(knight.hp))
print("fire_beam OK: knight hp", hpBefore, "->", knight.hp)
updtr.turn = chessUpdtr.TURN.PC

-- ------------------------------------------------------------- HAZARD TICK
line("HAZARD SINK MECHANIC")
local hazardCol, hazardRow = 14, 10 -- part of the hazard ring in sampleLevel
assert(map:getTile(hazardCol, hazardRow).type == chessMap.TILE.HAZARD, "expected hazard tile there")
-- put a throwaway pawn on the hazard tile
local victim = dplyr:deploy("movable_crate", hazardCol, hazardRow)
local ticks = 0
while map:getTile(hazardCol, hazardRow).type == chessMap.TILE.HAZARD do
    updtr:tickHazards()
    ticks = ticks + 1
    assert(ticks <= 20, "hazard never sank -- infinite loop guard tripped")
end
assert(map:getTile(hazardCol, hazardRow).type == chessMap.TILE.VOID, "hazard tile should become VOID after sinking")
assert(dplyr:getById(victim.id) == nil, "pawn standing on a fully-sunk tile should be removed")
assert(map:isWalkable(hazardCol, hazardRow) == false, "VOID tile should not be walkable")
print("hazard sink OK after", ticks, "ticks -- tile is now VOID, occupant removed")

-- ------------------------------------------------------------- WIN CHECK
line("CLEAR CONDITION")
local capturedClear = false
Runtime:addEventListener("levelCleared", function() capturedClear = true end)
local goal = map:getGoalTiles()[1]
dplyr:moveTo(knight.id, goal.col, goal.row)
updtr:checkClearCondition()
assert(capturedClear, "levelCleared event should have fired once the (only) goal tile is PC-occupied")
print("clear condition OK: levelCleared fired")

-- ------------------------------------------------------------- TURN CYCLE
line("TURN CYCLE / ENEMY AI PHASE")
local turnEvents = {}
Runtime:addEventListener("turnChanged", function(e) table.insert(turnEvents, e) end)
local roundBefore = updtr.roundNumber
updtr:endTurn()
assert(updtr.turn == chessUpdtr.TURN.PC, "turn should return to PC after a full cycle")
assert(updtr.roundNumber == roundBefore + 1, "round number should increment after a full cycle")
assert(#turnEvents == 1 and turnEvents[1].turn == "pc", "turnChanged event should report pc turn")
print("turn cycle OK: round", roundBefore, "->", updtr.roundNumber)

-- ------------------------------------------------------- AUTO ENEMY AI
line("AUTOMATIC ENEMY AI DURING END TURN")
-- line a fresh enemy up with a PC on a clear row, then let endTurn() run
-- the AI phase naturally (this is the exact path real play uses)
dplyr:moveTo(turret.id, 3, 7)
dplyr:moveTo(mage.id, 10, 7)
for c = 4, 9 do
    local occ = dplyr:getAt(c, 7)
    if occ and occ.id ~= turret.id and occ.id ~= mage.id then dplyr:remove(occ.id) end
end
local mageHpBefore = mage.hp
updtr.turn = chessUpdtr.TURN.PC -- ensure we start from PC phase like real play
updtr:endTurn() -- PC -> enemy (AI fires) -> PC
assert(mage.hp < mageHpBefore, "mage should have taken beam damage from the automatic enemy AI phase, hp=" .. tostring(mage.hp))
print("auto enemy AI OK: mage hp", mageHpBefore, "->", mage.hp)

line("ALL SMOKE TESTS PASSED")
