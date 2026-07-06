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

    Why the math is this simple: main.lua puts the whole board (map tiles +
    pawns) inside `worldGroup`, which itself is the sole child of a
    display.newContainer() clipped to the viewport rectangle and positioned
    at the viewport's center on screen. Because every tile/pawn's local
    x/y comes from chessMap:gridToWorld() with origin (0,0), the container's
    own screen position cancels out of the centering math -- to put world
    point (wx, wy) at the center of the viewport, you just set
    worldGroup.x, worldGroup.y = -wx, -wy. Clamping keeps that point within
    [viewportDim/2, worldDim - viewportDim/2] so the container's clip never
    shows past the map's edge.
]]

local camera = {}
camera.__index = camera

-- opts: { worldGroup, worldW, worldH, viewportW, viewportH, panTime }
function camera.new(opts)
    opts = opts or {}
    local self = setmetatable({}, camera)
    self.worldGroup = opts.worldGroup
    self.worldW = opts.worldW
    self.worldH = opts.worldH
    self.viewportW = opts.viewportW
    self.viewportH = opts.viewportH
    self.panTime = opts.panTime or 180
    self.focusX = self.worldW / 2
    self.focusY = self.worldH / 2
    return self
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

-- Pans (animated by default) so world point (worldX, worldY) ends up at
-- the center of the viewport, clamped to the map's bounds.
-- opts: { instant = true } to snap immediately (e.g. on level load).
function camera:focusOn(worldX, worldY, opts)
    opts = opts or {}
    self.focusX = clampAxis(worldX, self.worldW, self.viewportW)
    self.focusY = clampAxis(worldY, self.worldH, self.viewportH)

    local targetX, targetY = -self.focusX, -self.focusY
    if opts.instant or not transition then
        self.worldGroup.x, self.worldGroup.y = targetX, targetY
    else
        transition.to(self.worldGroup, { x = targetX, y = targetY, time = self.panTime, transition = easing.outQuad })
    end
end

return camera
