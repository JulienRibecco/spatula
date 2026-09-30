--------------------------------------------------------------------------------
-- SPATULA IR (Intermediate Representation)
-- Data structures representing compositions - no closures, just data.
-- IR is JSON-compatible for cross-language code generation.
--------------------------------------------------------------------------------

local IR = {}
local unpack = table.unpack or unpack

IR.curve = {}
IR.motion = {}
IR.form = {}
IR.trigger = {}
IR.distribution = {}
IR.falloff = {}
IR.field = {}

--------------------------------------------------------------------------------
-- JSON SERIALIZATION
--------------------------------------------------------------------------------

local JSON = require("spatula.json")
IR.toJSON = JSON.encode
IR.fromJSON = JSON.decode

local PI = math.pi
local PI2 = PI * 2

--------------------------------------------------------------------------------
-- STATE ID COUNTER (for stateful curves)
--------------------------------------------------------------------------------

local stateIdCounter = 0

local function nextStateId()
    stateIdCounter = stateIdCounter + 1
    return stateIdCounter
end

function IR.resetStateIds()
    stateIdCounter = 0
end

--------------------------------------------------------------------------------
-- CURVE IR NODES
--------------------------------------------------------------------------------

function IR.curve.const(value)
    return { op = "const", value = value }
end

--- Signal: a curve that reads from context instead of computing from time
--- @param name string The key to read from ctx
--- @param default number Optional default value (default: 0)
function IR.curve.signal(name, default)
    return { op = "fromCtx", key = name, default = default or 0 }
end
IR.curve.S = IR.curve.signal  -- shorthand

function IR.curve.linear(speed)
    return { op = "linear", speed = speed or 1 }
end

function IR.curve.sin(freq, amp, phase)
    return { op = "sin", freq = freq or 1, amp = amp or 1, phase = phase or 0 }
end

function IR.curve.cos(freq, amp, phase)
    return { op = "cos", freq = freq or 1, amp = amp or 1, phase = phase or 0 }
end

function IR.curve.triangle(freq, amp)
    return { op = "triangle", freq = freq or 1, amp = amp or 1 }
end

function IR.curve.saw(freq, amp)
    return { op = "saw", freq = freq or 1, amp = amp or 1 }
end

function IR.curve.square(freq, amp, duty)
    return { op = "square", freq = freq or 1, amp = amp or 1, duty = duty or 0.5 }
end

function IR.curve.pulse(freq, duty)
    return { op = "pulse", freq = freq or 1, duty = duty or 0.5 }
end

--------------------------------------------------------------------------------
-- STATEFUL CURVE IR NODES
-- These curves maintain state between evaluations via ctx.curveState
--------------------------------------------------------------------------------

--- Create a follow curve that smoothly approaches a target
--- @param targetCurve table IR node for the target value
--- @param speed number How fast to approach target (default 5)
function IR.curve.follow(targetCurve, speed)
    return {
        op = "follow",
        target = targetCurve,
        speed = speed or 5,
        stateId = nextStateId()
    }
end

--- Create a spring curve that bounces toward a target
--- @param targetCurve table IR node for the target value
--- @param stiffness number Spring stiffness (default 100)
--- @param damping number Damping factor (default 10)
function IR.curve.spring(targetCurve, stiffness, damping)
    return {
        op = "spring",
        target = targetCurve,
        stiffness = stiffness or 100,
        damping = damping or 10,
        stateId = nextStateId()
    }
end

function IR.curve.noise(scale, seed)
    return { op = "noise", scale = scale or 1, seed = seed or 0 }
end

function IR.curve.easeIn(duration, power)
    return { op = "easeIn", duration = duration or 1, power = power or 2 }
end

function IR.curve.easeOut(duration, power)
    return { op = "easeOut", duration = duration or 1, power = power or 2 }
end

function IR.curve.easeInOut(duration, power)
    return { op = "easeInOut", duration = duration or 1, power = power or 2 }
end

function IR.curve.ramp(start, target, duration)
    return { op = "ramp", start = start, target = target, duration = duration }
end

--------------------------------------------------------------------------------
-- CURVE COMBINATORS
--------------------------------------------------------------------------------

function IR.curve.add(...)
    return { op = "add", children = {...} }
end

function IR.curve.mul(...)
    return { op = "mul", children = {...} }
end

function IR.curve.sub(a, b)
    return { op = "sub", a = a, b = b }
end

function IR.curve.scale(curve, factor)
    if type(factor) == "number" then
        return { op = "scaleConst", curve = curve, factor = factor }
    else
        return { op = "scaleCurve", curve = curve, factor = factor }
    end
end

