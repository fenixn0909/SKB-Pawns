--[[
    data/sampleLevel.lua

    A demo room, 32x15 (an original 20x15 room plus a walled-off annex).
    Legend (see chessMap.LEGEND_CHARS):
        # wall   P PC spawn   E enemy spawn   M mechanism   G goal
        ~ hazard (sinking)    J jail bars     H wall w/ tiny hole
        T tunnel (paired by id -- see sampleLevel.tunnels)

    Original room (cols 1-20): three PCs start on the west wall, three
    enemies watch the east side, a gear mechanism sits center-left, and the
    goal tile is ringed by hazard tiles that sink into the void after a
    few turns.

    Annex (cols 22-32, past the dividing wall at col 21): a small sealed
    vault (rows 7-9, cols 26-28) only reachable by a Tiny Size pawn --
    through the jail bars (west wall), the wall's tiny hole (east wall),
    or by walking onto the tunnel tile out in the open (23,6), which
    teleports straight to the tunnel tile inside the vault. The new PCs
    (Brawler/Slinger/Scout) and enemies (Treant/Spitter) spawn below the
    vault (rows 11-13) -- deliberately past every original-room spawn in
    scan order, so sampleLevel.assignments' list order lines up cleanly
    with which spawn tile gets which kind (see the scan-order note there).
]]

local sampleLevel = {}

sampleLevel.rows = {
    "################################",
    "#..PP..............##..........#",
    "#.P.P............E.##..........#",
    "#.P..PP............##..........#",
    "#.P........#.....E.##..........#",
    "#..........#.......##.T.#####..#",
    "#.......M..#.......##...#...#..#",
    "#..................##...J.T.H..#",
    "#..................##...#...#..#",
    "#............~~~.E.##..........#",
    "#............~G~...##........E.#",
    "#.....#......~~~...##..........#",
    "#.....#............##........E.#",
    "#..................##..........#",
    "################################",
}

-- kinds are assigned to spawn tiles in the scan order chessMap discovers
-- them (top-to-bottom, left-to-right across the WHOLE row, original room
-- and annex alike -- they're not scanned as separate areas). The annex's
-- spawns are deliberately placed on rows 11-13, after the original room's
-- last spawn row (10), specifically so this list's order doesn't have to
-- interleave between the two areas.
sampleLevel.assignments = {
    pc = { "pc_knight", "pc_mage", "pc_guardian", "pc_brawler", "pc_slinger", "pc_scout" },
    enemy = { "enemy_turret", "enemy_wraith", "enemy_brute", "enemy_treant", "enemy_spitter" },
}

-- Tunnel pairing: the "T" at (23,6), out in the open near the Scout's
-- spawn, teleports to the "T" at (27,8), inside the sealed vault (and
-- vice versa) -- both tagged with the same id.
sampleLevel.tunnels = {
    { id = "vault", col = 23, row = 6 },
    { id = "vault", col = 27, row = 8 },
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

    -- Kick/Throw test furniture, in front of the Brawler/Slinger (annex
    -- spawns row 11/12, facing east): a short line to kick or throw around.
    { kind = "stone_a", col = 25, row = 11 },
    { kind = "stone_b", col = 26, row = 11 },
    { kind = "stone_a", col = 25, row = 12 },

    -- a little something worth reaching inside the sealed vault
    { kind = "stone_c", col = 27, row = 7 },
}

return sampleLevel
