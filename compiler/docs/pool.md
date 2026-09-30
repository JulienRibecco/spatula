# pool/init.lua

**Entity pool with FFI arrays and automatic strategy selection.**

## Overview

The Pool module manages collections of entities that share the same motion pattern but have different phases. It automatically selects the best evaluation strategy:

1. **Rotator** - Best for circle/ellipse (rotation matrix, zero trig per frame)
2. **LUT** - Good for periodic motions (table lookup)
3. **Rotscale** - For rotate/scale with non-periodic outer curve
4. **Hybrid** - For mixed pure + stateful compositions
5. **Compiled** - Fallback for stateful or complex motions

## Quick Start

```lua
local Pool = require("spatula.compiler.pool")
local Compiler = require("spatula.compiler.compiler")

-- Create motion
local orbit = Compiler.motion.circle(100, 0.5)

-- Create pool of 1000 entities
local pool = Pool.create(Compiler, orbit, { count = 1000, fps = 60 })

-- Initialize with random phases
pool:initRandom()

-- Game loop
function love.update(dt)
    pool:step()  -- advance all entities by dt
end

function love.draw()
    for i = 1, pool.count do
        love.graphics.circle("fill", 400 + pool.x[i], 300 + pool.y[i], 3)
    end
end
```

## Pool.create(Compiler, ir, opts)

Creates a new pool with automatic strategy selection.

**Parameters:**
- `Compiler` - The Compiler module
- `ir` - IR node from `Compiler.motion.*` or `Compiler.curve.*`
- `opts` - Options table:
  - `count` - Number of entities (default 1)
  - `fps` - Frames per second (default 60)
  - `dt` - Alternative to fps, timestep in seconds
  - `duration` - LUT loop duration (default 1)
  - `axis` - Force axis mode: `"x"`, `"y"`, or `"xy"`

**Returns:** Pool object

## Pool Methods

### Initialization

```lua
pool:init(phases)      -- Initialize with phase array (or zeros)
pool:initRandom(max)   -- Random phases in [0, max] (default max=1)
```

### Stepping

```lua
pool:step()           -- Advance by pool's dt
pool:stepDt(customDt) -- Advance by custom dt (less efficient for rotator)
```

### Position Access

```lua
-- Array access (fastest)
local x, y = pool.x[i], pool.y[i]

-- Method access
local x, y = pool:get(i)
```

### Per-Entity Control

```lua
pool:setPhase(i, phase)  -- Reset entity i to new phase
pool:resize(newCount)    -- Resize pool (expensive - reallocates)
```

### Axis Optimization

```lua
pool:useX()    -- Only compute X (skip Y)
pool:useY()    -- Only compute Y (skip X)
pool:useXY()   -- Compute both
pool:useAuto() -- Auto-detect from usage
```

### Info

```lua
local info = pool:info()
-- {
--   count = 1000,
--   strategy = "rotator",
--   isMotion = true,
--   axis = "xy",
--   autoAxis = false,
--   dt = 0.0166...,
--   fps = 60
-- }
```

## FFI Arrays

When LuaJIT's FFI is available, the pool uses C float arrays for position storage:

```lua
pool._posX[i]  -- FFI array (0-indexed!)
pool._posY[i]  -- FFI array (0-indexed!)
pool._useFFI   -- true if using FFI
```

The Lua-accessible `pool.x` and `pool.y` are 1-indexed wrappers.

## Auto-Axis Detection

The pool tracks which axes you access during a warmup period (5 frames). After warmup, it optimizes to only compute the axes you used:

```lua
-- If you only ever access pool.x, the pool will skip Y computation
for i = 1, pool.count do
    entity.x = pool.x[i]  -- only X accessed
end
```

## Strategy Selection Order

```
1. Rotator?  → circle/ellipse/sin/cos patterns
   ↓ no
2. LUT?      → periodic, no state, no ctx
   ↓ no
3. Rotscale? → rotate(periodic, non-periodic) or scale(periodic, non-periodic)
   ↓ no
4. Hybrid?   → motionAdd with pure + stateful children
   ↓ no
5. Compiled  → fallback (per-entity ctx for stateful)
```

## Internal State

| Field | Description |
|-------|-------------|
| `_phases` | Phase offsets per entity |
| `_times` | Current time per entity |
| `_states` | Rotator states (rotator strategy) |
| `_contexts` | Per-entity ctx (stateful strategy) |
| `_rotator` | Rotator object |
| `_batchLUT` | Batch LUT function |
| `_innerLUT` | Inner LUT (rotscale strategy) |
| `_outerFn` | Outer curve function (rotscale strategy) |
| `_singleFn` | Compiled function |

## Convenience Functions

```lua
-- Single entity optimizer
local fn = Pool.auto(Compiler, ir)

-- Create and init with random phases
local pool = Pool.createRandom(Compiler, ir, count, opts)
```

## Performance Tips

1. **Use FFI** - Run in LuaJIT for automatic FFI arrays
2. **Pick the right strategy** - Rotator > LUT > Compiled
3. **Force axis mode** - If you only need X, call `pool:useX()`
4. **Avoid resize** - Pre-allocate with correct count
5. **Use fixed dt** - Rotator is most efficient with fixed timestep
