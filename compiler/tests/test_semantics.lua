-- Cross-path regressions: the optimizer must preserve the authored timeline.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
local T = require("spatula.tests.support")
local C = require("spatula.compiler")
local Curve = require("spatula.curve")

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= (tolerance or 1e-8),
        string.format("expected %.12g, got %.12g", expected, actual))
end

T.test("scalar rotators publish values and retain time across step modes", function()
    for _, make in ipairs({C.curve.sin, C.curve.cos}) do
        local ir = make(0.7, 3, 0.2)
        local fn = C.compile(ir)
        local pool = C.createPool(ir, {count = 2, dt = 0.05}):init({0, 0.13})
        assert(pool.strategy == "rotator")
        local elapsed = 0
        for frame = 1, 25 do
            local dt = frame % 3 == 0 and 0.017 or 0.05
            if frame % 3 == 0 then pool:stepDt(dt) else pool:step() end
            elapsed = elapsed + dt
            near(pool.values[1], fn(elapsed, {}))
            near(pool.values[2], fn(elapsed + 0.13, {}))
        end
    end
end)

T.test("motion rotators retain time across step modes", function()
    local ir = C.motion.circle(12, 0.7)
    local fn = C.compile(ir)
    local pool = C.createPool(ir, {dt = 0.05}):init({0.13})
    pool:step():step():stepDt(0.017):step()
    local x, y = fn(0.297, {})
    near(pool.x[1], x)
    near(pool.y[1], y)
end)

T.test("finite and nonrepeating curves never silently wrap at one second", function()
    local cases = {
        C.curve.ramp(0, 10, 2), C.curve.easeOut(2, 2),
        C.curve.delay(C.curve.sin(1), 0.4), C.curve.noise(2, 7),
        C.curve.timeScale(C.curve.sin(1), C.curve.offset(C.curve.sin(1), 2)),
    }
    for _, ir in ipairs(cases) do
        assert(not C.canUseLUT(ir))
        local fn = C.compile(ir)
        local pool = C.createPool(ir, {dt = 0.125}):init()
        for frame = 1, 28 do
            pool:step()
            near(pool.values[1], fn(frame * 0.125, {}))
        end
    end
end)

T.test("rotator variants preserve oscillator phase, constants, and direction", function()
    local cases = {
        C.motion.xy(C.curve.cos(0.7, 2, 0.3), C.curve.sin(0.7, 3, 0.3)),
        C.motion.xy(C.curve.cos(0.7, 2, 0.3), C.curve.sin(0.7, 3, 0.9)),
        C.motion.xy(C.curve.cos(0.7, 2, 0.3), C.curve.sin(1.2, 3, 0.9)),
        C.motion.xy(C.curve.const(7), C.curve.sin(0.7, 3, 0.3)),
        C.motion.xy(C.curve.sin(0.7, 3, 0.3), C.curve.const(7)),
        C.motion.drift(3, -2),
    }
    for _, ir in ipairs(cases) do
        local fn = C.compile(ir)
        local pool = C.createPool(ir, {dt = 0.125}):init({0.3})
        assert(pool.strategy == "rotator")
        for frame = 0, 16 do
            local x, y = fn(frame * 0.125 + 0.3, {})
            near(pool.x[1], x)
            near(pool.y[1], y)
            pool:step()
        end
    end
end)

T.test("automatic LUT windows contain whole periods", function()
    local ir = C.curve.triangle(0.5, 3)
    assert(C.isPeriodic(ir))
    assert(not C.canUseLUT(ir, 1))
    assert(C.canUseLUT(ir, 2))
    assert(C.createPool(ir).strategy == "compiled")
    local pool = C.createPool(ir, {duration = 2, fps = 64}):init()
    assert(pool.strategy == "lut")
    local fn = C.compile(ir)
    for frame = 1, 160 do
        pool:step()
        near(pool.values[1], fn(frame / 64, {}), 1e-5)
    end
end)

T.test("fractional sample windows cannot shorten an automatic LUT period", function()
    local ir = C.curve.triangle(1 / 1.1, 3)
    assert(C.canUseLUT(ir, 1.1))
    assert(not C.canUseLUT(ir, 1.1, 16))
    local pool = C.createPool(ir, {duration = 1.1, fps = 16}):init()
    assert(pool.strategy == "compiled")
    local fn = C.compile(ir)
    for frame = 1, 64 do
        pool:step()
        near(pool.values[1], fn(frame / 16, {}))
    end
end)

T.test("stateful rotation angles retain per-entity history", function()
    local ir = C.motion.rotate(C.motion.circle(10, 1), C.curve.follow(C.curve.linear(2), 3))
    assert(C.hasStatefulNodes(ir))
    local pool = C.createPool(ir, {fps = 64}):init({0.25})
    assert(pool.strategy == "compiled")
    local fn, ctx = C.compile(ir), {}
    fn(0.25, ctx)
    for frame = 1, 64 do
        pool:step()
        local x, y = fn(frame / 64 + 0.25, ctx)
        near(pool.x[1], x)
        near(pool.y[1], y)
    end
end)

