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
sampleLevel.extras = {
    { kind = "movable_crate", col = 9, row = 8 },
}

return sampleLevel
