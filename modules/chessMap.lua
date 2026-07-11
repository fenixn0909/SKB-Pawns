--[[
    chessMap.lua

    Owns the tilemap: dimensions, legend, per-tile terrain data, and the
    "sinking star" hazard mechanic (tiles can be marked to sink after N
    turns, becoming permanent voids). Knows nothing about pawns/occupants --
    that bookkeeping lives in pawnDplyr. This keeps "what is the board" and
    "who is standing on it" cleanly separated.
]]

local chessMap = {}
chessMap.__index = chessMap

-- ------------------------------------------------------------------ LEGEND
chessMap.TILE = {
    EMPTY        = "empty",
    WALL         = "wall",
    SPAWN_PC     = "spawn_pc",
    SPAWN_ENEMY  = "spawn_enemy",
    MECHANISM    = "mechanism",   -- synergy parts (levers/gears pawns interact with)
    GOAL         = "goal",        -- clear condition tile
    HAZARD       = "hazard",      -- sinking tile: counts down, then becomes VOID
    VOID         = "void",        -- fully sunk -- impassable, no return
    JAIL         = "jail",        -- bars: blocks everyone except a Tiny Size pawn
    WALL_HOLE    = "wall_hole",   -- a wall with a tiny hole under it: same rule as JAIL
    TUNNEL       = "tunnel",      -- Tiny-only; paired by id (see opts.tunnels), teleports on entry
    CAGE         = "cage",        -- closed gate: blocks like a wall until its paired button is held
    CAGE_OPEN    = "cage_open",   -- runtime-only state: same tile, currently open (walkable)
    CAGE_BUTTON  = "cage_button", -- pressure plate: any pawn standing here opens its paired CAGE(s)
}

-- ASCII legend used by level data files (see data/sampleLevel.lua)
chessMap.LEGEND_CHARS = {
    ["."] = chessMap.TILE.EMPTY,
    ["#"] = chessMap.TILE.WALL,
    ["P"] = chessMap.TILE.SPAWN_PC,
    ["E"] = chessMap.TILE.SPAWN_ENEMY,
    ["M"] = chessMap.TILE.MECHANISM,
    ["G"] = chessMap.TILE.GOAL,
    ["~"] = chessMap.TILE.HAZARD,
    ["J"] = chessMap.TILE.JAIL,
    ["H"] = chessMap.TILE.WALL_HOLE,
    ["T"] = chessMap.TILE.TUNNEL,
    ["C"] = chessMap.TILE.CAGE,
    ["B"] = chessMap.TILE.CAGE_BUTTON,
}

local TILE_COLORS = {
    [chessMap.TILE.EMPTY]       = { 0.16, 0.17, 0.20 },
    [chessMap.TILE.WALL]        = { 0.10, 0.10, 0.12 },
    [chessMap.TILE.SPAWN_PC]    = { 0.14, 0.20, 0.28 },
    [chessMap.TILE.SPAWN_ENEMY] = { 0.28, 0.14, 0.14 },
    [chessMap.TILE.MECHANISM]   = { 0.20, 0.18, 0.10 },
    [chessMap.TILE.GOAL]        = { 0.22, 0.20, 0.08 },
    [chessMap.TILE.HAZARD]      = { 0.10, 0.16, 0.24 },
    [chessMap.TILE.VOID]        = { 0.03, 0.03, 0.04 },
    [chessMap.TILE.JAIL]        = { 0.16, 0.17, 0.20 },
    [chessMap.TILE.WALL_HOLE]   = { 0.10, 0.10, 0.12 },
    [chessMap.TILE.TUNNEL]      = { 0.18, 0.12, 0.22 },
    [chessMap.TILE.CAGE]        = { 0.24, 0.09, 0.09 },
    [chessMap.TILE.CAGE_OPEN]   = { 0.10, 0.20, 0.11 },
    [chessMap.TILE.CAGE_BUTTON] = { 0.22, 0.19, 0.07 },
}

