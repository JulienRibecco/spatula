--- Spatula Field Optimizations
--- @module spatula.opt.field
---
--- Native FFI acceleration for Field batch sampling:
--- - SIMD-accelerated batch sampling via C extension
--- - Falloff LUT baking for fast evaluation

local M = {}

-- FFI state (set by _init)
local ffi, float_array, field_native
local additiveBlend, staticFalloffs

--------------------------------------------------------------------------------
-- NATIVE CACHE PREPARATION
--------------------------------------------------------------------------------

--- Prepare native source cache (SoA layout for C)
--- @param self Field The field instance
--- @return table|nil Native cache or nil if not available
local function prepareNativeCache(self)
    if not field_native or self.blendFn ~= additiveBlend or type(self.base) ~= "number" then return nil end
    local cache = self._nativeCache
    local dirty = self._nativeDirty or not cache
    -- Native code supports static numeric sources and built-in falloffs only.
    -- Unknown curves may read active/global signals even without an explicit ctx.
    for _, src in pairs(self.sources) do
        if src.active and (type(src.x) ~= "number" or type(src.y) ~= "number"
            or type(src.radius) ~= "number" or src.radius <= 0
            or type(src.value) ~= "number" or not staticFalloffs[src.falloff]) then
            return nil
        end
        local previous = cache and cache.sources and cache.sources[src]
        if src.active then
            if not previous or previous[1] ~= src.x or previous[2] ~= src.y
                or previous[3] ~= src.radius or previous[4] ~= src.value or previous[5] ~= src.falloff then
                dirty = true
            end
        elseif previous then
            dirty = true
        end
    end

    local n = self.sourceCount
    if n == 0 then return nil end

    -- Check if cache needs rebuild
    if not dirty and cache.sourceCount == n then
        return cache
    end

    -- Allocate or reallocate SoA arrays
    if not cache or cache.capacity < n then
        cache = {
            x = ffi.new(float_array, n),
            y = ffi.new(float_array, n),
            radius = ffi.new(float_array, n),
            inv_radius = ffi.new(float_array, n),
            value = ffi.new(float_array, n),
            falloff = ffi.new(float_array, n * 256),
            count = 0,
            capacity = n,
        }
        self._nativeCache = cache
    end

    -- Fill arrays + bake falloff LUTs
    local idx = 0
    cache.sources = {}
    for _, src in pairs(self.sources) do
        if src.active then
            cache.x[idx] = src.x
            cache.y[idx] = src.y
            cache.radius[idx] = src.radius
            cache.inv_radius[idx] = 1.0 / src.radius
            cache.value[idx] = src.value
            cache.sources[src] = {src.x, src.y, src.radius, src.value, src.falloff}
            -- Bake falloff curve to 256-entry LUT
            local base = idx * 256
            for j = 0, 255 do
                cache.falloff[base + j] = src.falloff(j / 255, nil)
            end
            idx = idx + 1
        end
    end
    cache.count = idx
    cache.sourceCount = n

    self._nativeDirty = false
    return cache
end

--------------------------------------------------------------------------------
-- NATIVE BATCH SAMPLING
--------------------------------------------------------------------------------

--- Native batch sampling (SIMD accelerated)
--- Falls back to Lua if native extension unavailable
--- @param self Field The field instance
--- @param xs table|cdata X coordinates (FFI float array for best performance)
--- @param ys table|cdata Y coordinates
--- @param n number Count
--- @param outValues table|cdata|nil Output values (ignored, always returns FFI array)
--- @return cdata values (FFI float array, 0-indexed)
local function sampleBatchNative(self, xs, ys, n, outValues, ctx)
    local cache = ctx == nil and prepareNativeCache(self)
    if not cache then
        -- No native cache, use Lua fallback
        outValues = outValues or {}
        local offset = type(xs) == "cdata" and 1 or 0
        local outOffset = type(outValues) == "cdata" and 1 or 0
        for i = 1, n do
            outValues[i - outOffset] = self:sample(xs[i - offset], ys[i - offset], ctx)
        end
        return outValues
    end

    -- Convert Lua tables to FFI arrays if needed
    local ffi_xs, ffi_ys = xs, ys
    if type(xs) == "table" then
        ffi_xs = ffi.new(float_array, n)
        ffi_ys = ffi.new(float_array, n)
        for i = 1, n do
            ffi_xs[i-1] = xs[i]
            ffi_ys[i-1] = ys[i]
        end
    end

    -- Always use FFI array for output (C requires float*)
    local ffi_out = ffi.new(float_array, n)

    field_native.field_sample_batch_fast(
        cache.x, cache.y,
        cache.radius, cache.inv_radius,
        cache.value, cache.falloff,
        cache.count,
        ffi_xs, ffi_ys,
        ffi_out, n,
        self.base
    )

    return ffi_out