function IR.curve.offset(curve, amount)
    if type(amount) == "number" then
        return { op = "offsetConst", curve = curve, amount = amount }
    else
        return { op = "offsetCurve", curve = curve, amount = amount }
    end
end

function IR.curve.neg(curve)
    return { op = "neg", curve = curve }
end

function IR.curve.abs(curve)
    return { op = "abs", curve = curve }
end

function IR.curve.pow(curve, exponent)
    if type(exponent) == "number" then
        return { op = "powConst", curve = curve, exponent = exponent }
    else
        return { op = "powCurve", curve = curve, exponent = exponent }
    end
end

function IR.curve.clamp(curve, lo, hi)
    return { op = "clamp", curve = curve, lo = lo, hi = hi }
end

function IR.curve.exp(curve)
    return { op = "exp", curve = curve }
end

--------------------------------------------------------------------------------
-- TIME MANIPULATION
--------------------------------------------------------------------------------

function IR.curve.timeScale(curve, factor)
    if type(factor) == "number" then
        return { op = "timeScaleConst", curve = curve, factor = factor }
    else
        return { op = "timeScaleCurve", curve = curve, factor = factor }
    end
end

function IR.curve.timeOffset(curve, offset)
    if type(offset) == "number" then
        return { op = "timeOffsetConst", curve = curve, offset = offset }
    else
        return { op = "timeOffsetCurve", curve = curve, offset = offset }
    end
end

function IR.curve.loop(curve, duration)
    return { op = "loop", curve = curve, duration = duration }
end

function IR.curve.delay(curve, delay)
    return { op = "delay", curve = curve, delay = delay }
end

--- Remap time: evaluate curve at timeCurve(t) instead of t
--- This is the general time substitution primitive
--- @param curve table Curve to remap
--- @param timeCurve table Curve that produces the new time value
function IR.curve.remap(curve, timeCurve)
    return { op = "remap", curve = curve, timeCurve = timeCurve }
end

--- Pingpong: play curve forward then backward, repeating
--- @param curve table Curve to pingpong
--- @param duration number Duration of each leg; a full cycle takes 2 * duration
function IR.curve.pingpong(curve, duration)
    local freq = 1 / (2 * duration)
    local pingpongTime = IR.curve.scale(
        IR.curve.offset(IR.curve.triangle(freq, 1), 1),
        duration / 2
    )
    return IR.curve.remap(curve, pingpongTime)
end

--- Curve active only during time window [start, start+duration], 0 elsewhere
function IR.curve.segment(curve, start, duration)
    return { op = "segment", curve = curve, start = start, duration = duration }
end

