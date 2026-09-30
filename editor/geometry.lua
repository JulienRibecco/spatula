--- editor.geometry - Node geometry calculations
--- @module spatula.editor.geometry

local Constants = require("spatula.editor.constants")

local NODE_W = Constants.NODE_W
local NODE_H_BASE = Constants.NODE_H_BASE
local PORT_SPACING = Constants.PORT_SPACING
local NODE_PREVIEW_H = Constants.NODE_PREVIEW_H

local Geometry = {}

-- Check if a knob should be visible based on toggle state
local function isKnobVisible(node, knobName)
    -- Distribution: count for random/grid, spacing for poisson/hex
    if node.type == "dist" then
        local pattern = node.toggleValues and node.toggleValues.pattern or 1
        if knobName == "count" then return pattern <= 2 end
        if knobName == "spacing" then return pattern >= 3 end
    end
    -- Transform: value only for scale/offset, not abs/neg
    if node.type == "transform" then
        local op = node.toggleValues and node.toggleValues.op or 1
        if knobName == "value" then return op <= 2 end
    end
    -- Stats: scale only for integral
    if node.type == "stats" then
        local stat = node.toggleValues and node.toggleValues.stat or 1
        if knobName == "scale" then return stat == 3 end
    end
    return true
end

-- Count visible knobs for a node
local function countVisibleKnobs(node)
    if not node.knobs then return 0 end
    local count = 0
    for _, knob in ipairs(node.knobs) do
        if isKnobVisible(node, knob.name) then
            count = count + 1
        end
    end
    return count
end

--- Calculate the base height of a node (without preview)
--- @param node table The node
--- @return number Height in pixels
function Geometry.nodeHeight(node)
    local rows = math.max(#node.inputs, #node.outputs)
    local knobRows = countVisibleKnobs(node)
    local toggleRows = node.toggles and #node.toggles or 0
    local buttonRow = (node.buttons and #node.buttons > 0) and 1 or 0
    return NODE_H_BASE + rows * PORT_SPACING + knobRows * 20 + toggleRows * 20 + buttonRow * 24
end

--- Calculate the full height of a node (including preview)
--- @param node table The node
--- @return number Height in pixels
function Geometry.nodeHeightWithPreview(node)
    local h = Geometry.nodeHeight(node)
    if node.type ~= "xy_output" then
        h = h + NODE_PREVIEW_H
    end
    return h
end

--- Get the screen position of a port
--- @param node table The node
--- @param portName string Name of the port
--- @param isInput boolean True for input port, false for output
--- @return number, number X, Y position
function Geometry.portPos(node, portName, isInput)
    local list = isInput and node.inputs or node.outputs
    local x = isInput and node.x or (node.x + NODE_W)
    local baseY = node.y + 30
    for i, p in ipairs(list) do
        if p.name == portName then
            return x, baseY + (i - 1) * PORT_SPACING
        end
    end
    return x, baseY
end

--- Get the Y position where knobs start in a node
--- @param node table The node
--- @return number Y position
function Geometry.knobStartY(node)
    return node.y + 30 + math.max(#node.inputs, #node.outputs) * PORT_SPACING + 4
end

--- Get the bounding box of a node
--- @param node table The node
--- @return number, number, number, number x, y, width, height
function Geometry.nodeBounds(node)
    return node.x, node.y, NODE_W, Geometry.nodeHeightWithPreview(node)
end

return Geometry
