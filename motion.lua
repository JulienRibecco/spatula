--- Spatula Motion Module
--- @module spatula.motion
---
--- ============================================================================
--- Motion = f(t, ctx) → (x, y)
--- ============================================================================
---
--- A motion is TWO curves combined into a 2D signal.
---
--- PRIMITIVE:     xy(curveX, curveY)
--- COMBINATORS:   add, scale, rotate, mix
--- COMPOSITIONS:  circle, spiral, shake... all built from xy + Curve.*
---
--- The primitive xy() is the ONLY place where curves become motion.
--- Everything else composes from it.
---
--- ============================================================================

local U = require("spatula.util")
local Curve = require("spatula.curve")
local Motion = {}

local sin, cos, sqrt = U.sin, U.cos, U.sqrt
local PI2 = U.PI2

-- Helper: convert number to constant function (avoids repeated inline pattern)
local function asFunc(v)
    return type(v) == "number" and function() return v end or v
end

--------------------------------------------------------------------------------
-- PRIMITIVE
-- This is the single bridge from Curve to Motion.
--------------------------------------------------------------------------------

function Motion.xy(curveX, curveY)
    return function(t, ctx)
        return curveX(t, ctx), curveY(t, ctx)
    end
end

--------------------------------------------------------------------------------
-- COMBINATORS
-- Transform or combine motions. These work on (x,y) pairs.
--------------------------------------------------------------------------------

function Motion.add(...)
    local motions = {...}
    return function(t, ctx)
        local tx, ty = 0, 0
        for _, m in ipairs(motions) do
            local x, y = m(t, ctx)
            tx = tx + x
            ty = ty + y
        end
        return tx, ty
    end
end

function Motion.scale(motion, factor)
    local factorFn = asFunc(factor)
    return function(t, ctx)
        local f = factorFn(t, ctx)
        local x, y = motion(t, ctx)
        return x * f, y * f
    end
end

function Motion.rotate(motion, angleCurve)
    local angleFn = asFunc(angleCurve)
    return function(t, ctx)
        local x, y = motion(t, ctx)
        local a = angleFn(t, ctx)
        local c, s = cos(a), sin(a)
        return x * c - y * s, x * s + y * c
    end
end

function Motion.mix(motionA, motionB, factor)
    local factorFn = asFunc(factor)
    return function(t, ctx)
        local f = factorFn(t, ctx)
        local ax, ay = motionA(t, ctx)
        local bx, by = motionB(t, ctx)
        return ax * (1 - f) + bx * f, ay * (1 - f) + by * f
    end
end

--------------------------------------------------------------------------------
-- COMPOSITIONS
-- All built from xy() + Curve primitives. No raw math.
--
-- Pattern: define the motion in terms of what curves produce x and y.
--   circle  = (cos, sin)
--   spiral  = circle × growing scale factor
--   shake   = (noise, noise) with different seeds
--------------------------------------------------------------------------------

function Motion.circle(radius, speed)
    -- x = cos(t), y = sin(t), scaled by radius
    return Motion.xy(Curve.cos(speed, radius), Curve.sin(speed, radius))
end

function Motion.ellipse(radiusX, radiusY, speed)
    -- circle with different x/y radii
    return Motion.xy(Curve.cos(speed, radiusX), Curve.sin(speed, radiusY))
end

function Motion.spiral(radius, speed, growth)
    -- circle that grows over time
    -- scale = 1 + t*growth (starts at radius, increases)
    growth = growth or 1
    local scaleFactor = Curve.offset(Curve.linear(growth), 1)
    return Motion.scale(Motion.circle(radius, speed), scaleFactor)
end

function Motion.lissajous(freqX, freqY, ampX, ampY, phase)
    -- two independent sin waves create complex curves
    ampX = ampX or 1
    ampY = ampY or ampX
    phase = phase or (U.PI / 2)
    return Motion.xy(Curve.sin(freqX, ampX), Curve.sin(freqY, ampY, phase))
end

function Motion.figure8(size, speed)
    -- lissajous where y frequency = 2x frequency
    return Motion.lissajous(speed, speed * 2, size, size, 0)
end

function Motion.shake(intensity, speed)
    -- two noise curves with different seeds
    speed = speed or 10
    local noiseX = Curve.timeScale(Curve.noise(intensity, 0), speed)
    local noiseY = Curve.timeScale(Curve.noise(intensity, 12345), speed)
    return Motion.xy(noiseX, noiseY)
end

function Motion.drift(vx, vy)
    -- constant velocity: position = velocity × time
    vy = vy or 0
    return Motion.xy(Curve.linear(vx), Curve.linear(vy))
end

