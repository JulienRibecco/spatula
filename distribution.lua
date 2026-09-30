--- Spatula Distribution Module
--- @module spatula.distribution
---
--- ============================================================================
--- Distribution = arrange points within a Form
--- ============================================================================
---
--- TWO KINDS OF DISTRIBUTIONS:
---
---   Motion-based:  sample(motion, count)
---                  Evaluate a Motion at discrete t values → points along a path
---                  spiral, burst, rings, perimeter
---
---   Spatial:       grid, hexGrid, poisson, random
---                  Fill an area using spatial algorithms
---                  These are irreducible—can't be expressed as motion sampling
---
--- HOW THEY WORK TOGETHER:
---
---   Form provides:        contains(x, y), bounds(), edge(count), random()
---   Distribution uses:    contains() to filter points, bounds() for spatial extent
---
--- API PATTERN:
---   local form = Forms.circle(100, 100, 50)
---   Distribution.grid(form, 25, push)        -- form has baked-in origin/size
---   Distribution.random(form, 20, push)
---   Distribution.spiral(20, 2)(form, push)   -- motion-based returns function
---
--- ============================================================================

local P = require("spatula.point")
local Motion = require("spatula.motion")
local Util = require("spatula.util")
local sqrt, floor, cos, sin, max, ceil = Util.sqrt, Util.floor, Util.cos, Util.sin, Util.max, Util.ceil
local random = Util.random
local eval = Util.eval
local PI2 = Util.PI2
local unpack = table.unpack or unpack  -- Lua 5.1/LuaJIT compatibility

local Distribution = {}

-- Helper: filter points through form containment (batch or individual)
local function filterContained(form, xs, ys, n, push, ctx)
    if n == 0 then return end
    if form.containsBatch then
        local results = form:containsBatch(xs, ys, n, nil, ctx)
        for i = 1, n do
            if results[i] then push(xs[i], ys[i]) end
        end
    else
        for i = 1, n do
            if form:contains(xs[i], ys[i], ctx) then push(xs[i], ys[i]) end
        end
    end
end

--------------------------------------------------------------------------------
-- PRIMITIVE: Bridge between Motion and spatial distribution
--
-- sample(motion, count) evaluates a Motion at discrete t values in [0,1].
-- The motion operates in UNIT SPACE (output range ~[-1,1]).
-- The form's size parameter scales the result to world coordinates.
--
-- This is how Motion compositions become point distributions:
--   sample(Motion.arc(1), 12)      → 12 points on a circle
--   sample(Motion.outward(3), 50)  → 50 points in a spiral
--   sample(myCustomMotion, 100)    → any motion works
--
-- Note: scales by size * 0.999999 to avoid floating-point boundary issues
--------------------------------------------------------------------------------

local BOUNDARY_EPSILON = 0.999999

function Distribution.sample(motion, count)
    return function(form, push, ctx)
        ctx = ctx or {}
        local n = eval(count, ctx)
        local countM1 = max(1, n - 1)

        -- Get form bounds to determine scale
        local minX, minY, maxX, maxY = form:bounds(ctx)
        local ox = (minX + maxX) / 2
        local oy = (minY + maxY) / 2
        local size = max(maxX - ox, maxY - oy) * BOUNDARY_EPSILON

        for i = 1, n do
            local t = (i - 1) / countM1
            local dx, dy = motion(t, ctx)
            local px, py = ox + dx * size, oy + dy * size
            if form:contains(px, py, ctx) then
                push(px, py)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- SPATIAL PRIMITIVES
-- These are genuine spatial algorithms, not motion sampling.
-- They fill areas rather than trace paths.
--------------------------------------------------------------------------------

