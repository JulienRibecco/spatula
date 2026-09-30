--- Spatula Point Optimizations
--- @module spatula.opt.point
---
--- Performance variants for Point operations:
--- - *XY() functions return values instead of tables (no allocation)
--- - *Into() functions mutate existing tables (reuse allocation)
--- - *Batch() functions process arrays efficiently

local sqrt, cos, sin = math.sqrt, math.cos, math.sin
local type = type

local M = {}

-- Reference to Point.unpack (set by _init)
local P

--------------------------------------------------------------------------------
-- FAST UNPACK
--------------------------------------------------------------------------------

function M.unpackFast(a)
    local x = a.x
    if x then return x, a.y end
    return a[1], a[2]
end

--------------------------------------------------------------------------------
-- VALUE-RETURNING VARIANTS (no allocation)
--------------------------------------------------------------------------------

function M.addXY(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return ax + bx, ay + by
end

function M.subXY(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    return ax - bx, ay - by
end

function M.mulXY(a, b)
    local ax, ay = P(a)
    if type(b) == "number" then
        return ax * b, ay * b
    end
    local bx, by = P(b)
    return ax * bx, ay * by
end

function M.divXY(a, b)
    local ax, ay = P(a)
    if type(b) == "number" then
        return ax / b, ay / b
    end
    local bx, by = P(b)
    return ax / bx, ay / by
end

function M.negXY(p)
    local x, y = P(p)
    return -x, -y
end

function M.normalizeXY(p)
    local x, y = P(p)
    local len = sqrt(x * x + y * y)
    if len < 0.0001 then return 0, 0 end
    return x / len, y / len
end

function M.rotateXY(p, angle)
    local x, y = P(p)
    local c, s = cos(angle), sin(angle)
    return x * c - y * s, x * s + y * c
end

function M.rotateAroundXY(p, center, angle)
    local px, py = P(p)
    local cx, cy = P(center)
    local dx, dy = px - cx, py - cy
    local c, s = cos(angle), sin(angle)
    return cx + dx * c - dy * s, cy + dx * s + dy * c
end

function M.lerpXY(a, b, t)
    local ax, ay = P(a)
    local bx, by = P(b)
    return ax + (bx - ax) * t, ay + (by - ay) * t
end

function M.distanceSqXY(a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

--------------------------------------------------------------------------------
-- IN-PLACE VARIANTS (mutate existing table)
--------------------------------------------------------------------------------

function M.addInto(out, a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    out.x, out.y = ax + bx, ay + by
    return out
end

function M.subInto(out, a, b)
    local ax, ay = P(a)
    local bx, by = P(b)
    out.x, out.y = ax - bx, ay - by
    return out
end

function M.mulInto(out, a, b)
    local ax, ay = P(a)
    if type(b) == "number" then
        out.x, out.y = ax * b, ay * b
    else
        local bx, by = P(b)
        out.x, out.y = ax * bx, ay * by
    end
    return out
end

function M.normalizeInto(out, p)
    local x, y = P(p)
    local len = sqrt(x * x + y * y)
    if len < 0.0001 then
        out.x, out.y = 0, 0
    else
        out.x, out.y = x / len, y / len
    end
    return out
end

function M.lerpInto(out, a, b, t)
    local ax, ay = P(a)
    local bx, by = P(b)
    out.x, out.y = ax + (bx - ax) * t, ay + (by - ay) * t
    return out
end

function M.rotateInto(out, p, angle)
    local x, y = P(p)
    local c, s = cos(angle), sin(angle)
    out.x, out.y = x * c - y * s, x * s + y * c
    return out
end

--------------------------------------------------------------------------------
-- BATCH OPERATIONS
--------------------------------------------------------------------------------

function M.addBatch(xs, ys, dx, dy, outXs, outYs, n)
    outXs = outXs or xs
    outYs = outYs or ys
    for i = 1, n do
        outXs[i] = xs[i] + dx
        outYs[i] = ys[i] + dy
    end
    return outXs, outYs
end

function M.mulBatch(xs, ys, scale, outXs, outYs, n)
    outXs = outXs or xs
    outYs = outYs or ys
    for i = 1, n do
        outXs[i] = xs[i] * scale
        outYs[i] = ys[i] * scale
    end
    return outXs, outYs
end

function M.rotateBatch(xs, ys, angle, outXs, outYs, n)
    outXs = outXs or {}
    outYs = outYs or {}
    local c, s = cos(angle), sin(angle)
    for i = 1, n do
        local x, y = xs[i], ys[i]
        outXs[i] = x * c - y * s
        outYs[i] = x * s + y * c
    end
    return outXs, outYs
end

function M.normalizeBatch(xs, ys, outXs, outYs, n)
    outXs = outXs or {}
    outYs = outYs or {}
    for i = 1, n do
        local x, y = xs[i], ys[i]
        local len = sqrt(x * x + y * y)
        if len < 0.0001 then
            outXs[i], outYs[i] = 0, 0
        else
            outXs[i], outYs[i] = x / len, y / len
        end
    end
    return outXs, outYs
end

function M.lengthBatch(xs, ys, out, n)
    out = out or {}
    for i = 1, n do
        local x, y = xs[i], ys[i]
        out[i] = sqrt(x * x + y * y)
    end
    return out
end

function M.distanceBatch(xs, ys, tx, ty, out, n)
    out = out or {}
    for i = 1, n do
        local dx, dy = xs[i] - tx, ys[i] - ty
        out[i] = sqrt(dx * dx + dy * dy)
    end
    return out
end

function M.lerpBatch(ax, ay, bx, by, ts, outXs, outYs, n)
    outXs = outXs or {}
    outYs = outYs or {}
    for i = 1, n do
        local t = ts[i]
        outXs[i] = ax + (bx - ax) * t
        outYs[i] = ay + (by - ay) * t
    end
    return outXs, outYs
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function M._init(Point, Opt)
    P = Point.unpack
end

return M
