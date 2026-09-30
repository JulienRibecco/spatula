--- Spatula Curve Module
--- @module spatula.curve
---
--- ============================================================================
--- THE PRIMITIVE: Curve = f(t, ctx) → value
--- ============================================================================
---
--- A curve maps time to a value. This is the atomic unit of Spatula.
--- Everything else—Motion, Field, Pattern—composes from curves.
---
--- PRIMITIVES:    Irreducible building blocks (const, sin, noise, spring...)
--- COMBINATORS:   Transform or combine curves (add, scale, timeScale...)
--- COMPOSITIONS:  Built from primitives+combinators (gaussian)
---
--- ============================================================================

local U = require("spatula.util")
local Curve = {}

local sin, cos, abs, floor, min, max, exp = U.sin, U.cos, U.abs, U.floor, U.min, U.max, U.exp
local PI, PI2 = U.PI, U.PI2

--------------------------------------------------------------------------------
-- INTERNAL: Unique IDs for stateful curves
--------------------------------------------------------------------------------

local curveId = 0
local function nextId()
    curveId = curveId + 1
    return curveId
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Value sources
-- These produce values directly. They are the leaves of any composition.
--------------------------------------------------------------------------------

function Curve.const(value)
    return function(t, ctx) return value end
end

function Curve.linear(speed)
    speed = speed or 1
    return function(t, ctx) return t * speed end
end

function Curve.ramp(start, target, duration)
    if type(duration) == "function" then
        return function(t, ctx)
            local dur = duration(t, ctx)
            if t >= dur then return target end
            return start + (target - start) * (t / dur)
        end
    end
    return function(t, ctx)
        if t >= duration then return target end
        return start + (target - start) * (t / duration)
    end
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Oscillators
-- Periodic signals. These use sin/cos directly because they ARE the primitives.
-- Everything periodic in the library traces back here.
--------------------------------------------------------------------------------

function Curve.sin(freq, amp, phase)
    freq = freq or 1
    amp = amp or 1
    phase = phase or 0
    return function(t, ctx)
        return sin(t * freq * PI2 + phase) * amp
    end
end

function Curve.cos(freq, amp, phase)
    freq = freq or 1
    amp = amp or 1
    phase = phase or 0
    return function(t, ctx)
        return cos(t * freq * PI2 + phase) * amp
    end
end

function Curve.triangle(freq, amp)
    freq = freq or 1
    amp = amp or 1
    return function(t, ctx)
        local phase = (t * freq) % 1
        local v = phase < 0.5 and (phase * 4 - 1) or (3 - phase * 4)
        return v * amp
    end
end

function Curve.saw(freq, amp)
    freq = freq or 1
    amp = amp or 1
    return function(t, ctx)
        local phase = (t * freq) % 1
        return (phase * 2 - 1) * amp
    end
end

function Curve.square(freq, amp, duty)
    freq = freq or 1
    amp = amp or 1
    duty = duty or 0.5
    return function(t, ctx)
        local phase = (t * freq) % 1
        return (phase < duty and 1 or -1) * amp
    end
end

function Curve.pulse(freq, duty)
    freq = freq or 1
    duty = duty or 0.5
    return function(t, ctx)
        local phase = (t * freq) % 1
        return phase < duty and 1 or 0
    end
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Easing
-- Normalized transitions over a duration. Output goes 0→1.
-- Use with Curve.scale/offset to map to other ranges.
--------------------------------------------------------------------------------

function Curve.easeIn(duration, power)
    duration = duration or 1
    power = power or 2
    return function(t, ctx)
        local p = U.clamp(t / duration, 0, 1)
        return p ^ power
    end
end

function Curve.easeOut(duration, power)
    duration = duration or 1
    power = power or 2
    return function(t, ctx)
        local p = U.clamp(t / duration, 0, 1)
        return 1 - (1 - p) ^ power
    end
end

function Curve.easeInOut(duration, power)
    duration = duration or 1
    power = power or 2
    return function(t, ctx)
        local p = U.clamp(t / duration, 0, 1)
        if p < 0.5 then
            return (2 ^ (power - 1)) * (p ^ power)
        else
            return 1 - ((-2 * p + 2) ^ power) / 2
        end
    end
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Noise
-- Non-periodic variation. Deterministic given the same t and seed.
--------------------------------------------------------------------------------

