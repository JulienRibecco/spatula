-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Pool Module (standalone)
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_pool_module.lua

local Compiler = require("spatula.compiler.compiler")
local Pool = require("spatula.compiler.pool")

local function approxEq(a, b, eps)
    eps = eps or 0.001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Pool Module: Direct Usage ===\n")

test("Pool.create creates rotator pool", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Pool.create(Compiler, ir, { count = 10 })
    
    assert(pool, "Should create pool")
    assert(pool.strategy == "rotator", "Circle should use rotator")
    assert(pool.count == 10, "Should have 10 entities")
end)

test("Pool.create creates LUT pool", function()
    local ir = Compiler.motion.xy(Compiler.curve.triangle(1, 5), Compiler.curve.sin(1, 10))
    local pool = Pool.create(Compiler, ir, { count = 10 })
    
    assert(pool, "Should create pool")
    assert(pool.strategy == "lut", "Periodic motion should use LUT")
end)

test("Pool methods work", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Pool.create(Compiler, ir, { count = 5 }):init()
    
    local x1, y1 = pool:get(1)
    assert(approxEq(x1, 100), "Initial X should be 100")
    assert(approxEq(y1, 0), "Initial Y should be 0")
    
    pool:step()
    
    local x2, y2 = pool:get(1)
    assert(x2 ~= x1 or y2 ~= y1, "Position should change after step")
end)

test("Pool.createRandom convenience", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Pool.createRandom(Compiler, ir, 10)
    
    assert(pool, "Should create pool")
    assert(pool.count == 10, "Should have 10 entities")
    
    -- Should have random phases
    local phases = {}
    for i = 1, 10 do
        phases[i] = pool._phases[i]
    end
    
    -- At least some should be different
    local allSame = true
    for i = 2, 10 do
        if phases[i] ~= phases[1] then
            allSame = false
            break
        end
    end
    assert(not allSame, "Phases should be randomized")
end)

test("Pool.auto returns compiled function", function()
    local ir = Compiler.motion.circle(100, 1)
    local fn = Pool.auto(Compiler, ir)
    
    assert(type(fn) == "function", "Should return function")
    
    local x, y = fn(0, {})
    assert(approxEq(x, 100), "X at t=0 should be 100")
end)

print("\n=== Pool Module: Compatibility with Compiler.createPool ===\n")

test("Compiler.createPool matches Pool.create", function()
    local ir = Compiler.motion.circle(100, 1)
    
    local pool1 = Compiler.createPool(ir, { count = 5 }):init()
    local pool2 = Pool.create(Compiler, ir, { count = 5 }):init()
    
    -- Step both
    for _ = 1, 30 do
        pool1:step()
        pool2:step()
    end
    
    -- Should have same results
    for i = 1, 5 do
        assert(approxEq(pool1.x[i], pool2.x[i], 0.01), 
            string.format("X[%d] should match", i))
        assert(approxEq(pool1.y[i], pool2.y[i], 0.01),
            string.format("Y[%d] should match", i))
    end
end)

print("\n=== All Pool Module tests complete ===\n")

Support.finish()
