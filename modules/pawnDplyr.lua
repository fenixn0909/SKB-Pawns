--[[
    pawnDplyr.lua ("Pawn Deployer")

    Deploys and tracks every pawn on the board: player characters, enemies,
    movable objects (crates), and mechanisms. Owns the occupancy grid
    (who's standing where) and the pawn sprites. Does not know about
    input or ability rules -- see pawnCon.lua and abltMng.lua.
]]

local pawnDplyr = {}
pawnDplyr.__index = pawnDplyr

pawnDplyr.FACTION = {
    PC       = "pc",
    ENEMY    = "enemy",
    NEUTRAL  = "neutral",  -- crates, gears -- movable but not "alive"
}

-- Kind catalog: sprite image, faction, base stats, and default ability ids.
-- Ability ids are resolved against abltMng at deploy time.
--
-- `abilities`     -- click-to-arm abilities (ACTIVE trigger), unchanged from before.
-- `movingAbility` -- optional single ability id with a MOVING trigger. If
--                    set, it replaces what a directional input (arrow key /
--                    adjacent-tile tap) does for this pawn -- see
--                    chessUpdtr:requestStep(). Leave nil for plain
--                    one-tile-at-a-time baseline movement.
-- `traits`        -- native trait ids (see modules/traitMng.lua), copied
--                    into pawn.traits at deploy time. Traits can later be
--                    added/removed by buffs/debuffs at runtime.
-- `subType`       -- free-form classification tag (e.g. "stone") for
--                    kinds that share a faction/behavior family but aren't
--                    worth a whole new faction of their own.
pawnDplyr.KIND_INFO = {
    pc_knight = {
        image = "images/pc_knight.png", faction = pawnDplyr.FACTION.PC,
        name = "Knight", hp = 6, abilities = { "push_all", "swap" },
        movingAbility = "push", traits = {},
    },
    pc_mage = {
        image = "images/pc_mage.png", faction = pawnDplyr.FACTION.PC,
        name = "Mage", hp = 4, abilities = { "drag", "swap" },
        movingAbility = "swap_move", traits = { "lightweight" },
    },
    pc_guardian = {
        image = "images/pc_guardian.png", faction = pawnDplyr.FACTION.PC,
        name = "Guardian", hp = 8, abilities = { "push_all", "guard" },
        movingAbility = "pull", traits = {},
    },
    enemy_brute = {
        image = "images/enemy_brute.png", faction = pawnDplyr.FACTION.ENEMY,
        name = "Brute", hp = 5, abilities = { "guard" }, traits = {},
    },
    enemy_turret = {
        image = "images/enemy_turret.png", faction = pawnDplyr.FACTION.ENEMY,
        name = "Turret", hp = 3, abilities = { "fire_beam" }, traits = { "stealth" },
    },
    enemy_wraith = {
        image = "images/enemy_wraith.png", faction = pawnDplyr.FACTION.ENEMY,
        name = "Wraith", hp = 3, abilities = { "fire_beam" }, traits = {},
    },
    movable_crate = {
        image = "images/crate.png", faction = pawnDplyr.FACTION.NEUTRAL,
        name = "Crate", hp = nil, abilities = {}, isMovableOnly = true, traits = {},
    },
    mechanism_gear = {
        image = "images/mechanism_gear.png", faction = pawnDplyr.FACTION.NEUTRAL,
        name = "Gear", hp = nil, abilities = {}, isMechanism = true, traits = {},
    },

    -- STONES: plain, ability-less movable blockers -- a subType of the
    -- neutral "movable" pawn family, purpose-built as test furniture for
    -- the Push / Swap / Pull family of moving abilities. Three named
    -- variants exist only so a level can tell them apart in logs/labels;
    -- mechanically they're identical.
    stone_a = {
        image = "images/stone.png", faction = pawnDplyr.FACTION.NEUTRAL,
        name = "Stone A", hp = nil, abilities = {}, isMovableOnly = true,
        traits = {}, subType = "stone",
    },
    stone_b = {
        image = "images/stone.png", faction = pawnDplyr.FACTION.NEUTRAL,
        name = "Stone B", hp = nil, abilities = {}, isMovableOnly = true,
        traits = {}, subType = "stone",
    },
    stone_c = {
        image = "images/stone.png", faction = pawnDplyr.FACTION.NEUTRAL,
        name = "Stone C", hp = nil, abilities = {}, isMovableOnly = true,
        traits = {}, subType = "stone",
    },
}

-- ------------------------------------------------------------------- INIT
function pawnDplyr.new(mapRef, layerGroup)
    local self = setmetatable({}, pawnDplyr)
    self.map = mapRef
    self.layerGroup = layerGroup
    self.pawns = {}          -- id -> pawn
    self.occupancy = {}      -- "col,row" -> pawn id
    self.nextId = 1
    return self
end

local function occKey(col, row) return col .. "," .. row end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- default facing per faction for pawns that haven't moved yet -- lets Swap
-- have a sensible target direction from the very first turn. Matches
-- sampleLevel's layout (PCs west looking east at the enemies, enemies east
-- looking west); anything else just faces down.
local DEFAULT_FACING = {
    pc    = { 1, 0 },
    enemy = { -1, 0 },
}