function Curve.noise(scale, seed)
    scale = scale or 1
    seed = seed or 0
    return function(t, ctx)
        local n = sin(t * 1.0 + seed) * 0.5 +
                  sin(t * 2.3 + seed * 2) * 0.3 +
                  sin(t * 5.7 + seed * 3) * 0.2
        return n * scale
    end
end

function Curve.perlin(scale, octaves)
    scale = scale or 1
    octaves = octaves or 3
    return function(t, ctx)
        local value = 0
        local amp = 1
        local freq = 1
        local maxVal = 0
        for i = 1, octaves do
            local ti = t * freq
            local t0 = floor(ti)
            local t1 = t0 + 1
            local frac = ti - t0
            local smooth = frac * frac * (3 - 2 * frac)
            local h0 = sin(t0 * 127.1) * 43758.5453
            local h1 = sin(t1 * 127.1) * 43758.5453
            local n0 = (h0 - floor(h0)) * 2 - 1
            local n1 = (h1 - floor(h1)) * 2 - 1
            value = value + (n0 + (n1 - n0) * smooth) * amp
            maxVal = maxVal + amp
            amp = amp * 0.5
            freq = freq * 2
        end
        return (value / maxVal) * scale
    end
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Stateful
-- These track internal state via ctx.curveState.
-- They respond to OTHER curves, enabling reactive behaviors.
--------------------------------------------------------------------------------

function Curve.follow(targetFn, speed)
    speed = speed or 5
    local id = nextId()
    return function(t, ctx)
        ctx.curveState = ctx.curveState or {}
        local state = ctx.curveState[id]
        if not state then
            state = { value = targetFn(t, ctx), lastT = t }
            ctx.curveState[id] = state
        end

        local dt = t - state.lastT
        state.lastT = t

        local target = targetFn(t, ctx)
        state.value = state.value + (target - state.value) * min(1, speed * dt)
        return state.value
    end
end

function Curve.spring(targetFn, stiffness, damping)
    stiffness = stiffness or 100
    damping = damping or 10
    local id = nextId()
    return function(t, ctx)
        ctx.curveState = ctx.curveState or {}
        local state = ctx.curveState[id]
        if not state then
            state = { value = targetFn(t, ctx), velocity = 0, lastT = t }
            ctx.curveState[id] = state
        end

        local dt = min(t - state.lastT, 0.1)
        state.lastT = t

        local target = targetFn(t, ctx)
        local force = (target - state.value) * stiffness
        local dampForce = state.velocity * damping
        state.velocity = state.velocity + (force - dampForce) * dt
        state.value = state.value + state.velocity * dt
        return state.value
    end
end

--------------------------------------------------------------------------------
-- COMBINATORS: Arithmetic
-- Combine curve VALUES. The curves are evaluated, then combined.
--
--   add(a, b)     → a(t) + b(t)
--   mul(a, b)     → a(t) * b(t)
--   scale(a, 2)   → a(t) * 2
--   offset(a, 5)  → a(t) + 5
--------------------------------------------------------------------------------

function Curve.add(...)
    local curves = {...}
    return function(t, ctx)
        local sum = 0
        for _, c in ipairs(curves) do
            sum = sum + c(t, ctx)
        end
        return sum
    end
end

function Curve.mul(...)
    local curves = {...}
    return function(t, ctx)
        local product = 1
        for _, c in ipairs(curves) do
            product = product * c(t, ctx)
        end
        return product
    end
end

function Curve.sub(a, b)
    return function(t, ctx)
        return a(t, ctx) - b(t, ctx)
    end
end

function Curve.scale(curve, factor)
    local factorFn = type(factor) == "number" and Curve.const(factor) or factor
    return function(t, ctx)
        return curve(t, ctx) * factorFn(t, ctx)
    end
end

function Curve.offset(curve, amount)
    local amountFn = type(amount) == "number" and Curve.const(amount) or amount
    return function(t, ctx)
        return curve(t, ctx) + amountFn(t, ctx)
    end
end

