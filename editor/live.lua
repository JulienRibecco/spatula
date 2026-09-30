--- editor/live.lua - Claude Code Live Co-Pilot Integration
---
--- Enables bidirectional communication between the Spatula editor and Claude Code:
---   1. Export: graph.json + preview.png for Claude Code to observe
---   2. Import: edits.json with commands Claude Code proposes
---   3. Confirmation: auto-accept or manual Y/N approval
---   4. Undo: revert last applied edit batch
---
--- Usage:
---   In Editor:load():   Live.init(self)
---   In Editor:update(): Live.update(dt)
---   In Editor:draw():   Live.draw()
---   In Editor:keypressed(): Live.keypressed(key)

local Live = {}

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

Live.POLL_INTERVAL = 0.5  -- seconds between edit file checks
Live.MODE_AUTO = "auto"
Live.MODE_CONFIRM = "confirm"

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

Live.editor = nil
Live.exportDir = nil
Live.mode = Live.MODE_AUTO  -- Auto-accept edits (user confirms via Claude Code interface)
Live.pollTimer = 0
Live.lastEditTime = 0
Live.pendingEdits = nil
Live.tempIdMap = {}  -- Maps tempId string -> real node ID
Live.tempIdCounter = 0
Live.undoStack = {}  -- Stack of {nodes, cables} snapshots
Live.maxUndoLevels = 10
Live.errors = {}
Live.statusMessage = nil
Live.statusTimer = 0
Live.hasErrors = false

--------------------------------------------------------------------------------
-- JSON SERIALIZATION (reused from compiler/ir.lua)
--------------------------------------------------------------------------------

local JSON = require("spatula.json")
local toJSON, fromJSON = JSON.encode, JSON.decode

Live.toJSON = toJSON
Live.fromJSON = fromJSON

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

function Live.init(editor)
    Live.editor = editor
    Live.exportDir = "live"  -- Relative to love.filesystem save directory

    -- Create export directory
    love.filesystem.createDirectory(Live.exportDir)

    -- Initial export
    Live.exportState()

    Live.setStatus("Live co-pilot ready (E=export, M=mode, R=refresh)")
end

function Live.setStatus(msg)
    Live.statusMessage = msg
    Live.statusTimer = 3  -- Show for 3 seconds
end

--------------------------------------------------------------------------------
-- EXPORT SYSTEM
--------------------------------------------------------------------------------

function Live.exportState()
    Live.exportGraph()
    Live.capturePreview()
    Live.setStatus("Exported state to " .. Live.getExportPath())
end

function Live.getExportPath()
    return love.filesystem.getSaveDirectory() .. "/" .. Live.exportDir
end

