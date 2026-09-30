--- Spatula Forms Optimizations
--- @module spatula.opt.forms
---
--- Performance utilities for Forms:
--- - SpatialHash for efficient entity lookup
--- - containsBatch() for batch containment tests
--- - Native FFI acceleration
--- - updateTrackerSpatial/Delta for optimized tracking

local floor = math.floor

local M = {}

-- FFI state (set by _init)
local ffi, float_array, uint8_array, forms_native

-- Numeric key for spatial hash (avoids string allocation)
-- Supports coords roughly -500k to +500k
local function cellKey(cx, cy)
    return cx * 1000003 + cy
end

--------------------------------------------------------------------------------
-- SPATIAL HASH
--------------------------------------------------------------------------------

local SpatialHash = {}
SpatialHash.__index = SpatialHash

function M.SpatialHash(cellSize)
    return setmetatable({
        cellSize = cellSize or 64,
        cells = {},
        entityCell = {},
    }, SpatialHash)
end

function SpatialHash:clear()
    self.cells = {}
    self.entityCell = {}
end

function SpatialHash:insert(entity, id)
    id = id or entity.id
    local cs = self.cellSize
    local cx = floor(entity.x / cs)
    local cy = floor(entity.y / cs)
    local key = cellKey(cx, cy)

    local oldKey = self.entityCell[id]
    if oldKey and oldKey ~= key then
        local oldCell = self.cells[oldKey]
        if oldCell then
            for i = 1, #oldCell do
                local e = oldCell[i]
                if (e.id or i) == id then
                    table.remove(oldCell, i)
                    break
                end
            end
        end
    end

    local cell = self.cells[key]
    if not cell then
        cell = {}
        self.cells[key] = cell
    end
    cell[#cell + 1] = entity
    self.entityCell[id] = key
end

function SpatialHash:remove(id)
    local key = self.entityCell[id]
    if not key then return end

    local cell = self.cells[key]
    if cell then
        for i = 1, #cell do
            local e = cell[i]
            if (e.id or i) == id then
                table.remove(cell, i)
                break
            end
        end
    end
    self.entityCell[id] = nil
end

function SpatialHash:queryBounds(minX, minY, maxX, maxY, out)
    out = out or {}
    local cells = self.cells
    local cs = self.cellSize
    local cx1, cy1 = floor(minX / cs), floor(minY / cs)
    local cx2, cy2 = floor(maxX / cs), floor(maxY / cs)

    for cx = cx1, cx2 do
        for cy = cy1, cy2 do
            local cell = cells[cellKey(cx, cy)]
            if cell then
                for i = 1, #cell do
                    out[#out + 1] = cell[i]
                end
            end
        end
    end
    return out
end

function SpatialHash:rebuild(entities)
    self:clear()
    for i = 1, #entities do
        local e = entities[i]
        self:insert(e, e.id or i)
    end
end

--------------------------------------------------------------------------------
-- BATCH CONTAINMENT (Lua)
--------------------------------------------------------------------------------

function M.circleContainsBatch(origin, size, xs, ys, n, out, P)
    out = out or {}
    local ox, oy = P(origin)
    local r2 = size * size
    for i = 1, n do
        local dx = xs[i] - ox
        local dy = ys[i] - oy
        out[i] = (dx * dx + dy * dy) <= r2
    end
    return out
end

function M.rectContainsBatch(origin, size, ratio, xs, ys, n, out, P)
    out = out or {}
    local ox, oy = P(origin)
    local hw, hh = size * ratio, size
    local abs = math.abs
    for i = 1, n do
        local dx = abs(xs[i] - ox)
        local dy = abs(ys[i] - oy)
        out[i] = dx <= hw and dy <= hh
    end
    return out
end

function M.ellipseContainsBatch(origin, size, rx, ry, xs, ys, n, out, P)
    out = out or {}
    local ox, oy = P(origin)
    local sizeRx, sizeRy = size * rx, size * ry
    for i = 1, n do
        local dx = (xs[i] - ox) / sizeRx
        local dy = (ys[i] - oy) / sizeRy
        out[i] = (dx * dx + dy * dy) <= 1
    end
    return out
end

--------------------------------------------------------------------------------
-- NATIVE FFI BATCH CONTAINMENT
--------------------------------------------------------------------------------

local function toFloatArray(t, n)
    local arr = float_array(n)
    for i = 1, n do
        arr[i - 1] = t[i]
    end
    return arr
end

function M.circleContainsBatchNative(ox, oy, radius, xs, ys, n, out)
    out = out or {}
    local xs_ffi = toFloatArray(xs, n)
    local ys_ffi = toFloatArray(ys, n)
    local out_ffi = uint8_array(n)

    forms_native.circle_contains_batch_fast(ox, oy, radius * radius, xs_ffi, ys_ffi, out_ffi, n)

    for i = 1, n do
        out[i] = out_ffi[i - 1] == 1
    end
    return out
end

function M.rectContainsBatchNative(ox, oy, half_w, half_h, xs, ys, n, out)
    out = out or {}
    local xs_ffi = toFloatArray(xs, n)
    local ys_ffi = toFloatArray(ys, n)
    local out_ffi = uint8_array(n)

    forms_native.rect_contains_batch(ox, oy, half_w, half_h, xs_ffi, ys_ffi, out_ffi, n)

    for i = 1, n do
        out[i] = out_ffi[i - 1] == 1
    end
    return out
end

function M.ellipseContainsBatchNative(ox, oy, rx, ry, xs, ys, n, out)
    out = out or {}
    local xs_ffi = toFloatArray(xs, n)
    local ys_ffi = toFloatArray(ys, n)
    local out_ffi = uint8_array(n)

    forms_native.ellipse_contains_batch(ox, oy, rx, ry, xs_ffi, ys_ffi, out_ffi, n)

    for i = 1, n do
        out[i] = out_ffi[i - 1] == 1
    end
    return out
end

--------------------------------------------------------------------------------
-- OPTIMIZED TRACKER UPDATES
--------------------------------------------------------------------------------

function M.updateTrackerSpatial(tracker, spatialHash, dt)
    if not tracker.enabled then return end

    local minX, minY, maxX, maxY = tracker.bounds[1], tracker.bounds[2],
                                   tracker.bounds[3], tracker.bounds[4]

    local nearby = spatialHash:queryBounds(minX, minY, maxX, maxY)
    local seen = {}

    for _, e in ipairs(nearby) do
        local id = e.id
        if id then
            seen[id] = true
            local wasInside = tracker.inside[id]
            local isInside = tracker.contains({e.x, e.y})

            if isInside and not wasInside then
                tracker.inside[id] = true
                tracker.cooldowns[id] = 0
                if tracker.onEnter then
                    tracker.onEnter(e, tracker)
                end
            end

            if not isInside and wasInside then
                tracker.inside[id] = nil
                tracker.cooldowns[id] = nil
                if tracker.onExit then
                    tracker.onExit(e, tracker)
                end
            end

            if isInside and tracker.whileInside then
                tracker.cooldowns[id] = (tracker.cooldowns[id] or 0) - dt
                if tracker.cooldowns[id] <= 0 then
                    tracker.cooldowns[id] = tracker.whileInside.cooldown or 1
                    if tracker.whileInside.action then
                        tracker.whileInside.action(e, tracker)
                    end
                end
            end
        end
    end

    for id in pairs(tracker.inside) do
        if not seen[id] then
            tracker.inside[id] = nil
            tracker.cooldowns[id] = nil
        end
    end
end

function M.updateTrackerDelta(tracker, entities, movedIds, dt)
    if not tracker.enabled then return end

    local minX, minY, maxX, maxY = tracker.bounds[1], tracker.bounds[2],
                                   tracker.bounds[3], tracker.bounds[4]

    for id in pairs(movedIds) do
        local e = entities[id]
        if e then
            local wasInside = tracker.inside[id]

            local isInside
            if e.x < minX or e.x > maxX or e.y < minY or e.y > maxY then
                isInside = false
            else
                isInside = tracker.contains({e.x, e.y})
            end

            if isInside and not wasInside then
                tracker.inside[id] = true
                tracker.cooldowns[id] = 0
                if tracker.onEnter then
                    tracker.onEnter(e, tracker)
                end
            end

            if not isInside and wasInside then
                tracker.inside[id] = nil
                tracker.cooldowns[id] = nil
                if tracker.onExit then
                    tracker.onExit(e, tracker)
                end
            end

            if isInside and tracker.whileInside then
                tracker.cooldowns[id] = (tracker.cooldowns[id] or 0) - dt
                if tracker.cooldowns[id] <= 0 then
                    tracker.cooldowns[id] = tracker.whileInside.cooldown or 1
                    if tracker.whileInside.action then
                        tracker.whileInside.action(e, tracker)
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function M._init(Forms, Opt)
    -- Add SpatialHash
    Forms.SpatialHash = M.SpatialHash

    -- Add optimized tracker updates
    Forms.updateTrackerSpatial = M.updateTrackerSpatial
    Forms.updateTrackerDelta = M.updateTrackerDelta

    -- Setup FFI if available
    if Opt.hasFFI then
        ffi = Opt.ffi
        float_array = ffi.typeof("float[?]")
        uint8_array = ffi.typeof("uint8_t[?]")
    end

    -- Setup native library if available
    if Opt.hasNative then
        forms_native = Opt.native
        Forms._nativeCircle = M.circleContainsBatchNative
        Forms._nativeRect = M.rectContainsBatchNative
        Forms._nativeEllipse = M.ellipseContainsBatchNative
        Forms.hasNativeSupport = function() return true end
    else
        Forms.hasNativeSupport = function() return false end
    end

    -- Note: Forms now have containsBatch built-in via the new factory API
    -- Each form instance returned by Forms.circle(), Forms.rect(), etc.
    -- already has :containsBatch(xs, ys, n, out, ctx) method
end

return M
