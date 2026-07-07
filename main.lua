--[[
    main.lua -- SKB Pawns (mockup)

    Wires chessMap + pawnDplyr + pawnCon + abltMng + chessUpdtr + camera +
    traitMng + historyMng together into one playable demo scene. See
    modules/ for the actual systems -- this file is just the assembly + a
    thin sidebar UI.
]]

display.setDefault("background", 0.05, 0.05, 0.07)

local chessMap    = require("modules.chessMap")
local pawnDplyr   = require("modules.pawnDplyr")
local pawnCon     = require("modules.pawnCon")
local abltMng     = require("modules.abltMng")
local chessUpdtr  = require("modules.chessUpdtr")
local camera      = require("modules.camera")
local traitMng    = require("modules.traitMng")
local historyMng  = require("modules.historyMng")
local sampleLevel = require("data.sampleLevel")

abltMng.registerDefaults()
traitMng.registerDefaults()

-- ------------------------------------------------------------------ TITLE
local titleText = display.newText({
    text = "SKB PAWNS", x = display.contentCenterX, y = 18,
    font = native.systemFontBold, fontSize = 20,
})
titleText:setFillColor(0.85, 0.85, 0.95)

-- -------------------------------------------------------------- BOARD/MAP
-- Tile size is computed so the entire map fits inside the board area.
-- No camera panning needed -- the map sits centered in the board.
local BOARD_X, BOARD_Y = 8, 40
local SIDEBAR_W = 150
local BOARD_W = display.contentWidth - BOARD_X - SIDEBAR_W - 16
local BOARD_H = display.contentHeight - BOARD_Y - 10
local SIDEBAR_X = BOARD_X + BOARD_W + 8

local NUM_COLS = #sampleLevel.rows[1]
local NUM_ROWS = #sampleLevel.rows
local TILE_SIZE = math.floor(math.min(BOARD_W / NUM_COLS, BOARD_H / NUM_ROWS))

local map = chessMap.new(sampleLevel.rows, { tileSize = TILE_SIZE })

-- Board background: fills the board area so any map underflow is clean.
local boardBg = display.newRect(BOARD_X + BOARD_W / 2, BOARD_Y + BOARD_H / 2, BOARD_W, BOARD_H)
boardBg:setFillColor(0.05, 0.05, 0.07)

-- worldGroup holds everything board-related (tiles, tap rect, pawns).
-- It sits directly on stage; the sidebar and title overlay on top handle
-- any right/top overflow. No container clipping needed.
local worldGroup = display.newGroup()

map:draw(worldGroup)

-- invisible full-map-sized rect that catches taps on empty tiles; pawns
-- sit above it in the display list so they intercept their own taps first
-- Positioned at (0,0) so boardHit:contentToLocal() returns map-world coords.
local boardHit = display.newRect(0, 0, map.pixelW, map.pixelH)
boardHit:setFillColor(1, 1, 1, 0.01)
worldGroup:insert(boardHit)

local pawnGroup = display.newGroup()
worldGroup:insert(pawnGroup)

local cam = camera.new({
    worldGroup = worldGroup,
    worldW = map.pixelW, worldH = map.pixelH,
    viewportW = BOARD_W, viewportH = BOARD_H,
    boardCenterX = BOARD_X + BOARD_W / 2,
    boardCenterY = BOARD_Y + BOARD_H / 2,
    panTime = 180,
})

local function focusCameraOnGrid(col, row, opts)
    local wx, wy = map:gridToWorld(col, row)
    cam:focusOn(wx, wy, opts)
end

-- ------------------------------------------------------------------ PAWNS
local dplyr = pawnDplyr.new(map, pawnGroup)
dplyr:autoDeployFromMap(sampleLevel.assignments)
for _, extra in ipairs(sampleLevel.extras) do
    dplyr:deploy(extra.kind, extra.col, extra.row)
end

