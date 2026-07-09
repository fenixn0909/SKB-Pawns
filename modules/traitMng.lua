--[[
    traitMng.lua ("Trait Manager")

    Registry of trait definitions. A trait is a named, boolean, always-on
    modifier a pawn either has or doesn't (pawn.traits[traitId] == true) --
    contrast with abilities, which are discrete things a pawn *does*.
    Traits are meant to be cheap, composable adjectives ("lightweight",
    "stealth") that other systems (chessUpdtr's ctx primitives, abltMng's
    execute functions) check for by id, e.g.:

        if dplyr:hasTrait(pawn, "lightweight") then ... end

    Traits are native (KIND_INFO.traits, copied in at pawnDplyr:deploy) or
    granted temporarily by a buff/debuff status (see chessUpdtr:tickStatuses
    and the `grantTrait` status shape) -- either way they're added/removed
    through pawnDplyr:addTrait / :removeTrait, which is also the single
    place that fires the `traitChanged` event for any UI that wants to
    reflect it.

    Like abltMng, this module is just a catalog + description text for now;
    it does NOT itself hook gameplay. Each trait's actual mechanical effect
    lives wherever it's checked (documented per trait below) -- this keeps
    the same "rules vs engine" split abltMng/chessUpdtr already use.
]]

local traitMng = {}

local registry = {}

function traitMng.register(def)
    assert(def.id, "trait def needs an id")
    registry[def.id] = def
end

function traitMng.get(id)
    return registry[id]
end

function traitMng.all()
    return registry
end

-- -------------------------------------------------------------- DEFAULTS
function traitMng.registerDefaults()

    -- LIGHTWEIGHT: gets carried an extra tile by push/pull effects instead
    -- of stopping after one. Checked in chessUpdtr's tryPushChain/
    -- dragBehindChain primitives via dplyr:hasTrait(pawn, "lightweight").
    traitMng.register({
        id = "lightweight",
        name = "Lightweight",
        description = "Pushed or dragged one extra tile, if the tile beyond is clear.",
    })

    -- STEALTH: invisible to the automatic enemy targeting used by
    -- chessUpdtr:findBeamTarget -- enemies won't auto-fire at a stealthed
    -- PC even if they share a clear line. Checked in chessUpdtr directly.
    traitMng.register({
        id = "stealth",
        name = "Stealth",
        description = "Ignored by automatic enemy line-of-sight targeting.",
    })

    -- ARMOR / PROTECTED: both grant full immunity to Treant's melee slam
    -- and Spitter's acid ball (checked in chessUpdtr:findMeleeVictims /
    -- the acid_spit ability), and both count as "armored" for the
    -- jump-landing resolution table (see dragBehindChain's sibling,
    -- chessUpdtr's resolveJumpLanding): an armored pawn that lands on
    -- someone always crushes them, regardless of the other pawn's traits.
    -- Kept as two separate ids (rather than collapsing to one) since a
    -- level might want to grant them from different sources (a shield
    -- item vs. a temporary ward spell) while meaning the same thing
    -- mechanically -- every check below treats them identically.
    traitMng.register({
        id = "armor",
        name = "Armor",
        description = "Immune to Treant's slam and Spitter's acid ball. Crushes whoever it jump-lands on.",
    })
    traitMng.register({
        id = "protected",
        name = "Protected",
        description = "Immune to Treant's slam and Spitter's acid ball. Crushes whoever it jump-lands on.",
    })

    -- PARRY: immune to Treant's melee slam specifically (not Spitter's
    -- ranged acid) -- a defensive trait themed around blocking adjacent
    -- attacks rather than dodging ranged ones.
    traitMng.register({
        id = "parry",
        name = "Parry",
        description = "Immune to Treant's melee slam (does not stop ranged attacks like Spitter's acid ball).",
    })

    -- SPIKE-HEADED: a pawn a non-armored jumper is impaled on. See the
    -- jump-landing resolution table in chessUpdtr:resolveJumpLanding.
    traitMng.register({
        id = "spike_headed",
        name = "Spike-Headed",
        description = "A non-Armored/Protected pawn that jump-lands on this one dies instead.",
    })

    -- TINY SIZE: can pass through jail bars, a wall's tiny hole, and
    -- tunnels (including teleporting between a paired tunnel's two ends)
    -- -- tiles that block every other pawn. Checked in chessMap:isWalkable.
    traitMng.register({
        id = "tiny_size",
        name = "Tiny Size",
        description = "Can pass through jail bars, wall holes, and tunnels (which teleport it to the paired exit).",
    })
end

return traitMng
