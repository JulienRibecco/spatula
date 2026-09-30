#!/usr/bin/env lua
-- Opt-in comparison of the core, compiler, and current pool strategies.
-- Usage: lua compiler/benchmarks/benchmark_full.lua [entities] [frames]
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
local S = require("spatula")
local C = require("spatula.compiler")
local count, frames = tonumber(arg[1]) or 1000, tonumber(arg[2]) or 300
assert(count > 0 and count % 1 == 0 and frames > 0 and frames % 1 == 0, "counts must be positive integers")
local dt = 1 / 64
local cases = {
    {"circle", S.Motion.circle(10, 1), C.motion.circle(10, 1)},
    {"triangle", S.Curve.triangle(1, 2), C.curve.triangle(1, 2)},
    {"ramp", S.Curve.ramp(0, 10, 2), C.curve.ramp(0, 10, 2)},
}
local function measure(step)
    local sum, start = 0, os.clock()
    for frame = 1, frames do sum = sum + step(frame) end
    return os.clock() - start, sum
end
local function evaluate(fn)
    local ctx = {}
    return measure(function(frame)
        local sum = 0
        for i = 1, count do sum = sum + fn(frame * dt + (i - 1) / count, ctx) end
        return sum
    end)
end
print(string.format("%s: %d entities, %d frames", _VERSION, count, frames))
for _, case in ipairs(cases) do
    local directTime, directSum = evaluate(case[2])
    local compiledTime, compiledSum = evaluate(C.compile(case[3]))
    local phases = {}
    for i = 1, count do phases[i] = (i - 1) / count end
    local pool = C.createPool(case[3], {count = count, fps = 64}):init(phases):useXY()
    local poolTime, poolSum = measure(function()
        pool:step()
        local sum = 0
        for i = 1, count do sum = sum + pool:get(i) end
        return sum
    end)
    print(string.format("%-8s core %.4fs  compiled %.4fs  pool/%s %.4fs  checksums %.4f / %.4f / %.4f",
        case[1], directTime, compiledTime, pool.strategy, poolTime, directSum, compiledSum, poolSum))
end
