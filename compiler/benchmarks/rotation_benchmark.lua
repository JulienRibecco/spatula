--[[
    Rotation Performance Benchmark
    Compares: Lua tables, FFI arrays, and C via FFI

    Run with: lua5.4 benchmarks/rotation_benchmark.lua
    Or with LuaJIT: luajit benchmarks/rotation_benchmark.lua
]]

local ffi_ok, ffi = pcall(require, "ffi")

local COUNT = 50000
local ITERATIONS = 1000
local cosD = math.cos(0.1)
local sinD = math.sin(0.1)

local function measure(name, fn)
    -- Warmup
    for _ = 1, 10 do fn() end

    -- Measure
    local t0 = os.clock()
    for _ = 1, ITERATIONS do
        fn()
    end
    local elapsed = os.clock() - t0

    local rotationsPerSec = (COUNT * ITERATIONS) / elapsed
    local msPerFrame = (elapsed / ITERATIONS) * 1000

    print(string.format("%-25s %8.2f ms/frame  %8.1fM rot/sec",
        name, msPerFrame, rotationsPerSec / 1e6))

    return rotationsPerSec
end

print(string.format("\n=== Rotation Benchmark: %dk entities, %d iterations ===\n", COUNT/1000, ITERATIONS))
print(string.format("%-25s %8s  %15s", "Method", "Time", "Throughput"))
print(string.rep("-", 55))

local results = {}

--------------------------------------------------------------------------------
-- 1. Lua Tables (baseline)
--------------------------------------------------------------------------------
do
    local x, y = {}, {}
    for i = 1, COUNT do
        local angle = (i / COUNT) * math.pi * 2
        x[i] = math.cos(angle) * 200
        y[i] = math.sin(angle) * 200
    end

    results.lua_simple = measure("Lua tables (simple)", function()
        for i = 1, COUNT do
            local xi, yi = x[i], y[i]
            x[i] = xi * cosD - yi * sinD
            y[i] = xi * sinD + yi * cosD
        end
    end)
end

--------------------------------------------------------------------------------
-- 2. Lua Tables with 4-way unrolling (current scheduler)
--------------------------------------------------------------------------------
do
    local x, y = {}, {}
    for i = 1, COUNT do
        local angle = (i / COUNT) * math.pi * 2
        x[i] = math.cos(angle) * 200
        y[i] = math.sin(angle) * 200
    end

    results.lua_unrolled = measure("Lua tables (4x unroll)", function()
        local i = 1
        while i <= COUNT - 3 do
            local x1, y1 = x[i], y[i]
            local x2, y2 = x[i+1], y[i+1]
            local x3, y3 = x[i+2], y[i+2]
            local x4, y4 = x[i+3], y[i+3]

            x[i] = x1 * cosD - y1 * sinD
            y[i] = x1 * sinD + y1 * cosD
            x[i+1] = x2 * cosD - y2 * sinD
            y[i+1] = x2 * sinD + y2 * cosD
            x[i+2] = x3 * cosD - y3 * sinD
            y[i+2] = x3 * sinD + y3 * cosD
            x[i+3] = x4 * cosD - y4 * sinD
            y[i+3] = x4 * sinD + y4 * cosD

            i = i + 4
        end
        while i <= COUNT do
            local xi, yi = x[i], y[i]
            x[i] = xi * cosD - yi * sinD
            y[i] = xi * sinD + yi * cosD
            i = i + 1
        end
    end)
end

--------------------------------------------------------------------------------
-- 3. FFI Float Arrays (LuaJIT only)
--------------------------------------------------------------------------------
if ffi_ok then
    local x = ffi.new("float[?]", COUNT)
    local y = ffi.new("float[?]", COUNT)

    for i = 0, COUNT - 1 do
        local angle = ((i + 1) / COUNT) * math.pi * 2
        x[i] = math.cos(angle) * 200
        y[i] = math.sin(angle) * 200
    end

    results.ffi_simple = measure("FFI arrays (simple)", function()
        for i = 0, COUNT - 1 do
            local xi, yi = x[i], y[i]
            x[i] = xi * cosD - yi * sinD
            y[i] = xi * sinD + yi * cosD
        end
    end)

    -- FFI with unrolling
    results.ffi_unrolled = measure("FFI arrays (4x unroll)", function()
        local i = 0
        while i <= COUNT - 4 do
            local x1, y1 = x[i], y[i]
            local x2, y2 = x[i+1], y[i+1]
            local x3, y3 = x[i+2], y[i+2]
            local x4, y4 = x[i+3], y[i+3]

            x[i] = x1 * cosD - y1 * sinD
            y[i] = x1 * sinD + y1 * cosD
            x[i+1] = x2 * cosD - y2 * sinD
            y[i+1] = x2 * sinD + y2 * cosD
            x[i+2] = x3 * cosD - y3 * sinD
            y[i+2] = x3 * sinD + y3 * cosD
            x[i+3] = x4 * cosD - y4 * sinD
            y[i+3] = x4 * sinD + y4 * cosD

            i = i + 4
        end
        while i < COUNT do
            local xi, yi = x[i], y[i]
            x[i] = xi * cosD - yi * sinD
            y[i] = xi * sinD + yi * cosD
            i = i + 1
        end
    end)
else
    print("FFI arrays                 (skipped - LuaJIT required)")
end

--------------------------------------------------------------------------------
-- 4. C via FFI (requires compilation)
--------------------------------------------------------------------------------
if ffi_ok then
    -- Try to load pre-compiled library
    local c_lib = nil
    local ok = pcall(function()
        ffi.cdef[[
            void rotate_batch(float* x, float* y, int count, float cosD, float sinD);
            void rotate_batch_simd(float* x, float* y, int count, float cosD, float sinD);
        ]]
        c_lib = ffi.load("./librotation_native.dylib")
    end)

    if ok and c_lib then
        local x = ffi.new("float[?]", COUNT)
        local y = ffi.new("float[?]", COUNT)

        for i = 0, COUNT - 1 do
            local angle = ((i + 1) / COUNT) * math.pi * 2
            x[i] = math.cos(angle) * 200
            y[i] = math.sin(angle) * 200
        end

        results.c_basic = measure("C via FFI (basic)", function()
            c_lib.rotate_batch(x, y, COUNT, cosD, sinD)
        end)

        -- Try SIMD version if available
        local simd_ok = pcall(function()
            c_lib.rotate_batch_simd(x, y, COUNT, cosD, sinD)
        end)
        if simd_ok then
            results.c_simd = measure("C via FFI (SIMD)", function()
                c_lib.rotate_batch_simd(x, y, COUNT, cosD, sinD)
            end)
        end
    else
        print("C via FFI                  (skipped - compile rotation_native.c first)")
        print("                           gcc -O3 -shared -fPIC -o librotation_native.so rotation_native.c")
    end
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.rep("-", 55))

local baseline = results.lua_simple
if baseline then
    print("\nSpeedup vs Lua tables (simple):")
    for name, speed in pairs(results) do
        local speedup = speed / baseline
        print(string.format("  %-23s %.2fx", name, speedup))
    end
end

print(string.format("\nAt 60 FPS, max entities per frame:"))
for name, speed in pairs(results) do
    local maxEntities = speed / 60
    print(string.format("  %-23s %dk entities", name, maxEntities / 1000))
end