-- terrain types that get an overlay sprite drawn on top of the floor color
local TILE_OVERLAY_IMAGE = {
    [chessMap.TILE.WALL]      = "images/wall.png",
    [chessMap.TILE.MECHANISM] = "images/mechanism_gear.png",
    [chessMap.TILE.GOAL]      = "images/goal_star.png",
    [chessMap.TILE.HAZARD]    = "images/hazard_sink.png",
    [chessMap.TILE.JAIL]      = "images/jail_bars.png",
    [chessMap.TILE.WALL_HOLE] = "images/wall_hole.png",
    [chessMap.TILE.TUNNEL]    = "images/tunnel.png",
    [chessMap.TILE.CAGE]      = "images/cage_closed.png",
    [chessMap.TILE.CAGE_OPEN] = "images/cage_open.png",
    [chessMap.TILE.CAGE_BUTTON] = "images/cage_button.png",
}

-- tile types only a Tiny Size pawn can enter -- everyone else is blocked
-- as if it were a wall. See :isWalkable.
local TINY_ONLY_TILES = {
    [chessMap.TILE.JAIL]      = true,
    [chessMap.TILE.WALL_HOLE] = true,
    [chessMap.TILE.TUNNEL]    = true,
}

-- default number of turns a HAZARD tile survives before sinking to VOID
local DEFAULT_SINK_TURNS = 4

-- -------------------------------------------------------------------- NEW
-- levelRows: array of equal-length strings, one per map row, using LEGEND_CHARS
-- opts: { tileSize, originX, originY, sinkTurns }
--
-- Tile size is computed by main.lua (it fits the whole map inside the
-- board area, with zoom available on top -- see modules/camera.lua) and
-- passed in via opts.tileSize. originX/originY default to 0 (the map's
-- own coordinate frame); a non-zero origin is still supported for anyone
-- drawing a map without a camera (e.g. a future minimap), but main.lua's
-- normal setup leaves them at 0.
function chessMap.new(levelRows, opts)
    opts = opts or {}
    local self = setmetatable({}, chessMap)

    self.rows = #levelRows
    self.cols = #levelRows[1]

    self.tileSize = opts.tileSize or 48
    self.originX = opts.originX or 0
    self.originY = opts.originY or 0

    self.pixelW = self.tileSize * self.cols
    self.pixelH = self.tileSize * self.rows

    self.sinkTurns = opts.sinkTurns or DEFAULT_SINK_TURNS

    self.tiles = {}       -- tiles[row][col] = { type = TILE.xxx, sinkTimer = n|nil, tunnelId = id|nil }
    self.spawnPCs = {}     -- ordered list of {col,row}
    self.spawnEnemies = {} -- ordered list of {col,row}
    self.goalTiles = {}
    self.mechanismTiles = {}
    self.tunnelsById = {}  -- id -> array of {col,row} (normally exactly 2 -- an entrance and its exit)
    self.cageGroups = {}   -- id -> { buttons = {{col,row},...}, cages = {{col,row},...} }

    for r = 1, self.rows do
        self.tiles[r] = {}
        local rowStr = levelRows[r]
        for c = 1, self.cols do
            local ch = rowStr:sub(c, c)
            local tileType = chessMap.LEGEND_CHARS[ch] or chessMap.TILE.EMPTY
            local tile = { type = tileType }

            if tileType == chessMap.TILE.HAZARD then
                tile.sinkTimer = self.sinkTurns
            elseif tileType == chessMap.TILE.SPAWN_PC then
                table.insert(self.spawnPCs, { col = c, row = r })
            elseif tileType == chessMap.TILE.SPAWN_ENEMY then
                table.insert(self.spawnEnemies, { col = c, row = r })
            elseif tileType == chessMap.TILE.GOAL then
                table.insert(self.goalTiles, { col = c, row = r })
            elseif tileType == chessMap.TILE.MECHANISM then
                table.insert(self.mechanismTiles, { col = c, row = r })
            end

            self.tiles[r][c] = tile
        end
    end

    -- tunnel pairing: opts.tunnels = { {id=,col=,row=}, ... } -- each entry
    -- tags the TUNNEL tile already placed there (via the "T" legend char)
    -- with which pair it belongs to, so :getTunnelExit can find the other end.
    for _, t in ipairs(opts.tunnels or {}) do
        local tile = self.tiles[t.row] and self.tiles[t.row][t.col]
        assert(tile and tile.type == chessMap.TILE.TUNNEL,
            "chessMap: opts.tunnels entry at (" .. t.col .. "," .. t.row .. ") isn't a TUNNEL ('T') tile")
        tile.tunnelId = t.id
        self.tunnelsById[t.id] = self.tunnelsById[t.id] or {}
        table.insert(self.tunnelsById[t.id], { col = t.col, row = t.row })
    end

    -- cage pairing: opts.cages = { {id=, kind="button"|"cage", col=, row=}, ... }
    -- -- tags the already-placed CAGE ('C') / CAGE_BUTTON ('B') tile with
    -- which group it belongs to. A group can have several buttons and/or
    -- several cage tiles sharing one id; :tickCageGroup (driven by
    -- chessUpdtr) opens every cage tile in a group whenever any of its
    -- button tiles is occupied by a pawn, and closes them again once none are.
    for _, c in ipairs(opts.cages or {}) do
        local tile = self.tiles[c.row] and self.tiles[c.row][c.col]
        local wantType = (c.kind == "button") and chessMap.TILE.CAGE_BUTTON or chessMap.TILE.CAGE
        assert(tile and tile.type == wantType,
            "chessMap: opts.cages entry at (" .. c.col .. "," .. c.row .. ") isn't a " ..
            (c.kind == "button" and "CAGE_BUTTON ('B')" or "CAGE ('C')") .. " tile")
        self.cageGroups[c.id] = self.cageGroups[c.id] or { buttons = {}, cages = {} }
        local list = (c.kind == "button") and self.cageGroups[c.id].buttons or self.cageGroups[c.id].cages
        table.insert(list, { col = c.col, row = c.row })
    end

    self.tileVisuals = {} -- [row][col] = { bg=rect, overlay=image|nil }

    return self
