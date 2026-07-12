--[[
    data/sampleLevel2.lua -- Stage 2

    Loaded automatically once Stage 1's levelCleared fires (see main.lua's
    loadStage). Same roster of 6 PCs, a tighter map: a dividing wall splits
    the room in two, with only two ways across -- a cage gate (row 5) and
    an always-open corridor guarded by a Treant (row 9). Turret and Spitter
    watch the east side where both goals sit.

    Legend (see chessMap.LEGEND_CHARS):
        # wall   P PC spawn   E enemy spawn   G goal
        C cage (blocks like a wall until its button is held)
        B cage button (any pawn standing here opens its paired cage(s))
]]

local sampleLevel2 = {}

sampleLevel2.rows = {
    "######################",
    "#.PPPPPP...#.........#",
    "#..........#.....E...#",
    "#..........#.........#",
    "#.......B..C.....G...#",
    "#..........#.........#",
    "#..........#..E......#",
    "#..........#.........#",
    "#.........E......G...#",
    "#....................#",
    "######################",
}

sampleLevel2.assignments = {
    pc    = { "pc_knight", "pc_mage", "pc_guardian", "pc_brawler", "pc_slinger", "pc_scout" },
    enemy = { "enemy_turret", "enemy_spitter", "enemy_treant" },
}

sampleLevel2.tunnels = {}

sampleLevel2.cages = {
    { id = "gate", kind = "button", col = 9, row = 5 },
    { id = "gate", kind = "cage",   col = 12, row = 5 },
}

sampleLevel2.extras = {}

return sampleLevel2
