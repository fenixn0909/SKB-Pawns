--[[
    pawnDplyr.lua ("Pawn Deployer")

    Deploys and tracks every pawn on the board: player characters, enemies,
    movable objects (crates), and mechanisms. Owns the occupancy grid
    (who's standing where) and the pawn sprites. Does not know about
    input or ability rules -- see pawnCon.lua and abltMng.lua.
]]

local chessMap = require("modules.chessMap")

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
-- `image`         -- single static sprite path. Used by non-facing pawns
--                    (stones/crates/gears -- they never move under their
--                    own power, so there's no facing to show).
-- `images`         -- { down=, up=, left=, right= } directional sprite
--                    paths. Used by every PC/enemy instead of `image` --
--                    pawnDplyr swaps the displayed sprite to match
--                    pawn.facing whenever it changes (see :_applySprite).
pawnDplyr.KIND_INFO = {
    pc_knight = {
        images = {
            down = "images/pc_knight_down.png", up = "images/pc_knight_up.png",
            left = "images/pc_knight_left.png", right = "images/pc_knight_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Knight", hp = 6, abilities = {},
        movingAbility = "push", traits = {},
    },
    pc_mage = {
        images = {
            down = "images/pc_mage_down.png", up = "images/pc_mage_up.png",
            left = "images/pc_mage_left.png", right = "images/pc_mage_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Mage", hp = 4, abilities = {},
        movingAbility = "swap_move", traits = { "lightweight" },
    },
    pc_guardian = {
        images = {
            down = "images/pc_guardian_down.png", up = "images/pc_guardian_up.png",
            left = "images/pc_guardian_left.png", right = "images/pc_guardian_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Guardian", hp = 8, abilities = { "guard" },
        movingAbility = "pull", traits = {},
    },
    -- BRAWLER: Kick / Kick+ tester (see modules/abltMng.lua) -- after a
    -- normal step, kicks whoever's in its new facing direction; they slide
    -- until blocked by a wall or another pawn.
    pc_brawler = {
        images = {
            down = "images/pc_brawler_down.png", up = "images/pc_brawler_up.png",
            left = "images/pc_brawler_left.png", right = "images/pc_brawler_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Brawler", hp = 5, abilities = {},
        movingAbility = "kick", traits = {},
    },
    -- SLINGER: Throw tester -- after a normal step, throws whoever's
    -- adjacent in its new facing direction 2 tiles (jumping over the 1st).
    pc_slinger = {
        images = {
            down = "images/pc_slinger_down.png", up = "images/pc_slinger_up.png",
            left = "images/pc_slinger_left.png", right = "images/pc_slinger_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Slinger", hp = 4, abilities = {},
        movingAbility = "throw", traits = {},
    },
    -- SCOUT: Tiny Size tester -- can pass through jail bars, wall holes,
    -- and tunnels (which teleport it to the paired exit). Plain baseline
    -- movement otherwise (no movingAbility).
    pc_scout = {
        images = {
            down = "images/pc_scout_down.png", up = "images/pc_scout_up.png",
            left = "images/pc_scout_left.png", right = "images/pc_scout_right.png",
        },
        faction = pawnDplyr.FACTION.PC,
        name = "Scout", hp = 3, abilities = {},
        traits = { "tiny_size" },
    },
    enemy_brute = {
        images = {
            down = "images/enemy_brute_down.png", up = "images/enemy_brute_up.png",
            left = "images/enemy_brute_left.png", right = "images/enemy_brute_right.png",
        },
        faction = pawnDplyr.FACTION.ENEMY,
        name = "Brute", hp = 5, abilities = { "guard" }, traits = {},
    },
    enemy_turret = {
        images = {
            down = "images/enemy_turret_down.png", up = "images/enemy_turret_up.png",
            left = "images/enemy_turret_left.png", right = "images/enemy_turret_right.png",
        },
        faction = pawnDplyr.FACTION.ENEMY,
        name = "Turret", hp = 3, abilities = { "fire_beam" }, traits = {},
    },
    enemy_wraith = {
        images = {
            down = "images/enemy_wraith_down.png", up = "images/enemy_wraith_up.png",
            left = "images/enemy_wraith_left.png", right = "images/enemy_wraith_right.png",
        },
        faction = pawnDplyr.FACTION.ENEMY,
        name = "Wraith", hp = 3, abilities = { "fire_beam" }, traits = {},
    },
    -- TREANT: stationary melee attacker -- every enemy turn, hits all 8
    -- surrounding tiles (see abltMng's "treant_slam", aiPattern "melee8").
    -- Armor / Protected / Parry all grant immunity.
    enemy_treant = {
        images = {
            down = "images/enemy_treant_down.png", up = "images/enemy_treant_up.png",
            left = "images/enemy_treant_left.png", right = "images/enemy_treant_right.png",
        },
        faction = pawnDplyr.FACTION.ENEMY,
        name = "Treant", hp = 6, abilities = { "treant_slam" }, traits = {},
    },
    -- SPITTER: ranged single-target attacker -- every enemy turn, hits the
    -- first non-stealthed PC in a clear line ("acid_spit", aiPattern
    -- "beam_first" -- stops at the first hit, unlike Fire Beam's pierce).
    -- Armor / Protected grant immunity (Parry does not -- it's melee-only).
    enemy_spitter = {
        images = {
            down = "images/enemy_spitter_down.png", up = "images/enemy_spitter_up.png",
            left = "images/enemy_spitter_left.png", right = "images/enemy_spitter_right.png",
        },
        faction = pawnDplyr.FACTION.ENEMY,
        name = "Spitter", hp = 3, abilities = { "acid_spit" }, traits = {},
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

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end -- kept for anything using facing angles elsewhere

-- default facing per faction for pawns that haven't moved yet -- lets Swap
-- have a sensible target direction from the very first turn. Matches
-- sampleLevel's layout (PCs west looking east at the enemies, enemies east
-- looking west); anything else just faces down.
local DEFAULT_FACING = {
    pc    = { 1, 0 },
    enemy = { -1, 0 },
}

local function directionFromFacing(dCol, dRow)
    if dRow > 0 then return "down" end
    if dRow < 0 then return "up" end
    if dCol > 0 then return "right" end
    if dCol < 0 then return "left" end
    return "down"
end

-- shallow-copies a plain array of strings (used for KIND_INFO.traits so
-- every deployed pawn gets its own independent trait set to mutate)
local function copyTraitSet(list)
    local set = {}
    for _, id in ipairs(list or {}) do set[id] = true end
    return set
end

-- shallow-copies a plain dict (used for restoring a pawn's traits/statuses
-- from a history snapshot -- see :_recreateFromSnapshot). Distinct from
-- copyTraitSet above only in its input shape: this copies an existing
-- {key=true/turns,...} dict rather than an array of ids.
local function copyDict(d)
    local c = {}
    for k, v in pairs(d or {}) do c[k] = v end
    return c
end

function pawnDplyr:_spritePathFor(info, pawn)
    if info.images then
        local dir = directionFromFacing(pawn.facing[1], pawn.facing[2])
        return info.images[dir] or info.images.down
    end
    return info.image
end

-- Builds the container/sprite/HP-label for a pawn table that already has
-- all its data fields set (id, kind, col, row, hp, facing, ...). Shared by
-- :deploy() (fresh pawn) and :_recreateFromSnapshot() (restoring a pawn
-- from undo/redo/restart history) so the two can never drift apart.
function pawnDplyr:_buildVisuals(pawn, info)
    local x, y = self.map:gridToWorld(pawn.col, pawn.row)
    local size = self.map.tileSize

    -- Everything visual for this pawn lives in one container group,
    -- positioned at the pawn's world location. Children (sprite, HP text)
    -- use LOCAL coordinates around (0,0), so moving/animating the
    -- container moves all of them together -- no separate per-part
    -- tweening needed.
    local container = display.newGroup()
    self.layerGroup:insert(container)
    container.x, container.y = x, y
    pawn.container = container
    pawn._kindInfo = info -- re-looked-up by :_applySprite whenever facing changes

    -- Drop shadow: hidden at ground level (alpha 0) until moveTo's jump
    -- effect fades it in, so a pawn mid-Throw (or a lightweight pawn
    -- bouncing onward) is visibly airborne. Inserted before the sprite so
    -- it always renders behind it -- see :_applySprite, which re-asserts
    -- this ordering whenever facing swaps the sprite out.
    -- Solar2D has no display.newEllipse -- the standard trick is a circle
    -- squashed with yScale.
    local shadow = display.newCircle(container, 0, size * 0.32, size * 0.30)
    shadow.yScale = 0.12 / 0.30
    shadow:setFillColor(0, 0, 0, 0.4)
    shadow.alpha = 0
    pawn.shadow = shadow

    local sprite = display.newImageRect(container, self:_spritePathFor(info, pawn), size * 0.86, size * 0.86)
    sprite.x, sprite.y = 0, 0
    pawn.sprite = sprite

    -- HP label for anything with hit points
    if pawn.hp then
        local hpText = display.newText({
            parent = container, text = tostring(pawn.hp),
            x = size * 0.20, y = -size * 0.20, font = native.systemFontBold, fontSize = math.max(8, math.floor(size * 0.25)),
        })
        hpText:setFillColor(1, 1, 1)
        pawn.hpText = hpText
    end
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

    self:_buildVisuals(pawn, info)

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

    self:_buildVisuals(pawn, info)

    self.pawns[id] = pawn
    self.occupancy[occKey(col, row)] = id

    return pawn
end

-- ------------------------------------------------------------- HISTORY
-- Rebuilds one pawn's live object + visuals from a plain-data snapshot
-- (see modules/historyMng.lua). Distinct from :deploy() because it must
-- restore an EXACT prior state (id, hp, statuses, traits, facing) instead
-- of fresh defaults from KIND_INFO -- note the defensive copyDict() calls,
-- since the snapshot's own tables must never be handed out as a live
-- pawn's table (gameplay mutating them would corrupt that history entry
-- for good).
--
-- Does NOT call pawnCon:registerSelectable -- the fresh sprite has no tap
-- listener yet. The caller (historyMng, via its onPawnRecreated hook) is
-- responsible for re-registering it.
function pawnDplyr:_recreateFromSnapshot(entry)
    local info = pawnDplyr.KIND_INFO[entry.kind]
    assert(info, "pawnDplyr: unknown kind '" .. tostring(entry.kind) .. "' in snapshot")

    local pawn = {
        id = entry.id,
        kind = entry.kind,
        subType = entry.subType,
        name = entry.name,
        faction = entry.faction,
        hp = entry.hp,
        maxHp = entry.maxHp,
        abilities = entry.abilities,
        movingAbility = entry.movingAbility,
        traits = copyDict(entry.traits),
        col = entry.col,
        row = entry.row,
        isMovableOnly = entry.isMovableOnly,
        statuses = copyDict(entry.statuses),
        facing = { entry.facing[1], entry.facing[2] },
    }

    self:_buildVisuals(pawn, info)

    self.pawns[pawn.id] = pawn
    self.occupancy[occKey(pawn.col, pawn.row)] = pawn.id

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
-- Swaps the displayed sprite to match a directional pawn's current facing
-- (down/up/left/right). No-op for non-directional kinds (stones/crates/
-- gears use a single static `image` and have no `images` table).
function pawnDplyr:_applySprite(pawn)
    local info = pawn._kindInfo
    if not info or not info.images then return end
    local size = self.map.tileSize
    local path = self:_spritePathFor(info, pawn)
    if pawn.sprite then pawn.sprite:removeSelf() end
    local sprite = display.newImageRect(pawn.container, path, size * 0.86, size * 0.86)
    sprite.x, sprite.y = 0, 0
    pawn.container:insert(1, sprite) -- keep it behind the HP label
    pawn.sprite = sprite
    if pawn.shadow then pawn.container:insert(1, pawn.shadow) end -- re-assert shadow-behind-sprite order
end

-- Sets which way a pawn is looking (used by facing-dependent abilities
-- like Swap, and by Kick/Throw's "after move" direction) and keeps its
-- sprite in sync. dCol/dRow should be a unit cardinal direction, e.g.
-- (1,0) for east.
function pawnDplyr:setFacing(pawnId, dCol, dRow)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    pawn.facing = { dCol, dRow }
    self:_applySprite(pawn)
end

function pawnDplyr:remove(pawnId)
    local pawn = self.pawns[pawnId]
    if not pawn then return end
    self:_clearOccupancyIfOwner(pawnId, pawn.col, pawn.row)
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

-- Clears the occupancy slot at (col,row) only if `pawnId` still owns it.
-- Guards against a pawn's own old-tile cleanup wiping out a DIFFERENT
-- pawn's occupancy record if that tile got claimed out from under it in
-- the meantime -- e.g. a Throw's target tile, where the jumper's moveTo
-- claims (landCol,landRow) immediately but the bed pawn's own col/row
-- still say it's there too, until its (possibly delayed) removal runs.
function pawnDplyr:_clearOccupancyIfOwner(pawnId, col, row)
    if self.occupancy[occKey(col, row)] == pawnId then
        self.occupancy[occKey(col, row)] = nil
    end
end

-- Moves a pawn to a new grid cell and animates its sprite. Does NOT
-- validate walkability/occupancy -- chessUpdtr is responsible for the
-- rules; this module just carries out the relocation.
function pawnDplyr:moveTo(pawnId, col, row, opts)
    opts = opts or {}
    local pawn = self.pawns[pawnId]
    if not pawn then return end

    self:_clearOccupancyIfOwner(pawnId, pawn.col, pawn.row)
    pawn.col, pawn.row = col, row
    self.occupancy[occKey(col, row)] = pawnId

    -- Tunnel teleport: only a Tiny Size pawn can ever legally land here at
    -- all (see chessMap:isWalkable), so no extra trait check is needed --
    -- if it's on a paired tunnel tile, hop straight to the other end. This
    -- lives here (moveTo) rather than in requestStep because EVERY kind of
    -- relocation -- baseline step, push, pull, swap, kick, throw -- funnels
    -- through this one function.
    local tile = self.map:getTile(col, row)
    if tile and tile.type == chessMap.TILE.TUNNEL then
        local exitCol, exitRow = self.map:getTunnelExit(col, row)
        if exitCol and not self:isOccupied(exitCol, exitRow) then
            self:_clearOccupancyIfOwner(pawnId, col, row)
            pawn.col, pawn.row = exitCol, exitRow
            self.occupancy[occKey(exitCol, exitRow)] = pawnId
            col, row = exitCol, exitRow
        end
    end

    local x, y = self.map:gridToWorld(col, row)
    local duration = opts.duration or 160
    transition.cancel(pawn.container)
    transition.to(pawn.container, { x = x, y = y, time = duration, transition = easing.outQuad })

    -- Jump/air-state readability: Throw's own hop and a lightweight
    -- pawn's bounce-onward landing both pass opts.jump=true. The sprite
    -- visibly lifts and scales up, with a drop shadow fading in beneath
    -- it, then both settle back to normal on landing -- so a pawn mid-air
    -- reads differently from a normal step, push, pull, swap, or kick
    -- slide (none of which set opts.jump).
    if opts.jump and pawn.sprite and pawn.shadow then
        local size = self.map.tileSize
        local liftY = -size * 0.35
        local upTime = duration * 0.5
        local downTime = duration - upTime
        local sprite, shadow = pawn.sprite, pawn.shadow
        transition.cancel(sprite)
        transition.cancel(shadow)
        sprite.y, sprite.xScale, sprite.yScale = 0, 1, 1
        shadow.alpha = 0
        transition.to(sprite, {
            y = liftY, xScale = 1.18, yScale = 1.18, time = upTime, transition = easing.outQuad,
            onComplete = function()
                transition.to(sprite, { y = 0, xScale = 1, yScale = 1, time = downTime, transition = easing.inQuad })
            end,
        })
        transition.to(shadow, {
            alpha = 1, time = upTime, transition = easing.outQuad,
            onComplete = function()
                transition.to(shadow, { alpha = 0, time = downTime, transition = easing.inQuad })
            end,
        })
    end

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