function Live.exportGraph()
    local editor = Live.editor
    local nodes = {}

    -- Serialize each node
    for id, node in pairs(editor.nodes) do
        local nodeData = {
            id = id,
            type = node.type,
            label = node.label,
            x = node.x,
            y = node.y,
            inputs = {},
            outputs = {},
            knobs = {}
        }

        -- Serialize inputs
        for _, inp in ipairs(node.inputs) do
            nodeData.inputs[#nodeData.inputs + 1] = {
                name = inp.name,
                connected = inp.connected
            }
        end

        -- Serialize outputs
        for _, out in ipairs(node.outputs) do
            nodeData.outputs[#nodeData.outputs + 1] = {
                name = out.name
            }
        end

        -- Serialize knob values
        for name, value in pairs(node.knobValues) do
            nodeData.knobs[name] = value
        end

        -- Signal key if applicable
        if node.signalKey then
            nodeData.signalKey = node.signalKey
        end

        -- Macro data for macro nodes
        if node.type == "macro" and node.macroData then
            nodeData.macroData = node.macroData
        end

        nodes[#nodes + 1] = nodeData
    end

    -- Serialize cables
    local cables = {}
    for _, cable in ipairs(editor.cables) do
        cables[#cables + 1] = {
            fromNode = cable.fromNode,
            fromPort = cable.fromPort,
            toNode = cable.toNode,
            toPort = cable.toPort
        }
    end

    local graph = {
        version = "1.0.0",
        exportTime = os.time(),
        editorTime = editor.time,
        screenSize = {
            width = editor.screenW,
            height = editor.screenH
        },
        nodes = nodes,
        cables = cables
    }

    local json = toJSON(graph)
    love.filesystem.write(Live.exportDir .. "/graph.json", json)
end

function Live.capturePreview()
    love.graphics.captureScreenshot(function(imageData)
        imageData:encode("png", Live.exportDir .. "/preview.png")
    end)
end

--------------------------------------------------------------------------------
-- IMPORT SYSTEM
--------------------------------------------------------------------------------

function Live.checkForEdits()
    local editsPath = Live.exportDir .. "/edits.json"
    local info = love.filesystem.getInfo(editsPath)

    if not info then return false end

    -- Check if file was modified since last check
    if info.modtime and info.modtime <= Live.lastEditTime then
        return false
    end

    local content = love.filesystem.read(editsPath)
    if not content or content == "" or content == "{}" then
        return false
    end

    local ok, edits = pcall(fromJSON, content)
    if not ok then
        Live.setStatus("Error parsing edits.json: " .. tostring(edits))
        return false
    end

    -- Validate structure
    if not edits.commands or #edits.commands == 0 then
        return false
    end

    -- Version check
    if edits.version and edits.version ~= "1.0.0" then
        Live.setStatus("Unsupported edits version: " .. tostring(edits.version))
        return false
    end

    Live.lastEditTime = info.modtime or os.time()
    Live.pendingEdits = edits

    if Live.mode == Live.MODE_AUTO then
        Live.applyEdits()
    else
        Live.setStatus("Pending edits: " .. #edits.commands .. " commands (Y=accept, N=reject)")
    end

    return true
end

function Live.resolveNodeId(id)
    if type(id) == "string" then
        return Live.tempIdMap[id]
    end
    return id
end

function Live.generateTempId()
    Live.tempIdCounter = Live.tempIdCounter + 1
    return "_new" .. Live.tempIdCounter
end

--------------------------------------------------------------------------------
-- UNDO STACK
--------------------------------------------------------------------------------

function Live.pushUndoState()
    local editor = Live.editor

    -- Count nodes to estimate if this is a large graph
    local nodeCount = 0
    for _ in pairs(editor.nodes) do nodeCount = nodeCount + 1 end

    -- For very large graphs (100+), warn about memory usage
    -- Future optimization: use command-based undo instead of snapshot
    if nodeCount > 100 and #Live.undoStack >= Live.maxUndoLevels then
        -- Remove oldest to make room (already at limit)
        table.remove(Live.undoStack, 1)
    end

    -- Deep copy nodes (minimal data needed for restore)
    local nodesCopy = {}
    for id, node in pairs(editor.nodes) do
        local nodeCopy = {
            id = node.id,
            type = node.type,
            x = node.x,
            y = node.y,
            knobValues = {},
        }
        -- Copy knob values (usually small table)
        for k, v in pairs(node.knobValues) do
            nodeCopy.knobValues[k] = v
        end
        -- Only copy signalKey if present
        if node.signalKey then
            nodeCopy.signalKey = node.signalKey
        end
        -- Copy macroData for macro nodes
        if node.type == "macro" and node.macroData then
            nodeCopy.macroData = node.macroData
        end
        nodesCopy[id] = nodeCopy
    end

    -- Copy cables (4 fields each, typically few cables)
    local cablesCopy = {}
    local cables = editor.cables
    for i = 1, #cables do
        local c = cables[i]
        cablesCopy[i] = {
            fromNode = c.fromNode,
            fromPort = c.fromPort,
            toNode = c.toNode,
            toPort = c.toPort
        }
    end

    -- Copy draw order (just integers)
    local drawOrderCopy = {}
    local drawOrder = editor.drawOrder
    for i = 1, #drawOrder do
        drawOrderCopy[i] = drawOrder[i]
    end

    -- Push state
    Live.undoStack[#Live.undoStack + 1] = {
        nodes = nodesCopy,
        cables = cablesCopy,
        drawOrder = drawOrderCopy,
        nextNodeId = editor.nextNodeId
    }

    -- Limit stack size
    while #Live.undoStack > Live.maxUndoLevels do
        table.remove(Live.undoStack, 1)
    end
end

function Live.undo()
    if #Live.undoStack == 0 then
        Live.setStatus("Nothing to undo")
        return
    end

    local state = table.remove(Live.undoStack)
    local editor = Live.editor

    -- Restore nodes
    editor.nodes = {}
    for id, nodeData in pairs(state.nodes) do
        local def = nil
        for _, d in ipairs(editor.nodeDefs) do
            if d.type == nodeData.type then
                def = d
                break
            end
        end
        if def then
            local node = {
                id = id,
                type = def.type,
                label = def.label,
                color = def.color or {0.3, 0.3, 0.35},
                inputs = {},
                outputs = {},
                knobs = {},
                knobValues = {},
                x = nodeData.x,
                y = nodeData.y,
                buildCurve = def.buildCurve,
                _cachedCurve = nil
            }
            if def.inputs then
                for _, inp in ipairs(def.inputs) do
                    node.inputs[#node.inputs + 1] = {name = inp, connected = false}
                end
            end
            if def.outputs then
                for _, out in ipairs(def.outputs) do
                    node.outputs[#node.outputs + 1] = {name = out}
                end
            end
            if def.knobs then
                for _, k in ipairs(def.knobs) do
                    node.knobs[#node.knobs + 1] = {name = k.name, min = k.min, max = k.max}
                    node.knobValues[k.name] = nodeData.knobValues[k.name] or k.default
                end
            end
            if nodeData.signalKey then
                node.signalKey = nodeData.signalKey
            end
            -- Restore macroData for macro nodes
            if nodeData.macroData then
                node.macroData = nodeData.macroData
                -- Also restore dynamic inputs/outputs for macros
                node.inputs = {}
                for name in pairs(nodeData.macroData.inputMap or {}) do
                    node.inputs[#node.inputs + 1] = {name = name, connected = false}
                end
                node.outputs = {}
                for name in pairs(nodeData.macroData.outputMap or {}) do
                    node.outputs[#node.outputs + 1] = {name = name}
                end
            end
            editor.nodes[id] = node
        end
    end

    -- Restore cables and update connected state
    editor.cables = state.cables
    for _, cable in ipairs(editor.cables) do
        local toNode = editor.nodes[cable.toNode]
        if toNode then
            for _, inp in ipairs(toNode.inputs) do
                if inp.name == cable.toPort then
                    inp.connected = true
                end
            end
        end
    end

    -- Restore draw order and nextNodeId
    editor.drawOrder = state.drawOrder
    editor.nextNodeId = state.nextNodeId

    editor:invalidateCache()
    if editor._onGraphChanged then
        editor:_onGraphChanged()
    end

    Live.setStatus("Undone last edit batch")
end

--------------------------------------------------------------------------------
-- APPLY EDITS
--------------------------------------------------------------------------------

function Live.applyEdits()
    if not Live.pendingEdits then return end

    -- Push current state to undo stack
    Live.pushUndoState()

    local edits = Live.pendingEdits
    Live.tempIdMap = {}
    Live.tempIdCounter = 0  -- Reset counter for each batch
    Live.errors = {}

    for i, cmd in ipairs(edits.commands) do
        local ok, err = Live.applyCommand(cmd, i)
        if not ok then
            Live.errors[#Live.errors + 1] = {
                commandIndex = i,
                op = cmd.op,
                error = err,
                details = cmd
            }
        end
    end

    -- Clear edits file
    love.filesystem.write(Live.exportDir .. "/edits.json", "{}")

    -- Build status message with description
    local desc = edits.description and (edits.description .. " - ") or ""

    -- Write errors if any, or clear old errors file
    if #Live.errors > 0 then
        Live.writeErrors()
        Live.setStatus(string.format("%s%d/%d commands failed", desc, #Live.errors, #edits.commands))
        Live.hasErrors = true
    else
        -- Clear old errors file on success
        love.filesystem.remove(Live.exportDir .. "/errors.json")
        Live.setStatus(string.format("%sApplied %d commands", desc, #edits.commands))
        Live.hasErrors = false
    end

    Live.pendingEdits = nil

    -- Notify graph changed
    Live.editor:invalidateCache()
    if Live.editor._onGraphChanged then
        Live.editor:_onGraphChanged()
    end

    -- Re-export state with new graph and preview
    Live.exportGraph()
    Live.capturePreview()
end

function Live.rejectEdits()
    if Live.pendingEdits then
        -- Clear edits file
        love.filesystem.write(Live.exportDir .. "/edits.json", "{}")
        Live.pendingEdits = nil
        Live.setStatus("Rejected pending edits")
    end
end

function Live.applyCommand(cmd, index)
    local editor = Live.editor

    if cmd.op == "add_node" then
        -- Find node definition
        local def = nil
        for _, d in ipairs(editor.nodeDefs) do
            if d.type == cmd.type then
                def = d
                break
            end
        end
        if not def then
            return false, "Unknown node type: " .. tostring(cmd.type)
        end

        -- Calculate position (supports relative positioning)
        local x = cmd.x or 200
        local y = cmd.y or 200
        local NODE_W = 155
        local NODE_H = 150  -- Approximate node height

        -- Relative positioning: right_of, left_of, below, above
        local refNode = nil
        if cmd.right_of then
            local refId = Live.resolveNodeId(cmd.right_of)
            refNode = refId and editor.nodes[refId]
            if refNode then
                x = refNode.x + NODE_W + (cmd.offset_x or 50)
                y = refNode.y + (cmd.offset_y or 0)
            end
        elseif cmd.left_of then
            local refId = Live.resolveNodeId(cmd.left_of)
            refNode = refId and editor.nodes[refId]
            if refNode then
                x = refNode.x - NODE_W - (cmd.offset_x or 50)
                y = refNode.y + (cmd.offset_y or 0)
            end
        elseif cmd.below then
            local refId = Live.resolveNodeId(cmd.below)
            refNode = refId and editor.nodes[refId]
            if refNode then
                x = refNode.x + (cmd.offset_x or 0)
                y = refNode.y + NODE_H + (cmd.offset_y or 30)
            end
        elseif cmd.above then
            local refId = Live.resolveNodeId(cmd.above)
            refNode = refId and editor.nodes[refId]
            if refNode then
                x = refNode.x + (cmd.offset_x or 0)
                y = refNode.y - NODE_H - (cmd.offset_y or 30)
            end
        end

        local node = editor:createNode(def, x, y)

        -- Apply initial knob values
        if cmd.knobs then
            for name, value in pairs(cmd.knobs) do
                if node.knobValues[name] ~= nil then
                    for _, k in ipairs(node.knobs) do
                        if k.name == name then
                            node.knobValues[name] = math.max(k.min, math.min(k.max, value))
                            break
                        end
                    end
                end
            end
        end

        -- Store temp ID mapping
        if cmd.tempId then
            Live.tempIdMap[cmd.tempId] = node.id
        end

        return true

    elseif cmd.op == "delete_node" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        if not nodeId or not editor.nodes[nodeId] then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        editor:removeNode(nodeId)
        return true

    elseif cmd.op == "move_node" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        -- Clamp to screen bounds
        node.x = math.max(125, math.min(editor.screenW - 160, cmd.x or node.x))
        node.y = math.max(4, math.min(editor.screenH - 100, cmd.y or node.y))
        return true

    elseif cmd.op == "set_knob" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        if node.knobValues[cmd.knob] == nil then
            return false, "Knob not found: " .. tostring(cmd.knob)
        end
        -- Validate and clamp value
        for _, k in ipairs(node.knobs) do
            if k.name == cmd.knob then
                node.knobValues[cmd.knob] = math.max(k.min, math.min(k.max, cmd.value))
                break
            end
        end
        return true

    elseif cmd.op == "set_toggle" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        if not node.toggleValues then
            return false, "Node has no toggles: " .. tostring(cmd.nodeId)
        end
        if node.toggleValues[cmd.toggle] == nil then
            return false, "Toggle not found: " .. tostring(cmd.toggle)
        end
        -- Set the toggle value (bool or int for multi-option)
        node.toggleValues[cmd.toggle] = cmd.value
        -- Invalidate cache since toggles can affect output
        editor:invalidateCache()
        return true

    elseif cmd.op == "set_property" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        -- Set arbitrary property on node (e.g., keywords, datasetPath, oscAddress)
        node[cmd.property] = cmd.value
        -- Invalidate cache since property changes can affect output
        editor:invalidateCache()
        return true

    elseif cmd.op == "click_button" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node then
            return false, "Node not found: " .. tostring(cmd.nodeId)
        end
        -- Trigger button action (e.g., prev/next on dataset_loader)
        if editor.onButtonClick then
            editor:onButtonClick(nodeId, cmd.button)
        end
        return true

    elseif cmd.op == "add_cable" then
        local fromId = Live.resolveNodeId(cmd.fromNode)
        local toId = Live.resolveNodeId(cmd.toNode)

        if not editor.nodes[fromId] then
            return false, "Source node not found: " .. tostring(cmd.fromNode)
        end
        if not editor.nodes[toId] then
            return false, "Target node not found: " .. tostring(cmd.toNode)
        end

        -- Validate port exists
        local fromNode = editor.nodes[fromId]
        local toNode = editor.nodes[toId]
        local fromPortExists = false
        local toPortExists = false

        for _, out in ipairs(fromNode.outputs) do
            if out.name == cmd.fromPort then fromPortExists = true; break end
        end
        for _, inp in ipairs(toNode.inputs) do
            if inp.name == cmd.toPort then toPortExists = true; break end
        end

        if not fromPortExists then
            return false, "Output port not found: " .. tostring(cmd.fromPort)
        end
        if not toPortExists then
            return false, "Input port not found: " .. tostring(cmd.toPort)
        end

        editor:addCable(fromId, cmd.fromPort, toId, cmd.toPort)
        return true

    elseif cmd.op == "remove_cable" then
        local toId = Live.resolveNodeId(cmd.toNode)
        local cable = editor:findCableToInput(toId, cmd.toPort)
        if not cable then
            return false, "Cable not found to: " .. tostring(cmd.toNode) .. "." .. tostring(cmd.toPort)
        end

        -- Remove the cable
        for i = #editor.cables, 1, -1 do
            if editor.cables[i].toNode == toId and editor.cables[i].toPort == cmd.toPort then
                table.remove(editor.cables, i)
                break
            end
        end

        -- Update connected state
        local toNode = editor.nodes[toId]
        if toNode then
            for _, inp in ipairs(toNode.inputs) do
                if inp.name == cmd.toPort then
                    inp.connected = false
                    break
                end
            end
        end

        return true

    elseif cmd.op == "set_signal_key" then
        local nodeId = Live.resolveNodeId(cmd.nodeId)
        local node = editor.nodes[nodeId]
        if not node or node.type ~= "signal" then
            return false, "Signal node not found: " .. tostring(cmd.nodeId)
        end
        node.signalKey = cmd.key
        editor:invalidateCache()
        return true

    elseif cmd.op == "reload" then
        -- Full hot-reload: clear ALL modules and rebuild editor in-place
        Live.setStatus("Full reload...")

        -- Save current state
        local savedNodes = {}
        for id, node in pairs(editor.nodes) do
            savedNodes[id] = {
                type = node.type, x = node.x, y = node.y,
                knobValues = node.knobValues,
                toggleValues = node.toggleValues,
                signalKey = node.signalKey,
                datasetPath = node.datasetPath,
                macroData = node.macroData,
            }
        end
        local savedCables = {}
        for _, cable in ipairs(editor.cables) do
            savedCables[#savedCables + 1] = {
                fromNode = cable.fromNode, fromPort = cable.fromPort,
                toNode = cable.toNode, toPort = cable.toPort
            }
        end
        local savedNextId = editor.nextNodeId
        local savedCamera = {x = editor.cameraX, y = editor.cameraY, zoom = editor.zoom}
        local savedTime = editor.time

        -- Clear ALL spatula modules (including editor)
        local cleared = 0
        for name, _ in pairs(package.loaded) do
            if name:match("^spatula") and not name:match("live") then
                package.loaded[name] = nil
                cleared = cleared + 1
            end
        end

        -- Re-require editor to get fresh module
        local ok, EditorModule = pcall(require, "spatula.editor")
        if not ok then
            Live.setStatus("FAILED: " .. tostring(EditorModule):sub(1, 40))
            return false, "Module error: " .. tostring(EditorModule)
        end

        -- Create fresh instance to get new methods/definitions
        local fresh = EditorModule.new()

        -- Copy new methods to existing editor (keeps main.lua reference valid)
        for k, v in pairs(fresh) do
            if type(v) == "function" then
                editor[k] = v
            end
        end
        local mt = getmetatable(fresh)
        if mt and mt.__index then
            for k, v in pairs(mt.__index) do
                if type(v) == "function" then
                    editor[k] = v
                end
            end
        end

        -- Update node definitions
        editor.nodeDefs = fresh.nodeDefs
        editor.buildNodeDefs = fresh.buildNodeDefs

        -- Rebuild nodes with fresh definitions
        editor.nodes = {}
        editor.drawOrder = {}
        editor.nextNodeId = 1
        for id, saved in pairs(savedNodes) do
            local def = nil
            for _, d in ipairs(editor.nodeDefs) do
                if d.type == saved.type then def = d; break end
            end
            if def then
                local rebuilt = editor:createNode(def, saved.x, saved.y)
                editor.nodes[rebuilt.id] = nil
                rebuilt.id = id
                editor.nodes[id] = rebuilt
                -- Restore knob values
                for k, v in pairs(saved.knobValues or {}) do
                    if rebuilt.knobValues[k] ~= nil then
                        rebuilt.knobValues[k] = v
                    end
                end
                -- Restore toggle values
                for k, v in pairs(saved.toggleValues or {}) do
                    if rebuilt.toggleValues and rebuilt.toggleValues[k] ~= nil then
                        rebuilt.toggleValues[k] = v
                    end
                end
                rebuilt.signalKey = saved.signalKey
                rebuilt.datasetPath = saved.datasetPath
                -- Restore macroData for macro nodes
                if saved.macroData then
                    rebuilt.macroData = saved.macroData
                    rebuilt.inputs = {}
                    for name in pairs(saved.macroData.inputMap or {}) do
                        rebuilt.inputs[#rebuilt.inputs + 1] = {name = name, connected = false}
                    end
                    rebuilt.outputs = {}
                    for name in pairs(saved.macroData.outputMap or {}) do
                        rebuilt.outputs[#rebuilt.outputs + 1] = {name = name}
                    end
                end
            end
        end
        editor.nextNodeId = savedNextId

        -- Restore cables
        editor.cables = {}
        for _, cable in ipairs(savedCables) do
            if editor.nodes[cable.fromNode] and editor.nodes[cable.toNode] then
                editor:addCable(cable.fromNode, cable.fromPort, cable.toNode, cable.toPort)
            end
        end

        -- Restore state
        editor.cameraX = savedCamera.x
        editor.cameraY = savedCamera.y
        editor.zoom = savedCamera.zoom
        editor.time = savedTime
        editor:invalidateCache()

        Live.setStatus(string.format("Full reload: %d modules", cleared))
        return true
    end

    return false, "Unknown operation: " .. tostring(cmd.op)
end

function Live.writeErrors()
    local errorsData = {
        timestamp = os.time(),
        errors = Live.errors
    }
    local json = toJSON(errorsData)
    love.filesystem.write(Live.exportDir .. "/errors.json", json)
end

--------------------------------------------------------------------------------
-- UPDATE & DRAW
--------------------------------------------------------------------------------

function Live.update(dt)
    -- Poll for edits
    Live.pollTimer = Live.pollTimer + dt
    if Live.pollTimer >= Live.POLL_INTERVAL then
        Live.pollTimer = 0
        Live.checkForEdits()
        -- Write heartbeat file so Claude can check if editor is running
        local heartbeat = toJSON({
            timestamp = os.time(),
            editorTime = Live.editor.time or 0,
            mode = Live.mode
        })
        love.filesystem.write(Live.exportDir .. "/heartbeat.json", heartbeat)
    end

    -- Update status message timer
    if Live.statusTimer > 0 then
        Live.statusTimer = Live.statusTimer - dt
    end
end

function Live.draw()
    local screenW = Live.editor.screenW
    local screenH = Live.editor.screenH

    -- Draw status indicator (top right)
    love.graphics.setColor(0.15, 0.15, 0.2, 0.8)
    love.graphics.rectangle("fill", screenW - 160, 5, 155, 20, 4)

    local modeColor = Live.mode == Live.MODE_AUTO and {0.3, 0.8, 0.4} or {0.8, 0.6, 0.3}
    love.graphics.setColor(modeColor[1], modeColor[2], modeColor[3], 1)
    love.graphics.print("Live: " .. Live.mode, screenW - 155, 8)

    -- Draw status message (red background for errors)
    if Live.statusMessage and Live.statusTimer > 0 then
        local alpha = math.min(1, Live.statusTimer)
        if Live.hasErrors then
            love.graphics.setColor(0.4, 0.1, 0.1, 0.95 * alpha)
        else
            love.graphics.setColor(0.1, 0.1, 0.15, 0.9 * alpha)
        end
        love.graphics.rectangle("fill", screenW / 2 - 200, screenH - 35, 400, 25, 4)
        if Live.hasErrors then
            love.graphics.setColor(1, 0.7, 0.7, alpha)
        else
            love.graphics.setColor(0.9, 0.9, 0.95, alpha)
        end
        love.graphics.printf(Live.statusMessage, screenW / 2 - 195, screenH - 30, 390, "center")
    end

    -- Draw confirmation overlay
    if Live.pendingEdits and Live.mode == Live.MODE_CONFIRM then
        Live.drawConfirmationUI()
    end
end

function Live.drawConfirmationUI()
    local screenW = Live.editor.screenW
    local screenH = Live.editor.screenH
    local edits = Live.pendingEdits

    -- Overlay
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    -- Panel
    local panelW, panelH = 500, 400
    local panelX = (screenW - panelW) / 2
    local panelY = (screenH - panelH) / 2

    love.graphics.setColor(0.15, 0.15, 0.2, 0.95)
    love.graphics.rectangle("fill", panelX, panelY, panelW, panelH, 10)

    love.graphics.setColor(0.4, 0.4, 0.5, 1)
    love.graphics.rectangle("line", panelX, panelY, panelW, panelH, 10)

    -- Header
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Claude Code - Pending Edits", panelX + 20, panelY + 15)

    if edits.description then
        love.graphics.setColor(0.7, 0.7, 0.8, 1)
        love.graphics.printf(edits.description, panelX + 20, panelY + 40, panelW - 40, "left")
    end

    -- Command list
    local y = panelY + 70
    love.graphics.setColor(0.5, 0.5, 0.6, 1)
    love.graphics.print(string.format("%d commands:", #edits.commands), panelX + 20, y)
    y = y + 25

    for i, cmd in ipairs(edits.commands) do
        if y > panelY + panelH - 80 then
            love.graphics.print("...", panelX + 30, y)
            break
        end

        local summary = Live.summarizeCommand(cmd)
        love.graphics.setColor(0.8, 0.8, 0.9, 1)
        love.graphics.print(string.format("%d. %s", i, summary), panelX + 30, y)
        y = y + 20
    end

    -- Buttons
    local btnY = panelY + panelH - 50

    -- Accept button
    love.graphics.setColor(0.2, 0.5, 0.3, 1)
    love.graphics.rectangle("fill", panelX + 80, btnY, 120, 35, 5)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Accept (Y)", panelX + 105, btnY + 8)

    -- Reject button
    love.graphics.setColor(0.5, 0.2, 0.2, 1)
    love.graphics.rectangle("fill", panelX + 300, btnY, 120, 35, 5)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Reject (N)", panelX + 325, btnY + 8)
end

function Live.summarizeCommand(cmd)
    if cmd.op == "add_node" then
        if cmd.right_of then
            return string.format("Add %s right of %s", cmd.type, tostring(cmd.right_of))
        elseif cmd.left_of then
            return string.format("Add %s left of %s", cmd.type, tostring(cmd.left_of))
        elseif cmd.below then
            return string.format("Add %s below %s", cmd.type, tostring(cmd.below))
        elseif cmd.above then
            return string.format("Add %s above %s", cmd.type, tostring(cmd.above))
        end
        return string.format("Add %s at (%d, %d)", cmd.type, cmd.x or 0, cmd.y or 0)
    elseif cmd.op == "delete_node" then
        return string.format("Delete node %s", tostring(cmd.nodeId))
    elseif cmd.op == "move_node" then
        return string.format("Move %s to (%d, %d)", tostring(cmd.nodeId), cmd.x or 0, cmd.y or 0)
    elseif cmd.op == "set_knob" then
        return string.format("Set %s.%s = %.2f", tostring(cmd.nodeId), cmd.knob or "?", cmd.value or 0)
    elseif cmd.op == "set_toggle" then
        return string.format("Toggle %s.%s = %s", tostring(cmd.nodeId), cmd.toggle or "?", tostring(cmd.value))
    elseif cmd.op == "set_property" then
        local val = type(cmd.value) == "string" and ('"' .. cmd.value .. '"') or tostring(cmd.value)
        return string.format("Set %s.%s = %s", tostring(cmd.nodeId), cmd.property or "?", val)
    elseif cmd.op == "click_button" then
        return string.format("Click %s.%s", tostring(cmd.nodeId), cmd.button or "?")
    elseif cmd.op == "add_cable" then
        return string.format("Wire %s.%s -> %s.%s",
            tostring(cmd.fromNode), cmd.fromPort or "?", tostring(cmd.toNode), cmd.toPort or "?")
    elseif cmd.op == "remove_cable" then
        return string.format("Disconnect %s.%s", tostring(cmd.toNode), cmd.toPort or "?")
    elseif cmd.op == "set_signal_key" then
        return string.format("Set signal %s key = '%s'", tostring(cmd.nodeId), cmd.key or "?")
    elseif cmd.op == "reload" then
        return "Hot reload code"
    end
    return cmd.op or "unknown"
end

--------------------------------------------------------------------------------
-- KEYBOARD
--------------------------------------------------------------------------------

function Live.keypressed(key)
    -- Handle confirmation dialog first
    if Live.pendingEdits and Live.mode == Live.MODE_CONFIRM then
        if key == "y" then
            Live.applyEdits()
            return true
        elseif key == "n" then
            Live.rejectEdits()
            return true
        end
    end

    -- General controls
    if key == "e" then
        Live.exportState()
        return true
    elseif key == "r" then
        -- Manual refresh
        if Live.checkForEdits() then
            Live.setStatus("Found new edits")
        else
            Live.setStatus("No new edits")
        end
        return true
    elseif key == "m" then
        Live.mode = (Live.mode == Live.MODE_AUTO) and Live.MODE_CONFIRM or Live.MODE_AUTO
        Live.setStatus("Mode: " .. Live.mode)
        return true
    elseif key == "z" then
        Live.undo()
        return true
    end

    return false
end

return Live
