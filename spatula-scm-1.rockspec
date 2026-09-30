rockspec_format = "3.0"
package = "spatula"
version = "scm-1"

source = {
    url = "git+https://github.com/JulienRibecco/spatula.git",
    branch = "main",
}

description = {
    summary = "Compose motion and reactive behavior from small Lua functions",
    detailed = [[
        Dependency-free curves, signals, 2D motion, spatial fields, geometry,
        distributions, and triggers. Includes the experimental Lua compiler.
        CI targets Lua 5.4, Lua 5.5, and LuaJIT; LuaJIT reports Lua 5.1
        to LuaRocks. Editor, native accelerators, and JavaScript experiments
        are not installed by this rock.
    ]],
    homepage = "https://github.com/JulienRibecco/spatula",
    issues_url = "https://github.com/JulienRibecco/spatula/issues",
    license = "MIT",
    labels = {"animation", "gamedev", "procedural", "motion"},
}

dependencies = {"lua >= 5.1, < 5.6"}

build = {
    type = "builtin",
    -- Explicit modules keep experiments and platform binaries out of installs.
    modules = {
        ["spatula"] = "init.lua",
        ["spatula.init"] = "init.lua",
        ["spatula.curve"] = "curve.lua",
        ["spatula.signal"] = "signal.lua",
        ["spatula.motion"] = "motion.lua",
        ["spatula.field"] = "field.lua",
        ["spatula.forms"] = "forms.lua",
        ["spatula.distribution"] = "distribution.lua",
        ["spatula.trigger"] = "trigger.lua",
        ["spatula.point"] = "point.lua",
        ["spatula.audio"] = "audio.lua",
        ["spatula.tempo"] = "tempo.lua",
        ["spatula.util"] = "util.lua",
        ["spatula.json"] = "json.lua",
        ["spatula.compiler"] = "compiler/init.lua",
        ["spatula.compiler.init"] = "compiler/init.lua",
        ["spatula.compiler.compiler"] = "compiler/compiler.lua",
        ["spatula.compiler.ir"] = "compiler/ir.lua",
        ["spatula.compiler.period"] = "compiler/period.lua",
        ["spatula.compiler.pool"] = "compiler/pool/init.lua",
        ["spatula.compiler.pool.init"] = "compiler/pool/init.lua",
        ["spatula.compiler.pool.form"] = "compiler/pool/form.lua",
        ["spatula.compiler.pool.trigger"] = "compiler/pool/trigger.lua",
        ["spatula.compiler.pool.distribution"] = "compiler/pool/distribution.lua",
        ["spatula.compiler.strategies.incremental_rotator"] = "compiler/strategies/incremental_rotator.lua",
        ["spatula.compiler.strategies.lut"] = "compiler/strategies/lut.lua",
    },
    copy_directories = {},
}
