--- Spatula Compiled Module
--- @module spatula.compiled
---
--- ============================================================================
--- Auto-Detection Compiler for Spatula
--- ============================================================================
---
--- Automatically instruments all Spatula usage in your codebase.
--- Require this module once at startup, then call build() when ready.
---
--- Usage:
---   -- main.lua (before any other requires)
---   require("spatula.compiled")
---
---   -- Rest of codebase uses normal requires - automatically instrumented
---   local Curve = require("spatula.curve")
---   local Motion = require("spatula.motion")
---   local m = Motion.circle(100, 2)  -- tracked for compilation
---
---   -- After all modules loaded, compile everything
---   require("spatula.compiled").build()
---
--- ============================================================================

local Compiler = require("spatula.compiler.compiler")
local RawMotion = require("spatula.motion")
local RawCurve = require("spatula.curve")

-- Lua 5.1/LuaJIT compatibility: table.unpack (5.2+) vs unpack (5.1)
local unpack = table.unpack or unpack

-- Save original functions BEFORE we patch them
local OriginalCurve = {}
local OriginalMotion = {}
for k, v in pairs(RawCurve) do OriginalCurve[k] = v end
for k, v in pairs(RawMotion) do OriginalMotion[k] = v end

local Pool = require("spatula.compiler.pool")
local IR = require("spatula.compiler.ir")

local Compiled = {
    _VERSION = "2.0.0",
    _registry = {},      -- All created closures with IR
    _compiled = {},      -- Compiled versions (weak keys)
    _pools = {},         -- Pools by IR key
    _poolsList = {},     -- List of all pools for stepping
    _buildComplete = false,
    _dt = 1/60,          -- Default timestep
    _fps = 60,           -- Default FPS
}

-- Use weak table for compiled cache to allow GC
setmetatable(Compiled._compiled, { __mode = "k" })

--------------------------------------------------------------------------------
-- ANNOTATED WRAPPER
-- Creates a callable table that stores both closure and IR
--------------------------------------------------------------------------------

-- Flag to suppress wrapper creation during raw function building
local _creatingRaw = false

