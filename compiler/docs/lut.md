# strategies/lut.lua

**Lookup Table (LUT) generation for periodic motions.**

## Overview

The LUT module pre-computes all values for a motion at a given FPS and duration. At runtime, evaluation is just a table lookup with modular indexing - no math required.

## When to Use LUT

LUT works for motions that are:
- **Periodic** - repeat after a fixed duration
- **Stateless** - no `follow`, `spring`, or ctx-dependent values
- **Time-independent** - don't grow unbounded (no `linear`, `drift`)

## LUT.compile(ir, compile, opts)

Compile IR to a lookup table.

```lua
local lut, lutData = LUT.compile(ir, Compiler.compile, {
    fps = 60,        -- frames per second
    duration = 1,    -- loop duration in seconds
    loop = true,     -- wrap around (default true)
    interpolate = false  -- linear interpolation (default false)
})

-- Use
local x, y = lut(t)
```

**Memory:** `frameCount * valuesPerFrame * 8 bytes`
- Motion: 2 values (x, y) per frame
- Curve: 1 value per frame
- At 60fps, 1 second = 960 bytes for motion

## LUT.compileBatch(ir, compile, opts)

Compile to batch LUT function for pools.

```lua
local batchFn, frameCount, lutData = LUT.compileBatch(ir, compile, {
    fps = 60,
    duration = 1,
    preallocate = true
})

-- Evaluate many entities at once
batchFn(times, phases, n, outX, outY)
```

## Analysis Functions

### LUT.canUse(ir, hasStatefulNodes)

Check if IR can be LUT'd.

```lua
local canLUT = LUT.canUse(ir, Compiler.hasStatefulNodes)
```

Returns `false` if:
- Contains stateful nodes (`follow`, `spring`)
- Contains ctx-dependent values (`fromCtx`)

### LUT.analyzeHybrid(ir, hasStatefulNodes)

Analyze for partial LUT opportunity.

```lua
local canHybrid, pureChildren, statefulChildren = LUT.analyzeHybrid(ir, hasStatefulNodes)
```

For `motionAdd` or `add` operations, separates children into:
- `pureChildren` - can be LUT'd
- `statefulChildren` - need compiled evaluation

### LUT.estimateSize(ir, opts)

Estimate memory usage.

```lua
local bytes = LUT.estimateSize(ir, { fps = 60, duration = 1 })
-- Motion at 60fps, 1s = 60 frames * 2 values * 8 bytes = 960 bytes
```

## LUT.toSource(ir, compile, opts)

Generate Lua source code for embedding.

```lua
local source = LUT.toSource(ir, compile, { fps = 60, duration = 1 })
-- Returns Lua code that defines the LUT inline
```

Example output:
```lua
local floor = math.floor

local lut_x = {1.0, 0.866, 0.5, 0, -0.5, ...}
local lut_y = {0, 0.5, 0.866, 1.0, 0.866, ...}
local frameCount = 60
local fps = 60

return function(t)
  local idx = floor(t * fps) % frameCount + 1
  return lut_x[idx], lut_y[idx]
end
```

## How LUT Works

1. **Pre-computation**: Evaluate motion at each frame in [0, duration)
2. **Storage**: Store values in Lua arrays (1-indexed)
3. **Lookup**: `idx = floor(t * fps) % frameCount + 1`
4. **Optional interpolation**: Blend between adjacent frames

## Performance Characteristics

| Aspect | Value |
|--------|-------|
| Time per lookup | ~2 ops (floor, mod, index) |
| Memory per frame | 8 bytes (curve) or 16 bytes (motion) |
| Accuracy | Exact at frame boundaries, optional interpolation |
| Startup cost | O(frameCount) compilation |

## LUT vs Rotator

| | LUT | Rotator |
|---|-----|---------|
| Memory | O(frameCount) | O(1) per entity |
| Ops/frame | 2 (floor, mod) | 4 muls, 2 adds |
| Motion types | Any periodic | Circle, ellipse, sin/cos only |
| Accuracy | Frame-quantized | Continuous |

## Example

```lua
local shake = Compiler.motion.shake(10, 5)

-- Create LUT
local lut = LUT.compile(shake, Compiler.compile, {
    fps = 60,
    duration = 2  -- 2 second shake pattern
})

-- In game loop
local x, y = lut(gameTime)
-- Just a table lookup!
```
