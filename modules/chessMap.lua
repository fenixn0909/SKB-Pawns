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
}

-- terrain types that get an overlay sprite drawn on top of the floor color
local TILE_OVERLAY_IMAGE = {
    [chessMap.TILE.WALL]      = "images/wall.png",
    [chessMap.TILE.MECHANISM] = "images/mechanism_gear.png",
    [chessMap.TILE.GOAL]      = "images/goal_star.png",
    [chessMap.TILE.HAZARD]    = "images/hazard_sink.png",
}

-- default number of turns a HAZARD tile survives before sinking to VOID
local DEFAULT_SINK_TURNS = 4

-- -------------------------------------------------------------------- NEW
-- levelRows: array of equal-length strings, one per map row, using LEGEND_CHARS
-- opts: { tileSize, originX, originY, sinkTurns }
--
-- Tile size is now FIXED (not scaled to fit an available viewport) -- the
-- world can be larger than the screen, and modules/camera.lua is what pans
-- a scrollable viewport around it. originX/originY default to 0 (the map's
-- own coordinate frame); a non-zero origin is still supported for anyone
-- drawing a map without a camera (e.g. a future minimap), but main.lua's
-- normal setup leaves them at 0 and lets the camera do all positioning.
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

    self.tiles = {}       -- tiles[row][col] = { type = TILE.xxx, sinkTimer = n|nil }
    self.spawnPCs = {}     -- ordered list of {col,row}
    self.spawnEnemies = {} -- ordered list of {col,row}
    self.goalTiles = {}
    self.mechanismTiles = {}

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

function chessMap:isWalkable(col, row)
    local tile = self:getTile(col, row)
    if not tile then return false end
    return tile.type ~= chessMap.TILE.WALL and tile.type ~= chessMap.TILE.VOID
end

function chessMap:isBlocking(col, row)
    -- true if a straight-line effect (like Fire Beam) should stop here
    local tile = self:getTile(col, row)
    if not tile then return true end
    return tile.type == chessMap.TILE.WALL
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
                overlay = display.newImageRect(group, imgPath, self.tileSize * 0.8, self.tileSize * 0.8)
                overlay.x, overlay.y = x, y
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
        overlay.x, overlay.y = x, y
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

return chessMap
