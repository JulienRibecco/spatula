--- Spatula Field Module
--- @module spatula.field
---
--- ============================================================================
--- Field = curve(distance) + source bookkeeping
--- ============================================================================
---
--- A field is a 2D spatial signal. Sample any (x,y), get a value.
---
--- Each source contributes: falloff(distance/radius) × value
--- Sources blend together via add/max/min.
---
--- FALLOFFS ARE CURVES over normalized distance [0,1].
--- By using Curve primitives, you get the full combinator system:
---
---   local pulsing = Curve.mul(Field.falloff.smooth, Curve.offset(Curve.sin(2), 1))
---   field:add(pos, { falloff = pulsing })
---
--- ============================================================================

local P = require("spatula.point")
local Curve = require("spatula.curve")
local Util = require("spatula.util")
local sqrt, max, min, floor, ceil, abs = Util.sqrt, Util.max, Util.min, Util.floor, Util.ceil, Util.abs
local huge = Util.huge
local eval = Util.eval

local Field = {}

-- Module-level state for global default queryFn
local defaultQueryFn = nil
local seenThisFrame = {}  -- Reused to avoid GC pressure

function Field.setDefaultQueryFn(fn)
    defaultQueryFn = fn
end
Field.__index = Field

--------------------------------------------------------------------------------
-- FALLOFF CURVES
-- These are Curves over normalized distance d ∈ [0,1].
-- At d=0 (center): typically 1. At d=1 (edge): typically 0.
--------------------------------------------------------------------------------

local rampDown = Curve.ramp(1, 0, 1)  -- 1 at center, 0 at edge

Field.falloff = {
    linear   = rampDown,                    -- 1-d
    smooth   = Curve.pow(rampDown, 2),      -- (1-d)²
    spike    = Curve.pow(rampDown, 4),      -- (1-d)⁴ sharp center
    gaussian = Curve.gaussian(1),           -- e^(-3d²) natural falloff
    constant = Curve.const(1),              -- uniform, no falloff
    inverse  = Curve.linear(1),             -- d (grows outward)
    ring     = Curve.sin(0.5, 1, 0),        -- peaks at middle distance
    -- Additional presets
    steep    = Curve.pow(rampDown, 6),      -- (1-d)^6 very sharp center
    soft     = Curve.pow(rampDown, 1.5),    -- (1-d)^1.5 gentler than smooth
    step     = function(t) return t < 0.5 and 1 or 0 end,  -- hard edge at 50% radius
}

--------------------------------------------------------------------------------
-- BLEND MODES
-- How overlapping sources combine.
--------------------------------------------------------------------------------

Field.blend = {
    add = function(a, b) return a + b end,  -- accumulate (default)
    max = function(a, b) return max(a, b) end,  -- strongest wins
    min = function(a, b) return min(a, b) end,  -- weakest wins
}

-- Helper to resolve falloff from config (avoids duplication)
local function resolveFalloff(name)
    if type(name) == "function" then return name end
    return Field.falloff[name] or Field.falloff.smooth
end

-- Helper to resolve blend from config (avoids duplication)
local function resolveBlend(name)
    if type(name) == "function" then return name end
    return Field.blend[name] or Field.blend.add
end

--------------------------------------------------------------------------------
-- FIELD CREATION
--------------------------------------------------------------------------------

function Field.new(config)
    config = config or {}
    local self = setmetatable({}, Field)

    self.sources = {}
    self.sourceCount = 0
    self.nextId = 1

    self.defaultFalloff = resolveFalloff(config.falloff or "smooth")
    self.blendFn = resolveBlend(config.blend or "add")
    self.base = config.base or 0
    self.decay = config.decay or 0

    return self
end

--------------------------------------------------------------------------------
-- SOURCE MANAGEMENT
--------------------------------------------------------------------------------

function Field:add(pos, configOrY, config)
    local x, y
    if type(configOrY) == "number" then
        x, y = pos, configOrY
        config = config or {}
    else
        x, y = P(pos)
        config = configOrY or {}
    end

    local falloff = self.defaultFalloff
    if config.falloff then
        if type(config.falloff) == "function" then
            falloff = config.falloff
        elseif Field.falloff[config.falloff] then
            falloff = Field.falloff[config.falloff]
        end
    end

    local source = {
        x = x,
        y = y,
        radius = config.radius or 50,
        value = config.value or 1,
        falloff = falloff,
        id = self.nextId,
        active = true,
    }

    self.sources[source.id] = source
    self.sourceCount = self.sourceCount + 1
    self.nextId = self.nextId + 1
    self._spatialDirty = true
    self._nativeDirty = true

    return source
