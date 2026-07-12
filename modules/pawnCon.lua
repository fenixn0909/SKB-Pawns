--[[
    pawnCon.lua ("Pawn Controller")

    Picks a PC to activate (mouse click on it, Tab to cycle, or number keys
    1-9 to jump straight to the Nth PC) and controls the activated pawn:
    tapping a board tile moves it, tapping an ability button arms that
    ability, and the next tap/click supplies its target. Delegates all
    actual rule-checking and board mutation to chessUpdtr.
]]

local abltMng = require("modules.abltMng")

local pawnCon = {}
pawnCon.__index = pawnCon

pawnCon.MODE = { MOVE = "move", ABILITY = "ability" }

-- boardHitRect: an invisible full-board-sized rect placed BELOW the pawn
-- layer, used to catch taps on empty tiles (pawns sit on top and catch
-- their own taps first since they're higher in the display hierarchy).
function pawnCon.new(dplyrRef, mapRef, updtrRef, boardHitRect)
    local self = setmetatable({}, pawnCon)
    self.dplyr = dplyrRef
    self.map = mapRef
    self.updtr = updtrRef
    self.selectedId = nil
    self.mode = pawnCon.MODE.MOVE
    self.pendingAbility = nil
    self.selectionRing = nil
    self.boardHitRect = boardHitRect

    boardHitRect:addEventListener("tap", function(event)
        self:onBoardTap(event)
        return true
    end)

    self._keyListener = function(event) return self:onKeyEvent(event) end
    Runtime:addEventListener("key", self._keyListener)

    return self
end

-- Call when replacing this controller with a fresh one for a new stage --
-- Runtime listeners are global and outlive any display object, so without
-- this the old stage's controller would keep processing key events
-- alongside the new one (double-handling every keypress).
function pawnCon:destroy()
    Runtime:removeEventListener("key", self._keyListener)
end

-- call once right after pawnDplyr:deploy() for every pawn that should be
-- tappable (all of them -- enemies are tappable for sidebar inspection
-- too, see onPawnTap). Stashes the handler on the pawn itself so
-- pawnDplyr:_applySprite can re-attach it whenever facing swaps the
-- sprite object out from under it (see that function's comment).
function pawnCon:registerSelectable(pawn)
    local handler = function(event)
        self:onPawnTap(pawn)
        return true
    end
    pawn._tapHandler = handler
    pawn.sprite:addEventListener("tap", handler)
end

-- ---------------------------------------------------------------- SELECT
function pawnCon:select(pawnId)
    if self.selectionRing then
        pcall(function() self.selectionRing:removeSelf() end) -- no-op if already gone (e.g. prior pawn died)
        self.selectionRing = nil
    end
    self.selectedId = pawnId
    self:setMode(pawnCon.MODE.MOVE)

    local pawn = self.dplyr:getById(pawnId)
    if pawn then
        -- parented to the pawn's own container (local coords, centered at
        -- 0,0) so it rides along automatically through every future move,
        -- push, swap, or drag -- no per-move bookkeeping needed here.
        local ring = display.newImageRect(pawn.container, "images/selection_ring.png",
            self.map.tileSize * 0.98, self.map.tileSize * 0.98)
        ring.x, ring.y = 0, 0
        self.selectionRing = ring
    end

    Runtime:dispatchEvent({ name = "pawnSelected", pawnId = pawnId })
end

function pawnCon:getSelected()
    return self.selectedId and self.dplyr:getById(self.selectedId) or nil
end

function pawnCon:cyclePCs(direction)
    local pcs = self.dplyr:getAllByFaction("pc")
    if #pcs == 0 then return end
    table.sort(pcs, function(a, b) return a.id < b.id end)

    local idx = 1
    for i, p in ipairs(pcs) do
        if p.id == self.selectedId then idx = i break end
    end
    local newIdx = ((idx - 1 + direction) % #pcs) + 1
    self:select(pcs[newIdx].id)
end

-- Cycles through enemy pawns for sidebar inspection (see onPawnTap) --
-- 'i'/'p' mirror how Q/E cycle PCs. Bound directly to those keys below
-- rather than reusing Tab/Q/E, so cycling hostiles never fights with
-- cycling your own PCs.
function pawnCon:cycleHostiles(direction)
    local enemies = self.dplyr:getAllByFaction("enemy")
    if #enemies == 0 then return end
    table.sort(enemies, function(a, b) return a.id < b.id end)

    local idx = 1
    for i, p in ipairs(enemies) do
        if p.id == self.selectedId then idx = i break end
    end
    -- if a PC (or nothing) is currently selected, start from the first
    -- hostile rather than wrapping relative to an index that isn't in
    -- this list at all
    local currentIsHostile = false
    for _, p in ipairs(enemies) do
        if p.id == self.selectedId then currentIsHostile = true break end
    end
    local newIdx = currentIsHostile and (((idx - 1 + direction) % #enemies) + 1) or 1
    self:select(enemies[newIdx].id)
end

-- ------------------------------------------------------------------ MODE
-- MOVE: tapping a tile moves the selected pawn there.
-- ABILITY: an ability is armed (self.pendingAbility); the next tap on a
-- pawn or tile supplies its target, then control returns to MOVE mode.
function pawnCon:setMode(mode, abilityId)
    self.mode = mode
    self.pendingAbility = abilityId
    Runtime:dispatchEvent({ name = "controlModeChanged", mode = mode, abilityId = abilityId })
end

function pawnCon:beginAbility(abilityId)
    local user = self:getSelected()
    if not user then return end
    local def = abltMng.get(abilityId)
    if not def then return end

    if def.targeting == abltMng.TARGETING.NONE then
        local ok, result = self.updtr:useAbility(user, abilityId, nil)
        Runtime:dispatchEvent({ name = "abilityResolved", success = ok, abilityId = abilityId })
    else
        self:setMode(pawnCon.MODE.ABILITY, abilityId)
    end
end

-- ------------------------------------------------------------------ TAPS
-- Tapping a PC selects it as normal. Tapping a hostile (when no ability is
-- armed) also selects it -- not to command it (chessUpdtr's turn/faction
-- check still refuses to move or act it), just so its info shows in the
-- sidebar. Neutral pawns (stones/crates/gears) aren't selectable this way
-- -- there's nothing to inspect on them. See also 'i'/'p' below for
-- cycling hostiles by keyboard.
function pawnCon:onPawnTap(pawn)
    if self.mode == pawnCon.MODE.ABILITY and self.pendingAbility then
        self:resolveAbility(pawn)
        return
    end
    if pawn.faction == "pc" or pawn.faction == "enemy" then
        self:select(pawn.id)
    end
end

function pawnCon:onBoardTap(event)
    -- The board can now be panned by modules/camera.lua, so a raw
    -- event.x/y (always in screen/content space) no longer lines up with
    -- chessMap's grid math directly. contentToLocal() converts through
    -- every nested group transform (container clip + camera pan) back to
    -- the board's own coordinate frame, which is exactly what
    -- chessMap:worldToGrid expects.
    local lx, ly = self.boardHitRect:contentToLocal(event.x, event.y)
    local col, row = self.map:worldToGrid(lx, ly)
    if not self.map:isInBounds(col, row) then return end

    if self.mode == pawnCon.MODE.ABILITY and self.pendingAbility then
        local def = abltMng.get(self.pendingAbility)
        if def.targeting == abltMng.TARGETING.DIRECTION_TILE then
            self:resolveAbility({ col = col, row = row })
        else
            self:setMode(pawnCon.MODE.MOVE) -- tapped empty tile while expecting a pawn: cancel
        end
        return
    end

    local user = self:getSelected()
    if user then
        self.updtr:requestMove(user, col, row)
    end
end

function pawnCon:resolveAbility(target)
    local user = self:getSelected()
    if not user then self:setMode(pawnCon.MODE.MOVE); return end
    local ok, result = self.updtr:useAbility(user, self.pendingAbility, target)
    Runtime:dispatchEvent({ name = "abilityResolved", success = ok, abilityId = self.pendingAbility })
    self:setMode(pawnCon.MODE.MOVE)
end

pawnCon.ARROW_DIRS = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

-- --------------------------------------------------------------- KEYS
function pawnCon:onKeyEvent(event)
    if event.phase ~= "down" then return false end
    local key = event.keyName

    local dir = pawnCon.ARROW_DIRS[key]
    if dir then
        -- arrow keys only drive plain movement; if an ability is armed and
        -- waiting for a target, leave it to a tap/click (or Esc to cancel)
        if self.mode == pawnCon.MODE.MOVE then
            local user = self:getSelected()
            if user then
                self.updtr:requestStep(user, dir[1], dir[2])
            end
        end
        return true
    end

    if key == "tab" then
        self:cyclePCs(1)
        return true
    end
    if key == "q" then
        self:cyclePCs(-1) -- previous PC
        return true
    end
    if key == "e" then
        self:cyclePCs(1) -- next PC
        return true
    end
    if key == "i" then
        self:cycleHostiles(1) -- next hostile
        return true
    end
    if key == "p" then
        self:cycleHostiles(-1) -- previous hostile
        return true
    end
    local num = tonumber(key)
    if num and num >= 1 and num <= 9 then
        local pcs = self.dplyr:getAllByFaction("pc")
        table.sort(pcs, function(a, b) return a.id < b.id end)
        if pcs[num] then self:select(pcs[num].id) end
        return true
    end
    if key == "escape" then
        self:setMode(pawnCon.MODE.MOVE)
        return true
    end

    -- Guard is the one remaining click/key-activated (ACTIVE-trigger)
    -- ability now that Push/Swap/Pull moved to movingAbility -- bound
    -- straight to a key rather than a sidebar button.
    if key == "g" then
        local user = self:getSelected()
        if user and self.updtr:hasAbility(user, "guard") and self.mode == pawnCon.MODE.MOVE then
            local ok = self.updtr:useAbility(user, "guard", nil)
            Runtime:dispatchEvent({ name = "abilityResolved", success = ok, abilityId = "guard" })
        end
        return true
    end

    return false
end

return pawnCon