local function annotate(fn, ir, name)
    -- If we're creating a raw function, just return the function without wrapping
    if _creatingRaw then
        return fn
    end
    local wrapper = {
        _fn = fn,
        _ir = ir,
        _compiled = nil,  -- Filled after build()
        _name = name,
        _phase = 0,       -- Entity phase offset
        _pool = nil,      -- Pool reference (after build)
        _entityIndex = nil, -- Index in pool (after build)
        _isMotion = ir.type == "motion",
    }

    setmetatable(wrapper, {
        __call = function(self, t, ctx)
            -- Use compiled version if available (works for any t value)
            if self._compiled then
                return self._compiled(t + self._phase, ctx)
            end
            -- Use pool only if no compiled version and pool is available
            -- Note: pool returns pre-computed value at pool's current time,
            -- ignoring the t parameter. Only use for time-stepped entities.
            if self._pool then
                local idx = self._entityIndex
                if self._isMotion then
                    return self._pool.x[idx], self._pool.y[idx]
                else
                    return self._pool.values[idx]
                end
            end
            return self._fn(t + self._phase, ctx)
        end,
        __tostring = function(self)
            return string.format("Compiled<%s>", self._name or "anonymous")
        end,
        __index = {
            -- Set phase for this entity
            withPhase = function(self, phase)
                self._phase = phase or 0
                return self
            end,
            -- Get current phase
            getPhase = function(self)
                return self._phase
            end,
        }
    })

    -- Register for batch compilation
    Compiled._registry[#Compiled._registry + 1] = wrapper

    return wrapper
end

--------------------------------------------------------------------------------
-- CURVE WRAPPERS
-- Each wraps the raw function and attaches IR
--------------------------------------------------------------------------------

Compiled.Curve = {}

function Compiled.Curve.const(value)
    return annotate(
        OriginalCurve.const(value),
        Compiler.curve.const(value),
        "const(" .. tostring(value) .. ")"
    )
end

function Compiled.Curve.linear(speed)
    return annotate(
        OriginalCurve.linear(speed),
        Compiler.curve.linear(speed),
        "linear(" .. tostring(speed) .. ")"
    )
end

function Compiled.Curve.sin(freq, amp, phase)
    return annotate(
        OriginalCurve.sin(freq, amp, phase),
        Compiler.curve.sin(freq, amp, phase),
        "sin"
    )
end

function Compiled.Curve.cos(freq, amp, phase)
    return annotate(
        OriginalCurve.cos(freq, amp, phase),
        Compiler.curve.cos(freq, amp, phase),
        "cos"
    )
end

function Compiled.Curve.triangle(freq, amp)
    return annotate(
        OriginalCurve.triangle(freq, amp),
        Compiler.curve.triangle(freq, amp),
        "triangle"
    )
end

function Compiled.Curve.saw(freq, amp)
    return annotate(
        OriginalCurve.saw(freq, amp),
        Compiler.curve.saw(freq, amp),
        "saw"
    )
end

function Compiled.Curve.square(freq, amp, duty)
    return annotate(
        OriginalCurve.square(freq, amp, duty),
        Compiler.curve.square(freq, amp, duty),
        "square"
    )
end

function Compiled.Curve.pulse(freq, duty)
    return annotate(
        OriginalCurve.pulse(freq, duty),
        Compiler.curve.pulse(freq, duty),
        "pulse"
    )
end

function Compiled.Curve.noise(scale, seed)
    return annotate(
        OriginalCurve.noise(scale, seed),
        Compiler.curve.noise(scale, seed),
        "noise"
    )
end

function Compiled.Curve.easeIn(duration, power)
    return annotate(
        OriginalCurve.easeIn(duration, power),
        Compiler.curve.easeIn(duration, power),
        "easeIn"
    )
end

function Compiled.Curve.easeOut(duration, power)
    return annotate(
        OriginalCurve.easeOut(duration, power),
        Compiler.curve.easeOut(duration, power),
        "easeOut"
    )
end

function Compiled.Curve.easeInOut(duration, power)
    return annotate(
        OriginalCurve.easeInOut(duration, power),
        Compiler.curve.easeInOut(duration, power),
        "easeInOut"
    )
end

function Compiled.Curve.ramp(start, target, duration)
    return annotate(
        OriginalCurve.ramp(start, target, duration),
        Compiler.curve.ramp(start, target, duration),
        "ramp"
    )
end

-- Combinators need special handling for nested wrappers
local function unwrapIR(curve)
    if type(curve) == "table" and curve._ir then
        return curve._ir
    elseif type(curve) == "number" then
        return Compiler.curve.const(curve)
    end
    -- Fallback: can't compile, return nil
    return nil
end

local function unwrapFn(curve)
    if type(curve) == "table" and curve._fn then
        return curve._fn
    elseif type(curve) == "number" then
        return function() return curve end
    end
    return curve
end

function Compiled.Curve.add(...)
    local curves = {...}
    local rawCurves = {}
    local irCurves = {}
    local canCompile = true

    for i, c in ipairs(curves) do
        rawCurves[i] = unwrapFn(c)
        local ir = unwrapIR(c)
        if ir then
            irCurves[i] = ir
        else
            canCompile = false
        end
    end

    local fn = OriginalCurve.add(unpack(rawCurves))

    if canCompile then
        return annotate(fn, Compiler.curve.add(unpack(irCurves)), "add")
    end
    return fn
end

function Compiled.Curve.mul(...)
    local curves = {...}
    local rawCurves = {}
    local irCurves = {}
    local canCompile = true

    for i, c in ipairs(curves) do
        rawCurves[i] = unwrapFn(c)
        local ir = unwrapIR(c)
        if ir then
            irCurves[i] = ir
        else
            canCompile = false
        end
    end

    local fn = OriginalCurve.mul(unpack(rawCurves))

    if canCompile then
        return annotate(fn, Compiler.curve.mul(unpack(irCurves)), "mul")
    end
    return fn
end

function Compiled.Curve.scale(curve, factor)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)

    local fn = OriginalCurve.scale(rawCurve, type(factor) == "table" and unwrapFn(factor) or factor)

    if irCurve then
        local irFactor = type(factor) == "table" and unwrapIR(factor) or factor
        if irFactor then
            return annotate(fn, Compiler.curve.scale(irCurve, irFactor), "scale")
        end
    end
    return fn
end

