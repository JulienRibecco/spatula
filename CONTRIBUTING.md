# Contributing

Spatula builds behavior by composing `f(t, ctx)` functions. Read
[PHILOSOPHY.md](PHILOSOPHY.md) before adding API. Prefer existing primitives and
combinators; keep application-specific behavior in examples or applications.

## Checks

Python 3 drives the checks; the library itself only needs Lua. No Python packages
are required. Run these commands from the repository root:

```sh
python3 tools/test.py --lua lua
python3 tools/test.py --lua luajit
python3 tools/check_examples.py --lua lua
python3 tools/check_examples.py --lua luajit
python3 tools/check_examples.py --lua lua --luarocks luarocks
```

The runner accepts `--suite core`, `--suite compiler`, and `--suite editor`.
Use `--verbose` for successful test output. Each test file runs in a separate
process; a failed assertion, reported failure, or timeout fails the command.
You can also run a test directly: `lua compiler/tests/test_semantics.lua`.
CI covers Lua 5.4, Lua 5.5, and LuaJIT on Linux.

Timing assertions are excluded by default. To run those comparisons on your
machine, add `--benchmarks`. Report runtime version, hardware, workload, and
whether native extensions are active alongside any performance result.

The pool regression suite compares initialization, stepping, phase changes,
resizing, and FFI reads against direct evaluation across all strategies. Core
contract tests run independently of optional patches; native tests also check
that unsupported blends and dynamic sources fall back to Lua.

## Optional native field library

Native build products are ignored and should be built locally. For example,
on macOS, from the repository root:

```sh
cc -O3 -dynamiclib compiler/native/field_native.c -o compiler/native/libfield_native.dylib
luajit tests/test_native_context.lua
```

On Linux:

```sh
cc -O3 -shared -fPIC compiler/native/field_native.c -lm -o compiler/native/libfield_native.so
```

The optional loader obtains declarations
and the library together. Automatic native batching supports additive fields
with numeric sources and built-in falloffs; other configurations use Lua.
LUT-based native sampling is approximate. Ordinary gradients keep the core's
finite-difference behavior; `sampleBatchNativeWithGradient` is an explicit
approximate derivative API.

## Documentation and packaging

All fenced `lua` examples in README.md, QUICKSTART.md, and compiler/README.md
must be standalone programs. `tools/check_examples.py` builds the source bundle,
extracts it to a temporary project, and executes each example there using normal
Lua module discovery. Include assertions for the behavior an example teaches.

`python3 tools/package.py` creates `dist/spatula-source.zip`. Packaging uses an
explicit allowlist so local dependencies, experiments, and native build products
cannot accidentally enter the bundle. When adding a public module, update that
allowlist and `spatula-scm-1.rockspec`, then exercise its installed import in the
example check. The LuaRocks check lints the manifest, verifies the module lists
match, installs into a temporary tree, and runs the same examples there.

The README animation is built from `examples/orbit.lua`. Its recipe and embedded
code block must match; the checks also detect stale animation recipe hashes.
See [docs/README.md](docs/README.md) to rebuild it with Lua and Pillow.

## Fixes and reports

For a numerical or optimizer fix, add a small regression with expected values
or a comparison against the interpreted implementation. Include boundaries,
elapsed time beyond one cycle, and context changes where relevant. Keep timing
measurements separate from correctness assertions.

Bug reports should include a runnable example, expected and actual output,
Lua/LuaJIT version, and the chosen pool strategy if a pool is involved. Compiler
and JavaScript APIs are experimental; mention which implementation you used.
