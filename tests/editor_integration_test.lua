-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
--- Editor Integration Tests
--- Tests node chains programmatically without LOVE dependencies

package.path = package.path .. ";../?.lua;../?/init.lua;../src/?.lua;../src/?/init.lua"

-- Module preloads for spatula.* requires
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.signal"] = function() return require("signal") end
package.preload["spatula.motion"] = function() return require("motion") end
package.preload["spatula.forms"] = function() return require("forms") end
package.preload["spatula.field"] = function() return require("field") end
package.preload["spatula.distribution"] = function() return require("distribution") end
package.preload["spatula.trigger"] = function() return require("trigger") end
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.tempo"] = function() return require("tempo") end
package.preload["spatula.audio"] = function() return require("audio") end
package.preload["spatula.osc"] = function() return require("osc") end
package.preload["spatula.file_watcher"] = function() return require("file_watcher") end
package.preload["spatula.audio_fft"] = function() return require("audio_fft") end
package.preload["spatula.audio_stems"] = function() return require("audio_stems") end
package.preload["spatula.external"] = function() return require("external") end
package.preload["spatula.stream"] = function() return require("stream") end

-- Editor modules
package.preload["spatula.editor"] = function() return require("editor") end
package.preload["spatula.editor.nodes"] = function() return require("editor.nodes") end
package.preload["spatula.editor.constants"] = function() return require("editor.constants") end
package.preload["spatula.editor.geometry"] = function() return require("editor.geometry") end
package.preload["spatula.editor.hit"] = function() return require("editor.hit") end
package.preload["spatula.editor.live"] = function() return require("editor.live") end
package.preload["spatula.editor.types"] = function() return require("editor.types") end
package.preload["spatula.editor.camera"] = function() return require("editor.camera") end
package.preload["spatula.editor.presets"] = function() return require("editor.presets") end

-- Src modules
package.preload["spatula.src.text.input"] = function() return require("src.text.input") end
package.preload["spatula.src.text.nodes"] = function() return require("src.text.nodes") end
package.preload["spatula.src.clock.nodes"] = function() return require("src.clock.nodes") end

local Editor = require("editor")

--------------------------------------------------------------------------------
-- Test Framework
--------------------------------------------------------------------------------

local passed, failed = 0, 0

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertEq", tostring(b), tostring(a)))
    end
end

local function assertNear(a, b, tol, msg)
    tol = tol or 0.001
    if math.abs(a - b) > tol then
        error(string.format("%s: expected ~%s, got %s (diff: %s)", msg or "assertNear", b, a, math.abs(a-b)))
    end
end

local function assertTrue(cond, msg)
    if not cond then error(msg or "assertTrue failed") end
end

local function assertFalse(cond, msg)
    if cond then error(msg or "assertFalse failed") end
end

local tests = {}
local function test(name, fn)
    tests[#tests + 1] = {name = name, fn = fn}
end

local function runTests()
    print("Running Editor Integration tests...\n")
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print(string.format("  \027[32m✓\027[0m %s", t.name))
        else
            failed = failed + 1
            print(string.format("  \027[31m✗\027[0m %s", t.name))
            print(string.format("    %s", err))
        end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))
    return failed == 0
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Find node definition by type
local function findDef(editor, nodeType)
    for _, def in ipairs(editor.nodeDefs) do
        if def.type == nodeType then return def end
    end
    error("Node type not found: " .. nodeType)
end

-- Create node shorthand
local function createNode(editor, nodeType, x, y)
    return editor:createNode(findDef(editor, nodeType), x or 0, y or 0)
end

-- Set knob value
local function setKnob(node, name, value)
    node.knobValues[name] = value
end

-- Set toggle value
local function setToggle(node, name, value)
    node.toggleValues = node.toggleValues or {}
    node.toggleValues[name] = value
end

--------------------------------------------------------------------------------
-- Category 1: Basic Curve Chains
--------------------------------------------------------------------------------