T.test("additive hybrid keeps growing children on actual elapsed time", function()
    local ir = C.curve.add(C.curve.sin(1, 2), C.curve.linear(3))
    local fn = C.compile(ir)
    local pool = C.createPool(ir, {fps = 64}):init()
    assert(pool.strategy == "hybrid")
    for frame = 1, 160 do
        pool:step()
        near(pool.values[1], fn(frame / 64, {}), 1e-5)
    end
end)

T.test("rotating and scaling hybrids apply phase to the whole expression", function()
    for _, combine in ipairs({C.motion.rotate, C.motion.scale}) do
        local ir = combine(C.motion.circle(10, 1), C.curve.linear(2))
        local pool = C.createPool(ir, {fps = 64}):init({0.25})
        local fn = C.compile(ir)
        assert(pool.strategy == "rotscale")
        for frame = 1, 96 do
            pool:step()
            local x, y = fn(frame / 64 + 0.25, {})
            near(pool.x[1], x, 1e-5)
            near(pool.y[1], y, 1e-5)
        end
    end
end)

T.test("pingpong agrees with interpreted curves at both turnarounds", function()
    for _, duration in ipairs({0.5, 1, 2.3}) do
        local native = Curve.pingPong(Curve.linear(3), duration)
        local compiled = C.compile(C.curve.pingpong(C.curve.linear(3), duration))
        for _, fraction in ipairs({-1.2, -1, 0, 0.3, 1, 1.7, 2, 3, 4.1}) do
            local t = duration * fraction
            near(compiled(t, {}), native(t, {}))
        end
    end
end)

T.test("compiler sequences remain finite and work on LuaJIT", function()
    local ir = C.curve.sequence({C.curve.const(2), 1}, {C.curve.const(3), 1})
    local fn = C.compile(ir)
    near(fn(0.5, {}), 2)
    near(fn(1.5, {}), 3)
    near(fn(2.5, {}), 0)
    local native = Curve.sequence({{Curve.const(2), 1}, {Curve.const(3), 1}})
    near(native(2.5, {}), 2) -- Deliberate, documented API difference.
    assert(not C.canUseLUT(ir))
end)

T.test("reading one coordinate never drops a compiled batch output buffer", function()
    for _, axis in ipairs({"x", "y"}) do
        local ir = C.motion.shake(5, 10)
        local fn = C.compile(ir)
        local pool = C.createPool(ir, {fps = 64}):init()
        for frame = 1, 96 do
            pool:step()
            local x, y = fn(frame / 64, {})
            near(pool[axis][1], axis == "x" and x or y)
        end
        assert(pool.axis == axis)
    end
end)

T.test("compiling and inspecting source preserve independent state IDs", function()
    for _, inspect in ipairs({C.compile, C.toSource, function() C.compileBatchEval(C.curve.const(1)) end}) do
        for _, make in ipairs({C.curve.follow, C.curve.spring}) do
            local a = make(C.curve.const(0))
            inspect(a)
            local b = make(C.curve.const(100))
            assert(a.stateId ~= b.stateId)
            local fn = C.compile(C.motion.xy(a, b))
            local ctx = {}
            for _, t in ipairs({0, 0.1, 0.2}) do
                local x, y = fn(t, ctx)
                near(x, 0)
                near(y, 100)
            end
        end
    end
end)

T.test("LUT pools grow and shrink all buffers before stepping", function()
    local hasFFI, ffi = pcall(require, "ffi")
    for _, ir in ipairs({C.curve.triangle(1, 2), C.motion.xy(C.curve.triangle(1, 2), C.curve.sin(1, 3))}) do
        local pool = C.createPool(ir, {fps = 64}):init({0.25})
        local fn = C.compile(ir)
        assert(pool.strategy == "lut")
        for _, size in ipairs({4, 2, 0, 3}) do
            pool:resize(size)
            if hasFFI then
                for _, key in ipairs({"_posX", "_posY", "_ffiTimes", "_ffiPhases"}) do
                    assert(ffi.sizeof(pool[key]) == size * ffi.sizeof("float"), key .. " capacity")
                end
            end
            pool:init():step()
            for i = 1, size do
                local x, y = pool:get(i)
                local ex, ey = fn(1 / 64, {})
                near(x, ex, 1e-5)
                if y then near(y, ey, 1e-5) end
            end
        end
    end
end)