function Curve.clamp(curve, lo, hi)
    return function(t, ctx)
        return U.clamp(curve(t, ctx), lo, hi)
    end
end

function Curve.abs(curve)
    return function(t, ctx)
        return abs(curve(t, ctx))
    end
end

function Curve.neg(curve)
    return function(t, ctx)
        return -curve(t, ctx)
    end
end

--- Mixes multiple curves based on a table of weights.
--- @param curves table Array of curve functions.
--- @param weights table Array of numbers or curve functions.
function Curve.mix(curves, weights)
    local n = #curves
    -- Ensure weights are wrapped as functions
    local weightFns = {}
    for i = 1, n do
        local w = weights[i] or 0
        weightFns[i] = type(w) == "number" and Curve.const(w) or w
    end

    return function(t, ctx)
        local sum = 0
        local totalWeight = 0

        for i = 1, n do
            local w = weightFns[i](t, ctx)
            sum = sum + (curves[i](t, ctx) * w)
            totalWeight = totalWeight + w
        end

        -- Normalize the result: this ensures that if all curves are
        -- at '1.0', the output is '1.0' regardless of weight scale.
        if totalWeight == 0 then return 0 end
        return sum / totalWeight
    end
end

function Curve.pow(curve, exponent)
    local expFn = type(exponent) == "number" and Curve.const(exponent) or exponent
    return function(t, ctx)
        return curve(t, ctx) ^ expFn(t, ctx)
    end
end

function Curve.exp(curve)
    return function(t, ctx)
        return exp(curve(t, ctx))
    end
end

function Curve.quantize(curve, steps)
    steps = steps or 8
    return function(t, ctx)
        local v = curve(t, ctx)
        return floor(v * steps + 0.5) / steps
    end
end

--------------------------------------------------------------------------------
-- COMBINATORS: Time manipulation
-- Transform the T input before evaluating the curve.
--
--   timeScale(a, 2)   → a(t * 2)     -- twice as fast
--   timeOffset(a, 1)  → a(t + 1)     -- shifted forward
--   loop(a, 3)        → a(t % 3)     -- repeats every 3 seconds
--   delay(a, 1)       → 0 until t≥1, then a(t-1)
--------------------------------------------------------------------------------

function Curve.timeScale(curve, factor)
    local factorFn = type(factor) == "number" and Curve.const(factor) or factor
    return function(t, ctx)
        return curve(t * factorFn(t, ctx), ctx)
    end
end

function Curve.timeOffset(curve, offset)
    local offsetFn = type(offset) == "number" and Curve.const(offset) or offset
    return function(t, ctx)
        return curve(t + offsetFn(t, ctx), ctx)
    end
end

function Curve.loop(curve, duration)
    return function(t, ctx)
        return curve(t % duration, ctx)
    end
end

function Curve.pingPong(curve, duration)
    return function(t, ctx)
        local phase = (t / duration) % 2
        local lt = phase < 1 and (phase * duration) or ((2 - phase) * duration)
        return curve(lt, ctx)
    end
end

function Curve.hold(curve, duration)
    return function(t, ctx)
        return curve(min(t, duration), ctx)
    end
end

function Curve.delay(curve, delay)
    return function(t, ctx)
        if t < delay then return 0 end
        return curve(t - delay, ctx)
    end
end

--------------------------------------------------------------------------------
-- COMBINATORS: Sequencing
-- Chain multiple curves over time.
--
--   sequence({{curveA, 2}, {curveB, 3}})
--   → plays curveA for 2 seconds, then curveB for 3, then loops
--------------------------------------------------------------------------------

