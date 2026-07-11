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

line("ABILITY TRIGGER CLASSIFICATION")
for _, id in ipairs({ "fire_beam", "treant_slam", "acid_spit" }) do
    assert(abltMng.get(id).trigger == abltMng.TRIGGER.ATTACK,
        id .. " should be an ATTACK-trigger ability (shown as 'Attack' on the sidebar, not 'Active')")
end
for _, id in ipairs({ "push_all", "swap", "drag", "guard" }) do
    assert(abltMng.get(id).trigger == abltMng.TRIGGER.ACTIVE, id .. " should still be a player-armed ACTIVE ability")
end
print("trigger classification OK: hostile auto-attacks are ATTACK, PC-armed abilities are still ACTIVE")

line("BUILD MAP")
local map = chessMap.new(sampleLevel.rows, { tileSize = 48, tunnels = sampleLevel.tunnels, cages = sampleLevel.cages })
print(string.format("cols=%d rows=%d tileSize=%d spawnPCs=%d spawnEnemies=%d goals=%d",
    map.cols, map.rows, map.tileSize, #map.spawnPCs, #map.spawnEnemies, #map:getGoalTiles()))
assert(map.cols == 32 and map.rows == 15, "map dimensions wrong")
assert(#map.spawnPCs == 8 and #map.spawnEnemies == 5, "spawn counts wrong")

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
-- Knight's movingAbility is "push" (MOVING trigger), so requestMove/
-- requestStep don't do a plain move -- a push-fallback step happens when
-- the target tile's empty, but a pawn there gets shoved. Testing baseline
-- movement semantics from Knight's native spawn (4,2) would silently push
-- Mage (at the adjacent spawn (5,2)) out of position. Park Knight on open
-- scratch floor first so these moves land on empty tiles as intended.
dplyr:moveTo(knight.id, 13, 8)
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
-- (cols 14/16 -- clear of any spawn tile or extra furniture on row 4)
dplyr:moveTo(mage.id, 14, 4)
dplyr:moveTo(guardian.id, 16, 4)
local dragOk = updtr:useAbility(mage, "drag", guardian)
assert(dragOk, "drag should succeed on a pawn in a clear line within range")
assert(guardian.col == 15 and guardian.row == 4, "guardian should be pulled one tile toward mage, got (" .. guardian.col .. "," .. guardian.row .. ")")
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
local goals = map:getGoalTiles()
assert(#goals == 3, "expected 3 goal tiles, got " .. #goals)
dplyr:moveTo(knight.id, goals[1].col, goals[1].row)
updtr:checkClearCondition()
assert(not capturedClear, "levelCleared should NOT fire with only 1 of 3 goals held")
dplyr:moveTo(mage.id, goals[2].col, goals[2].row)
updtr:checkClearCondition()
assert(not capturedClear, "levelCleared should NOT fire with only 2 of 3 goals held")
dplyr:moveTo(guardian.id, goals[3].col, goals[3].row)
updtr:checkClearCondition()
assert(capturedClear, "levelCleared event should have fired once all 3 goal tiles are PC-occupied")
print("clear condition OK: levelCleared fired once all 3 goals were held")

-- ------------------------------------------------------------ CAGE GATES
line("CAGE MECHANISM -- BUTTON OPENS ITS PAIRED CAGE, CLOSES WHEN VACATED")
assert(map:getTile(17, 13).type == "cage", "cage_a should start closed")
assert(not map:isWalkable(17, 13), "a closed cage should block movement")
dplyr:moveTo(knight.id, 16, 13) -- onto cage_a's button
updtr:checkClearCondition() -- cages are ticked as part of this -- see chessUpdtr:tickCages
assert(map:getTile(17, 13).type == "cage_open", "cage_a should open once a pawn stands on its button")
assert(map:isWalkable(17, 13), "an open cage should be walkable")
dplyr:moveTo(knight.id, 10, 13) -- step off the button
updtr:checkClearCondition()
assert(map:getTile(17, 13).type == "cage", "cage_a should close again once its button is vacated")
assert(not map:isWalkable(17, 13), "a closed cage should block movement again")

assert(map:getTile(25, 14).type == "cage", "cage_b should start closed")
dplyr:moveTo(mage.id, 24, 14) -- onto cage_b's button
updtr:checkClearCondition()
assert(map:getTile(25, 14).type == "cage_open", "cage_b should open independently of cage_a")
assert(map:getTile(17, 13).type == "cage", "cage_a should still be closed -- the two sets are independent")
dplyr:moveTo(mage.id, 22, 14) -- step off the button
updtr:checkClearCondition()
assert(map:getTile(25, 14).type == "cage", "cage_b should close again once its button is vacated")
print("cage OK: both gates open on their own button and close independently when vacated")

line("CAGE MECHANISM -- A CLOSED CAGE ACTUALLY BLOCKS A PAWN'S MOVE, NOT JUST isWalkable")
assert(map:getTile(17, 13).type == "cage", "cage_a should be closed again (button was vacated above)")
dplyr:moveTo(knight.id, 18, 13) -- just east of the closed cage tile
local trappedOk = updtr:requestStep(knight, -1, 0) -- try to step west, into the closed cage
assert(not trappedOk, "a pawn should be refused entry into a closed cage tile")
assert(knight.col == 18 and knight.row == 13, "knight should not have moved -- still trapped on this side")
dplyr:moveTo(mage.id, 16, 13) -- stand on cage_a's button to open it
updtr:checkClearCondition()
assert(map:getTile(17, 13).type == "cage_open", "cage_a should be open now")
local freedOk = updtr:requestStep(knight, -1, 0)
assert(freedOk, "once the cage is open, the same step should succeed")
assert(knight.col == 17 and knight.row == 13, "knight should have moved onto the now-open cage tile")
print("cage OK: closed cage refused the step; opening it let the identical step through")
dplyr:moveTo(mage.id, 10, 13) -- off the button again, so it doesn't interfere with later tests
updtr:checkClearCondition()

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
-- row 4 has Slinger's spawn at col 3 and Scout's at col 6 -- both still
-- unmoved this early in the file. Start turret at col 2 (west of Slinger)
-- and relocate Scout out of the test lane first so it survives (removing
-- it outright would break the tunnel tests that need it later).
dplyr:moveTo(scout.id, 17, 4)
dplyr:moveTo(slinger.id, 18, 4)
dplyr:moveTo(turret.id, 2, 4)
dplyr:moveTo(knight.id, 10, 4)
for c = 3, 9 do
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
line("TREANT SLAM (melee4) -- HITS ANY LIVING PAWN IN THE 4 CARDINAL TILES, EITHER FACTION")
local brute = dplyr:getById(enemies[3].id) -- enemies[] wasn't refreshed after HISTORY like the named locals above -- re-fetch directly
dplyr:moveTo(treant.id, 5, 8) -- row 8 fully open, away from the mechanism/hazard tiles
for _, d in ipairs({ {-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1} }) do
    local occ = dplyr:getAt(5 + d[1], 8 + d[2])
    if occ and occ.id ~= treant.id then dplyr:remove(occ.id) end
end
dplyr:moveTo(mage.id, 5, 7)     -- N: armor
dplyr:moveTo(guardian.id, 5, 9) -- S: protected
dplyr:moveTo(brawler.id, 4, 8)  -- W: parry
dplyr:moveTo(brute.id, 6, 8)    -- E: an ENEMY, no immunity -- proves the slam is faction-agnostic
dplyr:moveTo(knight.id, 4, 7)   -- NW (diagonal): no immunity, but diagonals no longer count
dplyr:addTrait(mage.id, "armor")
dplyr:addTrait(guardian.id, "protected")
dplyr:addTrait(brawler.id, "parry")

local mageHp5, guardianHp5, brawlerHp5, bruteHp5, knightHp5 = mage.hp, guardian.hp, brawler.hp, brute.hp, knight.hp
updtr.turn = chessUpdtr.TURN.ENEMY -- treant_slam is an enemy ability; simulate enemy phase directly
local slamOk = updtr:useAbility(treant, "treant_slam", nil)
assert(slamOk, "treant_slam should execute")
assert(mage.hp == mageHp5, "armored mage should be immune to the slam")
assert(guardian.hp == guardianHp5, "protected guardian should be immune to the slam")
assert(brawler.hp == brawlerHp5, "parrying brawler should be immune to the slam")
assert(brute.hp == bruteHp5 - 2, "an unarmored ENEMY adjacent to the treant should also take damage -- the slam doesn't care about faction")
assert(knight.hp == knightHp5, "a pawn only diagonally adjacent should NOT be hit -- melee4 is cardinal-only, no diagonals")
print("treant_slam OK: N/S/W all immune as expected, E (an enemy) took", bruteHp5 - brute.hp, "damage, diagonal NW untouched")
dplyr:moveTo(brute.id, 18, 10) -- back near its own spawn -- (6,8) is reused by later tests
updtr.turn = chessUpdtr.TURN.PC
dplyr:removeTrait(mage.id, "armor")
dplyr:removeTrait(guardian.id, "protected")
dplyr:removeTrait(brawler.id, "parry")

line("TREANT SLAM -- THREE TREANTS IN A LINE ALL DAMAGE EACH OTHER")
local treant2 = dplyr:deploy("enemy_treant", 12, 8)
local treant3 = dplyr:deploy("enemy_treant", 13, 8)
dplyr:moveTo(treant.id, 11, 8)
local t1Hp, t2Hp, t3Hp = treant.hp, treant2.hp, treant3.hp
updtr.turn = chessUpdtr.TURN.ENEMY -- treant_slam is an enemy ability; simulate enemy phase directly
for _, t in ipairs({ treant, treant2, treant3 }) do
    updtr:useAbility(t, "treant_slam", nil)
end
assert(treant.hp == t1Hp - 2, "end treant should take one hit from its only neighbor")
assert(treant3.hp == t3Hp - 2, "the other end treant should also take one hit")
assert(treant2.hp == t2Hp - 4, "the middle treant has neighbors on both sides -- should take two hits")
print("treant_slam OK: line of 3 treants all damaged each other, middle one took", t2Hp - treant2.hp)
dplyr:remove(treant2.id); dplyr:remove(treant3.id)
updtr.turn = chessUpdtr.TURN.PC

line("TREANT SLAM -- A CLOSED CAGE BLOCKS THE SLAM (A CAGED HOSTILE CAN'T ATTACK THROUGH IT)")
knight.hp = knight.maxHp -- heal first -- accumulated damage from earlier tests could otherwise let this test's hit kill (and remove) it
if knight.hpText then knight.hpText.text = tostring(knight.hp) end
dplyr:moveTo(treant.id, 15, 8)
dplyr:moveTo(knight.id, 17, 8) -- 2 tiles east -- an ad-hoc closed cage sits between them at (16,8)
local originalTileType = map.tiles[8][16].type
map.tiles[8][16].type = "cage" -- not tied to any button group -- just testing that ANY closed cage blocks
map:refreshTile(16, 8)
local cagedHpBefore = knight.hp
updtr.turn = chessUpdtr.TURN.ENEMY
updtr:useAbility(treant, "treant_slam", nil)
assert(knight.hp == cagedHpBefore, "a pawn on the far side of a closed cage isn't adjacent -- the slam shouldn't reach it")
map.tiles[8][16].type = originalTileType -- open it back up and move the PC to genuinely adjacent
map:refreshTile(16, 8)
dplyr:moveTo(knight.id, 16, 8)
local cagedHpBefore2 = knight.hp
updtr:useAbility(treant, "treant_slam", nil)
assert(knight.hp == cagedHpBefore2 - 2, "once actually adjacent (cage out of the way), the identical slam connects")
print("treant_slam OK: a closed cage blocked the attack; removing it let the same attack connect")
knight.hp = knight.maxHp -- heal back -- knight accumulates damage across this whole file and later tests need it alive
if knight.hpText then knight.hpText.text = tostring(knight.hp) end
updtr.turn = chessUpdtr.TURN.PC

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

line("ACID SPIT -- CAN'T SEE THROUGH A NON-LIVING PAWN (STONE/CRATE)")
slinger.hp = slinger.maxHp -- heal first -- accumulated damage from earlier tests could otherwise let this test's hit kill (and remove) it
if slinger.hpText then slinger.hpText.text = tostring(slinger.hp) end
dplyr:moveTo(guardian.id, 22, 9) -- clear out of row 9 -- it was left at (5,9) by the earlier treant test
dplyr:moveTo(spitter.id, 2, 9)
dplyr:moveTo(slinger.id, 8, 9) -- would be a clear shot if nothing were in the way
local blockerStone = dplyr:deploy("stone_a", 5, 9) -- a non-living pawn directly in the line
local slingerHp8 = slinger.hp
updtr.turn = chessUpdtr.TURN.ENEMY
assert(updtr:findBeamTarget(spitter) == nil,
    "a stone blocking the line means there's no valid target -- findBeamTarget should see nobody")
updtr:runEnemyPhase() -- the automatic dispatch path should agree and do nothing
assert(slinger.hp == slingerHp8, "the stone should have blocked the shot entirely -- slinger untouched")
dplyr:remove(blockerStone.id)
local firedAt = updtr:findBeamTarget(spitter)
assert(firedAt and firedAt.col == slinger.col and firedAt.row == slinger.row,
    "with the stone gone, the same line should be clear again")
updtr:runEnemyPhase()
assert(slinger.hp == slingerHp8 - 2, "with the line clear, the spitter should auto-fire and hit slinger")
print("acid_spit OK: a stone fully blocked the shot; removing it let the spitter see and fire again")
slinger.hp = slinger.maxHp -- heal back -- slinger accumulates damage across this file and later Throw tests need it alive
if slinger.hpText then slinger.hpText.text = tostring(slinger.hp) end
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

-- --------------------------------------------------------- KICK (FACING)
line("KICK (FACING) -- TRIGGERS ON AN ADJACENT PAWN WITHOUT MOVING, SLIDES UNTIL BLOCKED")
dplyr:moveTo(brawler.id, 4, 2)
local kickTarget = dplyr:deploy("stone_a", 5, 2)
local kickBlocker = dplyr:deploy("stone_b", 10, 2)
local kickFacingBefore = { kickTarget.facing[1], kickTarget.facing[2] }
local kickOk = updtr:requestStep(brawler, 1, 0)
assert(kickOk, "kick should succeed: adjacent pawn triggers the kick")
assert(brawler.col == 4 and brawler.row == 2, "brawler should NOT move -- facing-trigger fires in place")
assert(kickTarget.col == 9 and kickTarget.row == 2, "kicked stone should slide until just before the blocker, got " .. kickTarget.col)
assert(kickTarget.facing[1] == kickFacingBefore[1] and kickTarget.facing[2] == kickFacingBefore[2],
    "a kicked pawn's own facing should never change")
print("kick OK: brawler stayed at", brawler.col, brawler.row, "-- kicked stone slid to", kickTarget.col)
dplyr:remove(kickTarget.id); dplyr:remove(kickBlocker.id)

line("KICK (FACING) -- FALLS BACK TO A NORMAL STEP WHEN NOTHING'S ADJACENT")
local kickStepOk = updtr:requestStep(brawler, 1, 0)
assert(kickStepOk, "kick should fall back to a normal step")
assert(brawler.col == 5 and brawler.row == 2, "brawler should have moved one tile east")
print("kick fallback OK: brawler moved to", brawler.col, brawler.row)

-- -------------------------------------------------------- KICK+ (FACING)
line("KICK+ (FACING) -- KICKS EVERY LINED-UP PAWN, FARTHEST FIRST")
brawler.movingAbility = "kick_plus"
dplyr:moveTo(brawler.id, 4, 2)
local k1 = dplyr:deploy("stone_a", 5, 2)
local k2 = dplyr:deploy("stone_b", 6, 2)
local k3 = dplyr:deploy("stone_c", 7, 2)
local kickBlocker2 = dplyr:deploy("stone_a", 12, 2)
local kickPlusOk = updtr:requestStep(brawler, 1, 0)
assert(kickPlusOk, "kick_plus should succeed")
assert(brawler.col == 4, "brawler should NOT move -- facing-trigger fires in place")
assert(k3.col == 11, "farthest pawn (kicked first, most room) should end up farthest, got " .. k3.col)
assert(k2.col == 10, "middle pawn should end up just behind it, got " .. k2.col)
assert(k1.col == 9, "nearest pawn should end up just behind that, got " .. k1.col)
print("kick_plus OK: chain resolved to", k1.col, k2.col, k3.col)
dplyr:remove(k1.id); dplyr:remove(k2.id); dplyr:remove(k3.id); dplyr:remove(kickBlocker2.id)
brawler.movingAbility = "kick" -- restore

-- ---------------------------------------------------------- THROW (FACING)
line("THROW (FACING) -- TRIGGERS ON AN ADJACENT PAWN WITHOUT MOVING, LANDS 2 TILES AWAY")
dplyr:moveTo(slinger.id, 4, 4)
local throwTarget = dplyr:deploy("stone_a", 5, 4)
local throwOk = updtr:requestStep(slinger, 1, 0)
assert(throwOk, "throw should succeed: adjacent pawn triggers the throw")
assert(slinger.col == 4 and slinger.row == 4, "slinger should NOT move -- facing-trigger fires in place")
assert(throwTarget.col == 7 and throwTarget.row == 4, "thrown stone should land 2 tiles from its start, got " .. throwTarget.col)
print("throw OK: slinger stayed at", slinger.col, slinger.row, "-- thrown stone landed at", throwTarget.col)
dplyr:remove(throwTarget.id)

line("THROW (FACING) -- FALLS BACK TO A NORMAL STEP WHEN NOTHING'S ADJACENT")
local throwStepOk = updtr:requestStep(slinger, 1, 0)
assert(throwStepOk, "throw should fall back to a normal step")
assert(slinger.col == 5 and slinger.row == 4, "slinger should have moved one tile east")
print("throw fallback OK: slinger moved to", slinger.col, slinger.row)

line("THROW -- JUMPS CLEAN OVER A PAWN ON THE 1ST GRID (IGNORED, NOT A WALL)")
dplyr:moveTo(slinger.id, 3, 8)
local throwTarget2 = dplyr:deploy("stone_a", 4, 8)
local overPawn = dplyr:deploy("stone_b", 5, 8)
local throwOk2 = updtr:requestStep(slinger, 1, 0)
assert(throwOk2, "throw should succeed")
assert(slinger.col == 3 and slinger.row == 8, "slinger should NOT move -- facing-trigger fires in place")
assert(throwTarget2.col == 6 and throwTarget2.row == 8, "thrown stone should land on the 2nd grid, jumping clean over the 1st, got " .. throwTarget2.col)
assert(overPawn.col == 5, "the pawn jumped over should not have moved")
print("throw OK: jumped clean over a pawn, landed at", throwTarget2.col)
dplyr:remove(throwTarget2.id); dplyr:remove(overPawn.id)

line("THROW -- BLOCKED BY A WALL (FACING-TRIGGER STILL FIRES, THE THROW ITSELF FAILS)")
dplyr:moveTo(slinger.id, 10, 6) -- row 6 has a wall at col 12
local throwTarget3 = dplyr:deploy("stone_a", 11, 6)
local throwWallOk = updtr:requestStep(slinger, 1, 0)
assert(throwWallOk, "requestStep should still report ok -- the facing-trigger fired, even though the throw itself was wall-blocked")
assert(slinger.col == 10 and slinger.row == 6, "slinger should NOT move -- facing-trigger fires in place")
assert(throwTarget3.col == 11 and throwTarget3.row == 6, "the stone should NOT have been thrown -- a wall blocks the jump")
print("throw OK: wall correctly blocked the jump, stone stayed at", throwTarget3.col)
dplyr:remove(throwTarget3.id)

line("THROW -- WALL 2 GRIDS AWAY DEGRADES TO A 1-GRID THROW INSTEAD OF FAILING")
dplyr:moveTo(slinger.id, 9, 6) -- row 6 has a wall at col 12; the 1st grid (11) is clear, only the 2nd (12) is the wall
local throwTarget4 = dplyr:deploy("stone_a", 10, 6)
local throwDegradeOk = updtr:requestStep(slinger, 1, 0)
assert(throwDegradeOk, "requestStep should report ok -- the facing-trigger fired")
assert(slinger.col == 9 and slinger.row == 6, "slinger should NOT move -- facing-trigger fires in place")
assert(throwTarget4.col == 11 and throwTarget4.row == 6,
    "wall 2 grids away should degrade to a 1-grid throw (landing on the 1st grid) instead of failing outright, got " .. throwTarget4.col)
print("throw OK: wall 2 grids away degraded to a 1-grid throw, stone landed at", throwTarget4.col)
dplyr:remove(throwTarget4.id)

-- ------------------------------------------- JUMP-LANDING RESOLUTION TABLE
line("JUMP LANDING -- CASE A: ARMORED JUMPER CRUSHES THE BED PAWN")
dplyr:moveTo(slinger.id, 3, 8)
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
dplyr:moveTo(slinger.id, 3, 8)
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
dplyr:moveTo(slinger.id, 3, 8)
local jmpC = dplyr:deploy("stone_a", 4, 8)
local bedC = dplyr:deploy("stone_b", 6, 8)
assert(updtr:requestStep(slinger, 1, 0), "throw should succeed")
assert(dplyr:getById(jmpC.id) == nil, "jumper should have died (case c: mutual destruction)")
assert(dplyr:getById(bedC.id) == nil, "bed pawn should have died too (case c: mutual destruction)")
print("jump-landing OK (case c): both jumper and bed pawn died")

line("JUMP LANDING -- CASE D: LIGHTWEIGHT JUMPER TAPS AND BOUNCES ONWARD")
dplyr:moveTo(slinger.id, 3, 8)
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
dplyr:moveTo(slinger.id, 3, 8)
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
dplyr:moveTo(slinger.id, 8, 6) -- row 6 has a wall at col 12
local jmpD3 = dplyr:deploy("stone_a", 9, 6)
dplyr:addTrait(jmpD3.id, "lightweight")
local bedD3 = dplyr:deploy("stone_b", 11, 6)
assert(updtr:requestStep(slinger, 1, 0), "the throw ability's own facing-trigger should still report ok")
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
