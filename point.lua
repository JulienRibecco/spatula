--- Spatula Point Module
--- @module spatula.point
---
--- ============================================================================
--- Point normalization and vector operations
--- ============================================================================
---
--- Points can come in many forms:
---   {x=10, y=20}     -- named fields
---   {10, 20}         -- array
---   10, 20           -- two numbers
---
--- Point.unpack() normalizes ANY of these to (x, y).
--- This lets all Spatula functions accept points flexibly.
---
--- The module is callable: P(thing) = Point.unpack(thing)
---
--- ============================================================================

local Util = require("spatula.util")
local sqrt, cos, sin, atan2 = Util.sqrt, Util.cos, Util.sin, Util.atan2
local type = type
local Point = {}

--------------------------------------------------------------------------------
-- PRIMITIVE
-- Normalize any point-like input to x, y values.
--------------------------------------------------------------------------------

function Point.unpack(a, b)
    local ta = type(a)
    if ta == "table" then
        local x = a.x
        if x then return x, a.y end
        return a[1] or 0, a[2] or 0
    elseif ta == "number" then
        return a, b or 0
    end
    return 0, 0
end

--------------------------------------------------------------------------------
-- CONSTRUCTORS
--------------------------------------------------------------------------------

function Point.new(x, y)
    if type(x) == "table" then
        return { x = x.x or x[1] or 0, y = x.y or x[2] or 0 }
    end
    return { x = x or 0, y = y or 0 }
end

function Point.fromAngle(angle, length)
    length = length or 1
    return { x = cos(angle) * length, y = sin(angle) * length }
end

--------------------------------------------------------------------------------
-- ARITHMETIC
--------------------------------------------------------------------------------

local P = Point.unpack

function Point.add(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return { x = ax + bx, y = ay + by }
end

function Point.sub(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return { x = ax - bx, y = ay - by }
end

function Point.mul(a, b)
    local ax, ay = P(a)
    if type(b) == "number" then
        return { x = ax * b, y = ay * b }
    end
    local bx, by = P(b)
    return { x = ax * bx, y = ay * by }
end

function Point.div(a, b)
    local ax, ay = P(a)
    if type(b) == "number" then
        return { x = ax / b, y = ay / b }
    end
    local bx, by = P(b)
    return { x = ax / bx, y = ay / by }
end

function Point.neg(p)
    local x, y = P(p)
    return { x = -x, y = -y }
end

--------------------------------------------------------------------------------
-- GEOMETRY
--------------------------------------------------------------------------------

function Point.length(p)
    local x, y = P(p)
    return sqrt(x * x + y * y)
end

function Point.lengthSq(p)
    local x, y = P(p)
    return x * x + y * y
end

function Point.distance(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end

function Point.distanceSq(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

function Point.normalize(p)
    local x, y = P(p)
    local len = sqrt(x * x + y * y)
    if len < 0.0001 then return { x = 0, y = 0 } end
    return { x = x / len, y = y / len }
end

function Point.dot(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return ax * bx + ay * by
end

function Point.cross(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return ax * by - ay * bx
end

function Point.angle(p)
    local x, y = P(p)
    return atan2(y, x)
end

function Point.angleTo(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return atan2(by - ay, bx - ax)
end

function Point.rotate(p, angle)
    local x, y = P(p)
    local c, s = cos(angle), sin(angle)
    return { x = x * c - y * s, y = x * s + y * c }
end

function Point.rotateAround(p, center, angle)
    local px, py = P(p)
    local cx, cy = P(center)
    local dx, dy = px - cx, py - cy
    local c, s = cos(angle), sin(angle)
    return { x = cx + dx * c - dy * s, y = cy + dx * s + dy * c }
end

--------------------------------------------------------------------------------
-- INTERPOLATION
--------------------------------------------------------------------------------

function Point.lerp(a, b, t)
    local ax, ay = P(a)
    local bx, by = P(b)
    return { x = ax + (bx - ax) * t, y = ay + (by - ay) * t }
end

--------------------------------------------------------------------------------
-- MAKE MODULE CALLABLE
--------------------------------------------------------------------------------

setmetatable(Point, {
    __call = function(_, a, b)
        return Point.unpack(a, b)
    end
})

--------------------------------------------------------------------------------
-- LOAD OPTIMIZATIONS
--------------------------------------------------------------------------------

local ok, opt = pcall(require, "opt")
if ok and opt.patchPoint then
    opt.patchPoint(Point)
end

return Point