function Curve.sequence(segments)
    -- Fast path: all static durations (zero overhead for existing usage)
    local allStatic = true
    for _, seg in ipairs(segments) do
        if type(seg[2]) ~= "number" then allStatic = false; break end
    end

    if allStatic then
        local totalDuration = 0
        for _, seg in ipairs(segments) do
            totalDuration = totalDuration + seg[2]
        end

        return function(t, ctx)
            local elapsed = t % totalDuration
            local accumulated = 0

            for _, seg in ipairs(segments) do
                local curve, duration = seg[1], seg[2]
                if elapsed < accumulated + duration then
                    return curve(elapsed - accumulated, ctx)
                end
                accumulated = accumulated + duration
            end

            local last = segments[#segments]
            return last[1](last[2], ctx)
        end
    end

    -- Dynamic path: durations can be f(t, ctx) → number
    return function(t, ctx)
        local totalDuration = 0
        for _, seg in ipairs(segments) do
            local dur = seg[2]
            totalDuration = totalDuration + (type(dur) == "function" and dur(t, ctx) or dur)
        end

        local elapsed = t % totalDuration
        local accumulated = 0

        for _, seg in ipairs(segments) do
            local dur = seg[2]
            dur = type(dur) == "function" and dur(t, ctx) or dur
            if elapsed < accumulated + dur then
                return seg[1](elapsed - accumulated, ctx)
            end
            accumulated = accumulated + dur
        end

        local last = segments[#segments]
        local lastDur = last[2]
        lastDur = type(lastDur) == "function" and lastDur(t, ctx) or lastDur
        return last[1](lastDur, ctx)
    end
end

--------------------------------------------------------------------------------
-- COMPOSITIONS
-- Built entirely from primitives and combinators.
-- These prove the system is complete—no raw math needed.
--------------------------------------------------------------------------------

function Curve.gaussian(width)
    -- gaussian(t) = e^(-3t²/width²)
    -- Builds up: t → t² → k·t² → e^(k·t²)
    width = width or 1
    local k = -3 / (width * width)
    local t = Curve.linear(1)              -- t
    local tSquared = Curve.pow(t, 2)       -- t²
    local exponent = Curve.scale(tSquared, k)  -- k·t² where k < 0
    return Curve.exp(exponent)             -- e^(k·t²)
end

--------------------------------------------------------------------------------
-- PRIMITIVES: Keyframe interpolation
-- For data-driven curves (audio envelopes, motion capture, etc.)
--------------------------------------------------------------------------------

--- Create a curve from keyframe data with interpolation
--- @param keyframes table Array of {t, v} pairs, sorted by time
--- @param mode string "linear" (default), "step", or "smooth" (catmull-rom)
--- @return function Curve f(t, ctx) -> value
function Curve.envelope(keyframes, mode)
    mode = mode or "linear"
    local n = #keyframes
    if n == 0 then return Curve.const(0) end
    if n == 1 then return Curve.const(keyframes[1][2]) end

    -- Binary search for keyframe index
    local function findSegment(t)
        if t <= keyframes[1][1] then return 1, 1 end
        if t >= keyframes[n][1] then return n, n end

        local lo, hi = 1, n
        while hi - lo > 1 do
            local mid = floor((lo + hi) / 2)
            if keyframes[mid][1] <= t then
                lo = mid
            else
                hi = mid
            end
        end
        return lo, hi
    end

    if mode == "step" then
        return function(t, ctx)
            local i = findSegment(t)
            return keyframes[i][2]
        end
    elseif mode == "smooth" then
        -- Catmull-Rom spline interpolation
        return function(t, ctx)
            local i, j = findSegment(t)
            if i == j then return keyframes[i][2] end

            local t0, v0 = keyframes[i][1], keyframes[i][2]
            local t1, v1 = keyframes[j][1], keyframes[j][2]
            local alpha = (t - t0) / (t1 - t0)

            -- Get surrounding points for spline
            local vm1 = i > 1 and keyframes[i-1][2] or v0
            local v2 = j < n and keyframes[j+1][2] or v1

            -- Catmull-Rom coefficients
            local a = alpha
            local a2 = a * a
            local a3 = a2 * a

            return 0.5 * (
                (2 * v0) +
                (-vm1 + v1) * a +
                (2*vm1 - 5*v0 + 4*v1 - v2) * a2 +
                (-vm1 + 3*v0 - 3*v1 + v2) * a3
            )
        end
    else -- linear (default)
        return function(t, ctx)
            local i, j = findSegment(t)
            if i == j then return keyframes[i][2] end

            local t0, v0 = keyframes[i][1], keyframes[i][2]
            local t1, v1 = keyframes[j][1], keyframes[j][2]
            local alpha = (t - t0) / (t1 - t0)

            return v0 + (v1 - v0) * alpha
        end
    end
end

return Curve