T.test("pool lifecycle agrees with direct evaluation across strategies", function()
    local cases = {
        {"rotator", C.curve.sin(1, 3)},
        {"rotator", C.motion.circle(10, 1)},
        {"lut", C.curve.triangle(1, 2)},
        {"lut", C.motion.xy(C.curve.triangle(1, 2), C.curve.sin(1, 3))},
        {"hybrid", C.curve.add(C.curve.sin(1), C.curve.linear(2))},
        {"hybrid", C.motion.add(C.motion.circle(2, 1), C.motion.drift(1, 2))},
        {"rotscale", C.motion.scale(C.motion.circle(2, 1), C.curve.linear(2))},
        {"rotscale", C.motion.rotate(C.motion.circle(2, 1), C.curve.linear(2))},
        {"compiled", C.curve.ramp(0, 10, 2)},
        {"compiled", C.motion.shake(5, 3)},
        {"compiled", C.curve.follow(C.curve.linear(2))},
        {"compiled", C.motion.xy(C.curve.follow(C.curve.linear(2)), C.curve.spring(C.curve.linear(3)))},
    }
    for _, case in ipairs(cases) do
        local ir, phases, times, contexts = case[2], {0.25, -0.125}, {0, 0}, {{}, {}}
        local pool = C.createPool(ir, {count = 2, fps = 64, dt = 0.125}):init(phases):useXY()
        assert(pool.strategy == case[1], pool.strategy .. " expected " .. case[1])
        local fn = C.compile(ir)
        local function check()
            local xs, ys, count, hasFFI = pool:getFFI()
            assert(count == pool.count)
            for i = 1, pool.count do
                local ex, ey = fn(times[i] + phases[i], contexts[i])
                local x, y = pool:get(i)
                near(x, ex, 1e-5)
                if y then near(y, ey, 1e-5) end
                if hasFFI then
                    near(xs[i - 1], x, 1e-5)
                    if y then near(ys[i - 1], y, 1e-5) end
                end
            end
        end
        check()
        for _, dt in ipairs({0.125, 0.03125, 0.125}) do
            if dt == pool.dt then pool:step() else pool:stepDt(dt) end
            for i = 1, pool.count do times[i] = times[i] + dt end
            check()
        end
        pool:setPhase(1, 0.375)
        phases[1], times[1], contexts[1] = 0.375, 0, {}
        check()
        pool:resize(4)
        for i = 3, 4 do phases[i], times[i], contexts[i] = 0, 0, {} end
        check()
        pool:step()
        for i = 1, pool.count do times[i] = times[i] + pool.dt end
        check()
        pool:resize(1)
        check()
        pool:init({0.5})
        phases, times, contexts = {0.5}, {0}, {{}}
        check()
    end
end)

T.test("compiled context lookups handle missing parents and nonidentifier keys", function()
    local fn = C.compile(C.curve.fromCtx('player.some-key', 7))
    near(fn(0, nil), 7)
    near(fn(0, {}), 7)
    near(fn(0, {player = {}}), 7)
    near(fn(2, {player = {['some-key'] = function(t, ctx) return t * ctx.factor end}, factor = 3}), 6)
end)

T.test("batch variants preserve per-entity contexts and state", function()
    for _, stateful in ipairs({false, true}) do
        for _, motion in ipairs({false, true}) do
            for _, phasesEnabled in ipairs({false, true}) do
                for _, preallocate in ipairs({false, true}) do
                    local signal = C.curve.fromCtx('target.value', 7)
                    local ir = stateful and C.curve.follow(signal, 3) or signal
                    if motion then ir = C.motion.xy(ir, C.curve.linear(2)) end
                    local batch = C.compileBatchEval(ir, {withPhase = phasesEnabled, preallocate = preallocate})
                    local direct = C.compile(ir)
                    local contexts = {{target = {value = 3}}, {target = {value = 8}}}
                    local reference = {{target = {value = 3}}, {target = {value = 8}}}
                    local phases = {0.25, -0.125}
                    for frame = 0, 3 do
                        local ts = {frame * 0.125, frame * 0.125}
                        for i = 1, 2 do
                            contexts[i].target.value = contexts[i].target.value + i
                            reference[i].target.value = contexts[i].target.value
                        end
                        local args = {ts}
                        if phasesEnabled then args[#args + 1] = phases end
                        args[#args + 1] = 2
                        local outX, outY = {}, {}
                        if preallocate then
                            args[#args + 1] = outX
                            if motion then args[#args + 1] = outY end
                        end
                        args[#args + 1] = contexts
                        local unpack = table.unpack or unpack
                        local xs, ys = batch(unpack(args))
                        if preallocate then assert(xs == outX and (not motion or ys == outY)) end
                        for i = 1, 2 do
                            local x, y = direct(ts[i] + (phasesEnabled and phases[i] or 0), reference[i])
                            near(xs[i], x)
                            if motion then near(ys[i], y) end
                        end
                    end
                end
            end
        end
    end
    near(C.compileBatchEval(C.curve.fromCtx('missing', 7))({0}, 1)[1], 7)
end)

T.finish()
