-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/gesture_test.lua
-- Tests for Gesture module: recognition via Motion template matching
-- Run with: lua tests/gesture_test.lua

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.motion"] = function() return require("motion") end
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.signal"] = function() return require("signal") end

local Gesture = require("gesture")
local Motion = require("motion")
local Curve = require("curve")

--------------------------------------------------------------------------------
-- TEST FRAMEWORK
--------------------------------------------------------------------------------

local tests = {}
local passed = 0
local failed = 0

local function test(name, fn)
    table.insert(tests, {name = name, fn = fn})
end

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assertNear(a, b, tolerance, msg)
    tolerance = tolerance or 0.0001
    if math.abs(a - b) > tolerance then
        error(string.format("%s: expected ~%s, got %s (tol=%s)", msg or "assertion failed", tostring(b), tostring(a), tostring(tolerance)))
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error(msg or "assertion failed: expected true")
    end
end

local function runTests()
    print("Running Gesture tests...\n")
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print(string.format("  ✓ %s", t.name))
        else
            failed = failed + 1
            print(string.format("  ✗ %s", t.name))
            print(string.format("    %s", err))
        end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))
    return failed == 0
end

--------------------------------------------------------------------------------
-- SYNTHETIC GESTURE HELPER
-- Samples a Motion at ~200 points with configurable transformations + noise
--------------------------------------------------------------------------------

local function syntheticGesture(motion, opts)
    opts = opts or {}
    local count = opts.count or 200
    local noise = opts.noise or 0
    local offsetX = opts.offsetX or 0
    local offsetY = opts.offsetY or 0
    local scale = opts.scale or 1
    local rotation = opts.rotation or 0

    local cosR, sinR = math.cos(rotation), math.sin(rotation)
    local points = {}
    for i = 1, count do
        local t = (i - 1) / (count - 1)
        local x, y = motion(t, {})
        -- Scale
        x, y = x * scale, y * scale
        -- Rotate
        local rx = x * cosR - y * sinR
        local ry = x * sinR + y * cosR
        -- Translate
        rx = rx + offsetX
        ry = ry + offsetY
        -- Add noise
        if noise > 0 then
            rx = rx + (math.random() - 0.5) * 2 * noise
            ry = ry + (math.random() - 0.5) * 2 * noise
        end
        points[i] = {rx, ry}
    end
    return points
end

--------------------------------------------------------------------------------
-- PREPROCESSING TESTS
--------------------------------------------------------------------------------

