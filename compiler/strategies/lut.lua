--------------------------------------------------------------------------------
-- SPATULA LUT MODULE
-- Pre-compute all values for fixed-fps scenarios
-- Eliminates ALL runtime math - just table lookup
--------------------------------------------------------------------------------

local LUT = {}

local floor = math.floor

-- FFI support for high-performance arrays
local ffi_ok, ffi = pcall(require, "ffi")
local useFFI = false
local float_array

if ffi_ok then
    local ok = pcall(function()
        float_array = ffi.typeof("float[?]")
    end)
    useFFI = ok
end

LUT.useFFI = useFFI

--------------------------------------------------------------------------------
-- ANALYSIS
--------------------------------------------------------------------------------

--- Check if IR can be compiled to a LUT (no stateful nodes)
--- @param ir table IR node
--- @param hasStatefulNodes function Function to check for stateful nodes
--- @return boolean canUseLUT
function LUT.canUse(ir, hasStatefulNodes)
    if not ir then return false end
    
    -- Stateful curves can't be LUT'd (they depend on history)
    if hasStatefulNodes and hasStatefulNodes(ir) then
        return false
    end
    
    -- Check for ctx-dependent nodes
    local function hasCtx(node)
        if not node or type(node) ~= "table" then return false end
        if node.op == "fromCtx" then return true end
        for k, v in pairs(node) do
            if type(v) == "table" and hasCtx(v) then return true end
        end
        return false
    end
    
    if hasCtx(ir) then
        return false
    end
    
    return true
end