-- ------------------------------------------------------------------ LOGIC
local updtr = chessUpdtr.new(map, dplyr)
local con = pawnCon.new(dplyr, map, updtr, boardHit)

for _, pawn in pairs(dplyr.pawns) do
    con:registerSelectable(pawn)
end

-- ------------------------------------------------------------------- UI
-- Thin sidebar: just status text now. Push/Swap/Pull are automatic
-- (movingAbility), and Guard/End Turn/Undo/Redo/Restart are keyboard
-- shortcuts (see the hotkeys line below and pawnCon's "g" handling) --
-- there's nothing left that needs a big button strip blocking the board.
local sidebarGroup = display.newGroup()

local sidebarBg = display.newRect(sidebarGroup, SIDEBAR_X + SIDEBAR_W / 2, BOARD_Y + BOARD_H / 2, SIDEBAR_W, BOARD_H)
sidebarBg:setFillColor(0.11, 0.11, 0.14)
sidebarBg.strokeWidth = 1
sidebarBg:setStrokeColor(0.3, 0.3, 0.35)

local turnLabel = display.newText({
    parent = sidebarGroup, text = "Turn: Player (Round 1)",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 16, font = native.systemFontBold, fontSize = 14,
    width = SIDEBAR_W - 16,
})
turnLabel:setFillColor(0.9, 0.85, 0.5)

local selectedLabel = display.newText({
    parent = sidebarGroup, text = "Selected: --",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 50, font = native.systemFontBold, fontSize = 13,
    width = SIDEBAR_W - 16,
})
selectedLabel:setFillColor(1, 1, 1)

local modeLabel = display.newText({
    parent = sidebarGroup, text = "Mode: Move",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 84, font = native.systemFont, fontSize = 12,
    width = SIDEBAR_W - 16,
})
modeLabel:setFillColor(0.6, 0.85, 1)

local logText = display.newText({
    parent = sidebarGroup, text = "",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + BOARD_H - 90, font = native.systemFont, fontSize = 12,
    width = SIDEBAR_W - 16,
})
logText:setFillColor(0.75, 0.9, 0.75)

local hotkeysText = display.newText({
    parent = sidebarGroup,
    text = "Tab/1-9 switch\nArrows/tap move\nG guard  E end turn\n, undo  . redo\nR restart\n+/- zoom",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + BOARD_H - 34, font = native.systemFont, fontSize = 11,
    width = SIDEBAR_W - 16,
})
hotkeysText:setFillColor(0.6, 0.6, 0.66)

local function updateSelectedLabel(pawn)
    if not pawn then
        selectedLabel.text = "Selected: --"
        return
    end
    local hpText = pawn.hp and (pawn.hp .. "/" .. pawn.maxHp) or "--"
    selectedLabel.text = string.format("%s\nHP %s", pawn.name, hpText)
end

-- small show/hide toggle for the sidebar, pinned outside sidebarGroup so
-- it stays put (and tappable) even while the sidebar itself is hidden
local sidebarVisible = true
local toggleBtn = display.newGroup()
local TOGGLE_X, TOGGLE_Y = display.contentWidth - 20, 20
local toggleBg = display.newRoundedRect(toggleBtn, TOGGLE_X, TOGGLE_Y, 28, 28, 6)
toggleBg:setFillColor(0.2, 0.2, 0.26)
toggleBg.strokeWidth = 1
toggleBg:setStrokeColor(0.4, 0.4, 0.46)
local toggleLabel = display.newText({
    parent = toggleBtn, text = "»", x = TOGGLE_X, y = TOGGLE_Y, font = native.systemFontBold, fontSize = 16,
})
toggleLabel:setFillColor(0.85, 0.85, 0.9)

local function setSidebarVisible(visible)
    sidebarVisible = visible
    sidebarGroup.isVisible = visible
    toggleLabel.text = visible and "»" or "«"
end

toggleBg:addEventListener("tap", function()
    setSidebarVisible(not sidebarVisible)
    return true
end)

-- --------------------------------------------------------------- HISTORY
-- Full-state undo/redo/restart -- see modules/historyMng.lua. A snapshot
-- is taken after every move/ability/completed round via
-- updtr.onStateChanged; the very first snapshot (below, after this block)
-- is the level's starting state, which Restart jumps back to.
local history = historyMng.new(map, dplyr, updtr)

history.onPawnRecreated = function(pawn)
    con:registerSelectable(pawn)
end

history.onApplied = function()
    local stillSelected = con.selectedId and dplyr:getById(con.selectedId)
    if stillSelected then
        con:select(con.selectedId)
    else
        local pcs = dplyr:getAllByFaction("pc")
        table.sort(pcs, function(a, b) return a.id < b.id end)
        if pcs[1] then con:select(pcs[1].id) end
    end

    local selPawn = con:getSelected()
    if selPawn then focusCameraOnGrid(selPawn.col, selPawn.row, { instant = true }) end

    local who = (updtr.turn == "pc") and "Player" or "Enemy"
    turnLabel.text = string.format("Turn: %s (Round %d)", who, updtr.roundNumber)
    logText.text = "History restored."
end

updtr.onStateChanged = function() history:snapshot() end

-- --------------------------------------------------------------- EVENTS
Runtime:addEventListener("pawnSelected", function(event)
    local pawn = dplyr:getById(event.pawnId)
    updateSelectedLabel(pawn)
    if pawn then focusCameraOnGrid(pawn.col, pawn.row) end
end)

Runtime:addEventListener("pawnMoved", function(event)
    if event.pawnId == con.selectedId then
        focusCameraOnGrid(event.col, event.row)
    end
    updateSelectedLabel(con:getSelected())
end)

Runtime:addEventListener("controlModeChanged", function(event)
    if event.mode == "ability" then
        local def = abltMng.get(event.abilityId)
        modeLabel.text = "Targeting: " .. def.name .. " (Esc cancels)"
    else
        modeLabel.text = "Mode: Move"
    end
end)

Runtime:addEventListener("turnChanged", function(event)
    local who = (event.turn == "pc") and "Player" or "Enemy"
    turnLabel.text = string.format("Turn: %s (Round %d)", who, event.round)
end)

Runtime:addEventListener("abilityResolved", function(event)
    logText.text = event.success and "Ability resolved." or "Ability failed / invalid target."
    updateSelectedLabel(con:getSelected())
end)

Runtime:addEventListener("levelCleared", function()
    logText.text = "LEVEL CLEARED!"
end)

Runtime:addEventListener("levelFailed", function()
    logText.text = "ALL PCS LOST -- LEVEL FAILED"
end)

-- meta/app-level keys: end turn, undo/redo, restart -- separate from
-- pawnCon's per-pawn input handling (movement, guard, selection)
Runtime:addEventListener("key", function(event)
    if event.phase ~= "down" then return false end
    local key = event.keyName
    if key == "e" then
        updtr:endTurn()
        return true
    elseif key == "," or key == "comma" then
        history:undo()
        return true
    elseif key == "." or key == "period" then
        history:redo()
        return true
    elseif key == "r" then
        history:restart()
        return true
    elseif key == "+" or key == "=" then
        cam:setZoom(cam:getZoom() * 1.25)
        return true
    elseif key == "-" or key == "_" then
        cam:setZoom(cam:getZoom() / 1.25)
        return true
    end
    return false
end)

-- ------------------------------------------------------------- KICK OFF
local firstPCs = dplyr:getAllByFaction("pc")
table.sort(firstPCs, function(a, b) return a.id < b.id end)
if firstPCs[1] then
    focusCameraOnGrid(firstPCs[1].col, firstPCs[1].row, { instant = true })
    con:select(firstPCs[1].id)
end

-- level-start baseline snapshot -- Restart (R) jumps back to this
history:snapshot()