end

function Field:remove(source)
    if source and source.id and self.sources[source.id] then
        self.sources[source.id] = nil
        self.sourceCount = self.sourceCount - 1
        self._spatialDirty = true
        self._nativeDirty = true
        return true
    end
    return false
end

function Field:move(source, pos, y)
    if source and self.sources[source.id] then
        source.x, source.y = P(pos, y)
        self._spatialDirty = true
        self._nativeDirty = true
    end
end

function Field:setValue(source, value)
    if source and self.sources[source.id] then
        source.value = value
        self._nativeDirty = true
    end
end

function Field:setRadius(source, radius)
    if source and self.sources[source.id] then
        source.radius = radius
        self._spatialDirty = true
        self._nativeDirty = true
    end
end

function Field:clear()
    self.sources = {}
    self.sourceCount = 0
    self._spatialDirty = true
    self._nativeDirty = true
end

function Field:count()
    return self.sourceCount
end

--------------------------------------------------------------------------------
-- QUADTREE SPATIAL INDEX
-- For fields with many sources (50+), reduces O(n) to O(log n) per sample.
--------------------------------------------------------------------------------

local Quadtree = {}
Quadtree.__index = Quadtree

function Quadtree.new(x, y, w, h, maxItems, maxDepth, depth)
    return setmetatable({
        x = x, y = y, w = w, h = h,
        items = {},
        children = nil,
        maxItems = maxItems or 8,
        maxDepth = maxDepth or 6,
        depth = depth or 0,
    }, Quadtree)
end

function Quadtree:subdivide()
    local hw, hh = self.w / 2, self.h / 2
    local x, y = self.x, self.y
    local mi, md, d = self.maxItems, self.maxDepth, self.depth + 1
    self.children = {
        Quadtree.new(x,      y,      hw, hh, mi, md, d),  -- NW
        Quadtree.new(x + hw, y,      hw, hh, mi, md, d),  -- NE
        Quadtree.new(x,      y + hh, hw, hh, mi, md, d),  -- SW
        Quadtree.new(x + hw, y + hh, hw, hh, mi, md, d),  -- SE
    }
end

function Quadtree:getQuadrant(sx, sy, radius)
    local midX = self.x + self.w / 2
    local midY = self.y + self.h / 2
    -- Check which quadrants the source overlaps
    local inNorth = sy - radius < midY
    local inSouth = sy + radius >= midY
    local inWest  = sx - radius < midX
    local inEast  = sx + radius >= midX
    return inNorth, inSouth, inWest, inEast
end