function Compiled.Curve.offset(curve, amount)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)

    local fn = OriginalCurve.offset(rawCurve, type(amount) == "table" and unwrapFn(amount) or amount)

    if irCurve then
        local irAmount = type(amount) == "table" and unwrapIR(amount) or amount
        if irAmount then
            return annotate(fn, Compiler.curve.offset(irCurve, irAmount), "offset")
        end
    end
    return fn
end

function Compiled.Curve.neg(curve)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.neg(rawCurve)

    if irCurve then
        return annotate(fn, Compiler.curve.neg(irCurve), "neg")
    end
    return fn
end

function Compiled.Curve.abs(curve)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.abs(rawCurve)

    if irCurve then
        return annotate(fn, Compiler.curve.abs(irCurve), "abs")
    end
    return fn
end

function Compiled.Curve.timeScale(curve, factor)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)

    local fn = OriginalCurve.timeScale(rawCurve, type(factor) == "table" and unwrapFn(factor) or factor)

    if irCurve then
        local irFactor = type(factor) == "table" and unwrapIR(factor) or factor
        if irFactor then
            return annotate(fn, Compiler.curve.timeScale(irCurve, irFactor), "timeScale")
        end
    end
    return fn
end

function Compiled.Curve.timeOffset(curve, offset)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)

    local fn = OriginalCurve.timeOffset(rawCurve, type(offset) == "table" and unwrapFn(offset) or offset)

    if irCurve then
        local irOffset = type(offset) == "table" and unwrapIR(offset) or offset
        if irOffset then
            return annotate(fn, Compiler.curve.timeOffset(irCurve, irOffset), "timeOffset")
        end
    end
    return fn
end

function Compiled.Curve.loop(curve, duration)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.loop(rawCurve, duration)

    if irCurve then
        return annotate(fn, Compiler.curve.loop(irCurve, duration), "loop")
    end
    return fn
end

function Compiled.Curve.delay(curve, delay)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.delay(rawCurve, delay)

    if irCurve then
        return annotate(fn, Compiler.curve.delay(irCurve, delay), "delay")
    end
    return fn
end

function Compiled.Curve.clamp(curve, lo, hi)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.clamp(rawCurve, lo, hi)

    if irCurve then
        return annotate(fn, Compiler.curve.clamp(irCurve, lo, hi), "clamp")
    end
    return fn
end

function Compiled.Curve.pow(curve, exponent)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.pow(rawCurve, exponent)

    if irCurve then
        local irExp = type(exponent) == "number" and exponent or unwrapIR(exponent)
        return annotate(fn, Compiler.curve.pow(irCurve, irExp), "pow")
    end
    return fn
end

function Compiled.Curve.exp(curve)
    local rawCurve = unwrapFn(curve)
    local irCurve = unwrapIR(curve)
    local fn = OriginalCurve.exp(rawCurve)

    if irCurve then
        return annotate(fn, Compiler.curve.exp(irCurve), "exp")
    end
    return fn
end

--------------------------------------------------------------------------------
-- MOTION WRAPPERS
--------------------------------------------------------------------------------

Compiled.Motion = {}

function Compiled.Motion.xy(curveX, curveY)
    local rawX = unwrapFn(curveX)
    local rawY = unwrapFn(curveY)
    local irX = unwrapIR(curveX)
    local irY = unwrapIR(curveY)

    local fn = OriginalMotion.xy(rawX, rawY)

    if irX and irY then
        return annotate(fn, Compiler.motion.xy(irX, irY), "xy")
    end
    return fn
end

function Compiled.Motion.circle(radius, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.circle(radius, speed)
    _creatingRaw = false
    return annotate(
        rawFn,
        Compiler.motion.circle(radius, speed),
        "circle(" .. radius .. "," .. speed .. ")"
    )
end

function Compiled.Motion.ellipse(radiusX, radiusY, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.ellipse(radiusX, radiusY, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.ellipse(radiusX, radiusY, speed), "ellipse")
end

function Compiled.Motion.spiral(radius, speed, growth)
    _creatingRaw = true
    local rawFn = OriginalMotion.spiral(radius, speed, growth)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.spiral(radius, speed, growth), "spiral")
end

function Compiled.Motion.lissajous(freqX, freqY, ampX, ampY, phase)
    _creatingRaw = true
    local rawFn = OriginalMotion.lissajous(freqX, freqY, ampX, ampY, phase)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.lissajous(freqX, freqY, ampX, ampY, phase), "lissajous")