-- shallow-copies a plain array of strings (used for KIND_INFO.traits so
-- every deployed pawn gets its own independent trait set to mutate)
local function copyTraitSet(list)
    local set = {}
    for _, id in ipairs(list or {}) do set[id] = true end
    return set
end

-- ----------------------------------------------------------------- DEPLOY
-- kind: key into KIND_INFO. opts: { faction override, hp override }
function pawnDplyr:deploy(kind, col, row, opts)
    opts = opts or {}
    local info = pawnDplyr.KIND_INFO[kind]
    assert(info, "pawnDplyr: unknown kind '" .. tostring(kind) .. "'")

    local id = self.nextId
    self.nextId = self.nextId + 1

    local faction = opts.faction or info.faction

    local pawn = {
        id = id,
        kind = kind,
        subType = info.subType,
        name = info.name,
        faction = faction,
        hp = opts.hp or info.hp,
        maxHp = opts.hp or info.hp,
        abilities = info.abilities,
        movingAbility = info.movingAbility,
        traits = copyTraitSet(info.traits),
        col = col,
        row = row,
        isMovableOnly = info.isMovableOnly or info.isMechanism,
        statuses = {}, -- e.g. statuses.guarded = turnsRemaining; see chessUpdtr for buff/debuff shapes
        facing = DEFAULT_FACING[faction] or { 0, 1 },
    }

    local x, y = self.map:gridToWorld(col, row)
    local size = self.map.tileSize

    -- Everything visual for this pawn lives in one container group,
    -- positioned at the pawn's world location. Children (sprite, HP text,
    -- selection ring, facing indicator) use LOCAL coordinates around
    -- (0,0), so moving/animating the container moves all of them together
    -- -- no separate per-part tweening needed.
    local container = display.newGroup()
    self.layerGroup:insert(container)
    container.x, container.y = x, y
    pawn.container = container

    local sprite = display.newImageRect(container, info.image, size * 0.86, size * 0.86)
    sprite.x, sprite.y = 0, 0
    pawn.sprite = sprite

    -- HP label for anything with hit points
    if pawn.hp then
        local hpText = display.newText({
            parent = container, text = tostring(pawn.hp),
            x = size * 0.30, y = -size * 0.30, font = native.systemFontBold, fontSize = 14,
        })
        hpText:setFillColor(1, 1, 1)
        pawn.hpText = hpText
    end

    -- facing indicator: a small triangle on a rotating sub-group so pawns
    -- with a facing-dependent ability (Swap) can actually be aimed by eye.
    -- Only living/actor pawns need this -- stones/crates/gears never move
    -- under their own power, so skip the visual clutter on them.
    if not pawn.isMovableOnly then
        local facingGroup = display.newGroup()
        container:insert(facingGroup)
        facingGroup.x, facingGroup.y = 0, 0
        local tip = size * 0.5
        local indicator = display.newPolygon(facingGroup, 0, 0,
            { tip, 0, tip - size * 0.16, size * 0.12, tip - size * 0.16, -size * 0.12 })
        indicator:setFillColor(1, 0.85, 0.3)
        indicator.strokeWidth = 1
        indicator:setStrokeColor(0.05, 0.05, 0.06)
        pawn.facingIndicator = facingGroup
        self:_applyFacingRotation(pawn)
    end

    self.pawns[id] = pawn
    self.occupancy[occKey(col, row)] = id

    return pawn
end

-- ------------------------------------------------------------------ TRAITS
function pawnDplyr:hasTrait(pawn, traitId)
    return pawn.traits ~= nil and pawn.traits[traitId] == true
end

function pawnDplyr:addTrait(pawnId, traitId)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    pawn.traits[traitId] = true
    Runtime:dispatchEvent({ name = "traitChanged", pawnId = pawnId, traitId = traitId, added = true })
end

function pawnDplyr:removeTrait(pawnId, traitId)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    pawn.traits[traitId] = nil
    Runtime:dispatchEvent({ name = "traitChanged", pawnId = pawnId, traitId = traitId, added = false })
end

