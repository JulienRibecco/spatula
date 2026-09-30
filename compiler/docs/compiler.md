# compiler.lua

**Main module for Spatula IR compilation, optimization, and code generation.**

## Overview

`compiler.lua` is the central module that:
- Exports IR constructors (`Compiler.curve.*`, `Compiler.motion.*`)
- Compiles IR to optimized Lua functions
- Applies optimization passes (constant folding, CSE, DCE)
- Provides strategy analysis (periodicity, statefulness)
- Coordinates with Pool, LUT, and Rotator modules

## Key Functions

### Compilation

```lua
-- Compile IR to a Lua function
local fn = Compiler.compile(ir, opts)
-- fn(t, ctx) -> value or (x, y)

-- Compile with optimization passes
local fn = Compiler.compileOptimized(ir, opts)

-- Get generated source code
local source = Compiler.toSource(ir)
```

### LUT Compilation

```lua
-- Compile to lookup table (periodic motions only)
local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
-- lut(t) -> (x, y)

-- Check if IR can use LUT
local canLUT, reason = Compiler.canUseLUT(ir)
```

### Rotator Compilation

```lua
-- Compile to incremental stepper (circle/ellipse only)
local rotator, err = Compiler.compileRotator(ir, { dt = 1/60 })
if rotator then
    local state = rotator.init(phase)
    rotator.step(state)  -- advance by dt
end

-- Check if IR can use rotator
local canStep, reason = Compiler.canUseRotator(ir)
```

### Analysis

```lua
-- Check for stateful nodes (follow, spring)
local hasState = Compiler.hasStatefulNodes(ir)

-- Check if periodic (bounded, repeating)
local isPeriodic = Compiler.isPeriodic(ir)

-- Analyze for rotscale hybrid
local canHybrid, info = Compiler.analyzeRotateScaleHybrid(ir)
-- info = { innerMotion, outerCurve, operation }

-- Get IR summary
local summary = Compiler.summarize(ir)
-- { nodeCount, hasState, ops = { sin = 2, cos = 2, ... } }
```

### Pool Creation

```lua
-- Create entity pool (delegates to pool module)
local pool = Compiler.createPool(ir, { count = 1000, fps = 60 })

-- Single entity optimizer
local fn = Compiler.auto(ir)
```

## Code Generators

The compiler has code generators for each IR operation type:

| Category | Operations |
|----------|------------|
| Primitives | `const`, `linear`, `sin`, `cos`, `triangle`, `saw`, `square`, `pulse`, `noise` |
| Stateful | `follow`, `spring` |
| Easing | `easeIn`, `easeOut`, `easeInOut`, `ramp` |
| Arithmetic | `add`, `mul`, `sub`, `scaleConst`, `scaleCurve`, `offsetConst`, `offsetCurve`, `neg`, `abs`, `powConst`, `powCurve`, `clamp` |
| Time | `timeScaleConst`, `timeScaleCurve`, `timeOffsetConst`, `timeOffsetCurve`, `loop`, `delay`, `segment`, `remap` |
| Motion | `xy`, `motionAdd`, `motionScaleConst`, `motionScaleCurve`, `motionRotateConst`, `motionRotateCurve`, `motionMixConst`, `motionMixCurve`, `motionSegment` |

## Optimization Passes

### Constant Folding
```lua
scale(const(2), 3) -> const(6)
add(const(1), const(2)) -> const(3)
neg(const(5)) -> const(-5)
```

### Identity Elimination
```lua
scale(x, 1) -> x
offset(x, 0) -> x
timeScale(x, 1) -> x
```

### Nested Collapse
```lua
scale(scale(x, 2), 3) -> scale(x, 6)
offset(offset(x, 1), 2) -> offset(x, 3)
timeScale(timeScale(x, 2), 3) -> timeScale(x, 6)
```

### Common Subexpression Elimination (CSE)
```lua
-- sin and cos with same frequency share the angle computation
local _v1 = t * 3.14159...
sin(_v1) * 100, cos(_v1) * 100
```

## Periodicity Detection

Non-periodic operations that grow unbounded:
- `linear` - grows linearly with t
- `t` - raw time
- `drift` - motion that drifts over time

These cannot be LUT'd because they don't repeat. The `isPeriodic(ir)` function recursively checks for these.

## Rotscale Hybrid Analysis

`analyzeRotateScaleHybrid(ir)` detects patterns like:
```lua
rotate(circle(100, 0.5), linear(0.1))  -- rotating circle
scale(figure8(50, 1), add(const(1), sin(0.5)))  -- pulsing figure8
```

When inner motion is periodic (can LUT) but outer curve is non-periodic (needs runtime eval), the rotscale strategy is used.