end

function Compiled.Motion.figure8(size, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.figure8(size, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.figure8(size, speed), "figure8")
end

function Compiled.Motion.shake(intensity, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.shake(intensity, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.shake(intensity, speed), "shake")
end

function Compiled.Motion.drift(vx, vy)
    _creatingRaw = true
    local rawFn = OriginalMotion.drift(vx, vy)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.drift(vx, vy), "drift")
end

function Compiled.Motion.hover(amount, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.hover(amount, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.hover(amount, speed), "hover")
end

function Compiled.Motion.sway(amount, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.sway(amount, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.sway(amount, speed), "sway")
end

function Compiled.Motion.bob(amount, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.bob(amount, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.bob(amount, speed), "bob")
end

function Compiled.Motion.wave(forward, amplitude, frequency)
    _creatingRaw = true
    local rawFn = OriginalMotion.wave(forward, amplitude, frequency)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.wave(forward, amplitude, frequency), "wave")
end

function Compiled.Motion.bounce(height, speed)
    _creatingRaw = true
    local rawFn = OriginalMotion.bounce(height, speed)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.bounce(height, speed), "bounce")
end

function Compiled.Motion.arc(turns)
    _creatingRaw = true
    local rawFn = OriginalMotion.arc(turns)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.arc(turns), "arc")
end

function Compiled.Motion.outward(turns)
    _creatingRaw = true
    local rawFn = OriginalMotion.outward(turns)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.outward(turns), "outward")
end

function Compiled.Motion.ray(angle)
    _creatingRaw = true
    local rawFn = OriginalMotion.ray(angle)
    _creatingRaw = false
    return annotate(rawFn, Compiler.motion.ray(angle), "ray")
end

-- Combinators
function Compiled.Motion.add(...)
    local motions = {...}
    local rawMotions = {}
    local irMotions = {}
    local canCompile = true

    for i, m in ipairs(motions) do
        rawMotions[i] = unwrapFn(m)
        local ir = unwrapIR(m)
        if ir then
            irMotions[i] = ir
        else
            canCompile = false
        end
    end

    local fn = OriginalMotion.add(unpack(rawMotions))

    if canCompile then
        return annotate(fn, Compiler.motion.add(unpack(irMotions)), "motion.add")
    end
    return fn
end

function Compiled.Motion.scale(motion, factor)
    local rawMotion = unwrapFn(motion)
    local irMotion = unwrapIR(motion)

    local fn = OriginalMotion.scale(rawMotion, type(factor) == "table" and unwrapFn(factor) or factor)

    if irMotion then
        local irFactor = type(factor) == "table" and unwrapIR(factor) or factor
        if irFactor then
            return annotate(fn, Compiler.motion.scale(irMotion, irFactor), "motion.scale")
        end
    end
    return fn
end

function Compiled.Motion.rotate(motion, angle)
    local rawMotion = unwrapFn(motion)
    local irMotion = unwrapIR(motion)

    local fn = OriginalMotion.rotate(rawMotion, type(angle) == "table" and unwrapFn(angle) or angle)

    if irMotion then
        local irAngle = type(angle) == "table" and unwrapIR(angle) or angle
        if irAngle then
            return annotate(fn, Compiler.motion.rotate(irMotion, irAngle), "motion.rotate")
        end
    end
    return fn
end

function Compiled.Motion.mix(motionA, motionB, factor)
    local rawA = unwrapFn(motionA)
    local rawB = unwrapFn(motionB)
    local irA = unwrapIR(motionA)
    local irB = unwrapIR(motionB)

    local fn = OriginalMotion.mix(rawA, rawB, type(factor) == "table" and unwrapFn(factor) or factor)

    if irA and irB then
        local irFactor = type(factor) == "table" and unwrapIR(factor) or factor
        if irFactor then
            return annotate(fn, Compiler.motion.mix(irA, irB, irFactor), "motion.mix")
        end
    end
    return fn
end

--------------------------------------------------------------------------------
-- BUILD SYSTEM
--------------------------------------------------------------------------------