--- Sequence curves in time: each plays for its duration, then next starts
--- Usage: sequence({curve1, dur1}, {curve2, dur2}, ...)
function IR.curve.sequence(...)
    local segments = {...}
    local parts = {}
    local currentTime = 0
    for _, seg in ipairs(segments) do
        local curve, duration = seg[1], seg[2]
        parts[#parts + 1] = IR.curve.segment(curve, currentTime, duration)
        currentTime = currentTime + duration
    end
    return IR.curve.add(unpack(parts))
end

--- Blend between two curves: a*(1-t) + b*t where t is a curve
function IR.curve.lerp(a, b, t)
    return IR.curve.add(
        IR.curve.mul(a, IR.curve.sub(IR.curve.const(1), t)),
        IR.curve.mul(b, t)
    )
end

--------------------------------------------------------------------------------
-- MOTION IR NODES
--------------------------------------------------------------------------------

function IR.motion.xy(curveX, curveY)
    return { op = "xy", x = curveX, y = curveY, type = "motion" }
end

function IR.motion.add(...)
    return { op = "motionAdd", children = {...}, type = "motion" }
end

function IR.motion.scale(motion, factor)
    if type(factor) == "number" then
        return { op = "motionScaleConst", motion = motion, factor = factor, type = "motion" }
    else
        return { op = "motionScaleCurve", motion = motion, factor = factor, type = "motion" }
    end
end

function IR.motion.rotate(motion, angle)
    if type(angle) == "number" then
        return { op = "motionRotateConst", motion = motion, angle = angle, type = "motion" }
    else
        return { op = "motionRotateCurve", motion = motion, angle = angle, type = "motion" }
    end
end

function IR.motion.mix(motionA, motionB, factor)
    if type(factor) == "number" then
        return { op = "motionMixConst", a = motionA, b = motionB, factor = factor, type = "motion" }
    else
        return { op = "motionMixCurve", a = motionA, b = motionB, factor = factor, type = "motion" }
    end
end

--- Motion active only during time window [start, start+duration], (0,0) elsewhere
function IR.motion.segment(motion, start, duration)
    return { op = "motionSegment", motion = motion, start = start, duration = duration, type = "motion" }
end

--- Sequence motions in time: each plays for its duration, then next starts
--- Usage: sequence({motion1, dur1}, {motion2, dur2}, ...)
function IR.motion.sequence(...)
    local segments = {...}
    local parts = {}
    local currentTime = 0
    for _, seg in ipairs(segments) do
        local motion, duration = seg[1], seg[2]
        parts[#parts + 1] = IR.motion.segment(motion, currentTime, duration)
        currentTime = currentTime + duration
    end
    return IR.motion.add(unpack(parts))
end

--- Blend between two motions: a*(1-t) + b*t where t is a curve
--- (alias for mix with curve factor)
function IR.motion.lerp(a, b, t)
    return IR.motion.mix(a, b, t)
end

--------------------------------------------------------------------------------
-- MOTION COMPOSITIONS (built from primitives)
--------------------------------------------------------------------------------

function IR.motion.circle(radius, speed)
    return IR.motion.xy(
        IR.curve.cos(speed, radius),
        IR.curve.sin(speed, radius)
    )
end

function IR.motion.ellipse(radiusX, radiusY, speed)
    return IR.motion.xy(
        IR.curve.cos(speed, radiusX),
        IR.curve.sin(speed, radiusY)
    )
end

function IR.motion.spiral(radius, speed, growth)
    growth = growth or 1
    local scaleFactor = IR.curve.offset(IR.curve.linear(growth), 1)
    return IR.motion.scale(IR.motion.circle(radius, speed), scaleFactor)
end

function IR.motion.lissajous(freqX, freqY, ampX, ampY, phase)
    ampX = ampX or 1
    ampY = ampY or ampX
    phase = phase or (PI / 2)
    return IR.motion.xy(
        IR.curve.sin(freqX, ampX),
        IR.curve.sin(freqY, ampY, phase)
    )
end

function IR.motion.figure8(size, speed)
    return IR.motion.lissajous(speed, speed * 2, size, size, 0)
end

function IR.motion.shake(intensity, speed)
    speed = speed or 10
    return IR.motion.xy(
        IR.curve.timeScale(IR.curve.noise(intensity, 0), speed),
        IR.curve.timeScale(IR.curve.noise(intensity, 12345), speed)
    )
end

function IR.motion.drift(vx, vy)
    vy = vy or 0
    return IR.motion.xy(
        IR.curve.linear(vx),
        IR.curve.linear(vy)
    )
end

function IR.motion.hover(amount, speed)
    amount = amount or 5
    speed = speed or 0.5
    return IR.motion.xy(
        IR.curve.sin(speed, amount),
        IR.curve.sin(speed * 1.3, amount, PI / 3)
    )
end

function IR.motion.sway(amount, speed)
    return IR.motion.xy(
        IR.curve.sin(speed, amount),
        IR.curve.const(0)
    )
end

function IR.motion.bob(amount, speed)
    return IR.motion.xy(
        IR.curve.const(0),
        IR.curve.sin(speed, amount)
    )
end

function IR.motion.wave(forward, amplitude, frequency)
    return IR.motion.xy(
        IR.curve.linear(forward),
        IR.curve.sin(frequency, amplitude)
    )
end

function IR.motion.bounce(height, speed)
    return IR.motion.xy(
        IR.curve.const(0),
        IR.curve.abs(IR.curve.sin(speed, height))
    )
end

function IR.motion.arc(turns)
    turns = turns or 1
    return IR.motion.circle(1, turns)
end

function IR.motion.outward(turns)
    turns = turns or 1
    return IR.motion.xy(
        IR.curve.mul(IR.curve.cos(turns, 1), IR.curve.linear(1)),
        IR.curve.mul(IR.curve.sin(turns, 1), IR.curve.linear(1))
    )
end

function IR.motion.ray(angle)
    return IR.motion.rotate(IR.motion.drift(1, 0), angle)
end

--------------------------------------------------------------------------------
-- FORM IR NODES
-- Spatial containment checks: (x, y) → bool
--------------------------------------------------------------------------------

--- Circle containment
--- @param ox number Center X
--- @param oy number Center Y
--- @param radius number Radius
function IR.form.circle(ox, oy, radius)
    return { op = "formCircle", ox = ox, oy = oy, radius = radius, type = "form" }
end

--- Rectangle containment (centered, half-widths)
--- @param ox number Center X
--- @param oy number Center Y
--- @param hw number Half-width
--- @param hh number Half-height
function IR.form.rect(ox, oy, hw, hh)
    return { op = "formRect", ox = ox, oy = oy, hw = hw, hh = hh, type = "form" }
end

--- Ellipse containment
--- @param ox number Center X
--- @param oy number Center Y
--- @param rx number Radius X
--- @param ry number Radius Y
function IR.form.ellipse(ox, oy, rx, ry)
    return { op = "formEllipse", ox = ox, oy = oy, rx = rx, ry = ry, type = "form" }
end

--- Ring (donut) containment
--- @param ox number Center X
--- @param oy number Center Y
--- @param outerR number Outer radius
--- @param innerR number Inner radius
function IR.form.ring(ox, oy, outerR, innerR)
    return { op = "formRing", ox = ox, oy = oy, outerR = outerR, innerR = innerR, type = "form" }
end

--- Union of forms (any match)
--- @vararg table Form IR nodes
function IR.form.union(...)
    return { op = "formUnion", children = {...}, type = "form" }
end

--- Intersection of forms (all must match)
--- @vararg table Form IR nodes
function IR.form.intersect(...)
    return { op = "formIntersect", children = {...}, type = "form" }
end

--- Subtract inner from outer
--- @param outer table Outer form IR
--- @param inner table Inner form IR to subtract
function IR.form.subtract(outer, inner)
    return { op = "formSubtract", outer = outer, inner = inner, type = "form" }
end

--------------------------------------------------------------------------------
-- TRIGGER IR NODES
-- Timing and selection patterns
--------------------------------------------------------------------------------

--- Interval timing - fires every N seconds
--- @param seconds number Interval between fires
function IR.trigger.interval(seconds)
    return { op = "triggerInterval", interval = seconds, type = "timing" }
end

--- Fire N times then stop
--- @param n number Number of times to fire
--- @param interval number Seconds between fires
function IR.trigger.times(n, interval)
    return { op = "triggerTimes", n = n, interval = interval, type = "timing" }
end

--- Burst pattern - fire count times quickly, then pause
--- @param count number Fires per burst
--- @param interval number Seconds between fires in burst
--- @param pause number Seconds between bursts
function IR.trigger.burst(count, interval, pause)
    return { op = "triggerBurst", count = count, interval = interval, pause = pause, type = "timing" }
end

--- Select all points
function IR.trigger.selectAll()
    return { op = "selectAll", type = "selection" }
end

--- Select N random points
--- @param n number Number of points to select
function IR.trigger.selectRandom(n)
    return { op = "selectRandom", n = n, type = "selection" }
end

--- Select first N points
--- @param n number Number of points to select
function IR.trigger.selectFirst(n)
    return { op = "selectFirst", n = n, type = "selection" }
end

--- Select last N points
--- @param n number Number of points to select
function IR.trigger.selectLast(n)
    return { op = "selectLast", n = n, type = "selection" }
end

--- Select one point sequentially (cycles through)
function IR.trigger.selectSequential()
    return { op = "selectSequential", type = "selection" }
end

--------------------------------------------------------------------------------
-- UNIT FORMS (for distributions - relative to origin/size)
-- These are forms defined in unit space [-1,1] that scale with size
--------------------------------------------------------------------------------

--- Unit circle - centered at origin, radius = size
function IR.form.circleUnit()
    return { op = "formCircleUnit", type = "form" }
end

--- Unit rectangle - centered at origin, half-widths = size
function IR.form.rectUnit()
    return { op = "formRectUnit", type = "form" }
end

--- Unit ellipse - centered at origin, rx = size * aspectX, ry = size * aspectY
--- @param aspectX number X aspect ratio (default 1)
--- @param aspectY number Y aspect ratio (default 1)
function IR.form.ellipseUnit(aspectX, aspectY)
    return { op = "formEllipseUnit", aspectX = aspectX or 1, aspectY = aspectY or 1, type = "form" }
end

--- Unit ring - centered at origin, outerR = size, innerR = size * innerRatio
--- @param innerRatio number Ratio of inner to outer radius (default 0.5)
function IR.form.ringUnit(innerRatio)
    return { op = "formRingUnit", innerRatio = innerRatio or 0.5, type = "form" }
end

--------------------------------------------------------------------------------
-- DISTRIBUTION IR NODES
-- Generate point patterns within Forms
--------------------------------------------------------------------------------

--- Sample points along a motion path, filtered by form
--- @param motionIR table Motion IR node defining the path
--- @param formIR table Form IR node for containment filtering
--- @param count number Number of points to sample
function IR.distribution.sample(motionIR, formIR, count)
    return {
        op = "distSample",
        motion = motionIR,
        form = formIR,
        count = count or 100,
        type = "distribution"
    }
end

--- Grid distribution within a form
--- @param formIR table Form IR node for containment filtering
--- @param cols number Number of columns
--- @param rows number Number of rows (optional, defaults to cols)
function IR.distribution.grid(formIR, cols, rows)
    return {
        op = "distGrid",
        form = formIR,
        cols = cols or 10,
        rows = rows or cols or 10,
        type = "distribution"
    }
end

--- Spiral distribution - points spiral outward from center
--- @param formIR table Form IR node for containment filtering
--- @param count number Number of points
--- @param turns number Number of spiral turns (default 3)
function IR.distribution.spiral(formIR, count, turns)
    return {
        op = "distSpiral",
        form = formIR,
        count = count or 100,
        turns = turns or 3,
        type = "distribution"
    }
end

--- Burst distribution - points radiate outward in rays
--- @param formIR table Form IR node for containment filtering
--- @param rays number Number of radial rays
--- @param pointsPerRay number Points per ray
function IR.distribution.burst(formIR, rays, pointsPerRay)
    return {
        op = "distBurst",
        form = formIR,
        rays = rays or 8,
        pointsPerRay = pointsPerRay or 5,
        type = "distribution"
    }
end

--- Random distribution within a form
--- @param formIR table Form IR node for containment filtering
--- @param count number Number of points to generate
function IR.distribution.random(formIR, count)
    return {
        op = "distRandom",
        form = formIR,
        count = count or 100,
        type = "distribution"
    }
end

--- Ring distribution - points arranged in concentric rings
--- @param formIR table Form IR node for containment filtering
--- @param rings number Number of rings
--- @param pointsPerRing number Points per ring (or table of counts)
function IR.distribution.rings(formIR, ringCount, pointsPerRing)
    return {
        op = "distRings",
        form = formIR,
        ringCount = ringCount or 3,
        pointsPerRing = pointsPerRing or 12,
        type = "distribution"
    }
end

--------------------------------------------------------------------------------
-- FALLOFF IR
-- Falloffs for Field sources - normalized distance [0,1] → influence [0,1]
-- Mirrors Field.falloff presets for compilable representation.
--------------------------------------------------------------------------------

--- Linear falloff: 1-d
function IR.falloff.linear()
    return { op = "falloffLinear", type = "falloff" }
end

--- Smooth falloff: (1-d)²
function IR.falloff.smooth()
    return { op = "falloffSmooth", type = "falloff" }
end

--- Spike falloff: (1-d)⁴ - sharp center
function IR.falloff.spike()
    return { op = "falloffSpike", type = "falloff" }
end

--- Steep falloff: (1-d)⁶ - very sharp center
function IR.falloff.steep()
    return { op = "falloffSteep", type = "falloff" }
end

--- Soft falloff: (1-d)^1.5 - gentler than smooth
function IR.falloff.soft()
    return { op = "falloffSoft", type = "falloff" }
end

--- Gaussian falloff: e^(-k*d²)
--- @param k number Decay rate (default 3)
function IR.falloff.gaussian(k)
    return { op = "falloffGaussian", k = k or 3, type = "falloff" }
end

--- Constant falloff: always 1 (uniform within radius)
function IR.falloff.constant()
    return { op = "falloffConstant", type = "falloff" }
end

--- Inverse falloff: d (grows outward)
function IR.falloff.inverse()
    return { op = "falloffInverse", type = "falloff" }
end

--- Ring falloff: peaks at middle distance (uses sin)
function IR.falloff.ring()
    return { op = "falloffRing", type = "falloff" }
end

--- Step falloff: 1 if d < threshold, else 0
--- @param threshold number Cutoff distance (default 0.5)
function IR.falloff.step(threshold)
    return { op = "falloffStep", threshold = threshold or 0.5, type = "falloff" }
end

--- Power falloff: (1-d)^n - generic power function
--- @param n number Power exponent
function IR.falloff.power(n)
    return { op = "falloffPower", n = n or 2, type = "falloff" }
end

--------------------------------------------------------------------------------
-- STATIC FIELD IR
-- Compile-time fixed-source field definition.
-- All source positions, radii, and falloffs are known at compile time.
--------------------------------------------------------------------------------

--- Static field with fixed sources
--- @param config table Configuration:
---   sources: array of {x, y, radius, value, falloff}
---   blend: "add"|"max"|"min" (default "add")
---   base: number - base value outside all sources (default 0)
function IR.field.static(config)
    config = config or {}
    return {
        op = "fieldStatic",
        sources = config.sources or {},
        blend = config.blend or "add",
        base = config.base or 0,
        type = "field"
    }
end

return IR
