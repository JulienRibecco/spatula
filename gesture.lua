--- Spatula Gesture Module
--- @module spatula.gesture
---
--- ============================================================================
--- Gesture Recognition via Motion Template Matching
--- ============================================================================
---
--- Recognizes drawn point sequences by matching against Spatula Motion
--- templates using Procrustes alignment. A drawn gesture IS a Motion
--- evaluated over t∈[0,1] — recognition finds which Motion composition
--- fits best.
---
--- ~30 tunable floats across all templates replace a neural network.
---
--- PIPELINE:
---   rawPoints → resample(n=64) → center → unitScale → Procrustes match
---
--- API:
---   Gesture.recognize(points, opts)   → best match or nil
---   Gesture.recognizeAll(points, opts) → sorted matches
---   Gesture.register(name, motion)    → add custom template
---   Gesture.unregister(name)          → remove template
---   Gesture.clear()                   → remove all
---   Gesture.reset()                   → restore built-ins
---
--- ============================================================================

local Motion = require("spatula.motion")
local Curve = require("spatula.curve")
local U = require("spatula.util")

local sqrt, sin, cos, atan2, huge = U.sqrt, U.sin, U.cos, U.atan2, U.huge
local random = U.random

local Gesture = {}

-- Template storage
local templates = {}

-- Default sample count
local DEFAULT_N = 64
-- Oversample count for template preprocessing
local OVERSAMPLE = 256

--------------------------------------------------------------------------------
-- PREPROCESSING
-- Pure functions: rawPoints → resampled → centered → unit-scaled
--------------------------------------------------------------------------------

--- Compute total arc length of a polyline.
local function pathLength(points, n)
    local len = 0
    for i = 2, n do
        local dx = points[i][1] - points[i-1][1]
        local dy = points[i][2] - points[i-1][2]
        len = len + sqrt(dx * dx + dy * dy)
    end
    return len
end

