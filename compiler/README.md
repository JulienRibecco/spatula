# Spatula compiler (experimental)

The compiler turns an intermediate representation (IR) into Lua functions and
batched pools. Use the Lua core as the reference API. Compilation is useful
when many entities share a composition, but its benefit depends on workload
and runtime; benchmark your use case.

Install the source bundle described in the [root README](../README.md).
The public entry point is `require("spatula.compiler")`; the existing
`require("spatula.compiler.compiler")` path also works.

## Compile a composition

IR constructors return data rather than callable curves. Compile the result
before sampling it. Time is in seconds; frequencies are cycles per second.

```lua
local C = require("spatula.compiler")
local ir = C.motion.circle(50, 0.5)
local orbit = C.compile(ir)
local x, y = orbit(0.5, {})
assert(math.abs(x) < 1e-9)
assert(math.abs(y - 50) < 1e-9)
```

## Pools

A pool stores independent times and results for a shared IR. `init` takes
optional per-entity time offsets in seconds. `step()` advances by the
configured fixed timestep; `stepDt(dt)` advances by a supplied timestep.
Use `stepDt(dt)` in an engine with a variable frame delta.

```lua
local C = require("spatula.compiler")
local pool = C.createPool(C.motion.circle(50, 0.5), {
    count = 2,
    fps = 60,
}):init({0, 0.5})

pool:stepDt(0.5)
assert(math.abs(pool.x[1]) < 1e-8)
assert(math.abs(pool.y[1] - 50) < 1e-8)
assert(math.abs(pool.x[2] + 50) < 1e-8)
```

Motion results are in `pool.x[i]` and `pool.y[i]`; scalar curves use
`pool.values[i]`. Indices start at one. `initRandom(maxTime)` initializes random
time offsets. `info()` reports the selected strategy. Pools observe coordinate
reads during warmup and may skip an unused axis; call `useXY()` if later code
needs both, or `useX()` / `useY()` to select explicitly.

`setPhase(i, seconds)` restarts one entity at the new offset. `resize(count)`
preserves existing entities and initializes added entities at time zero.
On LuaJIT, `getFFI()` exposes zero-indexed output buffers for supported strategies;
fetch them again after resizing because their allocations change.

## Batch contexts

`compileBatchEval` accepts an optional final array of per-entity contexts after
the usual time, phase, count, and output arguments. If omitted, the compiled
batch function owns persistent contexts for its entity slots.

```lua
local C = require("spatula.compiler")
local batch = C.compileBatchEval(C.curve.fromCtx("player.speed", 7))
local contexts = {{player = {speed = 3}}, {}}
local values = batch({0, 0}, 2, contexts)
assert(values[1] == 3 and values[2] == 7)
```

Nested context lookups use the default when an intermediate key is missing.
Stateful expressions retain history in their context. Replace the corresponding
context table when reusing an entity slot for a different entity.

## JSON interchange

IR and editor serialization share `spatula.json`. Strings retain escapes and
Unicode; numbers retain Lua's available precision. Malformed JSON raises an
error. `JSON.null` preserves explicit nulls, including array slots. Decoded empty
arrays remain arrays when encoded again; an ordinary empty Lua table encodes as
an object. Non-finite numbers and runtime-only values encode as null.

```lua
local C = require("spatula.compiler")
local JSON = require("spatula.json")
local ir = C.curve.fromCtx("player.speed", 7)
local restored = C.fromJSON(C.toJSON(ir))
assert(C.compile(restored)(0, {}) == 7)
assert(JSON.encode(JSON.decode('[null,[],{}]')) == '[null,[],{}]')
```

## Strategy selection

| Strategy | Use |
| --- | --- |
| `rotator` | Incremental evaluation of supported oscillators and linear paths |
| `lut` | Lookup of a proven repeating composition over the requested duration |
| `hybrid` | Repeating additive children use LUTs; remaining children evaluate normally |
| `rotscale` | A repeating inner motion with a stateless outer scale or rotation |
| `compiled` | General evaluation when the above optimizations do not apply |

Automatic LUT selection is conservative: boundedness does not prove repetition.
Ramps, easing, noise, delays, and finite sequences are not automatically looped.
The selected window must contain whole periods: a 0.5 Hz oscillator needs a
two-second window, not the default one second.
The window must also contain a whole number of samples at the configured FPS.

```lua
local C = require("spatula.compiler")
local ir = C.curve.triangle(0.5, 3)
assert(not C.canUseLUT(ir, 1))
assert(C.canUseLUT(ir, 2))
local pool = C.createPool(ir, {duration = 2, fps = 64}):init()
assert(pool.strategy == "lut")
pool:step()
assert(type(pool.values[1]) == "number")
```

LUTs sample at the configured FPS; they are approximations between sample times.
Explicit `compileLUT(ir, {fps = ..., duration = ...})` bakes and loops the chosen
window even when the original curve does not repeat. Use it only when that
change in behavior is intentional.

## Differences from the core

- Constructors live under lowercase `curve` and `motion` and produce IR tables.
  API coverage is incomplete; do not assume every core function has an equivalent.
- Core `Curve.pingPong` is spelled `curve.pingpong` in the compiler. Both take
  the duration of one leg; a complete forward/backward cycle takes twice that.
- Core `Curve.sequence({{curve, duration}, ...})` repeats. Compiler
  `curve.sequence({ir, duration}, ...)` is a finite sequence that returns zero
  after its last segment. Use an explicit `curve.loop` for a repeating IR sequence.
- Compiled stateful curves need persistent per-entity contexts. Pools allocate
  these automatically. Stateless core and compiled expressions should agree
  numerically, allowing for LUT sampling and floating-point error.
- Native accelerators and the automatic `compiled.lua` adapter remain separate
  experiments in the repository and are not included in the source bundle.

## Development

Run `python3 tools/test.py --suite compiler` from the repository root; add
`--lua luajit` for LuaJIT. `python3 tools/check_examples.py` checks this guide
against a freshly installed source bundle. Timing comparisons require
`--benchmarks` and are not correctness checks.

`lua compiler/benchmarks/benchmark_full.lua 1000 300` compares the core,
compiler, and current pool strategies. LUT checksums may differ because they
sample the timeline at a fixed FPS.
