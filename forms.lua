--- Spatula Forms Module
--- @module spatula.forms
---
--- ============================================================================
--- Form = contains(point) → bool
--- ============================================================================
---
--- A form is a geometric shape defined by containment.
--- Forms are created via factory functions with baked-in parameters.
---
--- EVERY FORM PROVIDES:
---   :contains(x, y, ctx) → bool   -- is point inside?
---   :signedDistance(x, y, ctx) → number  -- positive inside, negative outside
---   :bounds(ctx) → minX, minY, maxX, maxY
---   :edge(count, ctx) → iterator   -- points on perimeter
---   :random(ctx) → x, y            -- random point inside
---
--- SIGNALS: Any parameter can be a Signal for reactive geometry:
---   Forms.circle(0, 0, S("radius", 50))  -- radius from ctx
---
--- COMBINATORS work like set operations:
---   Forms.union(a, b)      -- inside if in a OR b
---   Forms.intersect(a, b)  -- inside if in a AND b
---   Forms.subtract(a, b)   -- inside if in a but NOT b
---
--- TRACKING with hysteresis (space) and throttle (time):
---   Forms.track(zone, {
---       -- Hysteresis (spatial buffer)
---       enterMargin = 5,    -- must be 5 units inside to trigger enter
---       exitMargin = 5,     -- must be 5 units outside to trigger exit
---       -- Throttle (temporal buffer) - requires S.setGlobal("time", t)
---       enterThrottle = 1,  -- can't re-enter for 1s after exiting
---       exitThrottle = 0.5, -- can't exit for 0.5s after entering
---       onEnter = function(e) ... end,
---       onExit = function(e) ... end,
---   })
---
--- ============================================================================

local Util = require("spatula.util")
local Signal = require("spatula.signal")
local cos, sin, abs, sqrt, random, floor = Util.cos, Util.sin, Util.abs, Util.sqrt, Util.random, Util.floor
local min, max = Util.min, Util.max
local PI2 = Util.PI2
local huge = Util.huge
local eval = Util.eval

local Forms = {}

-- Module-level state for global default queryFn
local defaultQueryFn = nil
local seenThisFrame = {}  -- Reused to avoid GC pressure

-- Get current time from global signal or fallback to 0
local function getTime()
    return Signal.getGlobal("time") or 0
end

-- Shared tracker transition logic (avoids duplication)
-- Now includes throttle checks for enter/exit transitions
local function handleTrackerTransition(tracker, id, entity, isInside, dt)
    local wasInside = tracker.inside[id]
    local t = getTime()

    if isInside and not wasInside then
        -- Check enter throttle: must wait enterThrottle seconds after last exit
        local canEnter = true
        if tracker.hasThrottle and tracker.enterThrottle > 0 then
            local lastExit = tracker.lastExitTime[id] or -huge
            canEnter = (t - lastExit) >= tracker.enterThrottle
        end

        if canEnter then
            tracker.inside[id] = entity or true
            tracker.cooldowns[id] = 0
            tracker.lastEnterTime[id] = t
            if tracker.onEnter then tracker.onEnter(entity, tracker) end
        end

    elseif not isInside and wasInside then
        -- Check exit throttle: must wait exitThrottle seconds after last enter
        local canExit = true
        if tracker.hasThrottle and tracker.exitThrottle > 0 then
            local lastEnter = tracker.lastEnterTime[id] or -huge
            canExit = (t - lastEnter) >= tracker.exitThrottle
        end

        if canExit then
            tracker.inside[id] = nil
            tracker.cooldowns[id] = nil
            tracker.lastExitTime[id] = t
            if tracker.onExit then tracker.onExit(entity, tracker) end
        end
    end

    -- whileInside uses dt-based cooldown (unchanged)
    if tracker.inside[id] and tracker.whileInside then
        tracker.cooldowns[id] = (tracker.cooldowns[id] or 0) - dt
        if tracker.cooldowns[id] <= 0 then
            tracker.cooldowns[id] = tracker.whileInside.cooldown or 1
            if tracker.whileInside.action then
                tracker.whileInside.action(entity, tracker)
            end
        end
    end
end

function Forms.setDefaultQueryFn(fn)
    defaultQueryFn = fn
end

--------------------------------------------------------------------------------
-- PRIMITIVE FORMS
-- Factory functions that return form objects with baked-in parameters.
-- All parameters support signals (functions that take ctx).
--------------------------------------------------------------------------------

