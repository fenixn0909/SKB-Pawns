--[[
    corona_stub.lua -- NOT part of the game. A minimal fake of the Solar2D
    display/transition/Runtime APIs so the game logic modules can be
    required and exercised with plain Lua/texlua, headlessly, for testing.
    transition.to applies changes immediately (no real animation needed).
]]

local function fakeDisplayObject(extra)
    local obj = extra or {}
    obj.x = obj.x or 0
    obj.y = obj.y or 0
    obj.rotation = obj.rotation or 0
    obj._listeners = {}
    function obj:addEventListener(kind, fn) self._listeners[kind] = fn end
    function obj:removeSelf() obj._removed = true end
    function obj:setFillColor(...) end
    function obj:setStrokeColor(...) end
    function obj:insert(child) end
    function obj:toBack() end
    function obj:toFront() end
    -- Real Solar2D converts content(stage) coords into this object's local
    -- coordinate space, accounting for any parent group transforms. The
    -- stub has no real transform stack, so it's a no-op identity mapping --
    -- fine for headless tests, which drive logic via grid coordinates
    -- directly rather than simulated taps.
    function obj:contentToLocal(x, y) return x, y end
    return obj
end

display = {}
display.contentWidth = 1280
display.contentHeight = 720
display.contentCenterX = 640
display.contentCenterY = 360
function display.setDefault(...) end

function display.newGroup()
    return fakeDisplayObject({})
end

function display.newContainer(w, h)
    return fakeDisplayObject({ width = w, height = h })
end

function display.newRect(parentOrX, xOrY, yOrW, wOrH, h)
    -- support both (x,y,w,h) and (parent,x,y,w,h) call signatures
    local obj = fakeDisplayObject({})
    return obj
end
display.newRoundedRect = display.newRect

function display.newImageRect(a, b, c, d)
    return fakeDisplayObject({})
end

function display.newPolygon(parentOrX, xOrY, yOrVertices, vertices)
    -- supports both (parent, x, y, vertices) and (x, y, vertices) signatures
    return fakeDisplayObject({})
end

function display.newCircle(parentOrX, xOrY, yOrRadius, radius)
    return fakeDisplayObject({})
end

function display.newText(params)
    local obj = fakeDisplayObject({ text = params and params.text or "" })
    return obj
end

native = { systemFont = "font", systemFontBold = "fontBold" }

transition = {}
function transition.to(obj, params)
    if not obj then return end
    for k, v in pairs(params) do
        if k ~= "time" and k ~= "transition" and k ~= "onComplete" then
            obj[k] = v
        end
    end
    if params.onComplete then params.onComplete(obj) end
end
function transition.cancel(obj) end

easing = { outQuad = "outQuad", inQuad = "inQuad", inOutQuad = "inOutQuad" }

-- timer.performWithDelay applies immediately (no real async needed for
-- headless tests) -- mirrors transition.to's "apply immediately" stance.
timer = {}
function timer.performWithDelay(delay, fn, iterations)
    if fn then fn() end
    return { cancelled = false }
end
function timer.cancel(handle) end

local listeners = {}
Runtime = {}
function Runtime:addEventListener(kind, fn)
    listeners[kind] = listeners[kind] or {}
    table.insert(listeners[kind], fn)
end
function Runtime:dispatchEvent(event)
    local hs = listeners[event.name] or {}
    for _, fn in ipairs(hs) do fn(event) end
end

print("[corona_stub] fake Solar2D environment loaded")