function Quadtree:insert(source)
    if self.children then
        local inN, inS, inW, inE = self:getQuadrant(source.x, source.y, source.radius)
        if inN and inW then self.children[1]:insert(source) end
        if inN and inE then self.children[2]:insert(source) end
        if inS and inW then self.children[3]:insert(source) end
        if inS and inE then self.children[4]:insert(source) end
        return
    end

    self.items[#self.items + 1] = source

    if #self.items > self.maxItems and self.depth < self.maxDepth then
        self:subdivide()
        for _, item in ipairs(self.items) do
            local inN, inS, inW, inE = self:getQuadrant(item.x, item.y, item.radius)
            if inN and inW then self.children[1]:insert(item) end
            if inN and inE then self.children[2]:insert(item) end
            if inS and inW then self.children[3]:insert(item) end
            if inS and inE then self.children[4]:insert(item) end
        end
        self.items = {}
    end
end

function Quadtree:query(x, y, out)
    out = out or {}
    -- Check if point is in this node's bounds
    if x < self.x or x >= self.x + self.w or y < self.y or y >= self.y + self.h then
        return out
    end

    for _, source in ipairs(self.items) do
        out[#out + 1] = source
    end

    if self.children then
        for _, child in ipairs(self.children) do
            child:query(x, y, out)
        end
    end

    return out
end

function Quadtree:clear()
    self.items = {}
    self.children = nil
end

--- Enable spatial indexing for faster sampling with many sources
--- @param bounds table|nil {minX, minY, maxX, maxY} or nil to auto-compute
function Field:enableSpatialIndex(bounds)
    if bounds then
        self._spatialBounds = {
            x = bounds[1],
            y = bounds[2],
            w = bounds[3] - bounds[1],
            h = bounds[4] - bounds[2],
        }
    else
        self._spatialBounds = nil  -- Will compute from sources
    end
    self._useSpatialIndex = true
    self._quadtree = nil
    self._spatialDirty = true
end

--- Disable spatial indexing
function Field:disableSpatialIndex()
    self._useSpatialIndex = false
    self._quadtree = nil
end

--- Rebuild the spatial index (called automatically when sampling if dirty)
function Field:rebuildIndex()
    if not self._useSpatialIndex then return end

    for _, source in pairs(self.sources) do
        if type(source.x) ~= "number" or type(source.y) ~= "number" or type(source.radius) ~= "number" then
            self._quadtree = nil
            return
        end
    end

    -- Compute bounds from sources if not specified
    local b = self._spatialBounds
    if not b then
        local minX, minY = huge, huge
        local maxX, maxY = -huge, -huge
        for _, source in pairs(self.sources) do
            local r = source.radius
            if source.x - r < minX then minX = source.x - r end
            if source.y - r < minY then minY = source.y - r end
            if source.x + r > maxX then maxX = source.x + r end
            if source.y + r > maxY then maxY = source.y + r end
        end
        if minX == huge then
            minX, minY, maxX, maxY = 0, 0, 100, 100
        end
        b = { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
    end

    self._quadtree = Quadtree.new(b.x, b.y, b.w, b.h)

    for _, source in pairs(self.sources) do
        if source.active then
            self._quadtree:insert(source)
        end
    end

    self._spatialDirty = false
end

--- Internal: sample using spatial index
function Field:_sampleWithIndex(x, y, ctx)
    if self._spatialDirty then
        self:rebuildIndex()
    end

    local result = eval(self.base, ctx)
    local count = 0
    local nearby = self._quadtree:query(x, y)

    for _, source in ipairs(nearby) do
        if source.active then
            local sx = eval(source.x, ctx)
            local sy = eval(source.y, ctx)
            local radius = eval(source.radius, ctx)
            local value = eval(source.value, ctx)

            local dx = x - sx
            local dy = y - sy
            local dist = sqrt(dx * dx + dy * dy)

            if dist < radius then
                local normalizedDist = dist / radius
                local influence = source.falloff(normalizedDist, ctx) * value
                count = count + 1
                result = self.blendFn(result, influence, count)
            end
        end
    end

    return result
end

--------------------------------------------------------------------------------
-- SAMPLING
--------------------------------------------------------------------------------

function Field:sample(pos, y, ctx)
    local x
    -- Handle (x, y, ctx) or ({x, y}, ctx) signatures
    if type(y) == "table" then
        ctx = y
        x, y = P(pos)
    else
        x, y = P(pos, y)
    end

    -- Use spatial index if enabled and we have many sources
    if self._useSpatialIndex then
        if self._spatialDirty or not self._quadtree then self:rebuildIndex() end
        if self._quadtree then return self:_sampleWithIndex(x, y, ctx) end
    end

    local result = eval(self.base, ctx)
    local count = 0

    for _, source in pairs(self.sources) do
        if source.active then
            local sx = eval(source.x, ctx)
            local sy = eval(source.y, ctx)
            local radius = eval(source.radius, ctx)
            local value = eval(source.value, ctx)

            local dx = x - sx
            local dy = y - sy
            local dist = sqrt(dx * dx + dy * dy)

            if dist < radius then
                local normalizedDist = dist / radius
                local influence = source.falloff(normalizedDist, ctx) * value
                count = count + 1
                result = self.blendFn(result, influence, count)
            end
        end
    end

    return result
end

--- Batch sample multiple positions
--- @param xs table X coordinates (1-indexed)
--- @param ys table Y coordinates
--- @param n number Count of positions
--- @param outValues table|nil Output array (optional, creates if nil)
--- @param ctx table|nil Context for signal evaluation
--- @return table values
function Field:sampleBatch(xs, ys, n, outValues, ctx)
    outValues = outValues or {}
    for i = 1, n do
        outValues[i] = self:sample(xs[i], ys[i], ctx)
    end
    return outValues
end

--- Batch sample with gradients
--- @param xs table X coordinates
--- @param ys table Y coordinates
--- @param n number Count
--- @param outValues table|nil Output values
--- @param outGx table|nil Output X gradients
--- @param outGy table|nil Output Y gradients
--- @param ctx table|nil Context for signal evaluation
--- @return table, table, table values, gradX, gradY
function Field:sampleBatchWithGradient(xs, ys, n, outValues, outGx, outGy, ctx)
    outValues = outValues or {}
    outGx = outGx or {}
    outGy = outGy or {}
    for i = 1, n do
        outValues[i] = self:sample(xs[i], ys[i], ctx)
        outGx[i], outGy[i] = self:gradient({xs[i], ys[i]}, nil, ctx)
    end
    return outValues, outGx, outGy
end

--- Check if native acceleration is available
--- @return boolean
function Field.hasNativeSupport()
    return false
end

--------------------------------------------------------------------------------
-- GRADIENT
--------------------------------------------------------------------------------

function Field:gradient(pos, epsilon, ctx)
    local x, y = P(pos)
    -- Handle (pos, ctx) signature
    if type(epsilon) == "table" then
        ctx = epsilon
        epsilon = 2
    end
    epsilon = epsilon or 2

    local v = self:sample(x, y, ctx)
    local vx = self:sample(x + epsilon, y, ctx)
    local vy = self:sample(x, y + epsilon, ctx)

    return (vx - v) / epsilon, (vy - v) / epsilon
end

--------------------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------------------

function Field:update(dt)
    if self.decay > 0 then
        local factor = 1 - self.decay * dt
        for _, source in pairs(self.sources) do
            source.value = source.value * factor
            if source.value < 0.01 then
                source.active = false
            end
        end
    end
end

--------------------------------------------------------------------------------
-- FIELD COMBINATORS
-- Combine fields just like curves: add, sub, mul, max, min.
-- Creates a new field-like object with sample() and gradient().
--------------------------------------------------------------------------------

local function compositeField()
    return {
        gradient = Field.gradient,
    }
end

function Field.combine(a, b)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return a:sample(pos, y, ctx) + b:sample(pos, y, ctx) end
    return f
end

function Field.sub(a, b)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return a:sample(pos, y, ctx) - b:sample(pos, y, ctx) end
    return f
end

function Field.mul(a, b)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return a:sample(pos, y, ctx) * b:sample(pos, y, ctx) end
    return f
end

function Field.max(a, b)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return max(a:sample(pos, y, ctx), b:sample(pos, y, ctx)) end
    return f
end

function Field.min(a, b)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return min(a:sample(pos, y, ctx), b:sample(pos, y, ctx)) end
    return f
end

function Field.invert(field)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return 1 - field:sample(pos, y, ctx) end
    return f
end

function Field.scale(field, factor)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return field:sample(pos, y, ctx) * factor end
    return f
end

function Field.clamp(field, lo, hi)
    local f = compositeField()
    f.sample = function(self, pos, y, ctx) return max(lo, min(hi, field:sample(pos, y, ctx))) end
    return f
end

--------------------------------------------------------------------------------
-- RESOLUTION COMBINATOR
-- Performance management: reduce evaluation frequency in time and/or space.
-- Returns a field-like object that caches samples.
--
--   local fastField = Field.resolution(enemyField, {
--       temporal = 0.1,                          -- re-evaluate every 100ms
--       spatial = 20,                            -- grid cell size
--       getTime = function() return gameTime end -- user provides time source
--   })
--
-- Composes with all other combinators:
--   Field.combine(Field.resolution(a, cfg), b)
--   Field.clamp(Field.resolution(a, cfg), 0, 1)
--------------------------------------------------------------------------------

function Field.resolution(field, config)
    config = config or {}
    local temporal = config.temporal or 0
    local spatial = config.spatial or 1
    local getTime = config.getTime or function() return 0 end

    local sampleCache = {}
    local gradientCache = {}
    local lastClearTime = -huge

    -- Use numeric key to avoid string allocation (assumes grid coords < 1M)
    local function getCacheKey(x, y)
        local gx = floor(x / spatial)
        local gy = floor(y / spatial)
        return gx * 1000003 + gy  -- prime multiplier avoids collisions
    end

    local function checkTime()
        local now = getTime()
        if temporal > 0 and now - lastClearTime > temporal then
            sampleCache = {}
            gradientCache = {}
            lastClearTime = now
        end
    end

    local f = {}

    f.sample = function(self, pos, y, ctx)
        if type(y) == "table" then ctx, y = y, nil end
        if ctx ~= nil then return field:sample(pos, y, ctx) end
        local x
        x, y = P(pos, y)

        checkTime()

        local key = getCacheKey(x, y)
        if sampleCache[key] == nil then
            sampleCache[key] = field:sample(x, y)
        end

        return sampleCache[key]
    end

    f.gradient = function(self, pos, eps, ctx)
        if type(eps) == "table" then ctx, eps = eps, nil end
        if ctx ~= nil then return field:gradient(pos, eps, ctx) end
        local x, y = P(pos)
        eps = eps or 2

        checkTime()

        -- Cache gradient separately — compute from raw field, not cached samples
        local key = getCacheKey(x, y)
        if gradientCache[key] == nil then
            local gx, gy = field:gradient({x, y}, eps)
            gradientCache[key] = { gx, gy }
        end

        return gradientCache[key][1], gradientCache[key][2]
    end

    f.invalidate = function(self)
        sampleCache = {}
        gradientCache = {}
        lastClearTime = getTime()
    end

    return f
end

--------------------------------------------------------------------------------
-- GRIDDED FIELD
-- Precomputed O(1) sampling for high-entity-count scenarios.
-- Compute once per frame, sample O(1) per entity.
--
--   local grid = Field.gridded({
--       world = {0, 0, 800, 600},      -- {minX, minY, maxX, maxY}
--       cellSize = 32,                  -- pixels per grid cell
--       falloff = "smooth",             -- falloff curve
--       blend = "add",                  -- blend mode
--   })
--
--   grid:add(x, y, { radius = 50, value = 1 })
--   grid:update()  -- recompute grid (call once per frame)
--   local value = grid:sample(x, y)  -- O(1)
--   local gx, gy = grid:gradient(x, y)  -- O(3)
--------------------------------------------------------------------------------

-- FFI support (optional, falls back to Lua tables)
local ffi = nil
local hasFfi = pcall(function() ffi = require("ffi") end)

-- FFI struct for grid cells (defined once)
local ffiDefined = false
local function ensureFFI()
    if hasFfi and not ffiDefined then
        ffi.cdef[[
            typedef struct { float value; float gx; float gy; } SpatulaFieldCell;
        ]]
        ffiDefined = true
    end
end

local GridField = {}
GridField.__index = GridField

function Field.gridded(config)
    config = config or {}
    if hasFfi then ensureFFI() end

    local self = setmetatable({}, GridField)

    -- World bounds
    local world = config.world or {0, 0, 800, 600}
    self.minX, self.minY = world[1], world[2]
    self.maxX, self.maxY = world[3], world[4]
    self.cellSize = config.cellSize or 32

    -- Grid dimensions
    self.cols = ceil((self.maxX - self.minX) / self.cellSize)
    self.rows = ceil((self.maxY - self.minY) / self.cellSize)
    local total = self.cols * self.rows

    -- Grid storage (FFI array or Lua table)
    if hasFfi then
        self.grid = ffi.new("SpatulaFieldCell[?]", total)
        self.useFfi = true
    else
        self.grid = {}
        for i = 0, total - 1 do
            self.grid[i] = { value = 0, gx = 0, gy = 0 }
        end
        self.useFfi = false
    end
    self.gridTotal = total

    -- Source management (same as regular Field)
    self.sources = {}
    self.sourceCount = 0
    self.nextId = 1

    self.defaultFalloff = resolveFalloff(config.falloff or "smooth")
    self.blendFn = resolveBlend(config.blend or "add")
    self.base = config.base or 0
    self.dirty = true

    return self
end

-- Source management (marks dirty)
function GridField:add(pos, configOrY, config)
    local x, y
    if type(configOrY) == "number" then
        x, y = pos, configOrY
        config = config or {}
    else
        x, y = P(pos)
        config = configOrY or {}
    end

    local falloff = self.defaultFalloff
    if config.falloff then
        if type(config.falloff) == "function" then
            falloff = config.falloff
        elseif Field.falloff[config.falloff] then
            falloff = Field.falloff[config.falloff]
        end
    end

    local source = {
        x = x,
        y = y,
        radius = config.radius or 50,
        value = config.value or 1,
        falloff = falloff,
        id = self.nextId,
        active = true,
    }

    self.sources[source.id] = source
    self.sourceCount = self.sourceCount + 1
    self.nextId = self.nextId + 1
    self.dirty = true

    return source
end

function GridField:remove(source)
    if source and source.id and self.sources[source.id] then
        self.sources[source.id] = nil
        self.sourceCount = self.sourceCount - 1
        self.dirty = true
        return true
    end
    return false
end

function GridField:move(source, pos, y)
    if source and self.sources[source.id] then
        source.x, source.y = P(pos, y)
        self.dirty = true
    end
end

function GridField:setValue(source, value)
    if source and self.sources[source.id] then
        source.value = value
        self.dirty = true
    end
end

function GridField:setRadius(source, radius)
    if source and self.sources[source.id] then
        source.radius = radius
        self.dirty = true
    end
end

function GridField:clear()
    self.sources = {}
    self.sourceCount = 0
    self.dirty = true
end

function GridField:count()
    return self.sourceCount
end

-- Recompute grid from sources (call once per frame)
function GridField:update()
    if not self.dirty then return end

    local grid = self.grid
    local cols = self.cols
    local rows = self.rows
    local cellSize = self.cellSize
    local minX, minY = self.minX, self.minY
    local base = self.base
    local blendFn = self.blendFn

    -- Clear grid
    for i = 0, self.gridTotal - 1 do
        grid[i].value = base
        grid[i].gx = 0
        grid[i].gy = 0
    end

    -- Splat each source into nearby cells
    for _, source in pairs(self.sources) do
        if source.active then
            local sx, sy = source.x, source.y
            local radius = source.radius
            local value = source.value
            local falloff = source.falloff

            local cellRadius = ceil(radius / cellSize)
            local cx = floor((sx - minX) / cellSize)
            local cy = floor((sy - minY) / cellSize)

            for dy = -cellRadius, cellRadius do
                for dx = -cellRadius, cellRadius do
                    local gx = cx + dx
                    local gy = cy + dy

                    if gx >= 0 and gx < cols and gy >= 0 and gy < rows then
                        -- Cell center in world space
                        local cellX = minX + (gx + 0.5) * cellSize
                        local cellY = minY + (gy + 0.5) * cellSize

                        local distX = cellX - sx
                        local distY = cellY - sy
                        local dist = sqrt(distX * distX + distY * distY)

                        if dist < radius then
                            local normalized = dist / radius
                            local influence = falloff(normalized, nil) * value

                            local idx = gy * cols + gx
                            grid[idx].value = blendFn(grid[idx].value, influence, 1)

                            -- Gradient points away from source
                            if dist > 0.01 then
                                local nx, ny = distX / dist, distY / dist
                                grid[idx].gx = grid[idx].gx + nx * influence
                                grid[idx].gy = grid[idx].gy + ny * influence
                            end
                        end
                    end
                end
            end
        end
    end

    self.dirty = false
end

-- O(1) sample from precomputed grid
function GridField:sample(pos, y)
    local x
    x, y = P(pos, y)

    local gx = floor((x - self.minX) / self.cellSize)
    local gy = floor((y - self.minY) / self.cellSize)

    if gx < 0 or gx >= self.cols or gy < 0 or gy >= self.rows then
        return self.base
    end

    return self.grid[gy * self.cols + gx].value
end

-- O(3) gradient from precomputed grid
function GridField:gradient(pos, epsilon)
    local x, y = P(pos)
    epsilon = epsilon or self.cellSize

    -- Use finite differences on grid samples
    local v = self:sample(x, y)
    local vx = self:sample(x + epsilon, y)
    local vy = self:sample(x, y + epsilon)

    return (vx - v) / epsilon, (vy - v) / epsilon
end

-- Direct gradient lookup (uses precomputed gradients)
function GridField:gradientDirect(pos, y)
    local x
    x, y = P(pos, y)

    local gx = floor((x - self.minX) / self.cellSize)
    local gy = floor((y - self.minY) / self.cellSize)

    if gx < 0 or gx >= self.cols or gy < 0 or gy >= self.rows then
        return 0, 0
    end

    local cell = self.grid[gy * self.cols + gx]
    return cell.gx, cell.gy
end

-- Force recomputation on next update()
function GridField:invalidate()
    self.dirty = true
end

--- Optimized batch sample for GridField (direct grid access)
--- @param xs table X coordinates
--- @param ys table Y coordinates
--- @param n number Count
--- @param outValues table|nil Output array
--- @return table values
function GridField:sampleBatch(xs, ys, n, outValues)
    outValues = outValues or {}
    local grid = self.grid
    local cols = self.cols
    local rows = self.rows
    local cellSize = self.cellSize
    local minX, minY = self.minX, self.minY
    local base = self.base

    for i = 1, n do
        local gx = floor((xs[i] - minX) / cellSize)
        local gy = floor((ys[i] - minY) / cellSize)

        if gx >= 0 and gx < cols and gy >= 0 and gy < rows then
            outValues[i] = grid[gy * cols + gx].value
        else
            outValues[i] = base
        end
    end
    return outValues
end

--- Optimized batch sample with gradients for GridField
--- @param xs table X coordinates
--- @param ys table Y coordinates
--- @param n number Count
--- @param outValues table|nil Output values
--- @param outGx table|nil Output X gradients
--- @param outGy table|nil Output Y gradients
--- @return table, table, table values, gradX, gradY
function GridField:sampleBatchWithGradient(xs, ys, n, outValues, outGx, outGy)
    outValues = outValues or {}
    outGx = outGx or {}
    outGy = outGy or {}
    local grid = self.grid
    local cols = self.cols
    local rows = self.rows
    local cellSize = self.cellSize
    local minX, minY = self.minX, self.minY
    local base = self.base

    for i = 1, n do
        local gx = floor((xs[i] - minX) / cellSize)
        local gy = floor((ys[i] - minY) / cellSize)

        if gx >= 0 and gx < cols and gy >= 0 and gy < rows then
            local cell = grid[gy * cols + gx]
            outValues[i] = cell.value
            outGx[i] = cell.gx
            outGy[i] = cell.gy
        else
            outValues[i] = base
            outGx[i] = 0
            outGy[i] = 0
        end
    end
    return outValues, outGx, outGy
end

--------------------------------------------------------------------------------
-- EVENT STREAMING
-- Track entities crossing field thresholds. Fires callbacks on transitions.
--
--   local tracker = Field.track(dangerField, ">", 0.5, {
--       onEnter = function(entity, tracker) ... end,  -- crossed above 0.5
--       onExit  = function(entity, tracker) ... end,  -- dropped below 0.5
--   })
--
--   -- In update loop:
--   Field.updateTracker(tracker, entities, dt)
--------------------------------------------------------------------------------

local comparators = {
    [">"]  = function(v, t) return v > t end,
    ["<"]  = function(v, t) return v < t end,
    [">="] = function(v, t) return v >= t end,
    ["<="] = function(v, t) return v <= t end,
    ["=="] = function(v, t) return abs(v - t) < 0.001 end,
}

function Field.track(field, op, threshold, cfg)
    cfg = cfg or {}
    local compare = comparators[op] or comparators[">"]
    local exitThreshold = cfg.exitThreshold or threshold

    return {
        field = field,                      -- stored for push mode
        threshold = threshold,
        exitThreshold = exitThreshold,      -- for hysteresis
        compare = compare,
        queryFn = cfg.queryFn,              -- spatial query callback
        contains = function(point)
            local px, py = P(point)
            return compare(field:sample(px, py), threshold)
        end,
        inside = {},
        cooldowns = {},
        onEnter = cfg.onEnter,
        onExit = cfg.onExit,
        whileInside = cfg.whileInside,
        enabled = cfg.enabled ~= false,
    }
end

-- Internal: Push mode - iterate sources, query nearby entities
local function updateTrackerPush(tracker, queryFn, dt)
    local field = tracker.field
    local inside = tracker.inside
    local compare = tracker.compare
    local threshold = tracker.threshold
    local exitThreshold = tracker.exitThreshold

    -- Clear reusable seen table (avoids GC pressure)
    for k in pairs(seenThisFrame) do seenThisFrame[k] = nil end

    -- Push from sources: query entities near each active source
    for _, source in pairs(field.sources) do
        if source.active then
            local nearby = queryFn(source.x, source.y, source.radius)

            for i = 1, #nearby do
                local e = nearby[i]
                local id = e.id or e  -- use entity as key if no id

                if not seenThisFrame[id] then
                    seenThisFrame[id] = true

                    -- Narrowphase: sample field at entity position
                    local val = field:sample(e.x, e.y)
                    local wasInside = inside[id]

                    -- Hysteresis: use threshold for enter, exitThreshold for exit
                    local isInside
                    if wasInside then
                        isInside = compare(val, exitThreshold)
                    else
                        isInside = compare(val, threshold)
                    end

                    -- Enter transition
                    if isInside and not wasInside then
                        inside[id] = e  -- store entity ref for cleanup
                        tracker.cooldowns[id] = 0
                        if tracker.onEnter then
                            tracker.onEnter(e, tracker)
                        end
                    end

                    -- Exit transition
                    if not isInside and wasInside then
                        inside[id] = nil
                        tracker.cooldowns[id] = nil
                        if tracker.onExit then
                            tracker.onExit(e, tracker)
                        end
                    end

                    -- whileInside with cooldown
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
    end

    -- Cleanup: entities that left all source ranges
    for id, entity in pairs(inside) do
        if not seenThisFrame[id] then
            -- Double-check they're actually out
            local val = field:sample(entity.x, entity.y)
            if not compare(val, exitThreshold) then
                inside[id] = nil
                tracker.cooldowns[id] = nil
                if tracker.onExit then
                    tracker.onExit(entity, tracker)
                end
            end
        end
    end
end

-- Internal: Pull mode - iterate all entities (original behavior)
local function updateTrackerPull(tracker, entities, dt)
    local compare = tracker.compare
    local threshold = tracker.threshold
    local exitThreshold = tracker.exitThreshold
    local field = tracker.field
    local inside = tracker.inside

    for i, e in ipairs(entities) do
        local id = e.id or i
        local wasInside = inside[id]

        -- Sample field and apply hysteresis
        local val = field:sample(e.x, e.y)
        local isInside
        if wasInside then
            isInside = compare(val, exitThreshold)
        else
            isInside = compare(val, threshold)
        end

        -- Enter transition
        if isInside and not wasInside then
            inside[id] = true
            tracker.cooldowns[id] = 0
            if tracker.onEnter then
                tracker.onEnter(e, tracker)
            end
        end

        -- Exit transition
        if not isInside and wasInside then
            inside[id] = nil
            tracker.cooldowns[id] = nil
            if tracker.onExit then
                tracker.onExit(e, tracker)
            end
        end

        -- whileInside with cooldown
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

--- Update tracker state for entities crossing field thresholds
--- @param tracker table The tracker state from Field.track()
--- @param dtOrEntities number|table If queryFn set: dt. Otherwise: entities list
--- @param dt number|nil Only needed if passing entities (old API)
function Field.updateTracker(tracker, dtOrEntities, dt)
    if not tracker.enabled then return end

    local queryFn = tracker.queryFn or defaultQueryFn
    if queryFn then
        -- Push mode: use queryFn (tracker-specific or global default)
        updateTrackerPush(tracker, queryFn, dtOrEntities)
    else
        -- Pull mode: requires entities list
        updateTrackerPull(tracker, dtOrEntities, dt)
    end
end

--------------------------------------------------------------------------------
-- LOAD OPTIMIZATIONS
--------------------------------------------------------------------------------

local ok, opt = pcall(require, "opt")
if ok and opt.patchField then
    opt.patchField(Field)
end

return Field
