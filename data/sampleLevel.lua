--[[
    data/sampleLevel.lua

    A first demo room, 20x15. Legend (see chessMap.LEGEND_CHARS):
        # wall   P PC spawn   E enemy spawn   M mechanism   G goal   ~ hazard (sinking)

    Three PCs start on the west wall; three enemies watch the east side.
    A gear mechanism sits center-left. The goal tile is ringed by hazard
    tiles that will sink into the void after a few turns -- push an enemy
    in, or just don't dawdle getting a Knight there yourself.
]]

local sampleLevel = {}

sampleLevel.rows = {
    "####################",
    "#..................#",
    "#.P..............E.#",
    "#.P................#",
    "#.P........#.....E.#",
    "#..........#.......#",
    "#.......M..#.......#",
    "#..................#",
    "#..................#",
    "#............~~~.E.#",
    "#............~G~...#",
    "#.....#......~~~...#",
    "#.....#............#",
    "#..................#",
    "####################",
}

-- kinds are assigned to spawn tiles in the scan order chessMap discovers
-- them (top-to-bottom, left-to-right)
sampleLevel.assignments = {
    pc = { "pc_knight", "pc_mage", "pc_guardian" },
    enemy = { "enemy_turret", "enemy_wraith", "enemy_brute" },
}

-- pawns placed directly by coordinate rather than through the map legend
-- (crates/extra mechanisms aren't "spawn points" -- they're just set dressing)
--
-- The stone_* entries are test furniture for the Push / Swap / Pull family
-- of moving abilities (modules/abltMng.lua + pawnDplyr.KIND_INFO's
-- movingAbility assignments). Stones are mechanically identical -- the
-- three kind ids just exist so a level could label them differently if it
-- wanted to; reusing a kind id for more than one instance is fine.
sampleLevel.extras = {
    { kind = "movable_crate", col = 9, row = 8 },

    -- Push chain in front of the Knight (spawns row 3, facing east): three
    -- in a row to test both an unlimited Push and Push+'s 2-pawn cap.
    { kind = "stone_a", col = 6, row = 3 },
    { kind = "stone_b", col = 7, row = 3 },
    { kind = "stone_c", col = 8, row = 3 },

    -- Pull chain, directly behind the Guardian (spawns row 5, facing
    -- east): stepping east drags this one into the Guardian's old tile.
    { kind = "stone_a", col = 2, row = 5 },

    -- Swap target down the Mage's row (spawns row 4, facing east): a clear
    -- line with nothing in between, to test Swap's unlimited range.
    { kind = "stone_b", col = 11, row = 4 },
}

return sampleLevel