function Motion.hover(amount, speed)
    -- organic idle motion: slightly different frequencies create drift
    amount = amount or 5
    speed = speed or 0.5
    return Motion.xy(
        Curve.sin(speed, amount),
        Curve.sin(speed * 1.3, amount, U.PI / 3)
    )
end

function Motion.sway(amount, speed)
    -- horizontal oscillation only
    return Motion.xy(Curve.sin(speed, amount), Curve.const(0))
end

function Motion.bob(amount, speed)
    -- vertical oscillation only
    return Motion.xy(Curve.const(0), Curve.sin(speed, amount))
end

function Motion.wave(forward, amplitude, frequency)
    -- move forward while oscillating: snake-like
    return Motion.xy(Curve.linear(forward), Curve.sin(frequency, amplitude))
end

function Motion.bounce(height, speed)
    -- absolute value of sin creates bouncing (always positive)
    return Motion.xy(Curve.const(0), Curve.abs(Curve.sin(speed, height)))
end

--------------------------------------------------------------------------------
-- COMPOSITIONS: Unit-space motions for Patterns
-- These output in [-1,1] or [0,1] range, scaled by Patterns.sample
--------------------------------------------------------------------------------

function Motion.arc(turns)
    -- circle of radius 1, for sampling points on a perimeter
    turns = turns or 1
    return Motion.circle(1, turns)
end

function Motion.outward(turns)
    -- spiral from center to edge: radius grows with t
    -- at t=0: (0,0), at t=1: (cos,sin) on unit circle
    turns = turns or 1
    return Motion.xy(
        Curve.mul(Curve.cos(turns, 1), Curve.linear(1)),
        Curve.mul(Curve.sin(turns, 1), Curve.linear(1))
    )
end

function Motion.ray(angle)
    -- straight line in a direction, for burst patterns
    -- uses rotate combinator to avoid raw cos/sin
    return Motion.rotate(Motion.drift(1, 0), angle)
end

--------------------------------------------------------------------------------
-- PRIMITIVE: Rounded rectangle perimeter
-- Arc-length parameterized for uniform speed. Output relative to center.
-- Parameters accept numbers or curves (for reactive geometry via Signal).
--------------------------------------------------------------------------------

function Motion.roundedRect(halfW, halfH, cornerRadius, speed)
    local halfWFn = asFunc(halfW)
    local halfHFn = asFunc(halfH)
    local crFn = asFunc(cornerRadius)
    local speedFn = asFunc(speed)
    local PI_HALF = U.PI / 2

    return function(t, ctx)
        local hw = halfWFn(t, ctx)
        local hh = halfHFn(t, ctx)
        local cr = U.min(crFn(t, ctx), hw, hh)
        local spd = speedFn(t, ctx)

        local edgeW = hw - cr
        local edgeH = hh - cr
        local arcLen = PI_HALF * cr
        local perim = 4 * edgeW + 4 * edgeH + 4 * arcLen
        if perim <= 0 then return 0, 0 end

        local p = (t * spd) % perim

        -- 1. Top edge: (-edgeW, -hh) → (edgeW, -hh)
        local seg = 2 * edgeW
        if p < seg then return -edgeW + p, -hh end
        p = p - seg

        -- 2. Top-right arc: center (edgeW, -edgeH)
        if p < arcLen then
            local a = -PI_HALF + (p / arcLen) * PI_HALF
            return edgeW + cr * cos(a), -edgeH + cr * sin(a)
        end
        p = p - arcLen

        -- 3. Right edge: (hw, -edgeH) → (hw, edgeH)
        seg = 2 * edgeH
        if p < seg then return hw, -edgeH + p end
        p = p - seg

        -- 4. Bottom-right arc: center (edgeW, edgeH)
        if p < arcLen then
            local a = (p / arcLen) * PI_HALF
            return edgeW + cr * cos(a), edgeH + cr * sin(a)
        end
        p = p - arcLen

        -- 5. Bottom edge: (edgeW, hh) → (-edgeW, hh)
        seg = 2 * edgeW
        if p < seg then return edgeW - p, hh end
        p = p - seg

        -- 6. Bottom-left arc: center (-edgeW, edgeH)
        if p < arcLen then
            local a = PI_HALF + (p / arcLen) * PI_HALF
            return -edgeW + cr * cos(a), edgeH + cr * sin(a)
        end
        p = p - arcLen

        -- 7. Left edge: (-hw, edgeH) → (-hw, -edgeH)
        seg = 2 * edgeH
        if p < seg then return -hw, edgeH - p end
        p = p - seg

        -- 8. Top-left arc: center (-edgeW, -edgeH)
        local a = U.PI + (p / U.max(arcLen, 0.001)) * PI_HALF
        return -edgeW + cr * cos(a), -edgeH + cr * sin(a)
    end
end

return Motion
