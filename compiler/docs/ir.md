# ir.lua

**IR (Intermediate Representation) node constructors for curves and motions.**

## Overview

`ir.lua` provides the data structures that represent motion compositions. IR nodes are plain Lua tables (no closures) that can be:
- Serialized to JSON for cross-language code generation
- Analyzed for optimization opportunities
- Compiled to different evaluation strategies

## Design Principle

**IR is data, not code.** Each node is a table with:
- `op` - operation type (e.g., `"sin"`, `"add"`, `"xy"`)
- `type` - `"motion"` for 2D motions (omitted for curves)
- Parameters specific to the operation

## Curve Primitives

```lua
IR.curve.const(value)              -- constant value
IR.curve.linear(speed)             -- speed * t
IR.curve.sin(freq, amp, phase)     -- amplitude * sin(freq * 2pi * t + phase)
IR.curve.cos(freq, amp, phase)     -- amplitude * cos(freq * 2pi * t + phase)
IR.curve.triangle(freq, amp)       -- triangle wave
IR.curve.saw(freq, amp)            -- sawtooth wave
IR.curve.square(freq, amp, duty)   -- square wave with duty cycle
IR.curve.pulse(freq, duty)         -- 1 during duty, 0 otherwise
IR.curve.noise(scale, seed)        -- deterministic noise approximation
```

## Stateful Curves

These maintain state between evaluations via `ctx.curveState`:

```lua
IR.curve.follow(targetCurve, speed)
-- Smoothly approaches target value
-- speed: how fast to approach (default 5)

IR.curve.spring(targetCurve, stiffness, damping)
-- Spring physics toward target
-- stiffness: spring constant (default 100)
-- damping: damping factor (default 10)
```

## Easing Curves

```lua
IR.curve.easeIn(duration, power)     -- t^power over duration
IR.curve.easeOut(duration, power)    -- 1-(1-t)^power over duration
IR.curve.easeInOut(duration, power)  -- smooth in and out
IR.curve.ramp(start, target, duration)  -- linear interpolation
```

## Curve Combinators

### Arithmetic
```lua
IR.curve.add(a, b, ...)           -- sum of curves
IR.curve.mul(a, b, ...)           -- product of curves
IR.curve.sub(a, b)                -- a - b
IR.curve.scale(curve, factor)     -- curve * factor (number or curve)
IR.curve.offset(curve, amount)    -- curve + amount (number or curve)
IR.curve.neg(curve)               -- -curve
IR.curve.abs(curve)               -- |curve|
IR.curve.pow(curve, exponent)     -- curve ^ exponent
IR.curve.clamp(curve, lo, hi)     -- clamp to [lo, hi]
```

### Time Manipulation
```lua
IR.curve.timeScale(curve, factor)    -- curve(t * factor)
IR.curve.timeOffset(curve, offset)   -- curve(t + offset)
IR.curve.loop(curve, duration)       -- curve(t % duration)
IR.curve.delay(curve, d)             -- 0 until t >= d, then curve(t - d)
IR.curve.segment(curve, start, dur)  -- curve in [start, start+dur), else 0
IR.curve.remap(curve, timeCurve)     -- curve(timeCurve(t))
IR.curve.pingpong(curve, duration)   -- forward then backward
```

### Sequencing
```lua
IR.curve.sequence({c1, dur1}, {c2, dur2}, ...)
-- Play curves in order, each for its duration

IR.curve.lerp(a, b, t)
-- Blend: a*(1-t) + b*t where t is a curve
```

## Motion Constructors

### Basic
```lua
IR.motion.xy(curveX, curveY)  -- combine two curves into 2D motion
```

### Combinators
```lua
IR.motion.add(m1, m2, ...)            -- sum motions
IR.motion.scale(motion, factor)       -- scale (factor: number or curve)
IR.motion.rotate(motion, angle)       -- rotate (angle: number or curve)
IR.motion.mix(a, b, factor)           -- blend (factor: number or curve)
IR.motion.segment(motion, start, dur) -- motion in time window
IR.motion.sequence(...)               -- motions in order
IR.motion.lerp(a, b, t)               -- blend by curve (alias for mix)
```

### Presets

All built from primitives:

```lua
IR.motion.circle(radius, speed)
IR.motion.ellipse(radiusX, radiusY, speed)
IR.motion.spiral(radius, speed, growth)
IR.motion.lissajous(freqX, freqY, ampX, ampY, phase)
IR.motion.figure8(size, speed)
IR.motion.shake(intensity, speed)
IR.motion.drift(vx, vy)
IR.motion.hover(amount, speed)
IR.motion.sway(amount, speed)
IR.motion.bob(amount, speed)
IR.motion.wave(forward, amplitude, frequency)
IR.motion.bounce(height, speed)
IR.motion.arc(turns)
IR.motion.outward(turns)
IR.motion.ray(angle)
```

## JSON Serialization

```lua
local json = IR.toJSON(node)
-- Serialize IR to JSON string

local node = IR.fromJSON(json)
-- Parse JSON back to IR node
```

## State ID Management

Stateful curves (`follow`, `spring`) receive unique IDs when constructed.
Compilation and source inspection preserve these IDs and never reset the counter.
`IR.resetStateIds()` is only suitable for isolated tooling after discarding every
previous IR and context. Calling it while older nodes survive can create collisions.

## IR Node Examples

```lua
-- circle(100, 0.5)
{
    op = "xy",
    type = "motion",
    x = { op = "cos", freq = 0.5, amp = 100, phase = 0 },
    y = { op = "sin", freq = 0.5, amp = 100, phase = 0 }
}

-- scale(sin(1, 10), 2)
{
    op = "scaleConst",
    curve = { op = "sin", freq = 1, amp = 10, phase = 0 },
    factor = 2
}

-- rotate(circle(50, 1), linear(0.1))
{
    op = "motionRotateCurve",
    type = "motion",
    motion = { op = "xy", ... },
    angle = { op = "linear", speed = 0.1 }
}
```
