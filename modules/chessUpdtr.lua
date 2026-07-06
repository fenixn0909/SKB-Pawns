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

        tryPush = function(pawn, dCol, dRow)
            if pawn.statuses.guarded then
                pawn.statuses.guarded = nil -- guard absorbs the push entirely
                return false
            end
            local nc, nr = pawn.col + dCol, pawn.row + dRow
            if map:isWalkable(nc, nr) and not dplyr:isOccupied(nc, nr) then
                dplyr:moveTo(pawn.id, nc, nr)
                return true
            end
            return false
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

        setStatus = function(pawnId, name, turns)
            local pawn = dplyr:getById(pawnId)
            if pawn then pawn.statuses[name] = turns end
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
-- "up". This is what arrow-key input calls directly.
function chessUpdtr:requestStep(pawn, dCol, dRow)
    local expectedFaction = (self.turn == chessUpdtr.TURN.PC) and "pc" or "enemy"
    if pawn.faction ~= expectedFaction then
        return false, "not your turn"
    end
    if not isUnitCardinal(dCol, dRow) then
        return false, "not a single orthogonal step"
    end

    local nc, nr = pawn.col + dCol, pawn.row + dRow
    if not self.map:isWalkable(nc, nr) then
        return false, "blocked"
    end
    if self.dplyr:isOccupied(nc, nr) then
        return false, "occupied"
    end

    self.dplyr:moveTo(pawn.id, nc, nr)
    self:checkClearCondition()
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
    return true, result
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
    end
    self:checkClearCondition()

    Runtime:dispatchEvent({ name = "turnChanged", turn = self.turn, round = self.roundNumber })
end

-- Deliberately simple: each enemy fires its beam at the nearest PC sharing
-- its row or column with a clear line, otherwise it holds position.
function chessUpdtr:runEnemyPhase()
    local enemies = self.dplyr:getAllByFaction("enemy")
    for _, enemy in ipairs(enemies) do
        if enemy.hp and enemy.hp > 0 then
            local firedAt = self:findBeamTarget(enemy)
            if firedAt and self:hasAbility(enemy, "fire_beam") then
                self:useAbility(enemy, "fire_beam", firedAt)
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
        if pc.col == enemy.col or pc.row == enemy.row then
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