function Distribution.grid(form, count, push, ctx)
    local n = eval(count, ctx)
    local minX, minY, maxX, maxY = form:bounds(ctx)
    local ox = (minX + maxX) / 2
    local oy = (minY + maxY) / 2
    local size = max(maxX - ox, maxY - oy)

    local cols = max(1, floor(sqrt(n)))
    local step = (size * 2) / cols
    local halfStep = step / 2

    -- Collect candidate points for batch testing
    local xs, ys = {}, {}
    local pn = 0
    local startX, endX = ox - size + halfStep, ox + size
    local startY, endY = oy - size + halfStep, oy + size

    for gx = startX, endX, step do
        if gx >= minX and gx <= maxX then
            for gy = startY, endY, step do
                if gy >= minY and gy <= maxY then
                    pn = pn + 1
                    xs[pn], ys[pn] = gx, gy
                end
            end
        end
    end

    filterContained(form, xs, ys, pn, push, ctx)
end

function Distribution.random(form, count, push, ctx)
    local n = eval(count, ctx)

    -- Use form's random if available (more efficient)
    if form.random then
        for _ = 1, n do
            local x, y = form:random(ctx)
            push(x, y)
        end
        return
    end

    local minX, minY, maxX, maxY = form:bounds(ctx)
    local width, height = maxX - minX, maxY - minY
    local generated = 0
    local maxAttempts = n * 10
    local attempts = 0

    while generated < n and attempts < maxAttempts do
        local px = minX + random() * width
        local py = minY + random() * height
        if form:contains(px, py, ctx) then
            push(px, py)
            generated = generated + 1
        end
        attempts = attempts + 1
    end
end

function Distribution.hexGrid(form, spacing, push, ctx)
    local sp = eval(spacing, ctx)
    local rowHeight = sp * sin(PI2 / 6)  -- sin(pi/3)
    local halfSpacing = sp / 2
    local minX, minY, maxX, maxY = form:bounds(ctx)

    -- Collect candidate points for batch testing
    local xs, ys = {}, {}
    local n = 0

    local row = 0
    local y = minY
    while y <= maxY do
        local offset = (row % 2 == 1) and halfSpacing or 0
        local x = minX + offset
        while x <= maxX do
            n = n + 1
            xs[n], ys[n] = x, y
            x = x + sp
        end
        y = y + rowHeight
        row = row + 1
    end

    filterContained(form, xs, ys, n, push, ctx)
end

function Distribution.poisson(form, minDist, push, ctx)
    local md = eval(minDist, ctx)
    local maxAttempts = 30
    local minDistSq = md * md

    local cellSize = md / sqrt(2)
    local invCellSize = 1 / cellSize
    local minX, minY, maxX, maxY = form:bounds(ctx)
    local cols = floor((maxX - minX) * invCellSize) + 1
    local rows = floor((maxY - minY) * invCellSize) + 1

    local grid = {}
    local active = {}
    local activeCount = 0
    local pointsX, pointsY = {}, {}  -- SoA layout for cache efficiency
    local pointCount = 0

    local function addPoint(x, y)
        local gx = floor((x - minX) * invCellSize)
        local gy = floor((y - minY) * invCellSize)
        local key = gy * cols + gx
        pointCount = pointCount + 1
        grid[key] = pointCount
        pointsX[pointCount] = x
        pointsY[pointCount] = y
        activeCount = activeCount + 1
        active[activeCount] = pointCount
    end

    local function tooClose(x, y)
        local gx = floor((x - minX) * invCellSize)
        local gy = floor((y - minY) * invCellSize)

        for dy = -2, 2 do
            local ny = gy + dy
            if ny >= 0 and ny < rows then
                local rowBase = ny * cols
                for dx = -2, 2 do
                    local nx = gx + dx
                    if nx >= 0 and nx < cols then
                        local idx = grid[rowBase + nx]
                        if idx then
                            local pdx = pointsX[idx] - x
                            local pdy = pointsY[idx] - y
                            if pdx * pdx + pdy * pdy < minDistSq then
                                return true
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    local startX, startY
    if form.random then
        startX, startY = form:random(ctx)
    else
        startX, startY = (minX + maxX) / 2, (minY + maxY) / 2
    end
    addPoint(startX, startY)

    while activeCount > 0 do
        local randIdx = random(1, activeCount)
        local pointIdx = active[randIdx]
        local px, py = pointsX[pointIdx], pointsY[pointIdx]
        local found = false

        for _ = 1, maxAttempts do
            local angle = random() * PI2
            local dist = md + random() * md
            local nx = px + cos(angle) * dist
            local ny = py + sin(angle) * dist

            if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY then
                if form:contains(nx, ny, ctx) and not tooClose(nx, ny) then
                    addPoint(nx, ny)
                    found = true
                end
            end
        end

        if not found then
            -- Swap-and-pop: O(1) instead of O(n) table.remove
            active[randIdx] = active[activeCount]
            active[activeCount] = nil
            activeCount = activeCount - 1
        end
    end

    for i = 1, pointCount do
        push(pointsX[i], pointsY[i])
    end