--- Resample a polyline to n equidistant points along arc length.
--- Classic $1-Recognizer algorithm.
function Gesture.resample(points, n)
    local count = #points
    if count == 0 then
        local out = {}
        for i = 1, n do out[i] = {0, 0} end
        return out
    end
    if count == 1 then
        local out = {}
        for i = 1, n do out[i] = {points[1][1], points[1][2]} end
        return out
    end

    -- Copy input so table.insert doesn't mutate caller's array
    local src = {}
    for i = 1, count do
        src[i] = {points[i][1], points[i][2]}
    end

    local totalLen = pathLength(src, count)
    if totalLen < 1e-12 then
        local out = {}
        for i = 1, n do out[i] = {src[1][1], src[1][2]} end
        return out
    end

    local interval = totalLen / (n - 1)
    local out = {{src[1][1], src[1][2]}}
    local accumulated = 0
    local prevX, prevY = src[1][1], src[1][2]
    local srcIdx = 2

    while #out < n and srcIdx <= count do
        local curX, curY = src[srcIdx][1], src[srcIdx][2]
        local dx = curX - prevX
        local dy = curY - prevY
        local segLen = sqrt(dx * dx + dy * dy)

        if segLen < 1e-12 then
            srcIdx = srcIdx + 1
        elseif accumulated + segLen >= interval then
            local ratio = (interval - accumulated) / segLen
            local nx = prevX + ratio * dx
            local ny = prevY + ratio * dy
            out[#out + 1] = {nx, ny}
            -- Next iteration starts from the interpolated point
            prevX, prevY = nx, ny
            accumulated = 0
        else
            accumulated = accumulated + segLen
            prevX, prevY = curX, curY
            srcIdx = srcIdx + 1
        end
    end

    -- Fill any remaining points (floating point edge case)
    while #out < n do
        out[#out + 1] = {points[count][1], points[count][2]}
    end

    return out
end

--- Compute centroid of a point set.
function Gesture.centroid(points)
    local n = #points
    if n == 0 then return 0, 0 end
    local sx, sy = 0, 0
    for i = 1, n do
        sx = sx + points[i][1]
        sy = sy + points[i][2]
    end
    return sx / n, sy / n
end

--- Translate all points by (dx, dy) in-place.
function Gesture.translate(points, dx, dy)
    for i = 1, #points do
        points[i][1] = points[i][1] + dx
        points[i][2] = points[i][2] + dy
    end
    return points
end

--- Scale all points so max distance from origin = 1.
--- Returns the original scale factor.
function Gesture.scaleToUnit(points)
    local maxDist = 0
    for i = 1, #points do
        local x, y = points[i][1], points[i][2]
        local d = sqrt(x * x + y * y)
        if d > maxDist then maxDist = d end
    end
    if maxDist < 1e-12 then return 0 end
    local inv = 1 / maxDist
    for i = 1, #points do
        points[i][1] = points[i][1] * inv
        points[i][2] = points[i][2] * inv
    end
    return maxDist
end

--- Full preprocessing pipeline.
--- Accepts both {x=,y=} and {[1],[2]} point formats.
--- Returns normalized points, original centroid, original scale.
function Gesture.preprocess(rawPoints, n)
    n = n or DEFAULT_N

    -- Normalize input format to {[1],[2]}
    local pts = {}
    for i = 1, #rawPoints do
        local p = rawPoints[i]
        if p.x then
            pts[i] = {p.x, p.y}
        else
            pts[i] = {p[1], p[2]}
        end
    end

    pts = Gesture.resample(pts, n)
    local cx, cy = Gesture.centroid(pts)
    Gesture.translate(pts, -cx, -cy)
    local scale = Gesture.scaleToUnit(pts)
    local sqn = Gesture.sqNorm(pts, n)
    return pts, cx, cy, scale, sqn
end

--------------------------------------------------------------------------------
-- PROCRUSTES 2D ALIGNMENT
-- Algebraic closed-form distance — one loop, zero allocations.
--------------------------------------------------------------------------------

--- Compute sum of squared norms for a point set.
function Gesture.sqNorm(points, n)
    local sum = 0
    for i = 1, n do
        local x, y = points[i][1], points[i][2]
        sum = sum + x * x + y * y
    end
    return sum
end

--- Algebraic Procrustes distance between two point sets.
--- MSE = (Σ|p|² + Σ|q|²)/n - 2·√(num² + den²)/n
--- One loop, no rotation, no allocation.
function Gesture.matchDistance(candidate, template, n, candSqNorm, tmplSqNorm)
    local num, den = 0, 0
    for i = 1, n do
        local px, py = candidate[i][1], candidate[i][2]
        local qx, qy = template[i][1], template[i][2]
        num = num + (px * qy - py * qx)
        den = den + (px * qx + py * qy)
    end
    return (candSqNorm + tmplSqNorm) / n - 2 * sqrt(num * num + den * den) / n
end

--------------------------------------------------------------------------------
-- TEMPLATE SYSTEM
-- Each template = { name, motion, points (cached), params }
--------------------------------------------------------------------------------

--- Sample a Motion at n uniform t values in [0,1].
function Gesture.sampleMotion(motion, n)
    local pts = {}
    for i = 1, n do
        local t = (i - 1) / (n - 1)
        local x, y = motion(t, {})
        pts[i] = {x, y}
    end
    return pts
end

--- Preprocess a motion into a normalized template.
--- Oversamples at 256, resamples to n for arc-length uniformity.
--- Returns normalized points and precomputed squared norm.
function Gesture.preprocessTemplate(motion, n)
    n = n or DEFAULT_N
    local raw = Gesture.sampleMotion(motion, OVERSAMPLE)
    raw = Gesture.resample(raw, n)
    local cx, cy = Gesture.centroid(raw)
    Gesture.translate(raw, -cx, -cy)
    Gesture.scaleToUnit(raw)
    return raw, Gesture.sqNorm(raw, n)
end

--------------------------------------------------------------------------------
-- BUILT-IN TEMPLATES
-- 6 gesture types, ~15 variants total
--------------------------------------------------------------------------------

local function registerBuiltins()
    -- Circle (1 variant)
    Gesture.register("circle", Motion.circle(1, 1))

    -- Line (1 variant)
    Gesture.register("line", Motion.drift(1, 0))

    -- Zigzag (5 variants, freq 2-6)
    local zigzagVariants = {}
    for freq = 2, 6 do
        zigzagVariants[#zigzagVariants + 1] = {
            motion = Motion.xy(Curve.linear(1), Curve.triangle(freq, 1)),
            params = {freq = freq}
        }
    end
    Gesture.register("zigzag", zigzagVariants)

    -- Spiral (3 variants, growth 0.5, 1, 2)
    local spiralVariants = {}
    for _, growth in ipairs({0.5, 1, 2}) do
        spiralVariants[#spiralVariants + 1] = {
            motion = Motion.spiral(1, 1, growth),
            params = {growth = growth}
        }
    end
    Gesture.register("spiral", spiralVariants)

    -- Figure 8 (1 variant)
    Gesture.register("figure8", Motion.figure8(1, 1))

    -- Wave (4 variants, freq 1-4)
    local waveVariants = {}
    for freq = 1, 4 do
        waveVariants[#waveVariants + 1] = {
            motion = Motion.wave(1, 1, freq),
            params = {freq = freq}
        }
    end
    Gesture.register("wave", waveVariants)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--- Register a template from raw point data (no Motion function needed).
--- Reuses the standard preprocessing pipeline: resample → center → scaleToUnit.
--- @param name string Template name
--- @param rawPoints table Array of {x,y} or {[1],[2]} points
--- @param params table|nil Optional parameters to attach to the template
function Gesture.registerPoints(name, rawPoints, params)
    local pts = {}
    for i = 1, #rawPoints do
        local p = rawPoints[i]
        pts[i] = p.x and {p.x, p.y} or {p[1], p[2]}
    end
    pts = Gesture.resample(pts, DEFAULT_N)
    local cx, cy = Gesture.centroid(pts)
    Gesture.translate(pts, -cx, -cy)
    Gesture.scaleToUnit(pts)
    templates[#templates + 1] = {
        name = name,
        motion = nil,
        points = pts,
        sqNorm = Gesture.sqNorm(pts, DEFAULT_N),
        params = params or {}
    }
end

--- Register a template. Accepts:
---   Gesture.register(name, motion)                    -- single motion
---   Gesture.register(name, {motion=m, params={...}})  -- with params
---   Gesture.register(name, {{motion=m1, params=...}, ...})  -- variants
function Gesture.register(name, spec)
    -- Single motion function
    if type(spec) == "function" then
        local pts, sqn = Gesture.preprocessTemplate(spec)
        templates[#templates + 1] = {
            name = name,
            motion = spec,
            points = pts,
            sqNorm = sqn,
            params = {}
        }
        return
    end

    -- Table with motion key = single variant with params
    if spec.motion then
        local pts, sqn = Gesture.preprocessTemplate(spec.motion)
        templates[#templates + 1] = {
            name = name,
            motion = spec.motion,
            points = pts,
            sqNorm = sqn,
            params = spec.params or {}
        }
        return
    end

    -- Array of variants
    for _, variant in ipairs(spec) do
        local pts, sqn = Gesture.preprocessTemplate(variant.motion)
        templates[#templates + 1] = {
            name = name,
            motion = variant.motion,
            points = pts,
            sqNorm = sqn,
            params = variant.params or {}
        }
    end
end

--- Remove all templates with the given name.
function Gesture.unregister(name)
    local i = 1
    while i <= #templates do
        if templates[i].name == name then
            table.remove(templates, i)
        else
            i = i + 1
        end
    end
end

--- Remove all templates.
function Gesture.clear()
    templates = {}
end

--- Remove all templates and restore built-ins.
function Gesture.reset()
    templates = {}
    registerBuiltins()
end

--- Recognize the best matching template for a set of drawn points.
--- @param points table Array of {x,y} or {[1],[2]} points
--- @param opts table|nil Options: n (sample count, default 64), threshold (max distance, default 0.3)
--- @return table|nil Result with name, distance, params, center, scale, motion; or nil if no match
function Gesture.recognize(points, opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local threshold = opts.threshold or 0.3

    local processed, cx, cy, scale, candSqNorm = Gesture.preprocess(points, n)

    local bestDist = huge
    local bestTemplate = nil

    for _, tmpl in ipairs(templates) do
        local dist = Gesture.matchDistance(processed, tmpl.points, n, candSqNorm, tmpl.sqNorm)
        if dist < bestDist then
            bestDist = dist
            bestTemplate = tmpl
        end
    end

    if not bestTemplate or bestDist > threshold then
        return nil
    end

    return {
        name = bestTemplate.name,
        distance = bestDist,
        params = bestTemplate.params,
        center = {cx, cy},
        scale = scale,
        motion = bestTemplate.motion
    }
end

--- Recognize all templates, sorted by distance (best first).
--- @param points table Array of {x,y} or {[1],[2]} points
--- @param opts table|nil Options: n (sample count, default 64)
--- @return table Array of results sorted by distance
function Gesture.recognizeAll(points, opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N

    local processed, cx, cy, scale, candSqNorm = Gesture.preprocess(points, n)

    local results = {}
    for _, tmpl in ipairs(templates) do
        local dist = Gesture.matchDistance(processed, tmpl.points, n, candSqNorm, tmpl.sqNorm)
        results[#results + 1] = {
            name = tmpl.name,
            distance = dist,
            params = tmpl.params,
            center = {cx, cy},
            scale = scale,
            motion = tmpl.motion
        }
    end

    table.sort(results, function(a, b) return a.distance < b.distance end)
    return results
end

--------------------------------------------------------------------------------
-- INITIALIZE BUILT-IN TEMPLATES
--------------------------------------------------------------------------------

registerBuiltins()

return Gesture