test("resample returns exactly n points", function()
    local pts = {{0, 0}, {10, 0}, {20, 0}, {30, 0}}
    local resampled = Gesture.resample(pts, 8)
    assertEq(#resampled, 8, "resample count")
end)

test("resampled points are equidistant", function()
    -- L-shaped path: (0,0)→(10,0)→(10,10)
    local pts = {{0, 0}, {10, 0}, {10, 10}}
    local resampled = Gesture.resample(pts, 5)
    assertEq(#resampled, 5, "count")

    -- Check spacing is approximately uniform
    local dists = {}
    for i = 2, #resampled do
        local dx = resampled[i][1] - resampled[i-1][1]
        local dy = resampled[i][2] - resampled[i-1][2]
        dists[#dists + 1] = math.sqrt(dx * dx + dy * dy)
    end
    for i = 2, #dists do
        assertNear(dists[i], dists[1], 0.01, "equidistant spacing")
    end
end)

test("preprocess centers points at origin", function()
    local pts = {{10, 20}, {20, 20}, {20, 30}, {10, 30}}
    local processed = Gesture.preprocess(pts, 16)
    local cx, cy = Gesture.centroid(processed)
    assertNear(cx, 0, 0.001, "centroid x")
    assertNear(cy, 0, 0.001, "centroid y")
end)

test("preprocess scales to unit", function()
    local pts = {{0, 0}, {100, 0}, {100, 100}, {0, 100}}
    local processed = Gesture.preprocess(pts, 16)
    local maxDist = 0
    for i = 1, #processed do
        local d = math.sqrt(processed[i][1]^2 + processed[i][2]^2)
        if d > maxDist then maxDist = d end
    end
    assertNear(maxDist, 1, 0.01, "unit scale")
end)

test("preprocess accepts {x=,y=} format", function()
    local pts = {{x=0, y=0}, {x=10, y=0}, {x=10, y=10}}
    local processed, cx, cy = Gesture.preprocess(pts, 8)
    assertEq(#processed, 8, "count with xy format")
    -- Should not error and should produce valid output
    assertTrue(type(cx) == "number", "centroid x is number")
    assertTrue(type(cy) == "number", "centroid y is number")
end)

--------------------------------------------------------------------------------
-- PROCRUSTES ALIGNMENT TESTS
--------------------------------------------------------------------------------

test("identity alignment gives zero distance", function()
    local pts = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
    local sqn = Gesture.sqNorm(pts, 4)
    local dist = Gesture.matchDistance(pts, pts, 4, sqn, sqn)
    assertNear(dist, 0, 0.001, "identity distance")
end)

test("algebraic distance is zero for identical point sets", function()
    local pts = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
    local sqn = Gesture.sqNorm(pts, 4)
    local dist = Gesture.matchDistance(pts, pts, 4, sqn, sqn)
    assertNear(dist, 0, 0.001, "identical sets should have zero distance")
end)

test("same shape different direction gives low distance", function()
    -- Forward: 1→2→3→4
    local fwd = {{0, 0}, {1, 0}, {2, 0}, {3, 0}}
    -- Reversed: 4→3→2→1 (same shape, reversed order)
    local rev = {{3, 0}, {2, 0}, {1, 0}, {0, 0}}

    -- Preprocess both
    local fwdP, _, _, _, fwdSqN = Gesture.preprocess(fwd, 4)
    local revP, _, _, _, revSqN = Gesture.preprocess(rev, 4)

    local dist = Gesture.matchDistance(fwdP, revP, 4, fwdSqN, revSqN)
    -- Same shape, so distance should be low
    assertTrue(dist < 0.01, "same shape should match closely: " .. tostring(dist))
end)

--------------------------------------------------------------------------------
-- RECOGNITION TESTS (one per built-in gesture)
--------------------------------------------------------------------------------

test("recognize circle", function()
    local pts = syntheticGesture(Motion.circle(1, 1))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize circle")
    assertEq(result.name, "circle", "name")
    assertTrue(result.distance < 0.05, "clean circle should have low distance: " .. tostring(result.distance))
end)

test("recognize line", function()
    local pts = syntheticGesture(Motion.drift(1, 0))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize line")
    assertEq(result.name, "line", "name")
    assertTrue(result.distance < 0.05, "clean line should have low distance: " .. tostring(result.distance))
end)

test("recognize zigzag", function()
    local pts = syntheticGesture(Motion.xy(Curve.linear(1), Curve.triangle(3, 1)))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize zigzag")
    assertEq(result.name, "zigzag", "name")
    assertTrue(result.distance < 0.1, "clean zigzag should have low distance: " .. tostring(result.distance))
end)

test("recognize spiral", function()
    local pts = syntheticGesture(Motion.spiral(1, 1, 1))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize spiral")
    assertEq(result.name, "spiral", "name")
    assertTrue(result.distance < 0.1, "clean spiral should have low distance: " .. tostring(result.distance))
end)

test("recognize figure8", function()
    local pts = syntheticGesture(Motion.figure8(1, 1))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize figure8")
    assertEq(result.name, "figure8", "name")
    assertTrue(result.distance < 0.1, "clean figure8 should have low distance: " .. tostring(result.distance))
end)

test("recognize wave", function()
    local pts = syntheticGesture(Motion.wave(1, 1, 2))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize wave")
    assertEq(result.name, "wave", "name")
    assertTrue(result.distance < 0.1, "clean wave should have low distance: " .. tostring(result.distance))
end)

--------------------------------------------------------------------------------
-- INVARIANCE TESTS
--------------------------------------------------------------------------------

test("scale invariance (radius 500)", function()
    local pts = syntheticGesture(Motion.circle(1, 1), {scale = 500})
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize scaled circle")
    assertEq(result.name, "circle", "name")
    assertTrue(result.distance < 0.05, "scale should not affect recognition: " .. tostring(result.distance))
end)

test("translation invariance (offset 1000, 2000)", function()
    local pts = syntheticGesture(Motion.circle(1, 1), {offsetX = 1000, offsetY = 2000})
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize translated circle")
    assertEq(result.name, "circle", "name")
    assertTrue(result.distance < 0.05, "translation should not affect recognition: " .. tostring(result.distance))
end)

test("rotation invariance (45° line)", function()
    local pts = syntheticGesture(Motion.drift(1, 0), {rotation = math.pi / 4})
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize rotated line")
    assertEq(result.name, "line", "name")
    assertTrue(result.distance < 0.05, "rotation should not affect recognition: " .. tostring(result.distance))
end)

test("reversed circle is distinguishable (direction sensitive)", function()
    local pts = syntheticGesture(Motion.circle(1, 1))
    -- Reverse the point order (CW → CCW)
    local reversed = {}
    for i = #pts, 1, -1 do
        reversed[#reversed + 1] = pts[i]
    end
    local fwdResult = Gesture.recognize(pts)
    assertTrue(fwdResult ~= nil, "forward circle should be recognized")
    assertEq(fwdResult.name, "circle", "forward name")
    -- Without reverse-matching, CW and CCW circles are distinct shapes.
    -- Reversed circle should have much higher distance (may exceed threshold).
    local allResults = Gesture.recognizeAll(reversed)
    assertTrue(allResults[1].distance > fwdResult.distance,
        "reversed should have higher distance: " .. tostring(allResults[1].distance) .. " vs " .. tostring(fwdResult.distance))
end)

--------------------------------------------------------------------------------
-- NOISE TESTS
--------------------------------------------------------------------------------

test("low noise is still recognized", function()
    math.randomseed(42)
    local pts = syntheticGesture(Motion.circle(1, 1), {scale = 200, noise = 3})
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "low noise should still be recognized")
    assertEq(result.name, "circle", "name")
end)

test("noise increases distance", function()
    math.randomseed(42)
    local clean = syntheticGesture(Motion.circle(1, 1), {scale = 100, noise = 0})
    local noisy = syntheticGesture(Motion.circle(1, 1), {scale = 100, noise = 5})
    local cleanResult = Gesture.recognize(clean)
    local noisyResult = Gesture.recognize(noisy)
    assertTrue(cleanResult ~= nil, "clean should match")
    assertTrue(noisyResult ~= nil, "noisy should match")
    assertTrue(noisyResult.distance > cleanResult.distance,
        "noisy distance should be higher: " .. tostring(noisyResult.distance) .. " vs " .. tostring(cleanResult.distance))
end)

test("high noise is rejected", function()
    math.randomseed(42)
    -- Pure random noise, no underlying gesture shape
    local pts = {}
    for i = 1, 200 do
        pts[i] = {math.random() * 1000, math.random() * 1000}
    end
    local result = Gesture.recognize(pts, {threshold = 0.1})
    assertTrue(result == nil, "pure noise should be rejected with low threshold")
end)

--------------------------------------------------------------------------------
-- CUSTOM TEMPLATE TESTS
--------------------------------------------------------------------------------

test("register and recognize custom template", function()
    -- Register a custom diagonal motion
    local diagonal = Motion.drift(1, 1)
    Gesture.register("diagonal", diagonal)

    local pts = syntheticGesture(diagonal)
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize custom template")
    assertEq(result.name, "diagonal", "name")

    -- Clean up
    Gesture.unregister("diagonal")
end)

test("unregister removes template", function()
    local diagonal = Motion.drift(1, 1)
    Gesture.register("diagonal", diagonal)
    Gesture.unregister("diagonal")

    local pts = syntheticGesture(diagonal)
    local result = Gesture.recognize(pts)
    -- Should match something, but not "diagonal"
    if result then
        assertTrue(result.name ~= "diagonal", "unregistered template should not match")
    end
end)

test("clear removes all templates", function()
    Gesture.clear()
    local pts = syntheticGesture(Motion.circle(1, 1))
    local result = Gesture.recognize(pts)
    assertTrue(result == nil, "no templates should mean no match")

    -- Restore built-ins
    Gesture.reset()
end)

--------------------------------------------------------------------------------
-- RECOGNIZEALL TESTS
--------------------------------------------------------------------------------

test("recognizeAll returns sorted results", function()
    local pts = syntheticGesture(Motion.circle(1, 1))
    local results = Gesture.recognizeAll(pts)
    assertTrue(#results > 0, "should have results")
    -- Check sorted order
    for i = 2, #results do
        assertTrue(results[i].distance >= results[i-1].distance,
            "results should be sorted by distance")
    end
    -- Best match should be circle
    assertEq(results[1].name, "circle", "best match")
end)

test("recognizeAll includes all templates", function()
    local pts = syntheticGesture(Motion.circle(1, 1))
    local results = Gesture.recognizeAll(pts)
    -- Should have at least the 15 built-in variants
    assertTrue(#results >= 15, "should include all templates: got " .. #results)
end)

--------------------------------------------------------------------------------
-- EDGE CASE TESTS
--------------------------------------------------------------------------------

test("single point input", function()
    local pts = {{5, 5}}
    local result = Gesture.recognize(pts)
    -- Should not crash; may or may not match
    assertTrue(true, "single point should not crash")
end)

test("two point input", function()
    local pts = {{0, 0}, {10, 0}}
    local result = Gesture.recognize(pts)
    -- Should not crash
    assertTrue(true, "two points should not crash")
end)

test("result includes center and scale", function()
    local pts = syntheticGesture(Motion.circle(1, 1), {scale = 100, offsetX = 500, offsetY = 300})
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize")
    assertTrue(result.center ~= nil, "should have center")
    assertTrue(result.scale ~= nil, "should have scale")
    assertNear(result.center[1], 500, 5, "center x")
    assertNear(result.center[2], 300, 5, "center y")
    assertTrue(result.scale > 50, "scale should reflect input size: " .. tostring(result.scale))
end)

test("register with params preserves params", function()
    Gesture.register("custom_wave", {
        motion = Motion.wave(1, 1, 3),
        params = {freq = 3, style = "smooth"}
    })
    local pts = syntheticGesture(Motion.wave(1, 1, 3))
    local result = Gesture.recognize(pts)
    -- It might match wave or custom_wave — check if params work when custom_wave wins
    local all = Gesture.recognizeAll(pts)
    local found = false
    for _, r in ipairs(all) do
        if r.name == "custom_wave" then
            assertEq(r.params.freq, 3, "params freq")
            assertEq(r.params.style, "smooth", "params style")
            found = true
            break
        end
    end
    assertTrue(found, "custom_wave should be in results")

    Gesture.unregister("custom_wave")
end)

test("reset restores built-ins after clear", function()
    Gesture.clear()
    Gesture.reset()
    local pts = syntheticGesture(Motion.circle(1, 1))
    local result = Gesture.recognize(pts)
    assertTrue(result ~= nil, "should recognize after reset")
    assertEq(result.name, "circle", "name after reset")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