end

-- --------------------------------------------------------------- GEOMETRY
function chessMap:gridToWorld(col, row)
    local x = self.originX + (col - 0.5) * self.tileSize
    local y = self.originY + (row - 0.5) * self.tileSize
    return x, y
end

function chessMap:worldToGrid(x, y)
    local col = math.floor((x - self.originX) / self.tileSize) + 1
    local row = math.floor((y - self.originY) / self.tileSize) + 1
    return col, row
end

function chessMap:isInBounds(col, row)
    return col >= 1 and col <= self.cols and row >= 1 and row <= self.rows
end

-- ------------------------------------------------------------------ QUERY
function chessMap:getTile(col, row)
    if not self:isInBounds(col, row) then return nil end
    return self.tiles[row][col]
end

-- pawn is optional -- pass the pawn attempting to enter (col,row) so a Tiny
-- Size one can pass through JAIL/WALL_HOLE/TUNNEL tiles; omit it (or pass a
-- non-Tiny pawn) to get "blocked for everyone" behavior, which is correct
-- for generic checks that aren't about a specific mover (chain-push/pull
-- landings currently use it this way -- see chessUpdtr).
function chessMap:isWalkable(col, row, pawn)
    local tile = self:getTile(col, row)
    if not tile then return false end
    if tile.type == chessMap.TILE.WALL or tile.type == chessMap.TILE.VOID then return false end
    if tile.type == chessMap.TILE.CAGE then return false end -- closed gate: blocks like a wall
    if TINY_ONLY_TILES[tile.type] then
        return pawn ~= nil and pawn.traits ~= nil and pawn.traits["tiny_size"] == true
    end
    return true
end

function chessMap:isBlocking(col, row)
    -- true if a straight-line effect (like Fire Beam) should stop here.
    -- JAIL/WALL_HOLE/TUNNEL are all physically slim enough to see through
    -- (bars, a hole, a tunnel mouth) -- only a solid WALL or closed CAGE
    -- blocks sight.
    local tile = self:getTile(col, row)
    if not tile then return true end
    return tile.type == chessMap.TILE.WALL or tile.type == chessMap.TILE.CAGE
end

-- Returns the OTHER end of a paired tunnel (col,row belongs to), or nil if
-- this isn't a paired tunnel tile. If more than two tiles share an id
-- (unusual), returns the first other one found.
function chessMap:getTunnelExit(col, row)
    local tile = self:getTile(col, row)
    if not tile or tile.type ~= chessMap.TILE.TUNNEL or not tile.tunnelId then return nil end
    local group = self.tunnelsById[tile.tunnelId]
    if not group then return nil end
    for _, spot in ipairs(group) do
        if spot.col ~= col or spot.row ~= row then
            return spot.col, spot.row
        end
    end
    return nil