test("const evaluates correctly", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 42)

    local curve = editor:evaluateNode(const.id)
    assertNear(curve(0, {}), 42)
    assertNear(curve(1, {}), 42)
    assertNear(curve(100, {}), 42)
end)

test("osc -> transform (scale) chain", function()
    local editor = Editor.new()
    local osc = createNode(editor, "osc")
    setKnob(osc, "freq", 1)
    setKnob(osc, "amp", 1)
    setKnob(osc, "offset", 0)

    local scale = createNode(editor, "transform")
    setToggle(scale, "op", 1)  -- scale
    setKnob(scale, "value", 10)
    editor:addCable(osc.id, "out", scale.id, "in")

    local curve = editor:evaluateNode(scale.id)
    -- At t=0, sin(0) = 0, scaled by 10 = 0
    assertNear(curve(0, {}), 0, 0.01)
    -- At t=0.25, sin(PI/2) = 1, scaled by 10 = 10
    assertNear(curve(0.25, {}), 10, 0.01)
end)

test("osc + osc via math node (add)", function()
    local editor = Editor.new()
    local osc1 = createNode(editor, "osc")
    setKnob(osc1, "freq", 1)
    setKnob(osc1, "amp", 5)
    setKnob(osc1, "offset", 0)

    local osc2 = createNode(editor, "osc")
    setKnob(osc2, "freq", 1)
    setKnob(osc2, "amp", 3)
    setKnob(osc2, "offset", 0)

    local mathNode = createNode(editor, "math")
    setToggle(mathNode, "op", 1)  -- add
    editor:addCable(osc1.id, "out", mathNode.id, "a")
    editor:addCable(osc2.id, "out", mathNode.id, "b")

    local curve = editor:evaluateNode(mathNode.id)
    -- At t=0, both sin(0)=0, sum=0
    assertNear(curve(0, {}), 0, 0.01)
    -- At t=0.25, sin(PI/2)*5 + sin(PI/2)*3 = 5 + 3 = 8
    assertNear(curve(0.25, {}), 8, 0.01)
end)

test("math node multiply", function()
    local editor = Editor.new()
    local const1 = createNode(editor, "const")
    setKnob(const1, "value", 7)

    local const2 = createNode(editor, "const")
    setKnob(const2, "value", 6)

    local mathNode = createNode(editor, "math")
    setToggle(mathNode, "op", 2)  -- multiply
    editor:addCable(const1.id, "out", mathNode.id, "a")
    editor:addCable(const2.id, "out", mathNode.id, "b")

    local curve = editor:evaluateNode(mathNode.id)
    assertNear(curve(0, {}), 42, 0.01)
end)

test("transform (offset) adds constant", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 10)

    local offset = createNode(editor, "transform")
    setToggle(offset, "op", 2)  -- offset
    setKnob(offset, "value", 5)
    editor:addCable(const.id, "out", offset.id, "in")

    local curve = editor:evaluateNode(offset.id)
    assertNear(curve(0, {}), 15, 0.01)
end)

--------------------------------------------------------------------------------
-- Category 2: Form + Distribution Chains
--------------------------------------------------------------------------------

