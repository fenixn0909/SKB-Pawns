require("tests.corona_stub")

local chessMap    = require("modules.chessMap")
local pawnDplyr   = require("modules.pawnDplyr")
local abltMng     = require("modules.abltMng")
local traitMng    = require("modules.traitMng")
local chessUpdtr  = require("modules.chessUpdtr")
local pawnCon     = require("modules.pawnCon")
local sampleLevel = require("data.sampleLevel")

local function line(msg) print("---- " .. msg .. " ----") end

abltMng.registerDefaults()
traitMng.registerDefaults()

line("BUILD MAP")
local map = chessMap.new(sampleLevel.rows, { tileSize = 48, tunnels = sampleLevel.tunnels })
print(string.format("cols=%d rows=%d tileSize=%d spawnPCs=%d spawnEnemies=%d goals=%d",
    map.cols, map.rows, map.tileSize, #map.spawnPCs, #map.spawnEnemies, #map:getGoalTiles()))
assert(map.cols == 32 and map.rows == 15, "map dimensions wrong")
assert(#map.spawnPCs == 6 and #map.spawnEnemies == 5, "spawn counts wrong")

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
assert(#pcs == 6, "expected 6 PCs")
assert(#enemies == 5, "expected 5 enemies")
for _, p in ipairs(pcs) do print(string.format("PC #%d %s at (%d,%d) hp=%d", p.id, p.name, p.col, p.row, p.hp)) end
for _, e in ipairs(enemies) do print(string.format("EN #%d %s at (%d,%d) hp=%d", e.id, e.name, e.col, e.row, e.hp)) end

local updtr = chessUpdtr.new(map, dplyr)
local boardHit = display.newRect(0,0,0,0)
local con = pawnCon.new(dplyr, map, updtr, boardHit)
for _, p in pairs(dplyr.pawns) do con:registerSelectable(p) end

local knight, mage, guardian = pcs[1], pcs[2], pcs[3]
local brawler, slinger, scout = pcs[4], pcs[5], pcs[6]
local treant, spitter = enemies[4], enemies[5]

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

-- ------------------------------------------------------- PUSH (MOVING)
line("PUSH (MOVING) -- UNLIMITED CHAIN")
dplyr:moveTo(knight.id, 3, 2) -- row 2 is fully open floor, no interior walls
local s1 = dplyr:deploy("stone_a", 4, 2)
local s2 = dplyr:deploy("stone_b", 5, 2)
local pushOk3 = updtr:requestStep(knight, 1, 0)
assert(pushOk3, "push should succeed shoving a 2-pawn chain with open space beyond")
assert(knight.col == 4 and knight.row == 2, "knight should have stepped into the tile the chain vacated")
assert(s1.col == 5 and s2.col == 6, "both stones should have shifted forward one tile each, got " .. s1.col .. "," .. s2.col)
print("push OK: knight at", knight.col, knight.row, "-- chain now at", s1.col, s2.col)
dplyr:remove(s1.id); dplyr:remove(s2.id)

-- ------------------------------------------------------ PUSH+ (MOVING)
line("PUSH+ (MOVING) -- CAPPED AT 2 PAWNS")
knight.movingAbility = "push_plus"
dplyr:moveTo(knight.id, 3, 6) -- row 6 open cols 2-11, wall at col12
local t1 = dplyr:deploy("stone_a", 4, 6)
local t2 = dplyr:deploy("stone_b", 5, 6)
local t3 = dplyr:deploy("stone_c", 6, 6)
local pushPlusOk = updtr:requestStep(knight, 1, 0)
assert(pushPlusOk == false, "push_plus should refuse a 3-pawn chain -- its cap is 2")
assert(knight.col == 3, "knight should not have moved when the chain was too long")
assert(t1.col == 4 and t2.col == 5 and t3.col == 6, "an over-cap chain should not shift at all")
print("push_plus OK: 3-pawn chain correctly resisted (cap is 2)")

dplyr:remove(t3.id) -- drop to exactly 2 -- now within push_plus's cap
local pushPlusOk2 = updtr:requestStep(knight, 1, 0)
assert(pushPlusOk2, "push_plus should succeed shoving exactly 2 pawns")
assert(knight.col == 4, "knight should have stepped forward")
assert(t1.col == 5 and t2.col == 6, "both stones should shift forward one tile each")
print("push_plus OK: 2-pawn chain succeeded, knight now at", knight.col, knight.row)
dplyr:remove(t1.id); dplyr:remove(t2.id)
knight.movingAbility = "push" -- restore for later tests

-- --------------------------------------------------------- SWAP (MOVING)
line("SWAP (MOVING) -- WALL BLOCKS LINE OF SIGHT, FALLS BACK TO A STEP")
dplyr:moveTo(knight.id, 3, 3) -- park knight elsewhere -- push_plus left it at (4,6), in this test's row
dplyr:moveTo(mage.id, 2, 6) -- row 6 has a wall at col 12
local farStone = dplyr:deploy("stone_a", 15, 6) -- beyond the wall
local swapBlockedOk = updtr:requestStep(mage, 1, 0)
assert(swapBlockedOk, "swap should fall back to a normal step when the line of sight is wall-blocked")
assert(mage.col == 3 and mage.row == 6, "mage should have just stepped one tile, not swapped, got (" .. mage.col .. "," .. mage.row .. ")")
assert(farStone.col == 15, "the far stone beyond the wall should not have moved")
print("swap OK: wall correctly blocked line of sight, fell back to a normal step")
dplyr:remove(farStone.id)

line("SWAP (MOVING) -- UNLIMITED RANGE ON A CLEAR LINE")
dplyr:moveTo(mage.id, 3, 2)
local nearStone = dplyr:deploy("stone_b", 10, 2)
local swapOk2 = updtr:requestStep(mage, 1, 0)
assert(swapOk2, "swap should succeed finding a pawn on a clear line")
assert(mage.col == 10 and mage.row == 2, "mage should have swapped all the way to the stone, got (" .. mage.col .. "," .. mage.row .. ")")
assert(nearStone.col == 3 and nearStone.row == 2, "the stone should now be where mage started")
print("swap OK: swapped across the whole clear row, mage now at", mage.col, mage.row)
dplyr:remove(nearStone.id)

-- -------------------------------------------------------- SWAP+ (MOVING)
line("SWAP+ (MOVING) -- SEES STRAIGHT THROUGH WALLS")
mage.movingAbility = "swap_plus"
dplyr:moveTo(mage.id, 2, 6)
local wallStone = dplyr:deploy("stone_c", 15, 6)
local swapPlusOk = updtr:requestStep(mage, 1, 0)
assert(swapPlusOk, "swap_plus should succeed even with a wall between mage and the target")
assert(mage.col == 15 and mage.row == 6, "mage should have swapped straight through the wall, got (" .. mage.col .. "," .. mage.row .. ")")
assert(wallStone.col == 2 and wallStone.row == 6, "the stone should now be at mage's old position")
print("swap+ OK: swapped straight through a wall, mage now at", mage.col, mage.row)
dplyr:remove(wallStone.id)
mage.movingAbility = "swap_move" -- restore

-- --------------------------------------------------------- PULL (MOVING)
line("PULL (MOVING) -- SINGLE LINK")
dplyr:moveTo(guardian.id, 5, 8) -- row 8 fully open
local behind1 = dplyr:deploy("stone_a", 4, 8)
local pullOk = updtr:requestStep(guardian, 1, 0)
assert(pullOk, "pull should succeed: guardian steps forward normally")
assert(guardian.col == 6 and guardian.row == 8, "guardian should have moved one tile east")
assert(behind1.col == 5 and behind1.row == 8, "the pawn behind should be dragged into guardian's old tile")
print("pull OK: guardian at", guardian.col, guardian.row, "-- dragged pawn now at", behind1.col, behind1.row)
dplyr:remove(behind1.id)

-- -------------------------------------------------------- PULL+ (MOVING)
line("PULL+ (MOVING) -- WHOLE CHAIN SHUFFLES FORWARD")
guardian.movingAbility = "pull_plus"
dplyr:moveTo(guardian.id, 6, 9) -- row 9 open cols 2-13
local link1 = dplyr:deploy("stone_a", 5, 9)
local link2 = dplyr:deploy("stone_b", 4, 9)
local link3 = dplyr:deploy("stone_c", 3, 9)
local pullPlusOk = updtr:requestStep(guardian, 1, 0)
assert(pullPlusOk, "pull_plus should succeed")
assert(guardian.col == 7, "guardian should have moved one tile east")
assert(link1.col == 6, "first link should shuffle into guardian's old tile, got " .. link1.col)
assert(link2.col == 5, "second link should shuffle into the first link's old tile, got " .. link2.col)
assert(link3.col == 4, "third link should shuffle into the second link's old tile, got " .. link3.col)
print("pull+ OK: whole chain shuffled forward -- guardian", guardian.col, "link1", link1.col, "link2", link2.col, "link3", link3.col)
dplyr:remove(link1.id); dplyr:remove(link2.id); dplyr:remove(link3.id)
guardian.movingAbility = "pull" -- restore

-- ------------------------------------------------------- LIGHTWEIGHT TRAIT
line("LIGHTWEIGHT TRAIT -- CARRIED AN EXTRA TILE WHEN PUSHED")
assert(dplyr:hasTrait(mage, "lightweight"), "mage should natively have the lightweight trait")
dplyr:moveTo(knight.id, 3, 2) -- row 2: fully open, unlike row 3 which has sampleLevel's stones
dplyr:moveTo(mage.id, 4, 2) -- directly east of knight, clear floor for 2 tiles beyond
local pushLwOk = updtr:requestStep(knight, 1, 0)
assert(pushLwOk, "push should succeed pushing the lightweight mage")
assert(mage.col == 6 and mage.row == 2, "a lightweight pawn should be carried 2 tiles instead of 1, got (" .. mage.col .. "," .. mage.row .. ")")
assert(knight.col == 4, "knight should have stepped into the tile mage vacated")
print("lightweight OK: mage carried an extra tile to", mage.col, mage.row)

-- ----------------------------------------------------------- STEALTH TRAIT
line("STEALTH TRAIT -- GRANTED/REVOKED AT RUNTIME, SKIPS ENEMY AUTO-TARGETING")
assert(not dplyr:hasTrait(knight, "stealth"), "knight should not have stealth natively")
dplyr:moveTo(turret.id, 3, 4)
dplyr:moveTo(knight.id, 10, 4)
for c = 4, 9 do
    local occ = dplyr:getAt(c, 4)
    if occ and occ.id ~= turret.id and occ.id ~= knight.id then dplyr:remove(occ.id) end
end
local targetBefore = updtr:findBeamTarget(turret)
assert(targetBefore and targetBefore.col == knight.col, "turret should be able to target knight before stealth is granted")
dplyr:addTrait(knight.id, "stealth")
assert(dplyr:hasTrait(knight, "stealth"), "addTrait should grant the trait")
local targetDuring = updtr:findBeamTarget(turret)
assert(targetDuring == nil, "a stealthed PC should be invisible to automatic enemy targeting")
dplyr:removeTrait(knight.id, "stealth")
assert(not dplyr:hasTrait(knight, "stealth"), "removeTrait should revoke the trait")
local targetAfter = updtr:findBeamTarget(turret)
assert(targetAfter and targetAfter.col == knight.col, "turret should be able to target knight again once stealth is revoked")
print("stealth OK: enemy targeting correctly skipped knight while stealthed, and re-acquired it after")

-- --------------------------------------------------------------- HISTORY
line("HISTORY -- SNAPSHOT / UNDO / REDO / RESTART")
local historyMng = require("modules.historyMng")
local history = historyMng.new(map, dplyr, updtr)
history.onPawnRecreated = function(pawn) con:registerSelectable(pawn) end

dplyr:moveTo(knight.id, 3, 12) -- row 12 open cols 2-6, wall at col 7
local baselineCol = knight.col
history:snapshot() -- "step 1" -- this test's baseline

assert(updtr:requestStep(knight, 1, 0), "setup step 1->2 should succeed")
history:snapshot() -- "step 2"
assert(knight.col == baselineCol + 1)

assert(updtr:requestStep(knight, 1, 0), "setup step 2->3 should succeed")
history:snapshot() -- "step 3"
assert(knight.col == baselineCol + 2)

assert(history:undo(), "undo should succeed")
local k1 = dplyr:getById(knight.id) -- history rebuilds pawns -- always re-fetch after undo/redo/restart
assert(k1.col == baselineCol + 1, "undo should restore the step-2 position, got " .. k1.col)
print("undo OK: knight back at col", k1.col)

assert(history:undo(), "second undo should succeed")
local k2 = dplyr:getById(knight.id)
assert(k2.col == baselineCol, "second undo should restore this test's baseline, got " .. k2.col)
print("undo OK (again): knight back at col", k2.col)

assert(history:undo() == false, "undo past the oldest snapshot should fail gracefully")
print("undo correctly refused past the oldest snapshot")

assert(history:redo(), "redo should succeed")
local k3 = dplyr:getById(knight.id)
assert(k3.col == baselineCol + 1, "redo should restore the step-2 position, got " .. k3.col)
print("redo OK: knight forward to col", k3.col)

-- branching: a new action after undoing should discard the old "future"
assert(updtr:requestStep(k3, 0, 1), "branch move should succeed") -- row 13, col unchanged, is open floor
history:snapshot()
assert(history:redo() == false, "redo should be unavailable -- the old future was discarded by the new branch")
print("branch correctly discarded the old redo future")

assert(history:restart(), "restart should succeed")
local k4 = dplyr:getById(knight.id)
assert(k4.col == baselineCol and k4.row == 12, "restart should return to this test's very first snapshot, got (" .. k4.col .. "," .. k4.row .. ")")
print("restart OK: knight back at (" .. k4.col .. "," .. k4.row .. ")")

line("HISTORY -- A REMOVED PAWN REAPPEARS ON UNDO")
local victim = dplyr:deploy("stone_a", 9, 13)
local victimId = victim.id
history:snapshot() -- "alive" checkpoint
dplyr:remove(victimId)
history:snapshot() -- "removed" checkpoint
assert(dplyr:getById(victimId) == nil, "sanity check: stone should be gone right now")
assert(history:undo(), "undo should succeed")
local revived = dplyr:getById(victimId)
assert(revived ~= nil, "the removed pawn should have reappeared after undo")
assert(revived.col == 9 and revived.row == 13, "revived pawn should be back at its pre-removal position")
print("history OK: removed pawn correctly reappeared at (" .. revived.col .. "," .. revived.row .. ") after undo")

-- history's undo/redo/restart tears down and rebuilds every pawn (same
-- ids, fresh tables) -- refresh every local reference before continuing,
-- or their fields would just be frozen snapshots of the pre-restart pawns.
knight = dplyr:getById(knight.id)
mage = dplyr:getById(mage.id)
guardian = dplyr:getById(guardian.id)
brawler = dplyr:getById(brawler.id)
slinger = dplyr:getById(slinger.id)
scout = dplyr:getById(scout.id)
treant = dplyr:getById(treant.id)
spitter = dplyr:getById(spitter.id)

-- ------------------------------------------------------- TREANT SLAM
line("TREANT SLAM (melee8) -- HITS ALL 8 NEIGHBORS, ARMOR/PROTECTED/PARRY IMMUNE")
dplyr:moveTo(treant.id, 5, 8) -- row 8 fully open, away from the mechanism/hazard tiles
for _, d in ipairs({ {-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1} }) do
    local occ = dplyr:getAt(5 + d[1], 8 + d[2])
    if occ and occ.id ~= treant.id then dplyr:remove(occ.id) end
end
dplyr:moveTo(knight.id, 4, 7)    -- NW: no immunity
dplyr:moveTo(mage.id, 5, 7)      -- N: armor
dplyr:moveTo(guardian.id, 6, 7)  -- NE: protected
dplyr:moveTo(brawler.id, 4, 8)   -- W: parry
dplyr:addTrait(mage.id, "armor")
dplyr:addTrait(guardian.id, "protected")
dplyr:addTrait(brawler.id, "parry")

local knightHp5, mageHp5, guardianHp5, brawlerHp5 = knight.hp, mage.hp, guardian.hp, brawler.hp
updtr.turn = chessUpdtr.TURN.ENEMY -- treant_slam is an enemy ability; simulate enemy phase directly
local slamOk = updtr:useAbility(treant, "treant_slam", nil)
assert(slamOk, "treant_slam should execute")
assert(knight.hp == knightHp5 - 2, "unarmored knight should take slam damage")
assert(mage.hp == mageHp5, "armored mage should be immune to the slam")
assert(guardian.hp == guardianHp5, "protected guardian should be immune to the slam")
assert(brawler.hp == brawlerHp5, "parrying brawler should be immune to the slam")
print("treant_slam OK: knight hp", knightHp5, "->", knight.hp, "-- armor/protected/parry all held")
updtr.turn = chessUpdtr.TURN.PC
dplyr:removeTrait(mage.id, "armor")
dplyr:removeTrait(guardian.id, "protected")
dplyr:removeTrait(brawler.id, "parry")

-- -------------------------------------------------------- ACID SPIT
line("ACID SPIT (beam_first) -- STOPS AT FIRST PAWN; PARRY DOES NOT HELP")
dplyr:moveTo(spitter.id, 2, 8)
dplyr:moveTo(brawler.id, 5, 8)
dplyr:addTrait(brawler.id, "parry")
dplyr:moveTo(slinger.id, 8, 8)

local brawlerHp6, slingerHp6 = brawler.hp, slinger.hp
updtr.turn = chessUpdtr.TURN.ENEMY -- acid_spit is an enemy ability; simulate enemy phase directly
assert(updtr:useAbility(spitter, "acid_spit", { col = brawler.col, row = brawler.row }), "acid_spit should execute")
assert(brawler.hp == brawlerHp6 - 2, "parry should NOT protect against acid_spit (only Armor/Protected do)")
assert(slinger.hp == slingerHp6, "acid_spit should stop at the first pawn, not pierce through to the second")
print("acid_spit OK: brawler (parry only) hp", brawlerHp6, "->", brawler.hp, "-- slinger behind untouched")
dplyr:removeTrait(brawler.id, "parry")

line("ACID SPIT -- ARMOR/PROTECTED ARE IMMUNE, AND THE SHOT STILL STOPS THERE")
dplyr:addTrait(brawler.id, "armor")
local brawlerHp7, slingerHp7 = brawler.hp, slinger.hp
updtr:useAbility(spitter, "acid_spit", { col = brawler.col, row = brawler.row })
assert(brawler.hp == brawlerHp7, "armor SHOULD protect against acid_spit")
assert(slinger.hp == slingerHp7, "the shot should still stop at the armored pawn, not pierce through")
print("acid_spit OK: armored brawler took no damage; shot didn't pierce through to slinger")
dplyr:removeTrait(brawler.id, "armor")
updtr.turn = chessUpdtr.TURN.PC

-- -------------------------------------------- GENERALIZED ENEMY AI DISPATCH
line("GENERALIZED ENEMY AI -- TREANT/SPITTER FIRE AUTOMATICALLY EACH ENEMY TURN")
-- heal knight/mage first -- they've accumulated damage from earlier tests
-- and this test's hit would otherwise kill (and remove) them, breaking
-- every later test that still expects to find them alive
knight.hp = knight.maxHp
if knight.hpText then knight.hpText.text = tostring(knight.hp) end
mage.hp = mage.maxHp
if mage.hpText then mage.hpText.text = tostring(mage.hp) end
dplyr:moveTo(treant.id, 5, 8)
dplyr:moveTo(knight.id, 6, 8)
dplyr:moveTo(spitter.id, 2, 3)
for c = 3, 8 do
    local occ = dplyr:getAt(c, 3)
    if occ and occ.id ~= spitter.id then dplyr:remove(occ.id) end
end
dplyr:moveTo(mage.id, 9, 3)

local knightHp8, mageHp8 = knight.hp, mage.hp
updtr.turn = chessUpdtr.TURN.PC
updtr:endTurn()
assert(knight.hp < knightHp8, "treant should have auto-hit knight during the enemy phase")
assert(mage.hp < mageHp8, "spitter should have auto-hit mage during the enemy phase")
print("generalized AI OK: knight hp", knightHp8, "->", knight.hp, "-- mage hp", mageHp8, "->", mage.hp)
dplyr:moveTo(treant.id, 30, 11) -- park back near its spawn -- the Throw tests below reuse row 8
dplyr:moveTo(knight.id, 3, 12)

-- --------------------------------------------------------- KICK (MOVING)
line("KICK (MOVING) -- SLIDES UNTIL BLOCKED, FACING NEVER CHANGES")
dplyr:moveTo(brawler.id, 3, 2)
local kickTarget = dplyr:deploy("stone_a", 5, 2)
local kickBlocker = dplyr:deploy("stone_b", 10, 2)
local kickFacingBefore = { kickTarget.facing[1], kickTarget.facing[2] }
local kickOk = updtr:requestStep(brawler, 1, 0)
assert(kickOk, "kick should succeed: brawler steps forward normally")
assert(brawler.col == 4 and brawler.row == 2, "brawler should have moved one tile east")
assert(kickTarget.col == 9 and kickTarget.row == 2, "kicked stone should slide until just before the blocker, got " .. kickTarget.col)
assert(kickTarget.facing[1] == kickFacingBefore[1] and kickTarget.facing[2] == kickFacingBefore[2],
    "a kicked pawn's own facing should never change")
print("kick OK: brawler at", brawler.col, brawler.row, "-- kicked stone slid to", kickTarget.col)
dplyr:remove(kickTarget.id); dplyr:remove(kickBlocker.id)

-- -------------------------------------------------------- KICK+ (MOVING)
line("KICK+ (MOVING) -- KICKS EVERY LINED-UP PAWN, FARTHEST FIRST")
brawler.movingAbility = "kick_plus"
dplyr:moveTo(brawler.id, 3, 2)
local k1 = dplyr:deploy("stone_a", 5, 2)
local k2 = dplyr:deploy("stone_b", 6, 2)
local k3 = dplyr:deploy("stone_c", 7, 2)
local kickBlocker2 = dplyr:deploy("stone_a", 12, 2)
local kickPlusOk = updtr:requestStep(brawler, 1, 0)
assert(kickPlusOk, "kick_plus should succeed")
assert(brawler.col == 4, "brawler should have moved one tile east")
assert(k3.col == 11, "farthest pawn (kicked first, most room) should end up farthest, got " .. k3.col)
assert(k2.col == 10, "middle pawn should end up just behind it, got " .. k2.col)
assert(k1.col == 9, "nearest pawn should end up just behind that, got " .. k1.col)
print("kick_plus OK: chain resolved to", k1.col, k2.col, k3.col)
dplyr:remove(k1.id); dplyr:remove(k2.id); dplyr:remove(k3.id); dplyr:remove(kickBlocker2.id)
brawler.movingAbility = "kick" -- restore

-- ---------------------------------------------------------- THROW (MOVING)
line("THROW (MOVING) -- LANDS 2 TILES AWAY ON AN EMPTY TILE")
dplyr:moveTo(slinger.id, 3, 4)
local throwTarget = dplyr:deploy("stone_a", 5, 4)
local throwOk = updtr:requestStep(slinger, 1, 0)
assert(throwOk, "throw should succeed: slinger steps forward normally")
assert(slinger.col == 4 and slinger.row == 4, "slinger should have moved one tile east")
assert(throwTarget.col == 7 and throwTarget.row == 4, "thrown stone should land 2 tiles from its start, got " .. throwTarget.col)
print("throw OK: slinger at", slinger.col, slinger.row, "-- thrown stone landed at", throwTarget.col)
dplyr:remove(throwTarget.id)

line("THROW -- JUMPS CLEAN OVER A PAWN ON THE 1ST GRID (IGNORED, NOT A WALL)")
dplyr:moveTo(slinger.id, 2, 8)
local throwTarget2 = dplyr:deploy("stone_a", 4, 8)
local overPawn = dplyr:deploy("stone_b", 5, 8)
local throwOk2 = updtr:requestStep(slinger, 1, 0)
assert(throwOk2, "throw should succeed")
assert(throwTarget2.col == 6 and throwTarget2.row == 8, "thrown stone should land on the 2nd grid, jumping clean over the 1st, got " .. throwTarget2.col)
assert(overPawn.col == 5, "the pawn jumped over should not have moved")
print("throw OK: jumped clean over a pawn, landed at", throwTarget2.col)
dplyr:remove(throwTarget2.id); dplyr:remove(overPawn.id)

line("THROW -- BLOCKED BY A WALL (THE STEP STILL SUCCEEDS, THE THROW DOESN'T)")
dplyr:moveTo(slinger.id, 9, 6) -- row 6 has a wall at col 12
local throwTarget3 = dplyr:deploy("stone_a", 11, 6)
local throwWallOk = updtr:requestStep(slinger, 1, 0)
assert(throwWallOk, "the move itself should still succeed even though the throw is wall-blocked")
assert(slinger.col == 10 and slinger.row == 6, "slinger should have moved one tile east")
assert(throwTarget3.col == 11 and throwTarget3.row == 6, "the stone should NOT have been thrown -- a wall blocks the jump")
print("throw OK: wall correctly blocked the jump, stone stayed at", throwTarget3.col)
dplyr:remove(throwTarget3.id)

-- ------------------------------------------- JUMP-LANDING RESOLUTION TABLE
line("JUMP LANDING -- CASE A: ARMORED JUMPER CRUSHES THE BED PAWN")
dplyr:moveTo(slinger.id, 2, 8)
local jmpA = dplyr:deploy("stone_a", 4, 8)
dplyr:addTrait(jmpA.id, "armor")
local bedA = dplyr:deploy("stone_b", 6, 8)
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
assert(dplyr:getById(bedA.id) == nil, "bed pawn should have died (case a: armored jumper crushes it)")
local jmpAAfter = dplyr:getById(jmpA.id)
assert(jmpAAfter and jmpAAfter.col == 6 and jmpAAfter.row == 8, "armored jumper should land safely on the now-empty tile")
print("jump-landing OK (case a): armored jumper crushed the bed pawn, landed at", jmpAAfter.col)
dplyr:remove(jmpA.id)

line("JUMP LANDING -- CASE B: SPIKE-HEADED BED PAWN IMPALES THE JUMPER")
dplyr:moveTo(slinger.id, 2, 8)
local jmpB = dplyr:deploy("stone_a", 4, 8)
local bedB = dplyr:deploy("stone_b", 6, 8)
dplyr:addTrait(bedB.id, "spike_headed")
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
assert(dplyr:getById(jmpB.id) == nil, "jumper should have died (case b: impaled on the spike-headed bed pawn)")
local bedBAfter = dplyr:getById(bedB.id)
assert(bedBAfter and bedBAfter.col == 6 and bedBAfter.row == 8, "spike-headed bed pawn should be unharmed and still in place")
print("jump-landing OK (case b): jumper impaled itself on the spike-headed bed pawn")
dplyr:remove(bedB.id)

line("JUMP LANDING -- CASE C: NEITHER SIDE PROTECTED -- BOTH DIE")
dplyr:moveTo(slinger.id, 2, 8)
local jmpC = dplyr:deploy("stone_a", 4, 8)
local bedC = dplyr:deploy("stone_b", 6, 8)
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
assert(dplyr:getById(jmpC.id) == nil, "jumper should have died (case c: mutual destruction)")
assert(dplyr:getById(bedC.id) == nil, "bed pawn should have died too (case c: mutual destruction)")
print("jump-landing OK (case c): both jumper and bed pawn died")

line("JUMP LANDING -- CASE D: LIGHTWEIGHT JUMPER TAPS AND BOUNCES ONWARD")
dplyr:moveTo(slinger.id, 2, 8)
local jmpD = dplyr:deploy("stone_a", 4, 8)
dplyr:addTrait(jmpD.id, "lightweight")
local bedD = dplyr:deploy("stone_b", 6, 8)
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
local bedDAfter = dplyr:getById(bedD.id)
assert(bedDAfter and bedDAfter.col == 6, "tapped bed pawn should survive and stay in place")
local jmpDAfter = dplyr:getById(jmpD.id)
assert(jmpDAfter and jmpDAfter.col == 7 and jmpDAfter.row == 8, "lightweight jumper should bounce onward to the next empty tile")
print("jump-landing OK (case d): lightweight jumper tapped the bed pawn, bounced onward to", jmpDAfter.col)
dplyr:remove(jmpD.id); dplyr:remove(bedD.id)

line("JUMP LANDING -- CASE D CHAINS THROUGH MULTIPLE BED PAWNS")
dplyr:moveTo(slinger.id, 2, 8)
local jmpD2 = dplyr:deploy("stone_a", 4, 8)
dplyr:addTrait(jmpD2.id, "lightweight")
local bedD2a = dplyr:deploy("stone_b", 6, 8)
local bedD2b = dplyr:deploy("stone_c", 7, 8)
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
assert(dplyr:getById(bedD2a.id), "1st tapped bed pawn should survive")
assert(dplyr:getById(bedD2b.id), "2nd tapped bed pawn should survive")
local jmpD2After = dplyr:getById(jmpD2.id)
assert(jmpD2After and jmpD2After.col == 8 and jmpD2After.row == 8, "lightweight jumper should chain-bounce past both, landing at col 8")
print("jump-landing OK: chained through 2 bed pawns, landed at", jmpD2After.col)
dplyr:remove(jmpD2.id); dplyr:remove(bedD2a.id); dplyr:remove(bedD2b.id)

line("JUMP LANDING -- CASE D DIES IF IT BOUNCES INTO A WALL")
dplyr:moveTo(slinger.id, 7, 6) -- row 6 has a wall at col 12
local jmpD3 = dplyr:deploy("stone_a", 9, 6)
dplyr:addTrait(jmpD3.id, "lightweight")
local bedD3 = dplyr:deploy("stone_b", 11, 6)
assert(updtr:requestStep(slinger, 1, 0), "the throw ability's own move should still succeed")
assert(dplyr:getById(jmpD3.id) == nil, "lightweight jumper should die bouncing into a wall")
assert(dplyr:getById(bedD3.id), "the tapped bed pawn should survive")
print("jump-landing OK: lightweight jumper died bouncing into a wall; tapped bed pawn survived")
dplyr:remove(bedD3.id)

-- ---------------------------------------- TUNNEL / JAIL BARS / WALL HOLE
line("TUNNEL -- TINY SIZE PAWN TELEPORTS TO THE PAIRED EXIT; OTHERS ARE BLOCKED")
assert(dplyr:hasTrait(scout, "tiny_size"), "scout should natively have the tiny_size trait")
dplyr:moveTo(scout.id, 22, 6)
local tunnelOk = updtr:requestStep(scout, 1, 0)
assert(tunnelOk, "scout should be able to step onto the tunnel tile")
assert(scout.col == 27 and scout.row == 8, "scout should have teleported to the paired tunnel exit, got (" .. scout.col .. "," .. scout.row .. ")")
print("tunnel OK: scout teleported to (" .. scout.col .. "," .. scout.row .. ")")

dplyr:moveTo(knight.id, 22, 6)
local tunnelBlockedOk = updtr:requestStep(knight, 1, 0)
assert(tunnelBlockedOk == false, "a non-Tiny pawn should be blocked by a tunnel tile, same as a wall")
print("tunnel OK: non-tiny knight correctly blocked")

line("JAIL BARS -- TINY SIZE PASSES, OTHERS BLOCKED")
dplyr:moveTo(scout.id, 24, 8)
local jailOk = updtr:requestStep(scout, 1, 0)
assert(jailOk, "scout should be able to step through jail bars")
assert(scout.col == 25 and scout.row == 8, "scout should now be standing on the jail bars tile")
print("jail bars OK: scout passed through to (" .. scout.col .. "," .. scout.row .. ")")

dplyr:moveTo(knight.id, 24, 8)
local jailBlockedOk = updtr:requestStep(knight, 1, 0)
assert(jailBlockedOk == false, "a non-Tiny pawn should be blocked by jail bars, same as a wall")
print("jail bars OK: non-tiny knight correctly blocked")

line("WALL HOLE -- TINY SIZE PASSES, OTHERS BLOCKED")
dplyr:moveTo(scout.id, 28, 8)
local holeOk = updtr:requestStep(scout, 1, 0)
assert(holeOk, "scout should be able to pass through the wall's tiny hole")
assert(scout.col == 29 and scout.row == 8, "scout should now be standing on the wall-hole tile")
print("wall hole OK: scout passed through to (" .. scout.col .. "," .. scout.row .. ")")

dplyr:moveTo(knight.id, 28, 8)
local holeBlockedOk = updtr:requestStep(knight, 1, 0)
assert(holeBlockedOk == false, "a non-Tiny pawn should be blocked by a wall hole, same as a wall")
print("wall hole OK: non-tiny knight correctly blocked")

line("ALL SMOKE TESTS PASSED")
