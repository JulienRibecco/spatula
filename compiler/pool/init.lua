--------------------------------------------------------------------------------
-- SPATULA POOL MODULE
-- Transparent pool API with auto-strategy selection
-- Auto-selects best strategy: rotator > LUT > compiled
--------------------------------------------------------------------------------

local Pool = {}

local floor = math.floor
local random = math.random

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

--- Create FFI float array (0-indexed) or Lua table (1-indexed)
--- @param count number Number of elements
--- @param useZeroIndex boolean If true, use 0-indexed FFI array
--- @return table|cdata Array
local function createArray(count, useZeroIndex)
    if useFFI and useZeroIndex then
        return ffi.new(float_array, count)
    else
        local arr = {}
        for i = 1, count do arr[i] = 0 end
        return arr
    end
end

Pool.useFFI = useFFI

--------------------------------------------------------------------------------
-- POOL CREATION
--------------------------------------------------------------------------------

--- Create a motion/curve pool that auto-selects the best evaluation strategy
--- @param Compiler table The Compiler module
--- @param ir table IR node
--- @param opts table Options:
---   count: number - Number of entities (default 1)
---   fps: number - Frames per second (default 60)
---   dt: number - Alternative to fps, timestep in seconds
---   duration: number - For LUT, loop duration (default 1)
--- @return table Pool object with simple API
function Pool.create(Compiler, ir, opts)
    opts = opts or {}
    local count = opts.count or 1
    local fps = opts.fps or 60
    local dt = opts.dt or (1 / fps)
    local duration = opts.duration or 1
    
    local isMotion = ir.type == "motion"
    
    local pool = {
        count = count,
        dt = dt,
        fps = fps,
        isMotion = isMotion,
        strategy = nil,  -- will be set below
        axis = opts.axis or "xy",  -- "x", "y", or "xy"
        
        -- Position/value arrays (always available)
        x = {},
        y = {},
        values = {},
        
        -- Internal state
        _phases = {},
        _times = {},
        _states = nil,
        _rotator = nil,
        _batchLUT = nil,
        _batchFn = nil,
        _singleFn = nil,
        
        -- Auto axis detection
        _autoAxis = true,       -- Auto-detect which axes are used
        _warmupFrames = 0,      -- Frames since init
        _warmupLimit = 5,       -- Frames before locking axis mode
        _xAccessed = false,
        _yAccessed = false,
    }
    
    -- Create tracked arrays for auto-detection
    local rawX = {}
    local rawY = {}
    local rawValues = {}
    
    -- Initialize arrays
    for i = 1, count do
        rawX[i] = 0
        rawY[i] = 0
        rawValues[i] = 0
        pool._phases[i] = 0
        pool._times[i] = 0
    end
    
    -- Metatable for tracking X access
    local xMeta = {
        __index = function(_, k)
            if pool._autoAxis and pool._warmupFrames < pool._warmupLimit then
                pool._xAccessed = true
            end
            return rawX[k]
        end,
        __newindex = function(_, k, v) rawX[k] = v end,
        __len = function() return pool.count end,
    }

    -- Metatable for tracking Y access
    local yMeta = {
        __index = function(_, k)
            if pool._autoAxis and pool._warmupFrames < pool._warmupLimit then
                pool._yAccessed = true
            end
            return rawY[k]
        end,
        __newindex = function(_, k, v) rawY[k] = v end,
        __len = function() return pool.count end,
    }
    
    pool.x = setmetatable({}, xMeta)
    pool.y = setmetatable({}, yMeta)
    pool.values = rawValues
    pool._rawX = rawX
    pool._rawY = rawY
    pool._trackedX = pool.x  -- Store for restoring after init()
    pool._trackedY = pool.y
    
    -- Check if stateful (needs per-entity ctx)
    local isStateful = Compiler.hasStatefulNodes(ir)
    
    -- Try strategies in order of preference
    local rotator = Compiler.compileRotator(ir, { dt = dt })
    
    if rotator then
        -- Best: Stepper (no memory, no trig per frame)
        pool.strategy = "rotator"
        pool._rotator = rotator
        pool._states = {}

        -- FFI position arrays for direct rotation (0-indexed for native SIMD)
        pool._useFFI = useFFI
        pool._posX = createArray(count, useFFI)  -- Position x (scaled)
        pool._posY = createArray(count, useFFI)  -- Position y (scaled)

        for i = 1, count do
            pool._states[i] = rotator.init(0)
            -- FFI arrays are 0-indexed
            local idx = useFFI and (i - 1) or i
            pool._posX[idx] = pool._states[i].x or 0
            pool._posY[idx] = pool._states[i].y or 0
        end
        
    elseif Compiler.canUseLUT(ir, duration, fps) then
        -- Good: Batch LUT (table lookup)
        pool.strategy = "lut"

        -- Use FFI batch LUT if available
        local batchFn, _, lutData
        if useFFI and Compiler.compileBatchLUTFFI then
            batchFn, _, lutData = Compiler.compileBatchLUTFFI(ir, {
                fps = fps,
                duration = duration,
            })
            pool._useFFI = true
            -- Create FFI position arrays for output
            pool._posX = createArray(count, true)
            pool._posY = createArray(count, true)
            -- Create FFI time/phase arrays for input
            pool._ffiTimes = ffi.new(float_array, count)
            pool._ffiPhases = ffi.new(float_array, count)
        else
            batchFn, _, lutData = Compiler.compileBatchLUT(ir, {
                fps = fps,
                duration = duration,
                preallocate = true
            })
        end
        pool._batchLUT = batchFn
        pool._lutData = lutData

    else
        -- Check for hybrid opportunity: motionAdd with some pure children
        local canHybrid, pureChildren, statefulChildren = Compiler.analyzeHybrid(ir, duration, fps)
        
        if canHybrid and #pureChildren > 0 and #statefulChildren > 0 then
            -- Hybrid: LUT for pure parts, compiled for stateful
            pool.strategy = "hybrid"
            pool._isStateful = true
            pool._contexts = {}
            for i = 1, count do
                pool._contexts[i] = {}
            end
            
            -- Pre-bake pure children to LUTs
            pool._pureLUTs = {}
            for idx, child in ipairs(pureChildren) do
                pool._pureLUTs[idx] = {
                    lut = Compiler.compileLUT(child.ir, { fps = fps, duration = duration }),
                    isMotion = child.ir.type == "motion"
                }
            end
            
            -- Compile stateful children
            pool._statefulFns = {}
            for idx, child in ipairs(statefulChildren) do
                pool._statefulFns[idx] = {
                    fn = Compiler.compile(child.ir),
                    isMotion = child.ir.type == "motion"
                }
            end
            
        else
            -- Check for rotate/scale hybrid (LUT for inner motion, runtime for outer curve)
            local canRotHybrid, rotInfo = Compiler.analyzeRotateScaleHybrid(ir, duration, fps)
            if canRotHybrid and rotInfo then
                pool.strategy = "rotscale"
                pool._innerLUT = Compiler.compileLUT(rotInfo.innerMotion, {
                    fps = fps,
                    duration = duration
                })
                pool._outerFn = Compiler.compile(rotInfo.outerCurve)
                pool._operation = rotInfo.operation  -- "rotate" or "scale"
            else
                -- Fallback: Compiled (with per-entity ctx for stateful)
                pool.strategy = "compiled"
                pool._singleFn = Compiler.compile(ir)
                pool._isStateful = isStateful

                -- For stateful: each entity gets its own ctx
                if isStateful then
                    pool._contexts = {}
                    for i = 1, count do
                        pool._contexts[i] = {}
                    end
                else
                    -- Non-stateful can use batch
                    pool._batchFn = Compiler.compileBatchEval(ir, {
                        withPhase = true,
                        preallocate = true
                    })
                end
            end
        end
    end
    
    -- Choose the evaluator once. Bulk stepping and single-entity resets share it.
    if pool.strategy == "rotator" then
        pool._evaluate = function(t, ctx, i)
            local state = pool._states[i]
            if isMotion then return state.x, state.y end
            return state.value
        end
    elseif pool.strategy == "lut" then
        local data = pool._lutData
        local xs = data.x or data
        local ys = data.y
        local frameCount = math.max(1, floor(fps * duration))
        local offset = pool._useFFI and 0 or 1
        pool._evaluate = function(t)
            local index = floor(t * fps) % frameCount + offset
            return xs[index], ys and ys[index]
        end
    elseif pool.strategy == "hybrid" then
        pool._evaluate = function(t, ctx)
            local x, y = 0, 0
            for _, child in ipairs(pool._pureLUTs) do
                local cx, cy = child.lut(t)
                x, y = x + cx, y + (cy or 0)
            end
            for _, child in ipairs(pool._statefulFns) do
                local cx, cy = child.fn(t, ctx)
                x, y = x + cx, y + (cy or 0)
            end
            return x, y
        end
    elseif pool.strategy == "rotscale" then
        pool._evaluate = function(t, ctx)
            local x, y = pool._innerLUT(t)
            local outer = pool._outerFn(t, ctx)
            if pool._operation == "rotate" then
                local c, s = math.cos(outer), math.sin(outer)
                return x * c - y * s, x * s + y * c
            end
            return x * outer, y * outer
        end
    else
        pool._evaluate = pool._singleFn
    end

    ----------------------------------------------------------------------------
    -- POOL METHODS
    ----------------------------------------------------------------------------
    
    --- Initialize pool with phases (or zeros)
    --- @param phases table|nil Phase values per entity
    --- @return table self for chaining
    function pool:init(phases)
        -- Reset auto-detection
        self._warmupFrames = 0
        self._xAccessed = false
        self._yAccessed = false
        self._autoAxis = true
        self.axis = "xy"
        self.x = self._trackedX
        self.y = self._trackedY
        
        for i = 1, self.count do
            self._phases[i] = phases and phases[i] or 0
            self._times[i] = 0
        end
        
        for i = 1, self.count do
            if self._states then self._states[i] = self._rotator.init(self._phases[i]) end
            if self._contexts then self._contexts[i] = {} end
        end
        self:_syncPositions()

        return self
    end
    
    --- Initialize pool with random phases
    --- @param maxPhase number Maximum phase value (default 1)
    --- @return table self for chaining
    function pool:initRandom(maxPhase)
        maxPhase = maxPhase or 1
        local phases = {}
        for i = 1, self.count do
            phases[i] = random() * maxPhase
        end
        return self:init(phases)
    end
    
    --- Step all entities forward by dt
    --- @return table self for chaining
    function pool:step()
        -- Handle auto-axis detection warmup
        if self._autoAxis and self._warmupFrames == self._warmupLimit then
            -- Warmup complete, lock axis mode
            if self._xAccessed and self._yAccessed then
                self.axis = "xy"
            elseif self._xAccessed then
                self.axis = "x"
            elseif self._yAccessed then
                self.axis = "y"
            end
            self._autoAxis = false
            -- Swap to raw arrays for direct access
            self.x = self._rawX
            self.y = self._rawY
        end
        
        if self._warmupFrames < self._warmupLimit then
            self._warmupFrames = self._warmupFrames + 1
        end
        
        for i = 1, self.count do
            self._times[i] = self._times[i] + self.dt
        end
        if self._states then self._rotator.stepBatch(self._states, self.count) end
        self:_syncPositions()

        return self
    end
    
    --- Step by a custom dt (less efficient for rotator)
    --- @param customDt number Custom timestep
    function pool:stepDt(customDt)
        if self.strategy == "rotator" and customDt ~= self.dt then
            -- Stepper requires fixed dt, fallback to recompute
            for i = 1, self.count do
                self._times[i] = self._times[i] + customDt
            end
            -- Reinit states at current time (expensive but correct)
            for i = 1, self.count do
                local t = self._times[i] + self._phases[i]
                self._states[i] = self._rotator.init(t)
                self:_syncOne(i)
            end
        else
            local oldDt = self.dt
            self.dt = customDt
            self:step()
            self.dt = oldDt
        end
        return self
    end
    
    --- Get position/value for a single entity
    --- @param i number Entity index
    --- @return number, number|nil x, y (for motion) or value (for curve)
    function pool:get(i)
        if self.isMotion then
            return self.x[i], self.y[i]
        else
            return self.values[i]
        end
    end
    
    --- Set phase for a single entity
    --- @param i number Entity index
    --- @param phase number New phase value
    function pool:setPhase(i, phase)
        self._phases[i] = phase
        self._times[i] = 0
        if self.strategy == "rotator" then
            self._states[i] = self._rotator.init(phase)
        end
        -- Reset context for stateful curves
        if self._contexts then
            self._contexts[i] = {}
        end
        self:_syncOne(i)
    end
    
    --- Sync all positions (internal)
    function pool:_syncPositions()
        -- Axis-aware computation
        local wantX = self.axis == "x" or self.axis == "xy"
        local wantY = self.axis == "y" or self.axis == "xy"
        
        if self.strategy == "lut" then
            if self._useFFI then
                for i = 0, self.count - 1 do
                    self._ffiTimes[i] = self._times[i + 1]
                    self._ffiPhases[i] = self._phases[i + 1]
                end
                self._batchLUT(self._ffiTimes, self._ffiPhases, self.count, self._posX, self._posY)
                for i = 1, self.count do
                    if self.isMotion then
                        if wantX then self._rawX[i] = self._posX[i - 1] end
                        if wantY then self._rawY[i] = self._posY[i - 1] end
                    else
                        self.values[i] = self._posX[i - 1]
                    end
                end
            elseif self.isMotion then
                self._batchLUT(self._times, self._phases, self.count,
                    wantX and self._rawX or nil, wantY and self._rawY or nil)
            else
                self._batchLUT(self._times, self._phases, self.count, self.values)
            end
        elseif self._batchFn then
            if self.isMotion then
                self._batchFn(self._times, self._phases, self.count,
                    wantX and self._rawX or nil, wantY and self._rawY or nil)
            else
                self._batchFn(self._times, self._phases, self.count, self.values)
            end
        else
            for i = 1, self.count do self:_syncOne(i) end
        end
    end

    --- Evaluate and publish one entity to both Lua and FFI outputs.
    function pool:_syncOne(i)
        local t = self._times[i] + self._phases[i]
        local ctx = self._contexts and self._contexts[i] or nil
        local x, y = self._evaluate(t, ctx, i)
        if self.isMotion then
            self._rawX[i], self._rawY[i] = x, y
        else
            self.values[i] = x
        end
        if self._posX then
            local index = self._useFFI and (i - 1) or i
            self._posX[index], self._posY[index] = x, y or 0
        end
    end

    --- Resize pool (expensive - reallocates)
    --- @param newCount number New entity count
    function pool:resize(newCount)
        if newCount == self.count then return self end

        local oldCount = self.count
        self.count = newCount
        local ffiMode = self._useFFI

        -- Resize every FFI buffer together, including LUT inputs.
        if ffiMode then
            local copyCount = math.min(oldCount, newCount)
            for _, key in ipairs({"_posX", "_posY", "_ffiTimes", "_ffiPhases"}) do
                local old = self[key]
                if old then
                    local resized = createArray(newCount, true)
                    for i = 0, copyCount - 1 do resized[i] = old[i] end
                    self[key] = resized
                end
            end
        end

        -- Extend or shrink Lua arrays
        for i = oldCount + 1, newCount do
            self._rawX[i] = 0
            self._rawY[i] = 0
            self.values[i] = 0
            self._phases[i] = 0
            self._times[i] = 0
            if self._states then self._states[i] = self._rotator.init(0) end
            if self._contexts then
                self._contexts[i] = {}
            end
            self:_syncOne(i)
        end

        -- Shrink Lua tables if needed (FFI arrays already reallocated)
        for i = newCount + 1, oldCount do
            self._rawX[i] = nil
            self._rawY[i] = nil
            self.values[i] = nil
            self._phases[i] = nil
            self._times[i] = nil
            if self._states then self._states[i] = nil end
            if self._contexts then self._contexts[i] = nil end
        end

        return self
    end
    
    --- Force X-only mode (skip Y computation)
    function pool:useX()
        self.axis = "x"
        self._autoAxis = false
        return self
    end
    
    --- Force Y-only mode (skip X computation)
    function pool:useY()
        self.axis = "y"
        self._autoAxis = false
        return self
    end
    
    --- Force XY mode (compute both)
    function pool:useXY()
        self.axis = "xy"
        self._autoAxis = false
        return self
    end
    
    --- Re-enable auto-axis detection
    function pool:useAuto()
        self._autoAxis = true
        self._warmupFrames = 0
        self._xAccessed = false
        self._yAccessed = false
        self.x = self._trackedX
        self.y = self._trackedY
        return self
    end
    
    --- Get FFI arrays for direct high-performance access (LuaJIT only)
    --- Returns 0-indexed FFI float arrays for maximum performance
    --- @return cdata|nil posX - FFI float array of X positions (0-indexed)
    --- @return cdata|nil posY - FFI float array of Y positions (0-indexed)
    --- @return number count - Number of entities
    --- @return boolean isFFI - Whether FFI is available
    function pool:getFFI()
        if self._useFFI and self._posX then
            return self._posX, self._posY, self.count, true
        end
        return nil, nil, self.count, false
    end

    --- Get pool info
    --- @return table Info about pool state
    function pool:info()
        return {
            count = self.count,
            strategy = self.strategy,
            isMotion = self.isMotion,
            axis = self.axis,
            autoAxis = self._autoAxis,
            warmupFrames = self._warmupFrames,
            dt = self.dt,
            fps = self.fps,
            sharedLUT = false,
            useFFI = self._useFFI or false,
        }
    end

    return pool
end

--------------------------------------------------------------------------------
-- CONVENIENCE FUNCTIONS
--------------------------------------------------------------------------------

--- Single entity optimizer (just returns compiled function)
--- @param Compiler table The Compiler module
--- @param ir table IR node
--- @param opts table Options
--- @return function Compiled evaluation function
function Pool.auto(Compiler, ir, opts)
    return Compiler.compileOptimized(ir, opts)
end

--- Create pool and init with random phases
--- @param Compiler table The Compiler module
--- @param ir table IR node
--- @param count number Number of entities
--- @param opts table Pool options
--- @return table Initialized pool
function Pool.createRandom(Compiler, ir, count, opts)
    opts = opts or {}
    opts.count = count
    return Pool.create(Compiler, ir, opts):initRandom()
end

return Pool