end

--------------------------------------------------------------------------------
-- COMPOSITIONS
-- Built from sample() + Motion. No raw trig—all traced to primitives.
--------------------------------------------------------------------------------

function Distribution.perimeter(form, count, push, ctx)
    local n = eval(count, ctx)
    -- Points around the edge. Uses form.edge if available, else samples arc.
    if form.edge then
        for x, y in form:edge(n, ctx) do
            push(x, y)
        end
    else
        Distribution.sample(Motion.arc(1), n)(form, push, ctx)
    end
end

function Distribution.spiral(count, turns)
    -- Points along an outward spiral path
    -- Motion.outward: starts at center, expands while rotating
    turns = turns or 3
    return Distribution.sample(Motion.outward(turns), count)
end

function Distribution.burst(rays, pointsPerRay)
    -- Radial lines from center outward (like sun rays)
    -- Each ray is Motion.ray(angle) sampled along its length
    return function(form, push, ctx)
        local r = eval(rays, ctx)
        local ppr = eval(pointsPerRay, ctx)
        for i = 1, r do
            local angle = (i - 1) / r * PI2
            Distribution.sample(Motion.ray(angle), ppr)(form, push, ctx)
        end
    end
end

function Distribution.rings(ringCount, pointsPerRing)
    -- Concentric circles, like tree rings
    -- Each ring is an arc scaled to its radius
    return function(form, push, ctx)
        local rc = eval(ringCount, ctx)
        local ppr = eval(pointsPerRing, ctx)
        for ring = 1, rc do
            local radius = ring / rc
            local count = type(ppr) == "function"
                and ppr(ring)
                or ppr
            local scaledMotion = Motion.scale(Motion.arc(1), radius)
            Distribution.sample(scaledMotion, count)(form, push, ctx)
        end
    end
end

--------------------------------------------------------------------------------
-- MODIFIERS
-- Transform any distribution function. Composable.
--
--   withJitter(myDist, 5)              -- add randomness
--   withFilter(Distribution.spiral(50), pred)  -- conditional inclusion
--
--------------------------------------------------------------------------------

function Distribution.withJitter(distFn, amount)
    return function(form, ...)
        local args = {...}
        local push = args[#args - 1] or args[#args]  -- push is before ctx or last
        local ctx = args[#args]
        if type(ctx) == "function" then
            ctx = nil
            push = args[#args]
        end

        local amt = eval(amount, ctx)
        local jitteredPush = function(x, y)
            local jx = x + (random() - 0.5) * amt * 2
            local jy = y + (random() - 0.5) * amt * 2
            push(jx, jy)
        end

        distFn(form, jitteredPush, ctx)
    end
end

function Distribution.withFilter(distFn, predicate)
    return function(form, push, ctx)
        local filteredPush = function(x, y)
            if predicate(x, y) then
                push(x, y)
            end
        end
        distFn(form, filteredPush, ctx)
    end
end

function Distribution.withIndex(distFn)
    return function(form, push, ctx)
        local idx = 0
        local indexedPush = function(x, y)
            idx = idx + 1
            push(x, y, idx)
        end
        distFn(form, indexedPush, ctx)
        return idx
    end
end

--------------------------------------------------------------------------------
-- LOAD OPTIMIZATIONS
--------------------------------------------------------------------------------

local ok, opt = pcall(require, "opt")
if ok and opt.patchDistribution then
    opt.patchDistribution(Distribution)
end

return Distribution
