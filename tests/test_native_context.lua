local root = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
local T = require("spatula.tests.support")
local Field = require("spatula.field")
local S = require("spatula.signal")

T.test("native wrappers preserve context in batch and gradient fallbacks", function()
    -- Exercise the native-enabled wrappers on every runtime, without requiring
    -- a platform binary. Explicit context must never enter native sampling.
    local Patched = {}
    for key, value in pairs(Field) do Patched[key] = value end
    local opt = assert(loadfile(root .. "opt/field.lua"))()
    opt._init(Patched, {hasNative = true, hasFFI = true,
        ffi = {typeof = function() return {} end}, native = {}})
    for _, count in ipairs({1, 12}) do
        local field = Field.new({falloff = "linear"})
        for _ = 1, count do
            field:add({100, 100}, {radius = S("radius", 50), value = 1})
        end
        local ctx = {radius = 150}
        local out = {}
        local values = Patched.sampleBatch(field, {150}, {100}, 1, out, ctx)
        assert(values == out)
        assert(math.abs(values[1] - count * 2 / 3) < 1e-8)
        local v, gx, gy = Patched.sampleBatchWithGradient(field, {150}, {100}, 1, nil, nil, nil, ctx)
        local expectedX, expectedY = field:gradient({150, 100}, nil, ctx)
        assert(math.abs(v[1] - field:sample(150, 100, ctx)) < 1e-8)
        assert(math.abs(gx[1] - expectedX) < 1e-8)
        assert(math.abs(gy[1] - expectedY) < 1e-8)
    end
end)

T.test("native-enabled dispatch preserves unsupported blends and dynamic falloffs", function()
    local Patched = {}
    for key, value in pairs(Field) do Patched[key] = value end
    local opt = assert(loadfile(root .. "opt/field.lua"))()
    opt._init(Patched, {hasNative = true, hasFFI = true,
        ffi = {typeof = function() return {} end}, native = setmetatable({}, {
            __index = function() error("unsupported field reached native code") end})})
    for _, blend in ipairs({"max", "min", function(a, b) return a + b * 2 end}) do
        local field = Field.new({blend = blend})
        for _ = 1, 12 do field:add({0, 0}, {radius = 10}) end
        assert(Patched.sampleBatch(field, {0}, {0}, 1)[1] == field:sample(0, 0))
    end
    for _, dynamic in ipairs({"position", "value", "radius", "falloff"}) do
        local field = Field.new()
        for _ = 1, 12 do
            field:add({dynamic == "position" and S("x", 0) or 0, 0}, {
                radius = dynamic == "radius" and S("radius", 10) or 10,
                value = dynamic == "value" and S("value", 3) or 3,
                falloff = dynamic == "falloff" and S("falloff", 1) or "smooth"})
        end
        assert(Patched.sampleBatch(field, {0}, {0}, 1)[1] == field:sample(0, 0))
    end
end)

if Field.hasNativeSupport() then
    T.test("native library loads declarations and tracks source mutations", function()
        local field = Field.new({falloff = "constant"})
        local sources = {}
        for i = 1, 12 do sources[i] = field:add({0, 0}, {radius = 10, value = 1}) end
        local function check()
            local out = {}
            assert(field:sampleBatch({0, 20}, {0, 0}, 2, out) == out)
            assert(out[1] == field:sample(0, 0) and out[2] == field:sample(20, 0))
        end
        check()
        sources[1].value = 5
        sources[2].active = false
        check()
        field:move(sources[3], {20, 0})
        field:remove(sources[4])
        check()
    end)
else
    print("  SKIP native binary integration (unavailable on this runtime/platform)")
    T.skipped = T.skipped + 1
end

T.finish()