-- ------------------------------------------------------------------ FACING
function pawnDplyr:_applyFacingRotation(pawn)
    if not pawn.facingIndicator then return end
    local dCol, dRow = pawn.facing[1], pawn.facing[2]
    pawn.facingIndicator.rotation = math.deg(atan2(dRow, dCol))
end

-- Sets which way a pawn is looking (used by facing-dependent abilities
-- like Swap) and keeps its visual indicator in sync. dCol/dRow should be a
-- unit cardinal direction, e.g. (1,0) for east.
function pawnDplyr:setFacing(pawnId, dCol, dRow)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    pawn.facing = { dCol, dRow }
    self:_applyFacingRotation(pawn)
end

function pawnDplyr:remove(pawnId)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    self.occupancy[occKey(pawn.col, pawn.row)] = nil
    if pawn.container then pawn.container:removeSelf() end -- takes sprite/hpText/ring with it
    self.pawns[pawnId] = nil
end

-- ------------------------------------------------------------------ QUERY
function pawnDplyr:getAt(col, row)
    local id = self.occupancy[occKey(col, row)]
    return id and self.pawns[id] or nil
end

function pawnDplyr:getById(id)
    return self.pawns[id]
end

function pawnDplyr:getAllByFaction(faction)
    local list = {}
    for _, pawn in pairs(self.pawns) do
        if pawn.faction == faction then table.insert(list, pawn) end
    end
    return list
end

function pawnDplyr:isOccupied(col, row)
    return self.occupancy[occKey(col, row)] ~= nil
end

-- ------------------------------------------------------------------- MOVE
-- Moves a pawn to a new grid cell and animates its sprite. Does NOT
-- validate walkability/occupancy -- chessUpdtr is responsible for the
-- rules; this module just carries out the relocation.
function pawnDplyr:moveTo(pawnId, col, row, opts)
    opts = opts or {}
    local pawn = self.pawns[pawnId]
    if not pawn then return end

    self.occupancy[occKey(pawn.col, pawn.row)] = nil
    pawn.col, pawn.row = col, row
    self.occupancy[occKey(col, row)] = pawnId

    local x, y = self.map:gridToWorld(col, row)
    local duration = opts.duration or 160
    transition.to(pawn.container, { x = x, y = y, time = duration, transition = easing.outQuad })

    Runtime:dispatchEvent({ name = "pawnMoved", pawnId = pawnId, col = col, row = row })
end

-- Swaps two pawns' grid positions in one atomic step (avoids a moment where
-- both would occupy/vacate the same cell if done as two separate moveTo calls).
function pawnDplyr:swapPawns(idA, idB)
    local a, b = self.pawns[idA], self.pawns[idB]
    if not a or not b then return end

    local aCol, aRow, bCol, bRow = a.col, a.row, b.col, b.row

    a.col, a.row = bCol, bRow
    b.col, b.row = aCol, aRow
    self.occupancy[occKey(bCol, bRow)] = idA
    self.occupancy[occKey(aCol, aRow)] = idB

    local ax, ay = self.map:gridToWorld(bCol, bRow)
    local bx, by = self.map:gridToWorld(aCol, aRow)
    transition.to(a.container, { x = ax, y = ay, time = 160, transition = easing.outQuad })
    transition.to(b.container, { x = bx, y = by, time = 160, transition = easing.outQuad })

    Runtime:dispatchEvent({ name = "pawnMoved", pawnId = idA, col = bCol, row = bRow })
    Runtime:dispatchEvent({ name = "pawnMoved", pawnId = idB, col = aCol, row = aRow })
end

function pawnDplyr:applyDamage(pawnId, amount)
    local pawn = self.pawns[pawnId]
    if not pawn or not pawn.hp then return end
    pawn.hp = math.max(0, pawn.hp - amount)
    if pawn.hpText then pawn.hpText.text = tostring(pawn.hp) end
    if pawn.hp <= 0 then
        self:remove(pawnId)
        return true -- died
    end
    return false
end

-- --------------------------------------------------------- AUTO-DEPLOY
-- Reads chessMap's spawn tiles in scan order and deploys pawns from two
-- ordered lists of kind names, e.g. assignments.pc = {"pc_knight","pc_mage"}
function pawnDplyr:autoDeployFromMap(assignments)
    assignments = assignments or {}
    local pcKinds = assignments.pc or {}
    local enemyKinds = assignments.enemy or {}

    for i, spot in ipairs(self.map.spawnPCs) do
        if pcKinds[i] then
            self:deploy(pcKinds[i], spot.col, spot.row)
        end
    end
    for i, spot in ipairs(self.map.spawnEnemies) do
        if enemyKinds[i] then
            self:deploy(enemyKinds[i], spot.col, spot.row)
        end
    end
end

return pawnDplyr
