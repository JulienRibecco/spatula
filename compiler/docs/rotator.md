# strategies/incremental_rotator.lua

**Rotation matrix-based stepping for fixed-timestep games.**

## Overview

The Rotator module provides the most efficient evaluation for circle/ellipse patterns. Instead of computing `sin(t)` and `cos(t)` each frame, it:

1. Stores a unit vector `(ux, uy)` on the unit circle
2. Rotates it by a fixed angle each frame using a pre-computed rotation matrix
3. Scales by radius to get position

**Result:** Zero trig calls per frame - just 4 multiplications and 2 additions.

## How It Works

For a circle at frequency `f` with timestep `dt`:

```
angle_delta = f * dt * 2π

Pre-compute once:
  cos_d = cos(angle_delta)
  sin_d = sin(angle_delta)

Each frame:
  ux_new = ux * cos_d - uy * sin_d
  uy_new = ux * sin_d + uy * cos_d

  x = ux_new * radius_x
  y = uy_new * radius_y
```

## Rotator.analyze(ir, hasStatefulNodes)

Analyze IR to determine if a rotator can be generated.

```lua
local result = Rotator.analyze(ir, Compiler.hasStatefulNodes)
-- {
--   canStep = true,
--   type = "circle",
--   params = { freq = 0.5, radiusX = 100, radiusY = 100 },
--   reason = nil
-- }
```

**Supported types:**

| Type | Pattern | Parameters |
|------|---------|------------|
| circle | `xy(cos, sin)` same freq | freq, radiusX, radiusY |
| ellipse | `xy(cos, sin)` diff freq | freqX, freqY, radiusX, radiusY |
| drift | `xy(linear, linear)` | vx, vy |
| hover | `xy(const, sin)` | freq, amplitude |
| sway | `xy(sin, const)` | freq, amplitude |
| sinCurve | `sin` | freq, amplitude |
| cosCurve | `cos` | freq, amplitude |
| linear | `linear` | speed |

## Rotator.compile(ir, opts, hasStatefulNodes)

Compile IR to a rotator object.

```lua
local rotator = Rotator.compile(ir, { dt = 1/60 }, Compiler.hasStatefulNodes)
if rotator then
    -- Has: init, step, stepBatch
end
```

Returns `nil` if IR cannot be stepped.

## Rotator Object API

```lua
-- Initialize state for a phase
local state = rotator.init(phase)
-- state = { ux, uy, x, y } (for circle)

-- Step single state
rotator.step(state)

-- Step many states (batch)
rotator.stepBatch(states, n)

-- Get positions from states
local xs, ys = rotator.getPositions(states, n)
```

## Rotator Implementations

### Circle/Ellipse
```lua
function Rotator.createCircle(params, dt)
    local angle = freq * dt * PI2
    local cosD = cos(angle)
    local sinD = sin(angle)

    return {
        init = function(phase)
            local a = phase * PI2
            return { ux = cos(a), uy = sin(a), x = cos(a)*rx, y = sin(a)*ry }
        end,
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.x = state.ux * rx
            state.y = state.uy * ry
        end,
        stepBatch = function(states, n)
            for i = 1, n do
                -- Same as step, inlined
            end
        end
    }
end
```

### Drift (Linear Motion)
```lua
-- Just adds dx, dy each frame
step = function(state)
    state.x = state.x + dx
    state.y = state.y + dy
end
```

### Hover/Sway (1D Oscillation)
```lua
-- Same rotation math, but only output X or Y
-- hover: y = uy * amp
-- sway: x = ux * amp
```

## Rotator.createStates(rotator, n, phases)

Create array of states for batch processing.

```lua
local states = Rotator.createStates(rotator, 1000, phases)
-- states[i] = rotator.init(phases[i])
```

## Performance

| Operation | Cost |
|-----------|------|
| init | 2 trig calls (sin, cos) |
| step | 4 muls, 2 adds |
| stepBatch(n) | n * (4 muls, 2 adds) |

Compare to direct evaluation:
- `sin(t)` + `cos(t)` = 2 trig calls per frame
- Rotator = 0 trig calls per frame

## Accuracy

Rotation matrices preserve magnitude but accumulate floating-point error over time. For typical game scenarios (hours of runtime), error is negligible (<0.01%).

Test result:
```
After 3600 frames (60 rotations): error = 0.00%
```

## When Rotator Fails

Returns `nil` for:
- Stateful curves (`follow`, `spring`)
- Ctx-dependent values (`fromCtx`)
- Complex compositions that don't match supported patterns
- Non-fixed timestep requirements

## Example

```lua
local Rotator = require("spatula.compiler.strategies.incremental_rotator")

local ir = Compiler.motion.circle(100, 0.5)
local rotator = Rotator.compile(ir, { dt = 1/60 })

-- Single entity
local state = rotator.init(0)
for frame = 1, 1000 do
    rotator.step(state)
    draw(state.x, state.y)
end

-- Batch (1000 entities)
local states = Rotator.createStates(rotator, 1000, randomPhases)
for frame = 1, 1000 do
    rotator.stepBatch(states, 1000)
    for i = 1, 1000 do
        draw(states[i].x, states[i].y)
    end
end
```
