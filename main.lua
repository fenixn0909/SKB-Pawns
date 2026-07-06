--[[
    main.lua -- Order of the Sinking Star (mockup)

    Wires chessMap + pawnDplyr + pawnCon + abltMng + chessUpdtr together
    into one playable demo scene. See modules/ for the actual systems --
    this file is just the assembly + a minimal sidebar UI.
]]

display.setDefault("background", 0.05, 0.05, 0.07)

local chessMap    = require("modules.chessMap")
local pawnDplyr   = require("modules.pawnDplyr")
local pawnCon     = require("modules.pawnCon")
local abltMng     = require("modules.abltMng")
local chessUpdtr  = require("modules.chessUpdtr")
local sampleLevel = require("data.sampleLevel")

abltMng.registerDefaults()

-- ------------------------------------------------------------------ TITLE
local titleText = display.newText({
    text = "ORDER OF THE SINKING STAR", x = display.contentCenterX, y = 18,
    font = native.systemFontBold, fontSize = 20,
})
titleText:setFillColor(0.85, 0.85, 0.95)

-- -------------------------------------------------------------- BOARD/MAP
local BOARD_X, BOARD_Y = 10, 46
local BOARD_W, BOARD_H = 1000, 654

local map = chessMap.new(sampleLevel.rows, {
    originX = BOARD_X, originY = BOARD_Y,
    availableWidth = BOARD_W, availableHeight = BOARD_H,
})

local mapGroup = display.newGroup()
map:draw(mapGroup)

-- invisible full-board rect that catches taps on empty tiles; pawns sit
-- above it in the display list so they intercept their own taps first
local boardPixelW, boardPixelH = map.tileSize * map.cols, map.tileSize * map.rows
local boardCenterX = map.originX + boardPixelW / 2
local boardCenterY = map.originY + boardPixelH / 2
local boardHit = display.newRect(boardCenterX, boardCenterY, boardPixelW, boardPixelH)
boardHit:setFillColor(1, 1, 1, 0.01)

local pawnGroup = display.newGroup()

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
local SIDEBAR_X = BOARD_X + BOARD_W + 10
local SIDEBAR_W = display.contentWidth - SIDEBAR_X - 10

local sidebarBg = display.newRect(SIDEBAR_X + SIDEBAR_W / 2, 46 + BOARD_H / 2, SIDEBAR_W, BOARD_H)
sidebarBg:setFillColor(0.11, 0.11, 0.14)
sidebarBg.strokeWidth = 1
sidebarBg:setStrokeColor(0.3, 0.3, 0.35)

local uiGroup = display.newGroup()
local uiY = 30

local function nextY(step) uiY = uiY + step; return uiY end

local turnLabel = display.newText({
    parent = uiGroup, text = "Turn: Player (Round 1)",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 10, font = native.systemFontBold, fontSize = 16,
})
turnLabel:setFillColor(0.9, 0.85, 0.5)

local selectedLabel = display.newText({
    parent = uiGroup, text = "Selected: --",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 40, font = native.systemFontBold, fontSize = 15,
    width = SIDEBAR_W - 20,
})
selectedLabel:setFillColor(1, 1, 1)

local modeLabel = display.newText({
    parent = uiGroup, text = "Mode: Move (tap a tile)",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + 66, font = native.systemFont, fontSize = 13,
    width = SIDEBAR_W - 20,
})
modeLabel:setFillColor(0.6, 0.85, 1)

-- ability buttons: rebuilt every time selection changes
local abilityButtons = {}
local ABILITY_BUTTON_TOP = BOARD_Y + 100
local ABILITY_BUTTON_H = 40

local function clearAbilityButtons()
    for _, btn in ipairs(abilityButtons) do btn:removeSelf() end
    abilityButtons = {}
end

local function makeButton(parent, x, y, w, h, label, onTap, fillColor)
    local group = display.newGroup()
    parent:insert(group)

    local bg = display.newRoundedRect(group, x, y, w, h, 6)
    bg:setFillColor(unpack(fillColor))
    bg.strokeWidth = 1
    bg:setStrokeColor(0.05, 0.05, 0.06)

    local label_ = display.newText({ parent = group, text = label, x = x, y = y, font = native.systemFontBold, fontSize = 14 })
    label_:setFillColor(1, 1, 1)

    bg:addEventListener("tap", function() onTap(); return true end)
    return group
end

local function refreshAbilityButtons(pawn)
    clearAbilityButtons()
    if not pawn then return end
    local defs = abltMng.getAbilitiesForPawn(pawn)
    local y = ABILITY_BUTTON_TOP
    for _, def in ipairs(defs) do
        local btn = makeButton(uiGroup, SIDEBAR_X + SIDEBAR_W / 2, y, SIDEBAR_W - 30, ABILITY_BUTTON_H,
            def.name, function() con:beginAbility(def.id) end, { 0.20, 0.30, 0.45 })
        table.insert(abilityButtons, btn)
        y = y + ABILITY_BUTTON_H + 10
    end
end

local function updateSelectedLabel(pawn)
    if not pawn then
        selectedLabel.text = "Selected: --"
        return
    end
    local hpText = pawn.hp and (pawn.hp .. "/" .. pawn.maxHp) or "--"
    selectedLabel.text = string.format("Selected: %s (HP %s)", pawn.name, hpText)
end

-- End Turn button pinned near the bottom of the sidebar
local endTurnBtn = makeButton(uiGroup, SIDEBAR_X + SIDEBAR_W / 2, BOARD_Y + BOARD_H - 70,
    SIDEBAR_W - 30, 44, "End Turn", function() updtr:endTurn() end, { 0.45, 0.20, 0.20 })

local logText = display.newText({
    parent = uiGroup, text = "Tab / 1-9: switch pawn -- Esc: cancel ability",
    x = SIDEBAR_X + SIDEBAR_W / 2, y = BOARD_Y + BOARD_H - 25, font = native.systemFont, fontSize = 12,
    width = SIDEBAR_W - 20,
})
logText:setFillColor(0.7, 0.7, 0.75)

-- --------------------------------------------------------------- EVENTS
Runtime:addEventListener("pawnSelected", function(event)
    local pawn = dplyr:getById(event.pawnId)
    updateSelectedLabel(pawn)
    refreshAbilityButtons(pawn)
end)

Runtime:addEventListener("controlModeChanged", function(event)
    if event.mode == "ability" then
        local def = abltMng.get(event.abilityId)
        modeLabel.text = "Targeting: " .. def.name .. " -- tap a target (Esc cancels)"
    else
        modeLabel.text = "Mode: Move (tap a tile)"
    end
end)

Runtime:addEventListener("turnChanged", function(event)
    local who = (event.turn == "pc") and "Player" or "Enemy"
    turnLabel.text = string.format("Turn: %s (Round %d)", who, event.round)
end)

Runtime:addEventListener("abilityResolved", function(event)
    logText.text = event.success and "Ability resolved." or "Ability failed / invalid target."
    -- keep selected pawn's HP label in sync (abilities can change HP, e.g. beams)
    updateSelectedLabel(con:getSelected())
end)

Runtime:addEventListener("levelCleared", function()
    logText.text = "LEVEL CLEARED!"
end)

Runtime:addEventListener("levelFailed", function()
    logText.text = "ALL PCS LOST -- LEVEL FAILED"
end)

-- ------------------------------------------------------------- KICK OFF
local firstPCs = dplyr:getAllByFaction("pc")
table.sort(firstPCs, function(a, b) return a.id < b.id end)
if firstPCs[1] then
    con:select(firstPCs[1].id)
end
