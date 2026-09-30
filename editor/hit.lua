--- editor.hit - Hit testing for nodes, ports, knobs, toggles, buttons, palette
--- @module spatula.editor.hit

local Constants = require("spatula.editor.constants")
local Geometry = require("spatula.editor.geometry")

local NODE_W = Constants.NODE_W
local PORT_R = Constants.PORT_R
local PORT_SPACING = Constants.PORT_SPACING
local PALETTE_W = Constants.PALETTE_W
local PALETTE_ITEM_H = Constants.PALETTE_ITEM_H

local Hit = {}

-- Check if a knob should be visible based on toggle state
local function isKnobVisible(node, knobName)
    if node.type == "dist" then
        local pattern = node.toggleValues and node.toggleValues.pattern or 1
        if knobName == "count" then return pattern <= 2 end
        if knobName == "spacing" then return pattern >= 3 end
    end
    if node.type == "transform" then
        local op = node.toggleValues and node.toggleValues.op or 1
        if knobName == "value" then return op <= 2 end
    end
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

--- Hit test for ports (inputs and outputs)
--- @param nodes table All nodes
--- @param wx number World X coordinate
--- @param wy number World Y coordinate
--- @return table|nil Port info {nodeId, portName, isInput, x, y} or nil
function Hit.port(nodes, wx, wy)
    for _, node in pairs(nodes) do
        for _, out in ipairs(node.outputs) do
            local px, py = Geometry.portPos(node, out.name, false)
            if (wx-px)*(wx-px) + (wy-py)*(wy-py) < (PORT_R+4)*(PORT_R+4) then
                return {nodeId=node.id, portName=out.name, isInput=false, x=px, y=py}
            end
        end
        for _, inp in ipairs(node.inputs) do
            local px, py = Geometry.portPos(node, inp.name, true)
            if (wx-px)*(wx-px) + (wy-py)*(wy-py) < (PORT_R+4)*(PORT_R+4) then
                return {nodeId=node.id, portName=inp.name, isInput=true, x=px, y=py}
            end
        end
    end
    return nil
end

--- Hit test for nodes (respects draw order for z-ordering)
--- @param nodes table All nodes
--- @param drawOrder table Draw order array
--- @param wx number World X coordinate
--- @param wy number World Y coordinate
--- @return table|nil Node or nil
function Hit.node(nodes, drawOrder, wx, wy)
    for i = #drawOrder, 1, -1 do
        local node = nodes[drawOrder[i]]
        if node then
            local h = Geometry.nodeHeightWithPreview(node)
            if wx >= node.x and wx <= node.x + NODE_W and wy >= node.y and wy <= node.y + h then
                return node
            end
        end
    end
    return nil
end

--- Hit test for knobs (skips hidden knobs)
--- @param nodes table All nodes
--- @param wx number World X coordinate
--- @param wy number World Y coordinate
--- @return table|nil Knob info {nodeId, knobIdx, knobName, sliderX, sliderW} or nil
function Hit.knob(nodes, wx, wy)
    for _, node in pairs(nodes) do
        local knobY = Geometry.knobStartY(node)
        local visibleIdx = 0
        for i, knob in ipairs(node.knobs) do
            if isKnobVisible(node, knob.name) then
                visibleIdx = visibleIdx + 1
                local kx = node.x + 8 + 70
                local ky = knobY + (visibleIdx - 1) * 20
                local sw = NODE_W - 86
                if wx >= kx - 4 and wx <= kx + sw + 4 and wy >= ky and wy <= ky + 14 then
                    return {nodeId = node.id, knobIdx = i, knobName = knob.name, sliderX = kx, sliderW = sw}
                end
            end
        end
    end
    return nil
end

--- Hit test for toggles (multi-option or boolean)
--- @param nodes table All nodes
--- @param wx number World X coordinate
--- @param wy number World Y coordinate
--- @return table|nil Toggle info or nil
function Hit.toggle(nodes, wx, wy)
    for _, node in pairs(nodes) do
        if not node.toggles or #node.toggles == 0 then goto continue end
        local knobY = Geometry.knobStartY(node)
        local toggleY = knobY + countVisibleKnobs(node) * 20
        for i, toggle in ipairs(node.toggles) do
            local ty = toggleY + (i - 1) * 20
            local tx = node.x + 8
            if toggle.options then
                -- Multi-option: check each pill
                local optX = tx + 45
                local optW = math.floor((NODE_W - 60) / #toggle.options)
                for j, opt in ipairs(toggle.options) do
                    local bx = optX + (j - 1) * optW
                    if wx >= bx and wx <= bx + optW - 2 and wy >= ty + 1 and wy <= ty + 15 then
                        return {nodeId = node.id, toggleIdx = i, toggleName = toggle.name, optionIdx = j}
                    end
                end
            else
                -- Boolean: check checkbox area
                local cbX = node.x + NODE_W - 24
                if wx >= cbX and wx <= cbX + 14 and wy >= ty + 1 and wy <= ty + 15 then
                    return {nodeId = node.id, toggleIdx = i, toggleName = toggle.name, isBoolean = true}
                end
            end
        end
        ::continue::
    end
    return nil
end

--- Hit test for buttons
--- @param nodes table All nodes
--- @param wx number World X coordinate
--- @param wy number World Y coordinate
--- @return table|nil Button info {nodeId, buttonIdx, buttonName} or nil
function Hit.button(nodes, wx, wy)
    for _, node in pairs(nodes) do
        if not node.buttons or #node.buttons == 0 then goto continue end
        local knobY = Geometry.knobStartY(node)
        local toggleY = knobY + countVisibleKnobs(node) * 20
        local buttonY = toggleY + (#node.toggles or 0) * 20
        local btnW = math.floor((NODE_W - 16) / #node.buttons)
        for i, btn in ipairs(node.buttons) do
            local bx = node.x + 8 + (i - 1) * btnW
            if wx >= bx and wx <= bx + btnW - 4 and wy >= buttonY + 2 and wy <= buttonY + 20 then
                return {nodeId = node.id, buttonIdx = i, buttonName = btn.name}
            end
        end
        ::continue::
    end
    return nil
end

--- Hit test for palette items
--- @param nodeDefs table Node definitions
--- @param mx number Screen X coordinate (not world)
--- @param my number Screen Y coordinate (not world)
--- @return number|nil Index of hit item or nil
function Hit.paletteItem(nodeDefs, mx, my)
    if mx > PALETTE_W then return nil end
    local py = 30
    local lastCat = nil
    for i, d in ipairs(nodeDefs) do
        if d.category ~= lastCat then
            lastCat = d.category
            py = py + 18
        end
        if my >= py and my < py + PALETTE_ITEM_H then
            return i
        end
        py = py + PALETTE_ITEM_H
    end
    return nil
end

return Hit
