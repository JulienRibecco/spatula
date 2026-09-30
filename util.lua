--- Spatula Utility Module
--- @module spatula.util
---
--- ============================================================================
--- Math helpers and constants
--- ============================================================================
---
--- Exports commonly used math functions for easy access.
--- All other modules import from here rather than math.* directly.
---
--- ============================================================================

local Util = {}

local cos, sin, sqrt, abs, floor, ceil, min, max, exp, atan2 =
    math.cos, math.sin, math.sqrt, math.abs, math.floor, math.ceil, math.min, math.max, math.exp, math.atan2

-- Export math functions
Util.cos, Util.sin, Util.sqrt, Util.abs = cos, sin, sqrt, abs
Util.floor, Util.ceil, Util.min, Util.max, Util.exp = floor, ceil, min, max, exp
-- LuaJIT exposes atan2; Lua 5.3+ uses the two-argument math.atan.
Util.atan2 = atan2 or function(y, x) return math.atan(y, x) end
Util.huge = math.huge
Util.PI = math.pi
Util.PI2 = math.pi * 2

-- Configurable RNG (for deterministic/reproducible behavior)
local _rng = math.random
Util.random = function(...) return _rng(...) end

function Util.setRNG(rngFn)
    _rng = rngFn or math.random
end

function Util.seed(seed)
    math.randomseed(seed)
end

function Util.clamp(v, lo, hi)
    return min(max(v, lo), hi)
end

function Util.lerp(a, b, t)
    return a + (b - a) * t
end

function Util.map(v, inMin, inMax, outMin, outMax)
    return outMin + (v - inMin) * (outMax - outMin) / (inMax - inMin)
end

function Util.distance(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx * dx + dy * dy)
end

function Util.distanceSq(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return dx * dx + dy * dy
end

function Util.normalizeAngle(angle)
    angle = angle % Util.PI2
    return angle < 0 and angle + Util.PI2 or angle
end

--- Evaluate a value that may be a signal or literal
--- Signals are functions f(t, ctx) -> value, literals are returned as-is
--- @param val any The value to evaluate (number, function, or other)
--- @param ctx table|nil The context for signal evaluation
--- @return any The evaluated value
function Util.eval(val, ctx)
    if type(val) == "function" then
        return val(0, ctx)
    end
    return val
end

return Util