test("form_circle -> dist generates points inside", function()
    local editor = Editor.new()
    local circle = createNode(editor, "form_circle")
    -- Default radius ~80

    local dist = createNode(editor, "dist")
    setKnob(dist, "count", 20)
    setToggle(dist, "pattern", 1)  -- random
    editor:addCable(circle.id, "form", dist.id, "form")

    local points = editor:generateDistributionPoints(dist.id, 0, {})
    assertTrue(#points >= 10, "should generate points: got " .. #points)

    -- All points should be within radius (default ~80)
    local form, cx, cy = editor:evaluateFormNode(circle.id, 0, {})
    for i, pt in ipairs(points) do
        -- Points are already translated, check distance from origin
        local dist = math.sqrt(pt.x * pt.x + pt.y * pt.y)
        assertTrue(dist <= 85, "point " .. i .. " should be inside circle, dist=" .. dist)
    end
end)

test("form_polygon -> dist generates points inside polygon", function()
    local editor = Editor.new()
    local polygon = createNode(editor, "form_polygon")
    setKnob(polygon, "sides", 6)  -- hexagon

    local dist = createNode(editor, "dist")
    setKnob(dist, "count", 30)
    setToggle(dist, "pattern", 1)  -- random
    editor:addCable(polygon.id, "form", dist.id, "form")

    local points = editor:generateDistributionPoints(dist.id, 0, {})
    assertTrue(#points >= 15, "should generate points: got " .. #points)

    local form = editor:evaluateFormNode(polygon.id, 0, {})
    for i, pt in ipairs(points) do
        assertTrue(form:contains(pt.x, pt.y, {}), "point " .. i .. " should be inside hexagon")
    end
end)

test("form_rect -> dist grid pattern", function()
    local editor = Editor.new()
    local rect = createNode(editor, "form_rect")

    local dist = createNode(editor, "dist")
    setKnob(dist, "count", 25)
    setToggle(dist, "pattern", 2)  -- grid
    editor:addCable(rect.id, "form", dist.id, "form")

    local points = editor:generateDistributionPoints(dist.id, 0, {})
    assertTrue(#points >= 10, "grid should generate points: got " .. #points)
end)

--------------------------------------------------------------------------------
-- Category 3: Sample Node Chains
--------------------------------------------------------------------------------

test("sample node extracts x from point", function()
    local editor = Editor.new()
    local point = createNode(editor, "point")

    local constX = createNode(editor, "const")
    setKnob(constX, "value", 100)
    local constY = createNode(editor, "const")
    setKnob(constY, "value", 200)

    editor:addCable(constX.id, "out", point.id, "x")
    editor:addCable(constY.id, "out", point.id, "y")

    local sample = createNode(editor, "sample")
    setToggle(sample, "axis", 1)  -- x
    editor:addCable(point.id, "entity", sample.id, "entity")

    local curve = editor:evaluateNode(sample.id)
    assertNear(curve(0, {}), 100, 0.01)
end)

test("sample node extracts y from point", function()
    local editor = Editor.new()
    local point = createNode(editor, "point")

    local constX = createNode(editor, "const")
    setKnob(constX, "value", 100)
    local constY = createNode(editor, "const")
    setKnob(constY, "value", 200)

    editor:addCable(constX.id, "out", point.id, "x")
    editor:addCable(constY.id, "out", point.id, "y")

    local sample = createNode(editor, "sample")
    setToggle(sample, "axis", 2)  -- y
    editor:addCable(point.id, "entity", sample.id, "entity")

    local curve = editor:evaluateNode(sample.id)
    assertNear(curve(0, {}), 200, 0.01)
end)

--------------------------------------------------------------------------------
-- Category 4: Macro Chains
--------------------------------------------------------------------------------

test("macro creation from selection", function()
    local editor = Editor.new()

    -- Create a simple chain: const -> transform (scale)
    local const = createNode(editor, "const")
    setKnob(const, "value", 10)

    local scale = createNode(editor, "transform")
    setToggle(scale, "op", 1)  -- scale
    setKnob(scale, "value", 2)
    editor:addCable(const.id, "out", scale.id, "in")

    -- Select both and create macro
    editor.selectedNodes = {[const.id] = true, [scale.id] = true}
    editor:createMacroFromSelection()

    -- Find the macro node
    local macroNode = nil
    for _, node in pairs(editor.nodes) do
        if node.type == "macro" then
            macroNode = node
            break
        end
    end
    assertTrue(macroNode ~= nil, "macro should be created")
    assertTrue(macroNode.macroData ~= nil, "macro should have macroData")
end)

test("macro ungroup restores nodes", function()
    local editor = Editor.new()

    -- Create and group nodes
    local const = createNode(editor, "const")
    setKnob(const, "value", 10)

    local scale = createNode(editor, "transform")
    setToggle(scale, "op", 1)  -- scale
    setKnob(scale, "value", 2)
    editor:addCable(const.id, "out", scale.id, "in")

    -- Count nodes before
    local nodeCountBefore = 0
    for _ in pairs(editor.nodes) do nodeCountBefore = nodeCountBefore + 1 end

    -- Create macro
    editor.selectedNodes = {[const.id] = true, [scale.id] = true}
    editor:createMacroFromSelection()

    -- Should have 1 macro node now
    local nodeCountAfterGroup = 0
    local macroId = nil
    for id, node in pairs(editor.nodes) do
        nodeCountAfterGroup = nodeCountAfterGroup + 1
        if node.type == "macro" then macroId = id end
    end
    assertEq(nodeCountAfterGroup, 1, "should have 1 node after grouping")

    -- Ungroup
    editor:ungroupMacro(macroId)

    -- Should have 2 nodes again
    local nodeCountAfterUngroup = 0
    for _ in pairs(editor.nodes) do nodeCountAfterUngroup = nodeCountAfterUngroup + 1 end
    assertEq(nodeCountAfterUngroup, 2, "should have 2 nodes after ungrouping")
end)

--------------------------------------------------------------------------------
-- Category 5: Edge Cases
--------------------------------------------------------------------------------

test("disconnected input uses default", function()
    local editor = Editor.new()
    local scale = createNode(editor, "transform")
    setToggle(scale, "op", 1)  -- scale
    setKnob(scale, "value", 5)
    -- No input connected

    local curve = editor:evaluateNode(scale.id)
    -- Default input should be 0, scaled by 5 = 0
    assertNear(curve(0, {}), 0, 0.01)
end)

test("cache invalidation on cable change", function()
    local editor = Editor.new()
    local const1 = createNode(editor, "const")
    setKnob(const1, "value", 10)
    local const2 = createNode(editor, "const")
    setKnob(const2, "value", 20)
    local scale = createNode(editor, "transform")
    setToggle(scale, "op", 1)  -- scale
    setKnob(scale, "value", 1)

    editor:addCable(const1.id, "out", scale.id, "in")
    local curve1 = editor:evaluateNode(scale.id)
    assertNear(curve1(0, {}), 10, 0.01)

    -- Rewire to const2
    editor:addCable(const2.id, "out", scale.id, "in")
    local curve2 = editor:evaluateNode(scale.id)
    assertNear(curve2(0, {}), 20, 0.01)
end)

test("knob value change affects output", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 10)

    local curve1 = editor:evaluateNode(const.id)
    assertNear(curve1(0, {}), 10, 0.01)

    -- Change knob
    setKnob(const, "value", 50)
    editor:invalidateCache()

    local curve2 = editor:evaluateNode(const.id)
    assertNear(curve2(0, {}), 50, 0.01)
end)

test("multiple outputs from same node", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 5)

    local scale1 = createNode(editor, "transform")
    setToggle(scale1, "op", 1)  -- scale
    setKnob(scale1, "value", 2)
    editor:addCable(const.id, "out", scale1.id, "in")

    local scale2 = createNode(editor, "transform")
    setToggle(scale2, "op", 1)  -- scale
    setKnob(scale2, "value", 3)
    editor:addCable(const.id, "out", scale2.id, "in")

    local curve1 = editor:evaluateNode(scale1.id)
    local curve2 = editor:evaluateNode(scale2.id)

    assertNear(curve1(0, {}), 10, 0.01)  -- 5 * 2
    assertNear(curve2(0, {}), 15, 0.01)  -- 5 * 3
end)

test("chain of three nodes", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 2)

    local scale1 = createNode(editor, "transform")
    setToggle(scale1, "op", 1)  -- scale
    setKnob(scale1, "value", 3)
    editor:addCable(const.id, "out", scale1.id, "in")

    local scale2 = createNode(editor, "transform")
    setToggle(scale2, "op", 1)  -- scale
    setKnob(scale2, "value", 4)
    editor:addCable(scale1.id, "out", scale2.id, "in")

    local curve = editor:evaluateNode(scale2.id)
    assertNear(curve(0, {}), 24, 0.01)  -- 2 * 3 * 4
end)

