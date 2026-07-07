--[[
    historyMng.lua ("History Manager")

    Undo/redo/restart for the whole board. Takes a full data-only snapshot
    (every pawn's position/hp/statuses/traits/facing, every tile's
    type/sink-timer, and the turn/round counters) after every
    state-changing action -- a move, an ability, or a completed round --
    via chessUpdtr's `onStateChanged` hook, and can step backward/forward
    through that history, or jump straight back to the level's starting
    snapshot.

    Why full snapshots instead of reversing individual moves: pawns can
    die or sink into a hazard (removed entirely), and hazard tiles change
    type over time. Reversing those cleanly move-by-move would need its
    own inverse for every kind of change; a snapshot sidesteps that
    entirely by just re-declaring "this is the state" and rebuilding to
    match. Applying a snapshot tears down every current pawn's display
    objects and recreates them fresh from the snapshot's data -- simpler
    and more robust than trying to animate everything back into place.
]]

local historyMng = {}
historyMng.__index = historyMng

function historyMng.new(map, dplyr, updtr)
    local self = setmetatable({}, historyMng)
    self.map = map
    self.dplyr = dplyr
    self.updtr = updtr
    self.stack = {}
    self.pointer = 0
    self.onPawnRecreated = nil -- set by main.lua to re-register tap handling
    self.onApplied = nil       -- set by main.lua to refresh selection/camera/UI
    return self
end

local function copyDict(d)
    local c = {}
    for k, v in pairs(d or {}) do c[k] = v end
    return c
end

-- ---------------------------------------------------------------- CAPTURE
function historyMng:captureState()
    local pawns = {}
    for _, pawn in pairs(self.dplyr.pawns) do
        table.insert(pawns, {
            id = pawn.id, kind = pawn.kind, faction = pawn.faction,
            name = pawn.name, subType = pawn.subType,
            col = pawn.col, row = pawn.row,
            hp = pawn.hp, maxHp = pawn.maxHp,
            abilities = pawn.abilities, movingAbility = pawn.movingAbility,
            isMovableOnly = pawn.isMovableOnly,
            statuses = copyDict(pawn.statuses),
            traits = copyDict(pawn.traits),
            facing = { pawn.facing[1], pawn.facing[2] },
        })
    end

    local tiles = {}
    for r = 1, self.map.rows do
        tiles[r] = {}
        for c = 1, self.map.cols do
            local t = self.map.tiles[r][c]
            tiles[r][c] = { type = t.type, sinkTimer = t.sinkTimer }
        end
    end

    return {
        pawns = pawns,
        nextId = self.dplyr.nextId,
        tiles = tiles,
        turn = self.updtr.turn,
        roundNumber = self.updtr.roundNumber,
    }
end

-- Pushes the current live state as a new history entry, discarding any
-- "future" (redo) entries beyond the current pointer -- the normal
-- undo-then-do-something-new behavior every undo/redo app has.
function historyMng:snapshot()
    local state = self:captureState()
    for i = #self.stack, self.pointer + 1, -1 do
        self.stack[i] = nil
    end
    table.insert(self.stack, state)
    self.pointer = #self.stack
end

-- ---------------------------------------------------------------- APPLY
function historyMng:applyState(state)
    for id in pairs(self.dplyr.pawns) do
        self.dplyr:remove(id)
    end
    for _, p in ipairs(state.pawns) do
        local pawn = self.dplyr:_recreateFromSnapshot(p)
        if self.onPawnRecreated then self.onPawnRecreated(pawn) end
    end
    self.dplyr.nextId = state.nextId

    for r = 1, self.map.rows do
        for c = 1, self.map.cols do
            local saved = state.tiles[r][c]
            local live = self.map.tiles[r][c]
            live.type = saved.type
            live.sinkTimer = saved.sinkTimer
            self.map:refreshTile(c, r)
        end
    end

    self.updtr.turn = state.turn
    self.updtr.roundNumber = state.roundNumber

    if self.onApplied then self.onApplied() end
    Runtime:dispatchEvent({ name = "historyApplied", turn = state.turn, round = state.roundNumber })
end

function historyMng:undo()
    if self.pointer <= 1 then return false end
    self.pointer = self.pointer - 1
    self:applyState(self.stack[self.pointer])
    return true
end

function historyMng:redo()
    if self.pointer >= #self.stack then return false end
    self.pointer = self.pointer + 1
    self:applyState(self.stack[self.pointer])
    return true
end

-- Jumps back to the very first snapshot (taken right after the level's
-- initial deployment, before any input) -- a full stage restart.
function historyMng:restart()
    if #self.stack == 0 then return false end
    self.pointer = 1
    self:applyState(self.stack[1])
    return true
end

return historyMng
