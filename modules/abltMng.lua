--[[
    abltMng.lua ("Ability Manager")

    The catalog of every ability in the game (PC and enemy alike) and the
    *rules* each one uses to interact with other pawns/mechanisms: its
    targeting mode, range, and an execute(user, target, ctx) function.

    abltMng does NOT touch the board directly -- it's handed a small `ctx`
    (context) table of primitives (tryPush, swapPawns, pullPawn, traceBeam,
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
    FLOW    = "flow",
}

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
        description = "Shove all adjacent pawns one tile outward.",
        targeting = abltMng.TARGETING.NONE,
        apCost = 1,
        execute = function(user, _target, ctx)
            local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
            local affected = {}
            for _, d in ipairs(dirs) do
                local nc, nr = user.col + d[1], user.row + d[2]
                local other = ctx.getAt(nc, nr)
                if other and other.id ~= user.id then
                    if ctx.tryPush(other, d[1], d[2]) then
                        table.insert(affected, other.id)
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

    -- GUARD: halves the next incoming push/damage this turn cycle.
    abltMng.register({
        id = "guard",
        name = "Guard",
        description = "Braces -- next hit or push against you this round is reduced.",
        targeting = abltMng.TARGETING.NONE,
        apCost = 1,
        execute = function(user, _target, ctx)
            ctx.setStatus(user.id, "guarded", 1)
            return { affectedIds = { user.id } }
        end,
    })
end

return abltMng
