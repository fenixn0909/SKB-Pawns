--[[
    chessUpdtr.lua ("Chess Updater")

    The resolution engine. Owns turn flow (PC phase / enemy phase), validates
    and carries out movement, and provides the small primitive toolkit
    ("ctx") that ability definitions in abltMng plug into: pushing,
    swapping, pulling, beam-tracing, status effects. Also runs the hazard
    tick (the sinking-star mechanic) and checks win/lose conditions.

    This is deliberately the one module that's allowed to reach into both
    chessMap and pawnDplyr and mutate them -- everywhere else talks to the
    board through here (or through pawnCon, for input).
]]

local abltMng = require("modules.abltMng")
local chessMap = require("modules.chessMap")

local chessUpdtr = {}
chessUpdtr.__index = chessUpdtr

chessUpdtr.TURN = { PC = "pc", ENEMY = "enemy" }

function chessUpdtr.new(mapRef, dplyrRef)
    local self = setmetatable({}, chessUpdtr)
    self.map = mapRef
    self.dplyr = dplyrRef
    self.turn = chessUpdtr.TURN.PC
    self.roundNumber = 1
    self:buildCtx()
    return self
end

-- ---------------------------------------------------------------- CTX API
-- The primitive operations abilities are built from. Bound as closures so
-- ability code in abltMng never needs a reference to map/dplyr directly.
function chessUpdtr:buildCtx()
    local map, dplyr = self.map, self.dplyr

    -- Kills a pawn through whichever channel is correct for it: HP-bearing
    -- pawns go through applyDamage (so the removal path stays uniform with
    -- ordinary combat), HP-less pawns (stones, crates) are just removed.
    -- Used by the jump-landing resolution table below.
    local function killPawn(pawnId)
        local p = dplyr:getById(pawnId)
        if not p then return end
        if p.hp then
            dplyr:applyDamage(pawnId, p.hp)
        else
            dplyr:remove(pawnId)
        end
    end

    local function isArmored(p)
        return dplyr:hasTrait(p, "armor") or dplyr:hasTrait(p, "protected")
    end

    -- The jump-landing resolution table (see Throw, below). jmpPawn has
    -- just tried to land on (landCol,landRow) while traveling (dCol,dRow);
    -- bedPawn is whoever's already standing there, if anyone:
    --   a. jmpPawn Armored/Protected             -> bedPawn dies, jmpPawn lands
    --   b. bedPawn Spike-Headed (jmpPawn isn't a) -> jmpPawn dies
    --   c. neither of the above, jmpPawn isn't
    --      Lightweight either                    -> both die
    --   d. jmpPawn Lightweight (neither a nor b)  -> taps bedPawn, keeps
    --      jumping to the next grid onward (recurses); dies if that's a wall
    local function resolveJumpLanding(jmpPawn, landCol, landRow, dCol, dRow)
        local bedPawn = dplyr:getAt(landCol, landRow)
        if not bedPawn then
            dplyr:moveTo(jmpPawn.id, landCol, landRow)
            return
        end

        if isArmored(jmpPawn) then
            killPawn(bedPawn.id)
            dplyr:moveTo(jmpPawn.id, landCol, landRow)
            return
        end

        if dplyr:hasTrait(bedPawn, "spike_headed") then
            killPawn(jmpPawn.id)
            return
        end

        if dplyr:hasTrait(jmpPawn, "lightweight") then
            local nextCol, nextRow = landCol + dCol, landRow + dRow
            if not map:isWalkable(nextCol, nextRow, jmpPawn) then
                killPawn(jmpPawn.id) -- hit a wall while bouncing onward
                return
            end
            resolveJumpLanding(jmpPawn, nextCol, nextRow, dCol, dRow)
            return
        end

        killPawn(bedPawn.id)
        killPawn(jmpPawn.id)
    end

    local function kickSlide(pawn, dCol, dRow)
        local c, r = pawn.col, pawn.row
        while true do
            local nc, nr = c + dCol, r + dRow
            if not map:isWalkable(nc, nr, pawn) then break end
            if dplyr:isOccupied(nc, nr) then break end
            c, r = nc, nr
        end
        if c ~= pawn.col or r ~= pawn.row then
            dplyr:moveTo(pawn.id, c, r) -- no setFacing -- a kicked pawn's own facing never changes
        end
    end

    self.ctx = {
        getAt = function(col, row) return dplyr:getAt(col, row) end,

        isLineClear = function(c1, r1, c2, r2)
            local dc = (c2 > c1) and 1 or (c2 < c1 and -1 or 0)
            local dr = (r2 > r1) and 1 or (r2 < r1 and -1 or 0)
            local c, r = c1 + dc, r1 + dr
            while c ~= c2 or r ~= r2 do
                if not map:isWalkable(c, r) or dplyr:isOccupied(c, r) then return false end
                c, r = c + dc, r + dr
            end
            return true
        end,

        swapPawns = function(idA, idB)
            dplyr:swapPawns(idA, idB)
        end,

        pullPawn = function(target, user)
            if target.statuses.guarded then
                target.statuses.guarded = nil
                return false
            end
            local dc = (user.col > target.col) and 1 or (user.col < target.col and -1 or 0)
            local dr = (user.row > target.row) and 1 or (user.row < target.row and -1 or 0)
            local nc, nr = target.col + dc, target.row + dr
            if nc == user.col and nr == user.row then return false end -- can't land on the puller
            if map:isWalkable(nc, nr) and not dplyr:isOccupied(nc, nr) then
                dplyr:moveTo(target.id, nc, nr)
                return true
            end
            return false
        end,

        traceBeam = function(user, dCol, dRow, damage)
            local affected = {}
            local c, r = user.col + dCol, user.row + dRow
            while map:isInBounds(c, r) and not map:isBlocking(c, r) do
                local pawn = dplyr:getAt(c, r)
                if pawn then
                    local dmg = damage
                    if pawn.statuses.guarded then
                        dmg = math.ceil(damage / 2)
                        pawn.statuses.guarded = nil
                    end
                    dplyr:applyDamage(pawn.id, dmg)
                    table.insert(affected, pawn.id)
                end
                c, r = c + dCol, r + dRow
            end
            return { affectedIds = affected }
        end,

        -- Like traceBeam, but stops at (and only affects) the first pawn
        -- reached -- a discrete projectile rather than a piercing beam.
        -- immuneTraits: if the first pawn hit has any of these, it takes
        -- no damage (the shot still stops there either way -- it hit
        -- *something*, immunity doesn't make it pass through).
        traceBeamFirst = function(user, dCol, dRow, damage, immuneTraits)
            local c, r = user.col + dCol, user.row + dRow
            while map:isInBounds(c, r) and not map:isBlocking(c, r) do
                local pawn = dplyr:getAt(c, r)
                if pawn then
                    for _, t in ipairs(immuneTraits or {}) do
                        if dplyr:hasTrait(pawn, t) then return { affectedIds = {} } end
                    end
                    dplyr:applyDamage(pawn.id, damage)
                    return { affectedIds = { pawn.id } }
                end
                c, r = c + dCol, r + dRow
            end
            return { affectedIds = {} }
        end,

        -- Damages every PC in the 8 tiles surrounding `user` (Treant Slam).
        -- immuneTraits: any PC with one of these takes no damage.
        meleeSlam8 = function(user, damage, immuneTraits)
            local dirs = { {-1,-1},{0,-1},{1,-1},{-1,0},{1,0},{-1,1},{0,1},{1,1} }
            local affected = {}
            for _, d in ipairs(dirs) do
                local p = dplyr:getAt(user.col + d[1], user.row + d[2])
                if p and p.faction == "pc" then
                    local immune = false
                    for _, t in ipairs(immuneTraits or {}) do
                        if dplyr:hasTrait(p, t) then immune = true break end
                    end
                    if not immune then
                        dplyr:applyDamage(p.id, damage)
                        table.insert(affected, p.id)
                    end
                end
            end
            return { affectedIds = affected }
        end,

        setStatus = function(pawnId, name, turns)
            local pawn = dplyr:getById(pawnId)
            if pawn then pawn.statuses[name] = turns end
        end,

        -- pawn is optional -- pass the mover so a Tiny Size pawn can path
        -- through jail bars/wall holes/tunnels; omit it for "blocked for
        -- everyone" checks (e.g. testing a chain's landing tile, where the
        -- chain members may have different traits than whoever's asking).
        isWalkable = function(col, row, pawn) return map:isWalkable(col, row, pawn) end,

        -- Unconditional relocation -- used where the caller has already
        -- established the destination is safe (e.g. a tile a pawn just
        -- vacated), so there's no need to re-check walkability/occupancy.
        relocate = function(pawnId, col, row)
            dplyr:moveTo(pawnId, col, row)
        end,

        -- Baseline "walk one tile" as a reusable primitive -- both the
        -- default (no movingAbility) path and several MOVING abilities'
        -- fallback behavior share this exact rule. Passes `pawn` through to
        -- isWalkable so a Tiny Size pawn can step onto jail/hole/tunnel tiles.
        stepIfClear = function(pawn, dCol, dRow)
            local nc, nr = pawn.col + dCol, pawn.row + dRow
            if map:isWalkable(nc, nr, pawn) and not dplyr:isOccupied(nc, nr) then
                dplyr:moveTo(pawn.id, nc, nr)
                return true
            end
            return false
        end,

        -- Collects a contiguous line of pawns starting at (startCol,startRow)
        -- going in direction (dCol,dRow), and -- if the chain is <= maxDepth
        -- long and there's a walkable, unoccupied tile right after it --
        -- shifts the whole chain forward by one tile. A guarded pawn
        -- anywhere in the chain absorbs the push and cancels the whole
        -- attempt (its guard status is consumed either way, matching the
        -- original single-pawn tryPush semantics). A Lightweight pawn that
        -- ends up in the lead position is carried one extra tile if clear.
        -- Returns (true, chain) on success, or (false) if blocked.
        tryPushChain = function(startCol, startRow, dCol, dRow, maxDepth)
            maxDepth = maxDepth or math.huge
            local chain = {}
            local c, r = startCol, startRow
            while true do
                if not map:isWalkable(c, r) then return false end
                local p = dplyr:getAt(c, r)
                if not p then break end
                if p.statuses.guarded then
                    p.statuses.guarded = nil
                    return false
                end
                table.insert(chain, p)
                if #chain > maxDepth then return false end
                c, r = c + dCol, r + dRow
            end

            -- move from the tail (farthest, lands in the tile we just
            -- confirmed is clear) back to the head, so occupancy never
            -- collides mid-shift
            for i = #chain, 1, -1 do
                local p = chain[i]
                local nc, nr = p.col + dCol, p.row + dRow
                dplyr:moveTo(p.id, nc, nr)
            end

            local lead = chain[#chain]
            if lead and dplyr:hasTrait(lead, "lightweight") then
                local ec, er = lead.col + dCol, lead.row + dRow
                if map:isWalkable(ec, er) and not dplyr:isOccupied(ec, er) then
                    dplyr:moveTo(lead.id, ec, er)
                end
            end

            return true, chain
        end,

        -- Scans from `user` along its facing direction for the first pawn
        -- found. A WALL tile blocks the scan entirely (nothing beyond it
        -- counts) unless ignoreWalls is true, in which case walls are
        -- transparent to the search. Returns the target pawn, or nil.
        swapFacing = function(user, ignoreWalls)
            local dCol, dRow = user.facing[1], user.facing[2]
            local c, r = user.col + dCol, user.row + dRow
            while map:isInBounds(c, r) do
                local tile = map:getTile(c, r)
                if tile.type == chessMap.TILE.WALL then
                    if not ignoreWalls then return nil end
                else
                    local p = dplyr:getAt(c, r)
                    if p then return p end
                end
                c, r = c + dCol, r + dRow
            end
            return nil
        end,

        -- After `user` has stepped from (oldCol,oldRow) in direction
        -- (dCol,dRow), drags whoever is directly behind that vacated tile
        -- into it. If `unlimited` is true, keeps chaining down the whole
        -- contiguous line behind (Pull+); otherwise only the immediate
        -- neighbor moves (Pull). A guarded pawn absorbs the drag and stops
        -- the chain there. A Lightweight pawn at the end of the chain gets
        -- carried one extra tile if the tile beyond is clear. Returns the
        -- array of dragged pawn ids.
        dragBehindChain = function(user, dCol, dRow, oldCol, oldRow, unlimited)
            local emptyCol, emptyRow = oldCol, oldRow
            local draggedIds = {}
            local lastDragged = nil
            while true do
                local behindCol, behindRow = emptyCol - dCol, emptyRow - dRow
                local behind = dplyr:getAt(behindCol, behindRow)
                if not behind then break end
                if behind.statuses.guarded then
                    behind.statuses.guarded = nil
                    break
                end
                dplyr:moveTo(behind.id, emptyCol, emptyRow)
                table.insert(draggedIds, behind.id)
                lastDragged = behind
                emptyCol, emptyRow = behindCol, behindRow
                if not unlimited then break end
            end
            if lastDragged and dplyr:hasTrait(lastDragged, "lightweight") then
                local ec, er = lastDragged.col + dCol, lastDragged.row + dRow
                if map:isWalkable(ec, er) and not dplyr:isOccupied(ec, er) then
                    dplyr:moveTo(lastDragged.id, ec, er)
                end
            end
            return draggedIds
        end,

        -- Kicks the pawn chain starting at (startCol,startRow) going
        -- (dCol,dRow): if allowChain is false, only the first pawn found
        -- is kicked (Kick); if true, every contiguous pawn in the line is
        -- (Kick+), farthest first so nobody transiently overlaps. Each
        -- kicked pawn slides via kickSlide (unlimited distance, no facing
        -- change). Returns the array of pawns that were kicked.
        kickChain = function(startCol, startRow, dCol, dRow, allowChain)
            local chain = {}
            local c, r = startCol, startRow
            while true do
                local p = dplyr:getAt(c, r)
                if not p then break end
                table.insert(chain, p)
                if not allowChain then break end
                c, r = c + dCol, r + dRow
            end
            for i = #chain, 1, -1 do
                kickSlide(chain[i], dCol, dRow)
            end
            return chain
        end,

        -- Throws `thrownPawn` in direction (dCol,dRow): it jumps over the
        -- immediately adjacent tile (ignoring any pawn there, but not a
        -- wall) and lands 2 tiles away, resolved via resolveJumpLanding
        -- above. Returns {ok=false} without moving anything if either tile
        -- along the way is a wall.
        throwPawn = function(thrownPawn, dCol, dRow)
            local x1c, x1r = thrownPawn.col + dCol, thrownPawn.row + dRow
            local x2c, x2r = thrownPawn.col + 2 * dCol, thrownPawn.row + 2 * dRow
            if not map:isWalkable(x1c, x1r, thrownPawn) or not map:isWalkable(x2c, x2r, thrownPawn) then
                return { ok = false, reason = "throw blocked by a wall" }
            end
            resolveJumpLanding(thrownPawn, x2c, x2r, dCol, dRow)
            return { ok = true }
        end,
    }
end

-- ------------------------------------------------------------- MOVEMENT
-- Baseline movement is deliberately simple: one grid cell per action,
-- straight (no diagonals). Abilities are the exception to this -- Push
-- All, Drag, and Swap can relocate a pawn further/differently, but that's
-- an ability effect (see abltMng.lua), not baseline movement.
local function isUnitCardinal(dCol, dRow)
    return (dCol == 0 and (dRow == 1 or dRow == -1)) or
           (dRow == 0 and (dCol == 1 or dCol == -1))
end

-- Moves a pawn exactly one tile in direction (dCol, dRow), e.g. (0,-1) for
-- "up" -- UNLESS the pawn has a MOVING-trigger ability assigned
-- (pawn.movingAbility), in which case that ability decides what a
-- directional input does instead (see modules/abltMng.lua's Push/Swap/Pull
-- family). Facing always updates to the input direction first, regardless
-- of which path handles the actual movement, since Swap depends on it.
function chessUpdtr:requestStep(pawn, dCol, dRow)
    local expectedFaction = (self.turn == chessUpdtr.TURN.PC) and "pc" or "enemy"
    if pawn.faction ~= expectedFaction then
        return false, "not your turn"
    end
    if not isUnitCardinal(dCol, dRow) then
        return false, "not a single orthogonal step"
    end

    self.dplyr:setFacing(pawn.id, dCol, dRow)

    local movingDef = pawn.movingAbility and abltMng.get(pawn.movingAbility)
    if movingDef and movingDef.trigger == abltMng.TRIGGER.MOVING then
        local result = movingDef.execute(pawn, { dCol = dCol, dRow = dRow }, self.ctx) or {}
        local ok = (result.ok ~= false)
        if ok then
            self:checkClearCondition()
            self:notifyChanged()
        end
        return ok, result.reason
    end

    -- baseline: exactly one tile, straight, onto open unoccupied floor
    if not self.ctx.stepIfClear(pawn, dCol, dRow) then
        return false, "blocked"
    end
    self:checkClearCondition()
    self:notifyChanged()
    return true
end

-- Tile-click movement: only legal if the tapped tile is exactly one
-- orthogonal step away (same rule as requestStep, expressed as a
-- destination instead of a direction).
function chessUpdtr:requestMove(pawn, col, row)
    return self:requestStep(pawn, col - pawn.col, row - pawn.row)
end

-- ------------------------------------------------------------- ABILITIES
-- target is a pawn table for ADJACENT_PAWN/PAWN_IN_LINE, or a {col,row}
-- tile for DIRECTION_TILE, or nil for NONE-targeting abilities.
function chessUpdtr:useAbility(user, abilityId, target)
    local expectedFaction = (self.turn == chessUpdtr.TURN.PC) and "pc" or "enemy"
    if user.faction ~= expectedFaction then
        return false, "not your turn"
    end

    local def = abltMng.get(abilityId)
    if not def then return false, "unknown ability" end

    if def.targeting ~= abltMng.TARGETING.NONE then
        if not target then return false, "needs a target" end
        if def.canTarget and not def.canTarget(user, target, self.ctx) then
            return false, "invalid target"
        end
    end

    local result = def.execute(user, target, self.ctx)
    self:checkClearCondition()
    self:notifyChanged()
    return true, result
end

-- Fired after any action that changes board state (a move, an ability, or
-- a completed end-of-turn). modules/historyMng.lua hooks this (via
-- updtr.onStateChanged) to take its undo/redo snapshots -- chessUpdtr
-- doesn't know history exists, it just offers this one seam.
function chessUpdtr:notifyChanged()
    if self.onStateChanged then self.onStateChanged() end
end

-- ------------------------------------------------------------------ TURN
function chessUpdtr:endTurn()
    if self.turn == chessUpdtr.TURN.PC then
        self.turn = chessUpdtr.TURN.ENEMY
        self:runEnemyPhase()
        self.turn = chessUpdtr.TURN.PC
        self.roundNumber = self.roundNumber + 1
        self:tickStatuses()
        self:tickHazards()
        self:notifyChanged()
    end
    self:checkClearCondition()

    Runtime:dispatchEvent({ name = "turnChanged", turn = self.turn, round = self.roundNumber })
end

-- Each enemy checks every ability it has for an aiPattern (see
-- abltMng.TRIGGER's doc comment) and fires accordingly: "melee8" always
-- fires (no targeting needed), "beam_pierce"/"beam_first" only fire if
-- findBeamTarget finds a clear line to a PC.
function chessUpdtr:runEnemyPhase()
    local enemies = self.dplyr:getAllByFaction("enemy")
    for _, enemy in ipairs(enemies) do
        if enemy.hp and enemy.hp > 0 then
            for _, abilityId in ipairs(enemy.abilities or {}) do
                local def = abltMng.get(abilityId)
                if def and def.aiPattern == "melee8" then
                    self:useAbility(enemy, abilityId, nil)
                elseif def and (def.aiPattern == "beam_pierce" or def.aiPattern == "beam_first") then
                    local firedAt = self:findBeamTarget(enemy)
                    if firedAt then
                        self:useAbility(enemy, abilityId, firedAt)
                    end
                end
            end
        end
    end
end

function chessUpdtr:hasAbility(pawn, abilityId)
    for _, id in ipairs(pawn.abilities or {}) do
        if id == abilityId then return true end
    end
    return false
end

function chessUpdtr:findBeamTarget(enemy)
    local pcs = self.dplyr:getAllByFaction("pc")
    for _, pc in ipairs(pcs) do
        if not self.dplyr:hasTrait(pc, "stealth") and (pc.col == enemy.col or pc.row == enemy.row) then
            if self.ctx.isLineClear(enemy.col, enemy.row, pc.col, pc.row) then
                return { col = pc.col, row = pc.row }
            end
        end
    end
    return nil
end

function chessUpdtr:tickStatuses()
    for _, pawn in pairs(self.dplyr.pawns) do
        for name, turns in pairs(pawn.statuses) do
            if turns ~= nil then
                pawn.statuses[name] = turns - 1
                if pawn.statuses[name] <= 0 then pawn.statuses[name] = nil end
            end
        end
    end
end

function chessUpdtr:tickHazards()
    local sunk = self.map:tickHazards()
    for _, spot in ipairs(sunk) do
        local pawn = self.dplyr:getAt(spot.col, spot.row)
        if pawn then
            self.dplyr:remove(pawn.id) -- the sinking star claims whoever was standing there
        end
    end
end

-- --------------------------------------------------------------- OUTCOME
function chessUpdtr:checkClearCondition()
    local goals = self.map:getGoalTiles()
    if #goals == 0 then return end

    local allHeld = true
    for _, spot in ipairs(goals) do
        local pawn = self.dplyr:getAt(spot.col, spot.row)
        if not pawn or pawn.faction ~= "pc" then
            allHeld = false
            break
        end
    end
    if allHeld then
        Runtime:dispatchEvent({ name = "levelCleared" })
        return
    end

    local pcs = self.dplyr:getAllByFaction("pc")
    if #pcs == 0 then
        Runtime:dispatchEvent({ name = "levelFailed" })
    end
end

return chessUpdtr
