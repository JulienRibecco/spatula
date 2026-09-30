# README motion study

The README animation is generated from [examples/orbit.lua](../examples/orbit.lua)
using the actual Lua library. A circle receives an oscillating radius and a
slowly changing rotation. The composition repeats every four seconds.

The renderer samples 1,600 positions with Lua, then uses Pillow to draw six
scaled copies with staggered time offsets and short fading trails. Fonts,
layout, trails, and repeated copies belong to the presentation, not the recipe.
No JavaScript translation or hand-coded replacement motion is involved.

## Rebuild

Run from the repository checkout. Requires Lua (or LuaJIT), Python 3 with Pillow, and either Georgia/Courier New
(macOS) or DejaVu Serif/Mono (Linux). These are documentation tools only;
Spatula's runtime has no dependency on Python, Pillow, or system fonts.

```sh
python3 tools/render_readme.py --lua lua
python3 tools/check_examples.py --lua lua
```

The outputs are `docs/assets/orbit.gif`, `orbit.png`, and `orbit.json`.
The GIF has 100 frames at 25 FPS; the PNG is a still alternative. The JSON
records dimensions, timing, and the recipe's SHA-256. The renderer checks the
loop boundary and the saved animation's frame count and timing.

When editing the recipe, update the identical code block between the
`orbit-example` markers in README.md and regenerate the assets. The regular
example check rejects differing snippets and stale recipe hashes without
requiring Pillow in CI. Regenerate the assets after changing relevant library
behavior or the renderer as well.

## LuaRocks

The root `spatula-scm-1.rockspec` describes a development build from `main`.
`luarocks make` installs the current checkout; it does not fetch `source.url`.
Its module allowlist matches the source ZIP. Native binaries, editor modules,
and unrelated experiments are excluded.

```sh
luarocks lint spatula-scm-1.rockspec
python3 tools/check_examples.py --lua lua --luarocks luarocks
```

The second command installs into a temporary LuaRocks tree and executes the
documentation examples from a separate directory. It also compares the rockspec
module list with the source-bundle module list. No global install is required.

Before a registry release, choose a tagged version, replace the development
rockspec's version and source branch with the release version and tag, and run
the install checks again. Registry publication is a separate step; there is no
published `luarocks install spatula` command promised by this checkout.

References: [LuaRocks rockspec format](https://github.com/luarocks/luarocks/blob/main/docs/rockspec_format.md)
and [creating a rock](https://github.com/luarocks/luarocks/blob/main/docs/creating_a_rock.md).
