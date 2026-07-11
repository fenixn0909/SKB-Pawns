--[[
    abltMng.lua ("Ability Manager")

    The catalog of every ability in the game (PC and enemy alike) and the
    *rules* each one uses to interact with other pawns/mechanisms: its
    targeting mode, range, and an execute(user, target, ctx) function.

    abltMng does NOT touch the board directly -- it's handed a small `ctx`
    (context) table of primitives (tryPushChain, swapPawns, pullPawn, traceBeam,
    setStatus, ...) by chessUpdtr, which is the module that actually owns
    board mutation and turn flow. This keeps "what an ability does" (here)
    separate from "how the board resolves interactions" (chessUpdtr),
    while avoiding a circular require between the two modules.
]]

local abltMng = {}

abltMng.TARGETING = {
    NONE          = "none",           -- affects the user / all adjacent -- no target needed
    ADJACENT_PAWN = "adjacent_pawn",  -- must pick an orthogonally adjacent pawn
    PAWN_IN_LINE  = "pawn_in_line",   -- must pick a pawn along a clear cardinal line
    DIRECTION_TILE = "direction_tile",-- tap any tile to imply a cardinal direction
}

-- How an ability activates. See README's design notes for the full picture;
-- short version:
--   ACTIVE  -- player arms it (click a button), then supplies a target if
--              needed. Everything before this trigger system existed was
--              implicitly ACTIVE (Push All, Swap, Drag, Guard, Fire Beam).
--   PASSIVE -- always on, no activation at all (closer to a trait than a
--              button -- reserved for future abilities that are just
--              permanent stat modifiers; none of the defaults below use it
--              yet, but the slot exists so mechanisms/equipment can grant
--              one via a buff).
--   MOVING  -- fires as *what a directional input does* for this pawn,
--              via pawn.movingAbility (see pawnDplyr.KIND_INFO). Replaces
--              baseline one-tile movement for that pawn; see
--              chessUpdtr:requestStep. execute(user, {dCol,dRow}, ctx).
--   FACING  -- also fires off pawn.movingAbility/directional input, but
--              doesn't require moving at all: the pawn's facing updates
--              (as it always does on directional input) and, if there's
--              a pawn immediately adjacent in that direction, the ability
--              triggers on it in place. If nothing's there, it falls back
--              to a normal one-tile step, same as MOVING's fallback
--              abilities do. execute(user, {dCol,dRow}, ctx) -- same
--              signature as MOVING, dispatched identically by
--              chessUpdtr:requestStep; the difference is entirely in what
--              the execute function itself checks (adjacency-before-move
--              instead of step-then-check-new-adjacency). Kick/Kick+/Throw
--              use this.
--   FLOW    -- fires as a *reaction* to being moved by someone/something
--              else (pushed, dragged, swapped). Pull/Pull+'s chain effect
--              on the pawn behind the mover is the current example, but
--              it's implemented as part of the mover's own MOVING ability
--              rather than a separate registry entry on the dragged pawn --
--              this tag exists for future abilities that need to react on
--              the *receiving* end of a displacement (e.g. "explodes when
--              pushed"), which would be checked from chessUpdtr's
--              tryPushChain/dragBehindChain primitives.
abltMng.TRIGGER = {
    ACTIVE  = "active",
    PASSIVE = "passive",
    MOVING  = "moving",
    FACING  = "facing",
    FLOW    = "flow",
}

-- Optional, enemy-only: how chessUpdtr's automatic enemy AI phase decides
-- whether/how to fire an ACTIVE ability without a player picking a target.
--   "beam_pierce" -- fire_beam's pattern: aim at any PC sharing a clear
--                    row/column, damage runs through everyone on the line.
--   "beam_first"  -- acid_spit's pattern: same aiming, but the shot stops
--                    at (and only affects) the first pawn it reaches.
--   "melee8"      -- treant_slam's pattern: no aiming/targeting at all --
--                    fires every enemy turn regardless, hitting all 8
--                    surrounding tiles at once.

local registry = {}

function abltMng.register(def)
    assert(def.id, "ability def needs an id")
    registry[def.id] = def
end

function abltMng.get(id)
    return registry[id]
end

-- resolves a pawn's ability id list into full ability defs
function abltMng.getAbilitiesForPawn(pawn)
    local list = {}
    for _, id in ipairs(pawn.abilities or {}) do
        if registry[id] then table.insert(list, registry[id]) end
    end
    return list
end

-- -------------------------------------------------------------- DEFAULTS
function abltMng.registerDefaults()

    -- PUSH ALL: shoves every pawn in the four cardinal neighbors one tile
    -- further away. Great synergy with hazard tiles (push enemies into the
    -- drink) and with mechanism gears (push them onto pressure tiles).
    abltMng.register({
        id = "push_all",
        name = "Push All",
        description = "Shove all adjacent pawns (and any chain behind them) outward.",
        targeting = abltMng.TARGETING.NONE,
        trigger = abltMng.TRIGGER.ACTIVE,
        apCost = 1,
        execute = function(user, _target, ctx)
            local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
            local affected = {}
            for _, d in ipairs(dirs) do
                local nc, nr = user.col + d[1], user.row + d[2]
                if ctx.getAt(nc, nr) then
                    local ok, chain = ctx.tryPushChain(nc, nr, d[1], d[2], math.huge)
                    if ok then
                        for _, p in ipairs(chain) do table.insert(affected, p.id) end
                    end
                end
            end
            return { affectedIds = affected }
        end,
    })

    -- SWAP: trade places with an adjacent pawn. Useful for repositioning
    -- a squishy ally out of a beam's path, or yanking an enemy off a goal.
    abltMng.register({
        id = "swap",
        name = "Swap",
        description = "Swap positions with an adjacent pawn.",
        targeting = abltMng.TARGETING.ADJACENT_PAWN,
        trigger = abltMng.TRIGGER.ACTIVE,
        apCost = 1,
        canTarget = function(user, target, ctx)
            if not target or target.id == user.id then return false end
            local dc, dr = math.abs(target.col - user.col), math.abs(target.row - user.row)
            return (dc + dr) == 1 -- orthogonally adjacent
        end,
        execute = function(user, target, ctx)
            ctx.swapPawns(user.id, target.id)
            return { affectedIds = { target.id } }
        end,
    })

    -- DRAG: pull a pawn one tile toward you along a clear cardinal line.
    abltMng.register({
        id = "drag",
        name = "Drag",
        description = "Pull a pawn one tile toward you (range 3, clear line).",
        targeting = abltMng.TARGETING.PAWN_IN_LINE,
        trigger = abltMng.TRIGGER.ACTIVE,
        range = 3,
        apCost = 1,
        canTarget = function(user, target, ctx)
            if not target or target.id == user.id then return false end
            if user.col ~= target.col and user.row ~= target.row then return false end
            local dist = math.abs(target.col - user.col) + math.abs(target.row - user.row)
            if dist > 3 then return false end
            return ctx.isLineClear(user.col, user.row, target.col, target.row)
        end,
        execute = function(user, target, ctx)
            ctx.pullPawn(target, user)
            return { affectedIds = { target.id } }
        end,
    })

    -- FIRE BEAM: enemy ability. Damages every pawn along a straight line
    -- until it hits a wall.
    abltMng.register({
        id = "fire_beam",
        name = "Fire Beam",
        description = "Damage everything in a straight line until a wall.",
        targeting = abltMng.TARGETING.DIRECTION_TILE,
        trigger = abltMng.TRIGGER.ACTIVE,
        aiPattern = "beam_pierce",
        apCost = 1,
        execute = function(user, targetTile, ctx)
            local dc = targetTile.col - user.col
            local dr = targetTile.row - user.row
            -- reduce to a unit cardinal direction
            if math.abs(dc) >= math.abs(dr) then
                dc = (dc > 0) and 1 or (dc < 0 and -1 or 0)
                dr = 0
            else
                dr = (dr > 0) and 1 or (dr < 0 and -1 or 0)
                dc = 0
            end
            if dc == 0 and dr == 0 then return { affectedIds = {} } end
            return ctx.traceBeam(user, dc, dr, 2) -- 2 damage per hit
        end,
    })

    -- TREANT SLAM: hits every PC in the 8 surrounding tiles (including
    -- diagonals) -- fires automatically every enemy turn regardless of
    -- position (see aiPattern "melee8"). Armor, Protected, and Parry all
    -- grant immunity.
    abltMng.register({
        id = "treant_slam",
        name = "Treant Slam",
        description = "Damages every PC in the 8 surrounding tiles. Armor, Protected, and Parry all grant immunity.",
        targeting = abltMng.TARGETING.NONE,
        trigger = abltMng.TRIGGER.ACTIVE,
        aiPattern = "melee8",
        apCost = 1,
        execute = function(user, _target, ctx)
            return ctx.meleeSlam8(user, 2, { "armor", "protected", "parry" })
        end,
    })

    -- ACID SPIT: like Fire Beam's aiming (any PC sharing a clear
    -- row/column), but the shot stops at -- and only affects -- the first
    -- pawn it reaches, rather than piercing the whole line (see aiPattern
    -- "beam_first"). Armor and Protected grant immunity (Parry does not --
    -- it's a melee-only defense).
    abltMng.register({
        id = "acid_spit",
        name = "Acid Spit",
        description = "Damages the first non-immune pawn in a clear line. Armor and Protected grant immunity.",
        targeting = abltMng.TARGETING.DIRECTION_TILE,
        trigger = abltMng.TRIGGER.ACTIVE,
        aiPattern = "beam_first",
        apCost = 1,
        execute = function(user, targetTile, ctx)
            local dc = targetTile.col - user.col
            local dr = targetTile.row - user.row
            if math.abs(dc) >= math.abs(dr) then
                dc = (dc > 0) and 1 or (dc < 0 and -1 or 0)
                dr = 0
            else
                dr = (dr > 0) and 1 or (dr < 0 and -1 or 0)
                dc = 0
            end
            if dc == 0 and dr == 0 then return { affectedIds = {} } end
            return ctx.traceBeamFirst(user, dc, dr, 2, { "armor", "protected" })
        end,
    })

    -- GUARD: halves the next incoming push/damage this turn cycle.
    abltMng.register({
        id = "guard",
        name = "Guard",
        description = "Braces -- next hit or push against you this round is reduced.",
        targeting = abltMng.TARGETING.NONE,
        trigger = abltMng.TRIGGER.ACTIVE,
        apCost = 1,
        execute = function(user, _target, ctx)
            ctx.setStatus(user.id, "guarded", 1)
            return { affectedIds = { user.id } }
        end,
    })

    -- ---------------------------------------------------------- MOVING ABILITIES
    -- These replace baseline one-tile movement for whichever pawn has them
    -- as pawn.movingAbility (see pawnDplyr.KIND_INFO). Signature differs
    -- from the ACTIVE abilities above: execute(user, moveVec, ctx), where
    -- moveVec = {dCol=, dRow=} is the direction the input asked to move
    -- in. Return a table including `ok` (chessUpdtr:requestStep treats a
    -- missing `ok` as true, but every def below sets it explicitly) --
    -- false means the input didn't do anything (nothing to report back to
    -- the player beyond "that didn't work").

    -- PUSH: walking into a pawn shoves it -- and anything chained directly
    -- behind it, unlimited depth -- forward by one tile, then you step
    -- into the space it left. Walking into open floor is just a normal step.
    abltMng.register({
        id = "push",
        name = "Push (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Walking into a pawn shoves it, and any chain behind it (unlimited depth), forward.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local nc, nr = user.col + dCol, user.row + dRow
            if not ctx.isWalkable(nc, nr, user) then return { ok = false, reason = "blocked" } end
            if not ctx.getAt(nc, nr) then
                ctx.relocate(user.id, nc, nr)
                return { ok = true }
            end
            local success = ctx.tryPushChain(nc, nr, dCol, dRow, math.huge)
            if not success then return { ok = false, reason = "push blocked" } end
            ctx.relocate(user.id, nc, nr)
            return { ok = true }
        end,
    })

    -- PUSH+: same as Push, but can only muscle through a chain of up to 2
    -- pawns -- a longer line won't budge at all.
    abltMng.register({
        id = "push_plus",
        name = "Push+ (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Like Push, but the chain it can shove tops out at 2 pawns.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local nc, nr = user.col + dCol, user.row + dRow
            if not ctx.isWalkable(nc, nr, user) then return { ok = false, reason = "blocked" } end
            if not ctx.getAt(nc, nr) then
                ctx.relocate(user.id, nc, nr)
                return { ok = true }
            end
            local success = ctx.tryPushChain(nc, nr, dCol, dRow, 2)
            if not success then return { ok = false, reason = "push blocked" } end
            ctx.relocate(user.id, nc, nr)
            return { ok = true }
        end,
    })

    -- SWAP (Moving): instead of stepping, instantly swaps with the first
    -- pawn along your facing direction -- unlimited range, but a wall
    -- blocks line of sight (only pawns before the first wall count). Falls
    -- back to a normal one-tile step if nothing's found to swap with.
    abltMng.register({
        id = "swap_move",
        name = "Swap (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Swaps with the first pawn you're facing; walls block line of sight. Falls back to a normal step if there's nothing to swap with.",
        execute = function(user, moveVec, ctx)
            local target = ctx.swapFacing(user, false)
            if target then
                ctx.swapPawns(user.id, target.id)
                return { ok = true, affectedIds = { target.id } }
            end
            return { ok = ctx.stepIfClear(user, moveVec.dCol, moveVec.dRow) }
        end,
    })

    -- SWAP+ (Moving): same as Swap, but sees straight through walls.
    abltMng.register({
        id = "swap_plus",
        name = "Swap+ (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Swaps with the first pawn you're facing, even through walls. Falls back to a normal step if there's nothing to swap with.",
        execute = function(user, moveVec, ctx)
            local target = ctx.swapFacing(user, true)
            if target then
                ctx.swapPawns(user.id, target.id)
                return { ok = true, affectedIds = { target.id } }
            end
            return { ok = ctx.stepIfClear(user, moveVec.dCol, moveVec.dRow) }
        end,
    })

    -- PULL (Moving): a normal one-tile step, plus whatever pawn is
    -- directly behind you gets dragged into the tile you just vacated.
    abltMng.register({
        id = "pull",
        name = "Pull (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Step forward normally; the pawn directly behind you is dragged into the tile you left.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local oldCol, oldRow = user.col, user.row
            if not ctx.stepIfClear(user, dCol, dRow) then return { ok = false } end
            local dragged = ctx.dragBehindChain(user, dCol, dRow, oldCol, oldRow, false)
            return { ok = true, affectedIds = dragged }
        end,
    })

    -- PULL+ (Moving): same, but the whole contiguous line behind you
    -- shuffles forward one tile each, like a conga line / sneaking train.
    abltMng.register({
        id = "pull_plus",
        name = "Pull+ (Moving)",
        trigger = abltMng.TRIGGER.MOVING,
        description = "Step forward normally; the whole contiguous line of pawns behind you shuffles forward one tile each.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local oldCol, oldRow = user.col, user.row
            if not ctx.stepIfClear(user, dCol, dRow) then return { ok = false } end
            local dragged = ctx.dragBehindChain(user, dCol, dRow, oldCol, oldRow, true)
            return { ok = true, affectedIds = dragged }
        end,
    })

    -- KICK (Facing): press a direction; if a pawn is immediately adjacent
    -- that way, it's kicked in place -- no move -- and slides until
    -- blocked by a wall or another pawn (unlimited distance). The kicked
    -- pawn's own facing never changes. If nothing's adjacent, falls back
    -- to a normal one-tile step (like Swap's fallback).
    abltMng.register({
        id = "kick",
        name = "Kick (Facing)",
        trigger = abltMng.TRIGGER.FACING,
        description = "Face a direction; a pawn immediately adjacent that way is kicked in place and slides until blocked. Its facing doesn't change. Falls back to a normal step if nothing's there.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local nc, nr = user.col + dCol, user.row + dRow
            if ctx.getAt(nc, nr) then
                local kicked = ctx.kickChain(nc, nr, dCol, dRow, false)
                local ids = {}
                for _, p in ipairs(kicked) do table.insert(ids, p.id) end
                return { ok = true, affectedIds = ids }
            end
            return { ok = ctx.stepIfClear(user, dCol, dRow) }
        end,
    })

    -- KICK+ (Facing): same, but kicks every pawn lined up in your facing
    -- direction, not just the first -- each slides independently, farthest
    -- one first so nobody transiently overlaps mid-resolution.
    abltMng.register({
        id = "kick_plus",
        name = "Kick+ (Facing)",
        trigger = abltMng.TRIGGER.FACING,
        description = "Like Kick, but kicks every pawn lined up in your facing direction, not just the first. Falls back to a normal step if nothing's there.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local nc, nr = user.col + dCol, user.row + dRow
            if ctx.getAt(nc, nr) then
                local kicked = ctx.kickChain(nc, nr, dCol, dRow, true)
                local ids = {}
                for _, p in ipairs(kicked) do table.insert(ids, p.id) end
                return { ok = true, affectedIds = ids }
            end
            return { ok = ctx.stepIfClear(user, dCol, dRow) }
        end,
    })

    -- THROW (Facing): press a direction; if a pawn is immediately adjacent
    -- that way, it's thrown in place -- no move -- jumping over the 1st
    -- grid beyond it (ignoring any pawn there, but not a wall) and landing
    -- on the 2nd. If it lands on an occupied tile, see chessUpdtr's
    -- resolveJumpLanding (Armor/Protected/Spike-Headed/Lightweight
    -- interactions). Falls back to a normal step if nothing's adjacent.
    abltMng.register({
        id = "throw",
        name = "Throw (Facing)",
        trigger = abltMng.TRIGGER.FACING,
        description = "Face a direction; a pawn immediately adjacent that way is thrown 2 tiles in place (jumping over the 1st, landing on the 2nd). Falls back to a normal step if nothing's there.",
        execute = function(user, moveVec, ctx)
            local dCol, dRow = moveVec.dCol, moveVec.dRow
            local target = ctx.getAt(user.col + dCol, user.row + dRow)
            if target then
                local result = ctx.throwPawn(target, dCol, dRow)
                if result.ok == false then return { ok = true, reason = result.reason } end
                return { ok = true, affectedIds = { target.id } }
            end
            return { ok = ctx.stepIfClear(user, dCol, dRow) }
        end,
    })
end

return abltMng