--- Create a circle form
--- @param ox number|function Center X (or signal)
--- @param oy number|function Center Y (or signal)
--- @param radius number|function Radius (or signal)
--- @return table Form object with contains, bounds, edge, random methods
function Forms.circle(ox, oy, radius)
    return {
        contains = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local dx, dy = x - cx, y - cy
            return dx * dx + dy * dy <= r * r
        end,

        signedDistance = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local dx, dy = x - cx, y - cy
            return r - sqrt(dx * dx + dy * dy)
        end,

        bounds = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            return cx - r, cy - r, cx + r, cy + r
        end,

        edge = function(self, count, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local i, step = 0, PI2 / count
            return function()
                i = i + 1
                if i <= count then
                    local angle = (i - 1) * step
                    return cx + cos(angle) * r, cy + sin(angle) * r
                end
            end
        end,

        random = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local angle = random() * PI2
            local dist = r * sqrt(random())
            return cx + cos(angle) * dist, cy + sin(angle) * dist
        end,

        -- Batch containment for performance (used by opt module)
        containsBatch = function(self, xs, ys, n, out, ctx)
            out = out or {}
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local r2 = r * r
            for i = 1, n do
                local dx, dy = xs[i] - cx, ys[i] - cy
                out[i] = dx * dx + dy * dy <= r2
            end
            return out
        end
    }
end

--- Create a rectangle form
--- @param ox number|function Center X (or signal)
--- @param oy number|function Center Y (or signal)
--- @param hw number|function Half-width (or signal)
--- @param hh number|function Half-height (or signal)
--- @return table Form object
function Forms.rect(ox, oy, hw, hh)
    return {
        contains = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            return abs(x - cx) <= w and abs(y - cy) <= h
        end,

        signedDistance = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            local dx, dy = abs(x - cx), abs(y - cy)
            local px, py = dx - w, dy - h
            if px <= 0 and py <= 0 then
                -- Inside: positive distance to nearest edge
                return min(-px, -py)
            else
                -- Outside: negative distance to rect
                return -sqrt(max(px, 0) * max(px, 0) + max(py, 0) * max(py, 0))
            end
        end,

        bounds = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            return cx - w, cy - h, cx + w, cy + h
        end,

        edge = function(self, count, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            local perimeter = 2 * (w + h) * 2
            local step = perimeter / count
            local i = 0
            return function()
                i = i + 1
                if i > count then return nil end
                local d = (i - 1) * step
                if d < w * 2 then
                    return cx - w + d, cy - h
                elseif d < w * 2 + h * 2 then
                    return cx + w, cy - h + (d - w * 2)
                elseif d < w * 4 + h * 2 then
                    return cx + w - (d - w * 2 - h * 2), cy + h
                else
                    return cx - w, cy + h - (d - w * 4 - h * 2)
                end
            end
        end,

        random = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            return cx + (random() * 2 - 1) * w,
                   cy + (random() * 2 - 1) * h
        end,

        containsBatch = function(self, xs, ys, n, out, ctx)
            out = out or {}
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local w = eval(hw, ctx)
            local h = eval(hh, ctx)
            for i = 1, n do
                out[i] = abs(xs[i] - cx) <= w and abs(ys[i] - cy) <= h
            end
            return out
        end
    }
end

--- Create an ellipse form
--- @param ox number|function Center X (or signal)
--- @param oy number|function Center Y (or signal)
--- @param rx number|function X radius (or signal)
--- @param ry number|function Y radius (or signal)
--- @return table Form object
function Forms.ellipse(ox, oy, rx, ry)
    return {
        contains = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            local dx = (x - cx) / radiusX
            local dy = (y - cy) / radiusY
            return dx * dx + dy * dy <= 1
        end,

        signedDistance = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            local dx = (x - cx) / radiusX
            local dy = (y - cy) / radiusY
            local nd = sqrt(dx * dx + dy * dy)
            -- Approximate: scale by smaller radius
            return (1 - nd) * min(radiusX, radiusY)
        end,

        bounds = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            return cx - radiusX, cy - radiusY, cx + radiusX, cy + radiusY
        end,

        edge = function(self, count, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            local i, step = 0, PI2 / count
            return function()
                i = i + 1
                if i <= count then
                    local angle = (i - 1) * step
                    return cx + cos(angle) * radiusX, cy + sin(angle) * radiusY
                end
            end
        end,

        random = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            local angle = random() * PI2
            local r = sqrt(random())
            return cx + cos(angle) * radiusX * r,
                   cy + sin(angle) * radiusY * r
        end,

        containsBatch = function(self, xs, ys, n, out, ctx)
            out = out or {}
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local radiusX = eval(rx, ctx)
            local radiusY = eval(ry, ctx)
            for i = 1, n do
                local dx = (xs[i] - cx) / radiusX
                local dy = (ys[i] - cy) / radiusY
                out[i] = dx * dx + dy * dy <= 1
            end
            return out
        end
    }
end

--- Create a ring (annulus) form
--- @param ox number|function Center X (or signal)
--- @param oy number|function Center Y (or signal)
--- @param outerR number|function Outer radius (or signal)
--- @param innerR number|function Inner radius (or signal)
--- @return table Form object
function Forms.ring(ox, oy, outerR, innerR)
    return {
        contains = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            local inner = eval(innerR, ctx)
            local dx, dy = x - cx, y - cy
            local d2 = dx * dx + dy * dy
            return d2 <= outer * outer and d2 >= inner * inner
        end,

        signedDistance = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            local inner = eval(innerR, ctx)
            local dx, dy = x - cx, y - cy
            local dist = sqrt(dx * dx + dy * dy)
            if dist > outer then
                return outer - dist  -- outside outer, negative
            elseif dist < inner then
                return dist - inner  -- inside inner, negative
            else
                return min(outer - dist, dist - inner)  -- inside ring, positive
            end
        end,

        bounds = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            return cx - outer, cy - outer, cx + outer, cy + outer
        end,

        edge = function(self, count, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            local i, step = 0, PI2 / count
            return function()
                i = i + 1
                if i <= count then
                    local angle = (i - 1) * step
                    return cx + cos(angle) * outer, cy + sin(angle) * outer
                end
            end
        end,

        random = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            local inner = eval(innerR, ctx)
            local angle = random() * PI2
            local r = inner + random() * (outer - inner)
            return cx + cos(angle) * r, cy + sin(angle) * r
        end,

        containsBatch = function(self, xs, ys, n, out, ctx)
            out = out or {}
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local outer = eval(outerR, ctx)
            local inner = eval(innerR, ctx)
            local outer2 = outer * outer
            local inner2 = inner * inner
            for i = 1, n do
                local dx, dy = xs[i] - cx, ys[i] - cy
                local d2 = dx * dx + dy * dy
                out[i] = d2 <= outer2 and d2 >= inner2
            end
            return out
        end
    }
end

--- Create a regular polygon form
--- @param ox number|function Center X (or signal)
--- @param oy number|function Center Y (or signal)
--- @param sides number Number of sides (static, not signal)
--- @param radius number|function Circumradius (or signal)
--- @param rotation number|function Rotation in radians (or signal), default 0
--- @return table Form object
function Forms.polygon(ox, oy, sides, radius, rotation)
    rotation = rotation or 0
    local angleStep = PI2 / sides

    return {
        contains = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local rot = eval(rotation, ctx)
            local dx, dy = x - cx, y - cy
            local inside = false

            for i = 1, sides do
                local a1 = rot + (i - 1) * angleStep
                local a2 = rot + i * angleStep
                local x1, y1 = cos(a1) * r, sin(a1) * r
                local x2, y2 = cos(a2) * r, sin(a2) * r

                if ((y1 > dy) ~= (y2 > dy)) and
                   (dx < (x2 - x1) * (dy - y1) / (y2 - y1) + x1) then
                    inside = not inside
                end
            end
            return inside
        end,

        bounds = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            return cx - r, cy - r, cx + r, cy + r
        end,

        edge = function(self, count, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local rot = eval(rotation, ctx)
            local i, step = 0, PI2 / count
            return function()
                i = i + 1
                if i <= count then
                    local angle = rot + (i - 1) * step
                    return cx + cos(angle) * r, cy + sin(angle) * r
                end
            end
        end,

        random = function(self, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local rot = eval(rotation, ctx)

            -- Pick random triangle (fan from center)
            local tri = floor(random() * sides) + 1
            local a1 = rot + (tri - 1) * angleStep
            local a2 = rot + tri * angleStep

            -- Random point in triangle (center, v1, v2)
            local u, v = random(), random()
            if u + v > 1 then u, v = 1 - u, 1 - v end

            local x1, y1 = cos(a1) * r, sin(a1) * r
            local x2, y2 = cos(a2) * r, sin(a2) * r

            -- Barycentric: P = (1-u-v)*center + u*v1 + v*v2
            -- center is (0,0), so P = u*v1 + v*v2
            return cx + u * x1 + v * x2, cy + u * y1 + v * y2
        end,

        signedDistance = function(self, x, y, ctx)
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local rot = eval(rotation, ctx)
            local dx, dy = x - cx, y - cy

            -- Find minimum distance to any edge
            local minDist = huge
            local crossings = 0

            for i = 1, sides do
                local a1 = rot + (i - 1) * angleStep
                local a2 = rot + i * angleStep
                local x1, y1 = cos(a1) * r, sin(a1) * r
                local x2, y2 = cos(a2) * r, sin(a2) * r

                -- Ray casting for inside check
                if ((y1 > dy) ~= (y2 > dy)) and
                   (dx < (x2 - x1) * (dy - y1) / (y2 - y1) + x1) then
                    crossings = crossings + 1
                end

                -- Distance to edge segment
                local ex, ey = x2 - x1, y2 - y1
                local len2 = ex * ex + ey * ey
                local t = max(0, min(1, ((dx - x1) * ex + (dy - y1) * ey) / len2))
                local px, py = x1 + t * ex, y1 + t * ey
                local dist = sqrt((dx - px) * (dx - px) + (dy - py) * (dy - py))
                if dist < minDist then minDist = dist end
            end

            local inside = (crossings % 2) == 1
            return inside and minDist or -minDist
        end,

        containsBatch = function(self, xs, ys, n, out, ctx)
            out = out or {}
            local cx = eval(ox, ctx)
            local cy = eval(oy, ctx)
            local r = eval(radius, ctx)
            local rot = eval(rotation, ctx)

            -- Precompute vertices
            local verts = {}
            for i = 1, sides do
                local a = rot + (i - 1) * angleStep
                verts[i] = {cos(a) * r, sin(a) * r}
            end

            for j = 1, n do
                local dx, dy = xs[j] - cx, ys[j] - cy
                local inside = false
                for i = 1, sides do
                    local x1, y1 = verts[i][1], verts[i][2]
                    local ni = i % sides + 1
                    local x2, y2 = verts[ni][1], verts[ni][2]
                    if ((y1 > dy) ~= (y2 > dy)) and
                       (dx < (x2 - x1) * (dy - y1) / (y2 - y1) + x1) then
                        inside = not inside
                    end
                end
                out[j] = inside
            end
            return out
        end
    }
end

--------------------------------------------------------------------------------
-- COMBINATORS
-- Combine forms using set operations.
--------------------------------------------------------------------------------

function Forms.union(...)
    local forms = {...}
    return {
        contains = function(self, x, y, ctx)
            for _, form in ipairs(forms) do
                if form:contains(x, y, ctx) then
                    return true
                end
            end
            return false
        end,

        bounds = function(self, ctx)
            local minX, minY, maxX, maxY = huge, huge, -huge, -huge
            for i = 1, #forms do
                local x1, y1, x2, y2 = forms[i]:bounds(ctx)
                minX, minY = min(minX, x1), min(minY, y1)
                maxX, maxY = max(maxX, x2), max(maxY, y2)
            end
            return minX, minY, maxX, maxY
        end
    }
end

function Forms.intersect(...)
    local forms = {...}
    return {
        contains = function(self, x, y, ctx)
            for _, form in ipairs(forms) do
                if not form:contains(x, y, ctx) then
                    return false
                end
            end
            return true
        end,

        bounds = function(self, ctx)
            if #forms == 0 then return 0, 0, 0, 0 end
            return forms[1]:bounds(ctx)
        end
    }
end

function Forms.subtract(outer, inner)
    return {
        contains = function(self, x, y, ctx)
            return outer:contains(x, y, ctx) and not inner:contains(x, y, ctx)
        end,
        bounds = function(self, ctx)
            return outer:bounds(ctx)
        end
    }
end

--------------------------------------------------------------------------------
-- EVENT STREAMING
-- Track entities entering/exiting forms.
--------------------------------------------------------------------------------

function Forms.track(form, cfg)
    cfg = cfg or {}

    -- Spatial config (hysteresis)
    local enterMargin = cfg.enterMargin or 0
    local exitMargin = cfg.exitMargin or 0
    local hasHysteresis = enterMargin > 0 or exitMargin > 0

    -- Temporal config (throttle)
    local enterThrottle = cfg.enterThrottle or 0
    local exitThrottle = cfg.exitThrottle or 0
    local hasThrottle = enterThrottle > 0 or exitThrottle > 0

    return {
        form = form,
        queryFn = cfg.queryFn,
        contains = function(x, y, ctx)
            return form:contains(x, y, ctx)
        end,
        -- Hysteresis support (space-domain)
        enterMargin = enterMargin,
        exitMargin = exitMargin,
        hasHysteresis = hasHysteresis,
        -- Throttle support (time-domain)
        enterThrottle = enterThrottle,
        exitThrottle = exitThrottle,
        hasThrottle = hasThrottle,
        lastEnterTime = {},  -- per-entity timestamps
        lastExitTime = {},
        -- State tracking
        inside = {},
        cooldowns = {},
        onEnter = cfg.onEnter,
        onExit = cfg.onExit,
        whileInside = cfg.whileInside,
        enabled = cfg.enabled ~= false,
    }
end

-- Determine if entity should be considered "inside" with hysteresis
local function isInsideWithHysteresis(tracker, x, y, wasInside, ctx)
    local form = tracker.form
    if not tracker.hasHysteresis or not form.signedDistance then
        -- No hysteresis or form doesn't support it - use simple containment
        return form:contains(x, y, ctx)
    end

    local dist = form:signedDistance(x, y, ctx)
    if wasInside then
        -- Was inside: stay inside until dist < -exitMargin
        return dist >= -tracker.exitMargin
    else
        -- Was outside: enter when dist > enterMargin
        return dist > tracker.enterMargin
    end
end

local function trackerBounds(tracker, ctx)
    local minX, minY, maxX, maxY = tracker.form:bounds(ctx)
    if tracker.hasHysteresis then
        local margin = max(tracker.enterMargin, tracker.exitMargin)
        minX, minY, maxX, maxY = minX - margin, minY - margin, maxX + margin, maxY + margin
    end
    return minX, minY, maxX, maxY
end

-- Internal: Spatial mode - use queryFn to get nearby entities
local function updateTrackerSpatial(tracker, queryFn, dt, ctx)
    local minX, minY, maxX, maxY = trackerBounds(tracker, ctx)
    local nearby = queryFn(minX, minY, maxX, maxY)

    -- Clear reusable seen table
    for k in pairs(seenThisFrame) do seenThisFrame[k] = nil end

    for i = 1, #nearby do
        local e = nearby[i]
        local id = e.id or i
        seenThisFrame[id] = true
        local wasInside = tracker.inside[id] ~= nil
        local isInside = isInsideWithHysteresis(tracker, e.x, e.y, wasInside, ctx)
        handleTrackerTransition(tracker, id, e, isInside, dt)
    end

    -- Cleanup: fire onExit for entities no longer in query results
    for id, entity in pairs(tracker.inside) do
        if not seenThisFrame[id] then
            handleTrackerTransition(tracker, id, entity, false, dt)
        end
    end
end

-- Internal: Pull mode - iterate all entities
local function updateTrackerPull(tracker, entities, dt, ctx)
    local minX, minY, maxX, maxY = trackerBounds(tracker, ctx)

    for i, e in ipairs(entities) do
        local id = e.id or i
        local wasInside = tracker.inside[id] ~= nil
        -- Fast AABB rejection
        local isInside
        if e.x < minX or e.x > maxX or e.y < minY or e.y > maxY then
            isInside = false
        else
            isInside = isInsideWithHysteresis(tracker, e.x, e.y, wasInside, ctx)
        end
        handleTrackerTransition(tracker, id, e, isInside, dt)
    end
end

--- Update tracker state
--- @param tracker table The tracker from Forms.track()
--- @param entitiesOrDt table|number Entities list (pull mode) or dt (spatial mode)
--- @param dtOrCtx number|table dt (pull mode) or ctx (spatial mode)
--- @param ctx table|nil Context for signal evaluation
function Forms.updateTracker(tracker, entitiesOrDt, dtOrCtx, ctx)
    if not tracker.enabled then return end

    local queryFn = tracker.queryFn or defaultQueryFn
    if queryFn then
        -- Spatial mode: entitiesOrDt is dt, dtOrCtx is ctx
        updateTrackerSpatial(tracker, queryFn, entitiesOrDt, dtOrCtx)
    else
        -- Pull mode: entitiesOrDt is entities, dtOrCtx is dt, ctx is ctx
        updateTrackerPull(tracker, entitiesOrDt, dtOrCtx, ctx)
    end
end

--------------------------------------------------------------------------------
-- LOAD OPTIMIZATIONS
--------------------------------------------------------------------------------

local ok, opt = pcall(require, "opt")
if ok and opt.patchForms then
    opt.patchForms(Forms)
end

return Forms