end

--- Native batch sampling with gradients (SIMD accelerated)
--- @param self Field The field instance
--- @return cdata, cdata, cdata values, gradX, gradY (FFI float arrays, 0-indexed)
local function sampleBatchNativeWithGradient(self, xs, ys, n, outValues, outGx, outGy, ctx)
    local cache = ctx == nil and prepareNativeCache(self)
    if not cache then
        -- No native cache, use Lua fallback
        outValues = outValues or {}
        outGx = outGx or {}
        outGy = outGy or {}
        local offset = type(xs) == "cdata" and 1 or 0
        for i = 1, n do
            local x, y = xs[i - offset], ys[i - offset]
            local gx, gy = self:gradient({x, y}, nil, ctx)
            outValues[type(outValues) == "cdata" and i - 1 or i] = self:sample(x, y, ctx)
            outGx[type(outGx) == "cdata" and i - 1 or i] = gx
            outGy[type(outGy) == "cdata" and i - 1 or i] = gy
        end
        return outValues, outGx, outGy
    end

    -- Convert Lua tables to FFI arrays if needed
    local ffi_xs, ffi_ys = xs, ys
    if type(xs) == "table" then
        ffi_xs = ffi.new(float_array, n)
        ffi_ys = ffi.new(float_array, n)
        for i = 1, n do
            ffi_xs[i-1] = xs[i]
            ffi_ys[i-1] = ys[i]
        end
    end

    -- Always use FFI arrays for output
    local ffi_out = ffi.new(float_array, n)
    local ffi_gx = ffi.new(float_array, n)
    local ffi_gy = ffi.new(float_array, n)

    field_native.field_sample_batch_gradient(
        cache.x, cache.y,
        cache.radius, cache.inv_radius,
        cache.value, cache.falloff,
        cache.count,
        ffi_xs, ffi_ys,
        ffi_out, ffi_gx, ffi_gy,
        n, self.base
    )

    return ffi_out, ffi_gx, ffi_gy
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function M._init(Field, Opt)
    additiveBlend = Field.blend.add
    staticFalloffs = {}
    for _, falloff in pairs(Field.falloff) do staticFalloffs[falloff] = true end
    -- Setup FFI if available
    if Opt.hasFFI then
        ffi = Opt.ffi
        float_array = ffi.typeof("float[?]")
    end

    -- Setup native library if available
    if Opt.hasNative then
        field_native = Opt.native

        -- Add native methods to Field prototype
        Field.sampleBatchNative = sampleBatchNative
        Field.sampleBatchNativeWithGradient = sampleBatchNativeWithGradient
        Field._prepareNativeCache = prepareNativeCache
        Field.hasNativeSupport = function() return true end

        -- Override sampleBatch to use native when beneficial
        local originalSampleBatch = Field.sampleBatch
        Field.sampleBatch = function(self, xs, ys, n, outValues, ctx)
            -- Use native when beneficial (>10 sources)
            if ctx == nil and self.sourceCount >= 10 then
                local result = sampleBatchNative(self, xs, ys, n, outValues)
                -- Convert FFI array back to Lua table if needed
                if type(result) ~= "table" then
                    outValues = outValues or {}
                    for i = 1, n do
                        outValues[i] = result[i-1]
                    end
                    return outValues
                end
                return result
            end
            -- Lua fallback for small fields
            return originalSampleBatch(self, xs, ys, n, outValues, ctx)
        end

        -- Keep ordinary gradients on their defined finite-difference path.
        -- The explicit native gradient API remains available for approximate derivatives.
    else
        Field.hasNativeSupport = function() return false end
    end
end

return M
