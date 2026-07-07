--[[
    camera.lua

    A scrolling, clamped camera for the board viewport. It pans a "world"
    display group so a chosen world-space point (in practice, the selected
    PC) sits at the center of the viewport, clamping so the map's edges
    never scroll past into empty space. If the map is smaller than the
    viewport on an axis, that axis is simply centered once and never
    scrolls again -- exactly today's sampleLevel, which fits entirely on
    screen, so nothing *visibly* changes for it. The payoff shows up on any
    future level bigger than the viewport.

    Also supports zoom (+/-). The zoom factor scales the world group and
    multiplies the offset so the focus point stays centered.

    Why the math is this simple: main.lua puts the whole board (map tiles +
    pawns) inside `worldGroup`, which itself is the sole child of a
    display.newContainer() clipped to the viewport rectangle and positioned
    at the viewport's center on screen. Because every tile/pawn's local
    x/y comes from chessMap:gridToWorld() with origin (0,0), the container's
    own screen position cancels out of the centering math -- to put world
    point (wx, wy) at the center of the viewport, you just set
    worldGroup.x, worldGroup.y = -wx * zoom, -wy * zoom. Clamping keeps that
    point within [viewportDim/2, worldDim - viewportDim/2] so the container's
    clip never shows past the map's edge.
]]

local camera = {}
camera.__index = camera

local ZOOM_MIN = 0.5
local ZOOM_MAX = 3.0

-- opts: { worldGroup, worldW, worldH, viewportW, viewportH, boardCenterX, boardCenterY, panTime }
function camera.new(opts)
    opts = opts or {}
    local self = setmetatable({}, camera)
    self.worldGroup = opts.worldGroup
    self.worldW = opts.worldW
    self.worldH = opts.worldH
    self.viewportW = opts.viewportW
    self.viewportH = opts.viewportH
    self.centerX = opts.boardCenterX or 0
    self.centerY = opts.boardCenterY or 0
    self.panTime = opts.panTime or 180
    self.focusX = self.worldW / 2
    self.focusY = self.worldH / 2
    self.zoom = 1
    return self
end

local function applyZoom(self)
    local targetX = self.centerX - self.focusX * self.zoom
    local targetY = self.centerY - self.focusY * self.zoom
    self.worldGroup.x, self.worldGroup.y = targetX, targetY
end

local function clampAxis(desired, worldDim, viewportDim)
    if worldDim <= viewportDim then
        return worldDim / 2 -- map fits inside the viewport on this axis: center it, never scroll
    end
    local minV, maxV = viewportDim / 2, worldDim - viewportDim / 2
    if desired < minV then return minV end
    if desired > maxV then return maxV end
    return desired
end

local function applyZoom(self)
    local targetX = -self.focusX * self.zoom
    local targetY = -self.focusY * self.zoom
    self.worldGroup.x, self.worldGroup.y = targetX, targetY
end

-- Pans (animated by default) so world point (worldX, worldY) ends up at
-- the center of the viewport, clamped to the map's bounds.
-- opts: { instant = true } to snap immediately (e.g. on level load).
function camera:focusOn(worldX, worldY, opts)
    opts = opts or {}
    self.focusX = clampAxis(worldX, self.worldW, self.viewportW)
    self.focusY = clampAxis(worldY, self.worldH, self.viewportH)

    local targetX, targetY = self.centerX - self.focusX * self.zoom, self.centerY - self.focusY * self.zoom
    if opts.instant or not transition then
        self.worldGroup.x, self.worldGroup.y = targetX, targetY
    else
        transition.to(self.worldGroup, { x = targetX, y = targetY, time = self.panTime, transition = easing.outQuad })
    end
end

function camera:setZoom(newZoom)
    local prevZoom = self.zoom
    self.zoom = math.max(ZOOM_MIN, math.min(ZOOM_MAX, newZoom))
    local ratio = self.zoom / prevZoom
    self.worldGroup:scale(ratio, ratio)
    applyZoom(self)
end

function camera:getZoom()
    return self.zoom
end

return camera
