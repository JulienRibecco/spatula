--- Demo 3: Signal Reactivity
--- Mouse position drives signals that modulate motion parameters in real-time.

local Curve = require("spatula.curve")
local Signal = require("spatula.signal")
local Motion = require("spatula.motion")

local S = Signal

local M = {}

local screenW, screenH
local time = 0
local entities = {}
local NUM_ENTITIES = 40

function M.load()
    screenW, screenH = love.graphics.getDimensions()

    -- Signals driven by mouse (these are curves: f(t,ctx) -> value)
    local radius = S("radius", 80)
    local speed = S("speed", 0.4)

    -- Build a reactive circle motion manually using curve combinators.
    -- Curve.cos/sin take numbers, so we compose: cos(t * speed * 2pi) * radius
    -- We use a raw function that reads the signal values at eval time.
    local PI2 = math.pi * 2
    local function reactiveCos(t, ctx)
        local r = radius(t, ctx)
        local s = speed(t, ctx)
        return math.cos(t * s * PI2) * r
    end
    local function reactiveSin(t, ctx)
        local r = radius(t, ctx)
        local s = speed(t, ctx)
        return math.sin(t * s * PI2) * r
    end
    local motionA = Motion.xy(reactiveCos, reactiveSin)

    -- A second motion: hover with signal-driven amplitude
    local hoverAmp = S("hoverAmp", 20)
    local function hoverX(t, ctx)
        local a = hoverAmp(t, ctx)
        return math.sin(t * 0.6 * PI2) * a
    end
    local function hoverY(t, ctx)
        local a = hoverAmp(t, ctx)
        return math.sin(t * 0.6 * 1.3 * PI2 + math.pi / 3) * a
    end
    local motionB = Motion.xy(hoverX, hoverY)

    -- Each entity gets a phase offset and uses the composed motion
    entities = {}
    for i = 1, NUM_ENTITIES do
        local phase = (i / NUM_ENTITIES) * math.pi * 2
        entities[i] = {
            phase = phase,
            motion = Motion.add(motionA, motionB),
            curveState = {},
            trail = {},
        }
    end
end

function M.update(dt)
    time = time + dt

    -- Map mouse X -> radius (40..200), mouse Y -> speed (0.1..1.5)
    local mx, my = love.mouse.getPosition()
    local radius = 40 + (mx / screenW) * 160
    local speed = 0.1 + (my / screenH) * 1.4
    local hoverAmp = 10 + (1 - my / screenH) * 50

    -- Set as globals so all Signal("radius") etc. resolve here
    S.setGlobal("radius", radius)
    S.setGlobal("speed", speed)
    S.setGlobal("hoverAmp", hoverAmp)

    for _, e in ipairs(entities) do
        local ctx = { curveState = e.curveState }
        local t = time + e.phase
        local x, y = e.motion(t, ctx)
        e.x = x
        e.y = y
        e.trail[#e.trail + 1] = { x = x, y = y }
        if #e.trail > 60 then table.remove(e.trail, 1) end
    end
end

function M.draw()
    local cx, cy = screenW / 2, screenH / 2

    -- Draw trails and dots
    for _, e in ipairs(entities) do
        for i, pt in ipairs(e.trail) do
            local alpha = i / #e.trail
            love.graphics.setColor(0.4, 0.6, 1.0, alpha * 0.3)
            love.graphics.circle("fill", cx + pt.x, cy + pt.y, 1.5)
        end
        if e.x then
            love.graphics.setColor(0.6, 0.85, 1.0, 1)
            love.graphics.circle("fill", cx + e.x, cy + e.y, 4)
        end
    end

    -- Crosshair at center
    love.graphics.setColor(0.4, 0.4, 0.4, 0.4)
    love.graphics.line(cx - 20, cy, cx + 20, cy)
    love.graphics.line(cx, cy - 20, cx, cy + 20)

    -- Info
    local mx, my = love.mouse.getPosition()
    local radius = 40 + (mx / screenW) * 160
    local speed = 0.1 + (my / screenH) * 1.4

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Signal Reactivity", 20, 20)
    love.graphics.print("Mouse drives motion parameters via Signal globals", 20, 42)
    love.graphics.print(string.format("radius = %.0f  |  speed = %.2f", radius, speed), 20, 64)

    -- Visual guide
    love.graphics.setColor(0.6, 0.6, 0.6, 1)
    love.graphics.print("Move mouse: X = orbit radius, Y = orbit speed", 20, screenH - 30)
end

function M.keypressed(key) end
function M.mousepressed() end

return M