--------------------------------------------------------------------------------
-- Category 6: Presets
--------------------------------------------------------------------------------

test("listPresets returns preset names", function()
    local editor = Editor.new()
    local presets = editor:listPresets()
    assertTrue(#presets >= 10, "should have at least 10 presets: got " .. #presets)

    -- Check some known presets exist
    local found = {}
    for _, name in ipairs(presets) do
        found[name] = true
    end
    assertTrue(found.orbit, "should have orbit preset")
    assertTrue(found.breathe, "should have breathe preset")
    assertTrue(found.wobble, "should have wobble preset")
end)

test("createPreset orbit creates macro with correct ports", function()
    local editor = Editor.new()
    local macro = editor:createPreset("orbit", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.type, "macro", "should be macro type")
    assertEq(macro.label, "Orbit", "should be labeled Orbit")

    -- Check inputs
    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.speed, "should have speed input")
    assertTrue(inputNames.radius, "should have radius input")

    -- Check outputs
    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.x, "should have x output")
    assertTrue(outputNames.y, "should have y output")
end)

test("createPreset breathe creates macro with tempo input", function()
    local editor = Editor.new()
    local macro = editor:createPreset("breathe", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Breathe", "should be labeled Breathe")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.tempo, "should have tempo input")
end)

test("createPreset freqBands creates macro with 3 outputs", function()
    local editor = Editor.new()
    local macro = editor:createPreset("freqBands", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Freq Bands", "should be labeled Freq Bands")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.low, "should have low output")
    assertTrue(outputNames.mid, "should have mid output")
    assertTrue(outputNames.high, "should have high output")
end)

test("createPreset colorCycle creates macro with color output", function()
    local editor = Editor.new()
    local macro = editor:createPreset("colorCycle", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Color Cycle", "should be labeled Color Cycle")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.colorOut, "should have colorOut output")
end)

test("createPreset returns nil for unknown preset", function()
    local editor = Editor.new()
    local macro = editor:createPreset("nonexistent", 100, 100)
    assertTrue(macro == nil, "should return nil for unknown preset")
end)

test("createPreset pingPong creates macro with speed input", function()
    local editor = Editor.new()
    local macro = editor:createPreset("pingPong", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Ping Pong", "should be labeled Ping Pong")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.speed, "should have speed input")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.out, "should have out output")
end)

test("createPreset spiral creates macro with x,y outputs", function()
    local editor = Editor.new()
    local macro = editor:createPreset("spiral", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Spiral", "should be labeled Spiral")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.x, "should have x output")
    assertTrue(outputNames.y, "should have y output")
end)

test("createPreset stutter creates macro with in/clock inputs", function()
    local editor = Editor.new()
    local macro = editor:createPreset("stutter", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Stutter", "should be labeled Stutter")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames["in"], "should have in input")
    assertTrue(inputNames.clock, "should have clock input")
end)

test("createPreset rampReset creates macro with speed/clock inputs", function()
    local editor = Editor.new()
    local macro = editor:createPreset("rampReset", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Ramp Reset", "should be labeled Ramp Reset")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.speed, "should have speed input")
    assertTrue(inputNames.clock, "should have clock input")
end)

test("createPreset valueMap creates macro with in/range/min inputs", function()
    local editor = Editor.new()
    local macro = editor:createPreset("valueMap", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Value Map", "should be labeled Value Map")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames["in"], "should have in input")
    assertTrue(inputNames.range, "should have range input")
    assertTrue(inputNames.min, "should have min input")
end)

test("createPreset swell creates macro with tempo input", function()
    local editor = Editor.new()
    local macro = editor:createPreset("swell", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Swell", "should be labeled Swell")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.tempo, "should have tempo input")
end)

test("listPresets returns at least 23 presets", function()
    local editor = Editor.new()
    local presets = editor:listPresets()
    assertTrue(#presets >= 23, "should have at least 23 presets: got " .. #presets)
end)

test("presets appear in nodeDefs for palette", function()
    local editor = Editor.new()

    -- Count preset entries in nodeDefs
    local presetCount = 0
    local hasPresetCategory = false
    for _, def in ipairs(editor.nodeDefs) do
        if def.category == "preset" then
            hasPresetCategory = true
            presetCount = presetCount + 1
            assertTrue(def.isPreset, "preset entry should have isPreset=true")
            assertTrue(def.presetName ~= nil, "preset entry should have presetName")
        end
    end

    assertTrue(hasPresetCategory, "should have preset category in nodeDefs")
    assertTrue(presetCount >= 23, "should have at least 23 preset entries: got " .. presetCount)
end)

--------------------------------------------------------------------------------
-- Category 7: New Nodes & Presets
--------------------------------------------------------------------------------

test("split node outputs same value on all ports", function()
    local editor = Editor.new()
    local const = createNode(editor, "const")
    setKnob(const, "value", 42)

    local split = createNode(editor, "split")
    editor:addCable(const.id, "out", split.id, "in")

    -- Evaluate each output
    local curveA = editor:evaluateNode(split.id, nil, "a")
    local curveB = editor:evaluateNode(split.id, nil, "b")
    local curveC = editor:evaluateNode(split.id, nil, "c")

    assertNear(curveA(0, {}), 42, 0.01)
    assertNear(curveB(0, {}), 42, 0.01)
    assertNear(curveC(0, {}), 42, 0.01)
end)

test("createPreset beatDetect creates macro", function()
    local editor = Editor.new()
    local macro = editor:createPreset("beatDetect", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Beat Detect", "should be labeled Beat Detect")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.out, "should have out output")
end)

test("createPreset ducking creates macro with in input", function()
    local editor = Editor.new()
    local macro = editor:createPreset("ducking", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Ducking", "should be labeled Ducking")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames["in"], "should have in input")
end)

test("createPreset audioGate creates macro with in input", function()
    local editor = Editor.new()
    local macro = editor:createPreset("audioGate", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Audio Gate", "should be labeled Audio Gate")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames["in"], "should have in input")
end)

test("createPreset pulsingCircle creates macro with form output", function()
    local editor = Editor.new()
    local macro = editor:createPreset("pulsingCircle", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Pulsing Circle", "should be labeled Pulsing Circle")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.tempo, "should have tempo input")
    assertTrue(inputNames.baseRadius, "should have baseRadius input")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.form, "should have form output")
end)

test("createPreset rotatingPolygon creates macro with form output", function()
    local editor = Editor.new()
    local macro = editor:createPreset("rotatingPolygon", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Rotating Polygon", "should be labeled Rotating Polygon")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.speed, "should have speed input")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.form, "should have form output")
end)

test("createPreset breathingRect creates macro with form output", function()
    local editor = Editor.new()
    local macro = editor:createPreset("breathingRect", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Breathing Rect", "should be labeled Breathing Rect")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.tempo, "should have tempo input")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.form, "should have form output")
end)

test("createPreset audioCircle creates macro with form output", function()
    local editor = Editor.new()
    local macro = editor:createPreset("audioCircle", 100, 100)

    assertTrue(macro ~= nil, "should create macro")
    assertEq(macro.label, "Audio Circle", "should be labeled Audio Circle")

    local inputNames = {}
    for _, inp in ipairs(macro.inputs) do
        inputNames[inp.name] = true
    end
    assertTrue(inputNames.sensitivity, "should have sensitivity input")
    assertTrue(inputNames.baseRadius, "should have baseRadius input")

    local outputNames = {}
    for _, out in ipairs(macro.outputs) do
        outputNames[out.name] = true
    end
    assertTrue(outputNames.form, "should have form output")
end)

--------------------------------------------------------------------------------
-- Run Tests
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