-- Check if IR benefits from pooling
-- Simple trig-based curves/motions are faster without pooling (especially in LuaJIT)
local function shouldPool(ir)
    if not ir then return false end

    -- Skip bare trig curves - JIT handles these optimally
    if ir.op == "sin" or ir.op == "cos" then
        return false
    end

    -- Skip simple xy motions (circle, ellipse, figure8, lissajous)
    -- These are just two trig functions - JIT is faster
    if ir.op == "xy" then
        local xSimple = ir.x and (ir.x.op == "sin" or ir.x.op == "cos")
        local ySimple = ir.y and (ir.y.op == "sin" or ir.y.op == "cos")
        if xSimple and ySimple then
            return false
        end
    end

    return true
end

--- Compile all registered closures with auto-pooling
--- Groups identical IR nodes and creates optimized pools
--- Call this once at game startup for optimal performance
--- @param opts table Options:
---   debug: bool - Print debug info
---   optimize: bool - Run optimization passes (default true)
---   pool: bool - Enable auto-pooling (default true)
---   poolThreshold: number - Min entities per pool (default 2)
---   fps: number - Frames per second (default 60)
---   dt: number - Timestep override
---   duration: number - LUT duration (default 1)
--- @return table Stats { compiled, pooled, pools, time }
function Compiled.build(opts)
    opts = opts or {}
    local startTime = love and love.timer.getTime() or os.clock()

    local usePooling = opts.pool ~= false
    local poolThreshold = opts.poolThreshold or 2
    local fps = opts.fps or Compiled._fps
    local dt = opts.dt or (1 / fps)
    local duration = opts.duration or 1

    Compiled._dt = dt
    Compiled._fps = fps

    local compiled = 0
    local failed = 0
    local pooled = 0
    local poolCount = 0

    -- Phase 1: Group wrappers by identical IR
    local groups = {}  -- irKey -> list of wrappers

    for _, wrapper in ipairs(Compiled._registry) do
        if wrapper._ir then
            local irKey = IR.toJSON(wrapper._ir)
            if not groups[irKey] then
                groups[irKey] = {
                    ir = wrapper._ir,
                    wrappers = {}
                }
            end
            table.insert(groups[irKey].wrappers, wrapper)
        end
    end

    -- Phase 2: Create pools for groups, compile singles
    Compiled._pools = {}
    Compiled._poolsList = {}

    for irKey, group in pairs(groups) do
        local wrappers = group.wrappers
        local ir = group.ir
        local count = #wrappers

        if usePooling and count >= poolThreshold and shouldPool(ir) then
            -- Create pool for this group
            local ok, pool = pcall(function()
                return Pool.create(Compiler, ir, {
                    count = count,
                    fps = fps,
                    dt = dt,
                    duration = duration,
                })
            end)

            if ok and pool then
                -- Also compile for arbitrary-t evaluation (falloff curves, etc.)
                local compiledFn = nil
                local compileOk, result = pcall(function()
                    if opts.optimize ~= false then
                        return Compiler.compileOptimized(ir, {
                            name = wrappers[1]._name,
                            debug = opts.debug
                        })
                    else
                        return Compiler.compile(ir, {
                            name = wrappers[1]._name,
                            debug = opts.debug
                        })
                    end
                end)
                if compileOk then
                    compiledFn = result
                end

                -- Collect phases from wrappers
                local phases = {}
                for i, wrapper in ipairs(wrappers) do
                    phases[i] = wrapper._phase or 0
                    wrapper._pool = pool
                    wrapper._entityIndex = i
                    wrapper._compiled = compiledFn  -- Share compiled fn for arbitrary-t calls
                end

                -- Initialize pool with phases
                pool:init(phases)

                Compiled._pools[irKey] = pool
                table.insert(Compiled._poolsList, pool)

                pooled = pooled + count
                poolCount = poolCount + 1

                if opts.debug then
                    print(string.format("[Compiled] Pool created: %s (%d entities, strategy: %s)",
                        wrappers[1]._name or "anonymous", count, pool.strategy))
                end
            else
                -- Pool creation failed, fall back to individual compilation
                if opts.debug then
                    print(string.format("[Compiled] Pool failed for %s: %s",
                        wrappers[1]._name or "anonymous", tostring(pool)))
                end
                for _, wrapper in ipairs(wrappers) do
                    local compileOk, result = pcall(function()
                        if opts.optimize ~= false then
                            return Compiler.compileOptimized(wrapper._ir, {
                                name = wrapper._name,
                                debug = opts.debug
                            })
                        else
                            return Compiler.compile(wrapper._ir, {
                                name = wrapper._name,
                                debug = opts.debug
                            })
                        end
                    end)

                    if compileOk then
                        wrapper._compiled = result
                        compiled = compiled + 1
                    else
                        failed = failed + 1
                    end
                end
            end
        else
            -- Single entity or pooling disabled - compile individually
            for _, wrapper in ipairs(wrappers) do
                if not wrapper._compiled then
                    local ok, result = pcall(function()
                        if opts.optimize ~= false then
                            return Compiler.compileOptimized(wrapper._ir, {
                                name = wrapper._name,
                                debug = opts.debug
                            })
                        else
                            return Compiler.compile(wrapper._ir, {
                                name = wrapper._name,
                                debug = opts.debug
                            })
                        end
                    end)

                    if ok then
                        wrapper._compiled = result
                        compiled = compiled + 1
                    else
                        if opts.debug then
                            print("[Compiled] Failed to compile " .. (wrapper._name or "anonymous") .. ": " .. tostring(result))
                        end
                        failed = failed + 1
                    end
                end
            end
        end
    end

    local elapsed = (love and love.timer.getTime() or os.clock()) - startTime
    Compiled._buildComplete = true

    local stats = {
        compiled = compiled,
        failed = failed,
        pooled = pooled,
        pools = poolCount,
        total = #Compiled._registry,
        time = elapsed * 1000,  -- ms
    }

    if not opts.silent then
        if poolCount > 0 then
            print(string.format("[Spatula] Built %d entities: %d pooled (%d pools), %d compiled in %.1fms",
                #Compiled._registry, pooled, poolCount, compiled, stats.time))
        else
            print(string.format("[Spatula] Compiled %d/%d motions in %.1fms",
                compiled, #Compiled._registry, stats.time))
        end
    end

    return stats
end

--- Step all pools forward by dt
--- Call this once per frame in your game loop
--- @param dt number Timestep (optional, uses configured dt if nil)
function Compiled.step(dt)
    dt = dt or Compiled._dt
    for _, pool in ipairs(Compiled._poolsList) do
        if dt == pool.dt then
            pool:step()
        else
            pool:stepDt(dt)
        end
    end
end

--- Configure default timestep
--- @param dt number Timestep in seconds
function Compiled.setDt(dt)
    Compiled._dt = dt
    Compiled._fps = 1 / dt
end

--- Configure default FPS
--- @param fps number Frames per second
function Compiled.setFps(fps)
    Compiled._fps = fps
    Compiled._dt = 1 / fps
end

--- Check if build has been completed
function Compiled.isBuilt()
    return Compiled._buildComplete
end

--- Get compilation stats
function Compiled.getStats()
    local annotated = 0
    local compiled = 0

    for _, wrapper in ipairs(Compiled._registry) do
        if wrapper._ir then
            annotated = annotated + 1
            if wrapper._compiled then
                compiled = compiled + 1
            end
        end
    end

    return {
        registered = #Compiled._registry,
        annotated = annotated,
        compiled = compiled,
        buildComplete = Compiled._buildComplete,
    }
end

--- Clear registry (for testing)
function Compiled.reset()
    Compiled._registry = {}
    Compiled._compiled = {}
    Compiled._pools = {}
    Compiled._poolsList = {}
    Compiled._buildComplete = false
end

--- Get pool info for debugging
--- @return table Info about pools
function Compiled.getPoolInfo()
    local info = {}
    for irKey, pool in pairs(Compiled._pools) do
        info[#info + 1] = {
            strategy = pool.strategy,
            count = pool.count,
            isMotion = pool.isMotion,
            axis = pool.axis,
        }
    end
    return info
end

--------------------------------------------------------------------------------
-- AUTO-INSTRUMENTATION
-- Patch the original modules so any require("spatula.curve") gets instrumented
--------------------------------------------------------------------------------

for name, fn in pairs(Compiled.Curve) do
    RawCurve[name] = fn
end

for name, fn in pairs(Compiled.Motion) do
    RawMotion[name] = fn
end

return Compiled