end

-- ------------------------------------------------------------------- DRAW
-- draws all terrain tiles into parentGroup; returns the group used
function chessMap:draw(parentGroup)
    local group = display.newGroup()
    parentGroup:insert(group)
    self.displayGroup = group

    for r = 1, self.rows do
        self.tileVisuals[r] = {}
        for c = 1, self.cols do
            local tile = self.tiles[r][c]
            local x, y = self:gridToWorld(c, r)

            local bg = display.newRect(group, x, y, self.tileSize - 1, self.tileSize - 1)
            local col3 = TILE_COLORS[tile.type] or TILE_COLORS[chessMap.TILE.EMPTY]
            bg:setFillColor(col3[1], col3[2], col3[3])
            bg.strokeWidth = 1
            bg:setStrokeColor(0, 0, 0, 0.35)

            local overlay = nil
            local imgPath = TILE_OVERLAY_IMAGE[tile.type]
            if imgPath then
                -- display.newImageRect returns nil (not an error) if the
                -- image file is missing -- fall back to the solid-color
                -- tile rather than crashing on a not-yet-added asset.
                overlay = display.newImageRect(group, imgPath, self.tileSize * 0.8, self.tileSize * 0.8)
                if overlay then
                    overlay.x, overlay.y = x, y
                end
            end

            self.tileVisuals[r][c] = { bg = bg, overlay = overlay }
        end
    end

    return group
end

-- refresh a single tile's visuals (used after a hazard sinks, etc.)
function chessMap:refreshTile(col, row)
    local tile = self.tiles[row][col]
    local vis = self.tileVisuals[row] and self.tileVisuals[row][col]
    if not vis then return end

    local col3 = TILE_COLORS[tile.type] or TILE_COLORS[chessMap.TILE.EMPTY]
    vis.bg:setFillColor(col3[1], col3[2], col3[3])

    if vis.overlay then
        vis.overlay:removeSelf()
        vis.overlay = nil
    end
    local imgPath = TILE_OVERLAY_IMAGE[tile.type]
    if imgPath then
        local x, y = self:gridToWorld(col, row)
        local overlay = display.newImageRect(self.displayGroup, imgPath, self.tileSize * 0.8, self.tileSize * 0.8)
        if overlay then
            overlay.x, overlay.y = x, y
        end
        vis.overlay = overlay
    end
end

-- ------------------------------------------------------------- SINK TICK
-- advances hazard countdowns; called once per full turn by chessUpdtr.
-- returns an array of {col,row} tiles that sank this tick (VOID now), so
-- chessUpdtr can check whether any pawn needs to be dropped/destroyed.
function chessMap:tickHazards()
    local sunk = {}
    for r = 1, self.rows do
        for c = 1, self.cols do
            local tile = self.tiles[r][c]
            if tile.type == chessMap.TILE.HAZARD and tile.sinkTimer then
                tile.sinkTimer = tile.sinkTimer - 1
                if tile.sinkTimer <= 0 then
                    tile.type = chessMap.TILE.VOID
                    tile.sinkTimer = nil
                    self:refreshTile(c, r)
                    table.insert(sunk, { col = c, row = r })
                end
            end
        end
    end
    return sunk
end

function chessMap:getGoalTiles()
    return self.goalTiles
end

-- Opens or closes every CAGE tile in group `groupId` (a no-op for any tile
-- already in that state, so it's safe to call every turn regardless of
-- whether anything actually changed). See chessUpdtr:tickCages, which
-- decides `isOpen` per group by checking its button tiles for occupants.
function chessMap:setCageOpen(groupId, isOpen)
    local group = self.cageGroups[groupId]
    if not group then return end
    local wantType = isOpen and chessMap.TILE.CAGE_OPEN or chessMap.TILE.CAGE
    for _, spot in ipairs(group.cages) do
        local tile = self.tiles[spot.row][spot.col]
        if tile.type ~= wantType then
            tile.type = wantType
            self:refreshTile(spot.col, spot.row)
        end
    end
end

return chessMap