--- Analyze IR for hybrid LUT opportunity (some pure, some stateful)
--- @param ir table IR node
--- @param hasStatefulNodes function Function to check for stateful nodes
--- @return boolean canHybrid
--- @return table pureChildren
--- @return table statefulChildren
function LUT.analyzeHybrid(ir, hasStatefulNodes)
    if not ir then
        return false, {}, {}
    end
    
    -- Only motionAdd or add can be hybrid
    if ir.op ~= "motionAdd" and ir.op ~= "add" then
        return false, {}, {}
    end
    
    local children = ir.children
    if not children or #children < 2 then
        return false, {}, {}
    end
    
    local pureChildren = {}
    local statefulChildren = {}
    
    for i, child in ipairs(children) do
        if hasStatefulNodes and hasStatefulNodes(child) then
            statefulChildren[#statefulChildren + 1] = { idx = i, ir = child }
        else
            pureChildren[#pureChildren + 1] = { idx = i, ir = child }
        end
    end
    
    -- Hybrid is beneficial if we have both pure and stateful
    local canHybrid = #pureChildren > 0 and #statefulChildren > 0
    
    return canHybrid, pureChildren, statefulChildren
end

--- Estimate LUT memory size
--- @param ir table IR node
--- @param opts table Options: fps, duration
--- @return number Size in bytes (approximate)
function LUT.estimateSize(ir, opts)
    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    local frameCount = floor(fps * duration)
    
    local isMotion = ir and ir.type == "motion"
    
    -- Each value is 8 bytes (Lua number = double)
    -- Motion: 2 values per frame (x, y)
    -- Curve: 1 value per frame
    local valuesPerFrame = isMotion and 2 or 1
    
    return frameCount * valuesPerFrame * 8
end

--------------------------------------------------------------------------------
-- LUT COMPILATION
--------------------------------------------------------------------------------

--- Compile a curve/motion to a lookup table
--- @param ir table IR node
--- @param compile function The compile(ir) function from Compiler
--- @param opts table Options: fps, duration, loop, interpolate
--- @return function Lookup function f(t) -> value or (x, y)
--- @return table The raw LUT data
function LUT.compile(ir, compile, opts)
    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    local shouldLoop = opts.loop ~= false
    local interpolate = opts.interpolate or false
    
    local frameCount = floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end
    
    local isMotion = ir.type == "motion"
    
    -- Compile IR to function
    local compiled = compile(ir)
    
    -- Pre-compute all frame values
    local lut = {}
    local ctx = {}
    
    for i = 0, frameCount - 1 do
        local t = i / fps
        if isMotion then
            local x, y = compiled(t, ctx)
            lut[i + 1] = { x = x, y = y }
        else
            lut[i + 1] = compiled(t, ctx)
        end
    end
    
    -- Generate lookup function
    if isMotion then
        if interpolate then
            return function(t)
                local frame = t * fps
                local idx = floor(frame)
                local frac = frame - idx
                
                if shouldLoop then
                    idx = idx % frameCount
                else
                    if idx < 0 then idx = 0 end
                    if idx >= frameCount - 1 then
                        local last = lut[frameCount]
                        return last.x, last.y
                    end
                end
                
                local a = lut[idx + 1]
                local b = lut[(idx + 1) % frameCount + 1]
                return a.x + (b.x - a.x) * frac,
                       a.y + (b.y - a.y) * frac
            end, lut
        else
            return function(t)
                local idx = floor(t * fps)
                if shouldLoop then
                    idx = idx % frameCount
                else
                    if idx < 0 then idx = 0 end
                    if idx >= frameCount then idx = frameCount - 1 end
                end
                local v = lut[idx + 1]
                return v.x, v.y
            end, lut
        end
    else
        if interpolate then
            return function(t)
                local frame = t * fps
                local idx = floor(frame)
                local frac = frame - idx
                
                if shouldLoop then
                    idx = idx % frameCount
                else
                    if idx < 0 then idx = 0 end
                    if idx >= frameCount - 1 then
                        return lut[frameCount]
                    end
                end
                
                local a = lut[idx + 1]
                local b = lut[(idx + 1) % frameCount + 1]
                return a + (b - a) * frac
            end, lut
        else
            return function(t)
                local idx = floor(t * fps)
                if shouldLoop then
                    idx = idx % frameCount
                else
                    if idx < 0 then idx = 0 end
                    if idx >= frameCount then idx = frameCount - 1 end
                end
                return lut[idx + 1]
            end, lut
        end
    end
end

--------------------------------------------------------------------------------
-- BATCH LUT COMPILATION
--------------------------------------------------------------------------------

--- Compile to batch LUT function for pool evaluation
--- @param ir table IR node
--- @param compile function The compile(ir) function
--- @param opts table Options: fps, duration, preallocate
--- @return function Batch function(times, phases, n, outX, outY)
--- @return number frameCount
--- @return table lutData { x = [...], y = [...] }
function LUT.compileBatch(ir, compile, opts)
    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    
    local frameCount = floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end
    
    local isMotion = ir.type == "motion"
    
    -- Compile and pre-compute
    local compiled = compile(ir)
    local ctx = {}
    
    local lutX, lutY = {}, {}
    for i = 0, frameCount - 1 do
        local t = i / fps
        if isMotion then
            lutX[i + 1], lutY[i + 1] = compiled(t, ctx)
        else
            lutX[i + 1] = compiled(t, ctx)
        end
    end
    
    local lutData = { x = lutX, y = isMotion and lutY or nil }
    
    -- Create batch function
    if isMotion then
        return function(times, phases, n, outX, outY)
            for i = 1, n do
                local idx = floor((times[i] + phases[i]) * fps) % frameCount + 1
                outX[i] = lutX[idx]
                outY[i] = lutY[idx]
            end
        end, frameCount, lutData
    else
        return function(times, phases, n, out)
            for i = 1, n do
                local idx = floor((times[i] + phases[i]) * fps) % frameCount + 1
                out[i] = lutX[idx]
            end
        end, frameCount, lutData
    end
end

--------------------------------------------------------------------------------
-- FFI-OPTIMIZED BATCH LUT (LuaJIT only)
--------------------------------------------------------------------------------

--- Compile to FFI batch LUT for maximum performance
--- Uses FFI float arrays for LUT data and output
--- @param ir table IR node
--- @param compile function The compile(ir) function
--- @param opts table Options: fps, duration
--- @return function Batch function(times, phases, n, outX, outY)
--- @return number frameCount
--- @return table lutData { x = ffi_array, y = ffi_array }
function LUT.compileBatchFFI(ir, compile, opts)
    if not useFFI then
        -- Fall back to Lua version
        return LUT.compileBatch(ir, compile, opts)
    end

    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1

    local frameCount = floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end

    local isMotion = ir.type == "motion"

    -- Compile and pre-compute into FFI arrays
    local compiled = compile(ir)
    local ctx = {}

    local lutX = ffi.new(float_array, frameCount)
    local lutY = isMotion and ffi.new(float_array, frameCount) or nil

    for i = 0, frameCount - 1 do
        local t = i / fps
        if isMotion then
            lutX[i], lutY[i] = compiled(t, ctx)
        else
            lutX[i] = compiled(t, ctx)
        end
    end

    local lutData = { x = lutX, y = lutY, ffi = true }

    -- Create batch function optimized for FFI arrays
    if isMotion then
        return function(times, phases, n, outX, outY)
            -- 0-indexed loop for FFI arrays
            for i = 0, n - 1 do
                local idx = floor((times[i] + phases[i]) * fps) % frameCount
                outX[i] = lutX[idx]
                outY[i] = lutY[idx]
            end
        end, frameCount, lutData
    else
        return function(times, phases, n, out)
            for i = 0, n - 1 do
                local idx = floor((times[i] + phases[i]) * fps) % frameCount
                out[i] = lutX[idx]
            end
        end, frameCount, lutData
    end
end

--- Compile LUT with FFI storage (single-entity lookup, FFI-backed)
--- @param ir table IR node
--- @param compile function The compile(ir) function
--- @param opts table Options: fps, duration, loop, interpolate
--- @return function Lookup function f(t) -> value or (x, y)
--- @return table The raw LUT data (FFI arrays)
function LUT.compileFFI(ir, compile, opts)
    if not useFFI then
        return LUT.compile(ir, compile, opts)
    end

    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    local shouldLoop = opts.loop ~= false

    local frameCount = floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end

    local isMotion = ir.type == "motion"

    -- Compile IR to function
    local compiled = compile(ir)
    local ctx = {}

    -- Pre-compute into FFI arrays
    local lutX = ffi.new(float_array, frameCount)
    local lutY = isMotion and ffi.new(float_array, frameCount) or nil

    for i = 0, frameCount - 1 do
        local t = i / fps
        if isMotion then
            lutX[i], lutY[i] = compiled(t, ctx)
        else
            lutX[i] = compiled(t, ctx)
        end
    end

    local lutData = { x = lutX, y = lutY, ffi = true, frameCount = frameCount }

    -- Generate lookup function (0-indexed for FFI)
    if isMotion then
        return function(t)
            local idx = floor(t * fps)
            if shouldLoop then
                idx = idx % frameCount
            else
                if idx < 0 then idx = 0 end
                if idx >= frameCount then idx = frameCount - 1 end
            end
            return lutX[idx], lutY[idx]
        end, lutData
    else
        return function(t)
            local idx = floor(t * fps)
            if shouldLoop then
                idx = idx % frameCount
            else
                if idx < 0 then idx = 0 end
                if idx >= frameCount then idx = frameCount - 1 end
            end
            return lutX[idx]
        end, lutData
    end
end

--------------------------------------------------------------------------------
-- SOURCE GENERATION
--------------------------------------------------------------------------------

--- Generate Lua source for a LUT (for embedding)
--- @param ir table IR node
--- @param compile function The compile(ir) function
--- @param opts table Options: fps, duration
--- @return string Lua source code
function LUT.toSource(ir, compile, opts)
    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    
    local frameCount = floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end
    
    local isMotion = ir.type == "motion"
    local compiled = compile(ir)
    local ctx = {}
    
    local lines = {}
    lines[#lines + 1] = "local floor = math.floor"
    lines[#lines + 1] = ""
    
    if isMotion then
        local xvals, yvals = {}, {}
        for i = 0, frameCount - 1 do
            local t = i / fps
            local x, y = compiled(t, ctx)
            xvals[#xvals + 1] = string.format("%.10g", x)
            yvals[#yvals + 1] = string.format("%.10g", y)
        end
        
        lines[#lines + 1] = "local lut_x = {" .. table.concat(xvals, ",") .. "}"
        lines[#lines + 1] = "local lut_y = {" .. table.concat(yvals, ",") .. "}"
        lines[#lines + 1] = "local frameCount = " .. frameCount
        lines[#lines + 1] = "local fps = " .. fps
        lines[#lines + 1] = ""
        lines[#lines + 1] = "return function(t)"
        lines[#lines + 1] = "  local idx = floor(t * fps) % frameCount + 1"
        lines[#lines + 1] = "  return lut_x[idx], lut_y[idx]"
        lines[#lines + 1] = "end"
    else
        local vals = {}
        for i = 0, frameCount - 1 do
            local t = i / fps
            vals[#vals + 1] = string.format("%.10g", compiled(t, ctx))
        end
        
        lines[#lines + 1] = "local lut = {" .. table.concat(vals, ",") .. "}"
        lines[#lines + 1] = "local frameCount = " .. frameCount
        lines[#lines + 1] = "local fps = " .. fps
        lines[#lines + 1] = ""
        lines[#lines + 1] = "return function(t)"
        lines[#lines + 1] = "  local idx = floor(t * fps) % frameCount + 1"
        lines[#lines + 1] = "  return lut[idx]"
        lines[#lines + 1] = "end"
    end
    
    return table.concat(lines, "\n")
end

return LUT
