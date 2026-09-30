# Spatula quickstart

From a checkout, install with `luarocks --local make spatula-scm-1.rockspec`,
using the module paths reported by `luarocks path`. Alternatively, build
`dist/spatula-source.zip` with `python3 tools/package.py` and extract it into
your project's module search directory, keeping `spatula.lua` beside `spatula/`.
These examples run with plain Lua or LuaJIT; no engine is required.

## Curves: time to a value

Construct a curve once, then sample it with elapsed time in seconds.

```lua
local C = require("spatula.curve")
local wave = C.sin(2, 10)                 -- 2 cycles/second, amplitude 10
local fade = C.scale(C.easeOut(2), 100)   -- 0 → 100 over two seconds
local ramp = C.ramp(0, 100, 2)

assert(math.abs(wave(0.125) - 10) < 1e-9)
assert(math.abs(fade(1) - 75) < 1e-9)
assert(ramp(1) == 50)
assert(ramp(3) == 100)
```

Use `add`, `mul`, `scale`, and `offset` to combine values. Use `timeScale`,
`timeOffset`, `loop`, and `pingPong` to change when a curve is sampled.
`pingPong(curve, duration)` plays forward for `duration` seconds and backward
for the same duration. `noise(scale, seed)` takes amplitude and a seed;
use `timeScale` to control its speed.

## Motion: two curves to a position

`Motion.xy` combines curves into an `(x, y)` result. Presets are compositions
of the same primitives. Add a constant motion to translate a path.

```lua
local Spatula = require("spatula")
local C, M = Spatula.Curve, Spatula.Motion

local orbit = M.circle(50, 0.5) -- radius 50, one revolution every two seconds
local centered = M.add(orbit, M.xy(C.const(400), C.const(300)))
local x, y = centered(0.5, {})
assert(math.abs(x - 400) < 1e-9)
assert(math.abs(y - 350) < 1e-9)
```

For an engine update loop, accumulate `elapsed = elapsed + dt` and evaluate
`centered(elapsed, ctx)`. Add the resulting coordinates to your renderer.
`Motion.spiral(radius, speed, growth)` grows its scale as `1 + t * growth`;
it is not a transition between two radii.

## Signals: read changing values from context

A signal is a curve that reads a named value. Put it in a combinator that
accepts a curve, such as `Motion.scale`.

```lua
local Spatula = require("spatula")
local M, S = Spatula.Motion, Spatula.S
local orbit = M.scale(M.circle(1, 0.5), S("radius", 50))

local x = orbit(0, {})
assert(x == 50)
local larger = orbit(0, {radius = 120})
assert(larger == 120)
```

Lookup order is explicit context, active context (`S.setActive`), global
registry (`S.setGlobal`), then the signal's default. Prefer explicit context
when independent entities or systems need different values.

## Forms and distributions

Forms describe regions. Distributions push generated coordinates into your
callback; you decide how to store or draw them.

```lua
local Spatula = require("spatula")
local F, D = Spatula.Forms, Spatula.Distribution
local area = F.circle(100, 100, 50)
assert(area:contains(100, 100))
assert(not area:contains(200, 100))

local points = {}
D.random(area, 12, function(x, y)
    assert(area:contains(x, y))
    points[#points + 1] = {x = x, y = y}
end)
assert(#points == 12)
```

## Fields: sample spatial influence

Field sources have a position, radius, value, and falloff. `gradient` takes a
point table, then an optional finite-difference epsilon and context.

```lua
local Field = require("spatula.field")
local field = Field.new({falloff = "linear"})
local source = field:add({100, 100}, {radius = 50, value = 1})

assert(field:sample(100, 100) == 1)
assert(math.abs(field:sample(125, 100) - 0.5) < 1e-9)
local gx, gy = field:gradient({125, 100})
assert(gx < 0) -- points toward increasing influence

field:move(source, {200, 100})
assert(field:sample(100, 100) == 0)
field:remove(source)
assert(field:sample(200, 100) == 0)
```

## Stateful curves

`follow` and `spring` store history in context. Reuse a context per entity,
advance time monotonically, and use a fresh context when restarting.

```lua
local Spatula = require("spatula")
local smooth = Spatula.Curve.follow(Spatula.S("target", 0), 5)
local entity = {target = 0}
assert(smooth(0, entity) == 0)
entity.target = 10
assert(math.abs(smooth(0.1, entity) - 5) < 1e-9)
assert(smooth(0.1, {target = 20}) == 20) -- independent history
```

For batching and compilation, continue with the experimental
[compiler guide](compiler/README.md). The core functions and compiler IR have
some different signatures and sequence behavior; migration is explicit.
