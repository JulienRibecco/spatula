--- spatula.editor — Reusable node-based graph editor for Spatula
---
--- A visual graph editor for composing Spatula curves, motions, forms, and
--- distributions. Provides the complete node system, cable wiring, palette,
--- evaluation engine, and rendering. Consumers create an editor instance and
--- forward LÖVE callbacks to it.
---
--- Usage:
---   local Editor = require("spatula.editor")
---   local editor = Editor.new()
---   -- in love.load:
---   editor:load(screenW, screenH)
---   -- in love.update:
---   editor:update(dt)
---   -- in love.draw:
---   editor:draw()
---   -- forward mouse/key:
---   editor:mousepressed(x, y, btn)
---   editor:mousereleased(x, y, btn)
---   editor:mousemoved(x, y)
---   editor:keypressed(key)
---
--- After wiring changes, call editor:buildMotion() to get the composed
--- Motion function, or use editor:onGraphChanged(fn) to register a callback.
---
--- ─── ARCHITECTURE ───────────────────────────────────────────────────────
---
--- The graph is made of Nodes and Cables.
---
---   Node: a typed unit with input ports, output ports, and knobs.
---         Each node carries a `buildCurve(inputs, knobValues)` that returns
---         a Curve closure. Source nodes ignore inputs; combinators compose
---         them. The closure captures the live knobValues *table reference*
---         (not a snapshot), so dragging a knob smoothly morphs the output
---         without rebuilding the graph or clearing the trail — the same
---         principle as Spatula's Signal system.
---
---   Cable: connects one output port to one input port. Evaluation walks
---          cables recursively (with cycle guard) to assemble the final
---          composed curve. Cycles are detected and visually flagged with
---          red cables.
---
--- ─── NODE CATEGORIES ────────────────────────────────────────────────────
---
---   Sources (leaf nodes, no inputs):
---     sin, cos       — periodic oscillators (freq, amp knobs)
---     triangle, saw  — non-sinusoidal periodic waves
---     square         — binary pulse wave
---     noise          — deterministic pseudo-noise (sum of incommensurate sines)
---     linear         — unbounded ramp (speed knob)
---     const          — fixed value
---
---   Combinators (transform / merge curves):
---     add, mul       — binary arithmetic on two curves
---     scale, offset  — unary: multiply or shift by a knob value
---     timeScale      — warp the time axis (speed up / slow down)
---     abs, neg       — unary shape transforms
---     clamp          — restrict to min/max knob range
---
---   Triggers (time-conditional combinators):
---     gate           — pass signal during duty phase, zero otherwise
---     S&H            — sample input on integer clock crossings, hold between
---     reset          — restart input from t=0 each clock cycle (retriggered LFO)
---     envelope       — attack/release envelope per clock cycle
---     All take "in" + "t" (clock curve) inputs. Wire linear/saw for steady
---     tempo, oscillators for swing, noise for probability. These are just
---     combinators that care about integer crossings or phase of the clock.
---     S&H state resets on cache invalidation (cable changes) — intentional.
---     Envelope: attack + release can sum > 1, eliminating the silent phase.
---
---   Motion output (Motion.xy):
---     A pass-through node with x/y inputs AND x/y outputs.
---     Inputs receive composed curves → evaluated as the 2D motion.
---     Outputs forward those curves downstream so forms can use them.
---
---   Forms (geometric containment):
---     circle (cx, cy, r)    — all parameters are curve inputs, not knobs.
---     rect   (cx, cy, w, h)   Forms are "just combinations of two curves"
---                              so every dimension is driven by upstream
---                              waveforms.
---
---   Distributions (point generation inside a form):
---     random, grid   — count knob controls density
---     poisson, hex   — spacing knob controls regularity
---     Each takes a "form" input port.
---
--- ─── PREVIEWS ───────────────────────────────────────────────────────────
---
---   Inline card preview (inside every node except xy_output):
---     Source / combinator → waveform plot (4 seconds, normalized to ±200)
---     Form               → animated shape outline, cx/cy driven by inputs
---     Distribution        → scatter dots inside faint form outline
---     Shows what THIS node alone produces.
---
---   Chain preview (circular bubble above hovered node):
---     Shows the accumulated upstream result up to this node.
---     Curve nodes → composed waveform, xy_output → motion trail,
---     form → animated shape with offsets, dist → full scatter.
---     Only appears when the node is far enough from the top edge.
---
--- ─── INTERACTION ────────────────────────────────────────────────────────
---
---   Palette (left sidebar):
---     Drag an item onto the canvas to spawn a node.
---
---   Wiring:
---     Drag from an output port to an input port to connect.
---     Drag from a connected input port to detach and re-route.
---     Type-safe: only compatible ports snap (curve↔curve, form↔form).
---     While dragging, nearby valid input ports glow (snap-to-port, 25px).
---     The cable visually snaps to the nearest target within range.
---     Press ESC to cancel a wiring drag.
---     Cycles are detected and cables turn red.
---
---   Knobs:
---     Click or drag the slider to change a value.
---     Hold Shift while dragging for fine-tuning (0.15× sensitivity).
---     Changes are immediate — closures read live knob values.
---
---   Node management:
---     Right-click a node to delete it (and its cables).
---     Right-click a connected input port to disconnect that cable.
---     Nodes are clamped to the visible canvas area.
---     Clicked nodes come to front (z-order via draw list).
---
---   Keyboard:
---     R     — reset (fires onGraphChanged callback)
---     ESC   — cancel active wiring
---
--- ─── DESIGN CHOICES ─────────────────────────────────────────────────────
---
---   • Live knob closures over rebuild: buildCurve returns a function that
---     reads knobValues[name] at eval time. No graph rebuild on knob drag,
---     no trail clear, no stutter. This mirrors Spatula's Signal pattern.
---
---   • Forms as curve inputs: forms have no knobs. cx, cy, r/w/h are all
---     input ports wired to curves. This keeps the "everything is a curve"
---     philosophy consistent and lets you animate form parameters.
---
---   • xy_output as pass-through: it has both inputs and outputs so the
---     same composed curves that define the motion can feed downstream
---     into form cx/cy inputs, enabling the full pipeline in one graph.
---
---   • Snap-to-port wiring: reduces precision frustration. The cable
---     visually locks onto the nearest valid port within range, and
---     releasing anywhere in that radius completes the connection.
---
---   • Type-safe wiring: port names are classified (curve/form/pts) and
---     only matching types can connect. Prevents nonsensical cables.
---
---   • Z-ordered draw list: nodes render back-to-front via a separate
---     drawOrder array. Clicking a node brings it to front. Hit testing
---     iterates in reverse so the topmost node wins.
---
---   • Cycle detection with visual feedback: evaluateNode tracks visited
---     nodes; cycles return Curve.const(0) and mark the node, causing
---     connected cables to render in red.
---
---   • Per-node colors: each source type has a distinct hue so the graph
---     is scannable at a glance (greens for trig, blues for angular waves,
---     purple for square, warm for noise, neutral for const/linear).
---
---   • Cache note: _cachedCurve invalidates on cable changes only. The
---     built-in nodes are pure (knobValues + inputs), so this is safe.
---     If you add custom nodes that read external state (e.g. Signal
---     globals), call editor:invalidateCache() when that state changes.

local Curve = require("spatula.curve")
local Motion = require("spatula.motion")
local Forms = require("spatula.forms")
local Distribution = require("spatula.distribution")
local Signal = require("spatula.signal")
local Tempo = require("spatula.tempo")
local Audio = require("spatula.audio")
local Trigger = require("spatula.trigger")
local Field = require("spatula.field")
local Live = require("spatula.editor.live")
local TextInput = require("spatula.src.text.input")
local TextNodes = require("spatula.src.text.nodes")
local ClockNodes = require("spatula.src.clock.nodes")
local OSC = require("spatula.osc")
local FileWatcher = require("spatula.file_watcher")
local AudioFFT = require("spatula.audio_fft")

-- Extracted modules
local Constants = require("spatula.editor.constants")
local Types = require("spatula.editor.types")
local Camera = require("spatula.editor.camera")
local Geometry = require("spatula.editor.geometry")
local Hit = require("spatula.editor.hit")
local NodeDefs = require("spatula.editor.nodes")
local Presets = require("spatula.editor.presets")

local Editor = {}
Editor.__index = Editor

--------------------------------------------------------------------------------
-- CONSTANTS (from extracted module)
--------------------------------------------------------------------------------

local NODE_W = Constants.NODE_W
local NODE_H_BASE = Constants.NODE_H_BASE
local PORT_R = Constants.PORT_R
local PORT_SPACING = Constants.PORT_SPACING
local PREVIEW_NORM = Constants.PREVIEW_NORM
local PREVIEW_STEPS = Constants.PREVIEW_STEPS
local NODE_PREVIEW_H = Constants.NODE_PREVIEW_H
local PALETTE_W = Constants.PALETTE_W
local PALETTE_ITEM_H = Constants.PALETTE_ITEM_H
local PI2 = Constants.PI2

local sin, cos, abs = math.sin, math.cos, math.abs

-- Re-export from Types module
local hslToRgb = Types.hslToRgb
local portWireType = Types.portWireType

--------------------------------------------------------------------------------
-- NODE DEFINITIONS (extracted to editor/nodes/init.lua)
--------------------------------------------------------------------------------

-- Local alias for buildNodeDefs (for backward compatibility with hot-reload)
local buildNodeDefs = NodeDefs.buildDefs

-- NOTE: The following ~1000 lines of node definitions have been moved to
-- editor/nodes/init.lua for better maintainability. The NodeDefs.buildDefs()
-- function returns all 66+ node definitions.

--[[ REMOVED: 1000 lines of node definitions moved to editor/nodes/init.lua
     See editor/nodes/init.lua for all 66+ node type definitions.
]]

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function Editor.new()
    local self = setmetatable({}, Editor)
    self.nodes = {}
    self.drawOrder = {}
    self.cables = {}
    self.nextNodeId = 1
    self.cycleNodes = {}
    self.nodeDefs = buildNodeDefs()
    self.buildNodeDefs = buildNodeDefs  -- Expose for hot-reload

    -- Add preset entries to palette
    local presetColor = {0.4, 0.5, 0.35}
    for _, name in ipairs(Presets.list()) do
        local def = Presets.getDef(name)
        self.nodeDefs[#self.nodeDefs + 1] = {
            type = "preset_" .. name,
            label = def.name,
            category = "preset",
            color = presetColor,
            isPreset = true,
            presetName = name,
        }
    end
    self.screenW = 0
    self.screenH = 0
    self.time = 0

    -- Camera state (zoom/pan)
    self.camera = Camera.new()

    -- Selection state
    self.selectedNodes = {}  -- Set of selected node IDs: {[nodeId] = true}
    self.boxSelect = nil     -- {startX, startY, endX, endY} during box select drag
    self.groupDrag = nil     -- {offsets = {[nodeId] = {offX, offY}}} during group drag

    -- Interaction state
    self.dragging = nil
    self.wiring = nil
    self.hoverPort = nil
    self.snapPort = nil
    self.knobDrag = nil
    self.hoveredNode = nil
    self.paletteHover = nil
    self.spawnDrag = nil
    self.panning = nil       -- {startX, startY, camX, camY} during pan drag

    -- External data (set by consumer for chain preview of xy_output)
    self.trail = {}

    -- Debug overlay
    self.showDebugOverlay = false
    self.debugStats = {evalCount = 0, cacheHits = 0, lastEvalTime = 0}

    -- Callback
    self._onGraphChanged = nil
    return self
end

--- Register a callback fired whenever the graph topology changes.
--- fn receives (self) as argument.
function Editor:onGraphChanged(fn)
    self._onGraphChanged = fn
end

--------------------------------------------------------------------------------
-- CAMERA / COORDINATE CONVERSION
--------------------------------------------------------------------------------

--- Delegate camera methods (implementation in camera.lua module)
function Editor:screenToWorld(sx, sy)
    return self.camera:screenToWorld(sx, sy)
end

function Editor:worldToScreen(wx, wy)
    return self.camera:worldToScreen(wx, wy)
end

function Editor:resetCamera()
    self.camera:reset()
end

function Editor:setWorldScissor(wx, wy, ww, wh)
    self.camera:setWorldScissor(wx, wy, ww, wh)
end

--------------------------------------------------------------------------------
-- NODE SYSTEM
--------------------------------------------------------------------------------

-- Geometry helpers (from extracted module)
local nodeHeight = Geometry.nodeHeight
local nodeHeightWithPreview = Geometry.nodeHeightWithPreview
local portPos = Geometry.portPos

function Editor:createNode(def, x, y)
    local id = self.nextNodeId
    self.nextNodeId = self.nextNodeId + 1
    local node = {
        id = id,
        type = def.type,
        label = def.label,
        color = def.color or {0.3, 0.3, 0.35},
        inputs = {},
        outputs = {},
        knobs = {},
        knobValues = {},
        toggles = {},        -- Discrete option toggles
        toggleValues = {},   -- Current toggle selections
        buttons = {},        -- Clickable action buttons
        x = x, y = y,
        buildCurve = def.buildCurve,
        _cachedCurve = nil,
        signalKey = def.signalKey,  -- For signal nodes
        -- Copy custom properties (datasetPath, oscAddress, filePath, etc.)
        datasetPath = def.datasetPath,
        oscAddress = def.oscAddress,
        filePath = def.filePath,
        sourcePath = def.sourcePath,
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
            node.knobValues[k.name] = k.default
        end
    end
    -- Initialize toggles (discrete options or boolean)
    if def.toggles then
        for _, t in ipairs(def.toggles) do
            node.toggles[#node.toggles + 1] = {
                name = t.name,
                options = t.options,  -- nil for boolean, array for multi-option
                label = t.label or t.name
            }
            node.toggleValues[t.name] = t.default or (t.options and 1 or false)
        end
    end
    -- Initialize buttons (clickable actions)
    if def.buttons then
        for _, b in ipairs(def.buttons) do
            node.buttons[#node.buttons + 1] = {
                name = b.name,
                label = b.label or b.name
            }
        end
    end
    self.nodes[id] = node
    self.drawOrder[#self.drawOrder + 1] = id
    return node
end

function Editor:bringToFront(id)
    for i, did in ipairs(self.drawOrder) do
        if did == id then
            table.remove(self.drawOrder, i)
            self.drawOrder[#self.drawOrder + 1] = id
            return
        end
    end
end

function Editor:removeNode(id)
    local i = 1
    while i <= #self.cables do
        if self.cables[i].fromNode == id or self.cables[i].toNode == id then
            local c = self.cables[i]
            if self.nodes[c.toNode] then
                for _, inp in ipairs(self.nodes[c.toNode].inputs) do
                    if inp.name == c.toPort then inp.connected = false end
                end
            end
            table.remove(self.cables, i)
        else
            i = i + 1
        end
    end
    self.nodes[id] = nil
    for i, did in ipairs(self.drawOrder) do
        if did == id then table.remove(self.drawOrder, i) break end
    end
end

function Editor:findCableToInput(nodeId, portName)
    for _, c in ipairs(self.cables) do
        if c.toNode == nodeId and c.toPort == portName then
            return c
        end
    end
    return nil
end

function Editor:invalidateCache()
    for _, n in pairs(self.nodes) do
        n._cachedCurve = nil
    end
    self.cycleNodes = {}
end

--- Create a sub-editor instance from macro data for evaluation
--- @param macroData table The macro's internal graph data
--- @return table A minimal Editor-like object for curve evaluation
function Editor:_createSubEditor(macroData)
    local subEditor = {
        nodes = {},
        cables = {},
        drawOrder = {},
        cycleNodes = {},
        nodeDefs = self.nodeDefs,  -- Share node definitions
    }

    -- Copy methods needed for evaluation
    subEditor.evaluateNode = Editor.evaluateNode
    subEditor.findCableToInput = Editor.findCableToInput
    subEditor.invalidateCache = Editor.invalidateCache
    subEditor.resolveInputCurve = Editor.resolveInputCurve
    subEditor.getTransform = Editor.getTransform
    subEditor.evaluateFormNode = Editor.evaluateFormNode
    subEditor.generateDistributionPoints = Editor.generateDistributionPoints
    subEditor._createSubEditor = Editor._createSubEditor

    -- Restore nodes from snapshots
    for _, snapshot in ipairs(macroData.nodes or {}) do
        -- Find the node definition
        local def = nil
        for _, d in ipairs(self.nodeDefs) do
            if d.type == snapshot.type then
                def = d
                break
            end
        end
        if def then
            local node = {
                id = snapshot.id,
                type = snapshot.type,
                label = snapshot.label or def.label,
                color = def.color,
                x = snapshot.x or 0,
                y = snapshot.y or 0,
                inputs = {},
                outputs = {},
                knobs = {},
                knobValues = {},
                toggles = def.toggles and {} or nil,
                toggleValues = {},
                buttons = def.buttons,
                buildCurve = def.buildCurve,
                signalKey = snapshot.signalKey,
                _injectedInputs = {},  -- For macro input injection
            }

            -- Copy inputs/outputs structure
            for _, inp in ipairs(def.inputs or {}) do
                node.inputs[#node.inputs + 1] = {name = inp, connected = false}
            end
            for _, out in ipairs(def.outputs or {}) do
                node.outputs[#node.outputs + 1] = {name = out}
            end

            -- Copy knobs
            for _, k in ipairs(def.knobs or {}) do
                node.knobs[#node.knobs + 1] = {name = k.name, min = k.min, max = k.max}
                node.knobValues[k.name] = snapshot.knobValues and snapshot.knobValues[k.name] or k.default
            end

            -- Copy toggles
            if def.toggles then
                for _, t in ipairs(def.toggles) do
                    node.toggles[#node.toggles + 1] = t
                    node.toggleValues[t.name] = snapshot.toggleValues and snapshot.toggleValues[t.name] or t.default
                end
            end

            subEditor.nodes[node.id] = node
            subEditor.drawOrder[#subEditor.drawOrder + 1] = node.id
        end
    end

    -- Restore cables
    for _, cableData in ipairs(macroData.cables or {}) do
        subEditor.cables[#subEditor.cables + 1] = {
            fromNode = cableData.fromNode,
            fromPort = cableData.fromPort,
            toNode = cableData.toNode,
            toPort = cableData.toPort
        }
        -- Mark input as connected
        local toNode = subEditor.nodes[cableData.toNode]
        if toNode then
            for _, inp in ipairs(toNode.inputs) do
                if inp.name == cableData.toPort then
                    inp.connected = true
                end
            end
        end
    end

    return subEditor
end

function Editor:addCable(fromId, fromPort, toId, toPort)
    local i = 1
    while i <= #self.cables do
        if self.cables[i].toNode == toId and self.cables[i].toPort == toPort then
            for _, inp in ipairs(self.nodes[toId].inputs) do
                if inp.name == toPort then inp.connected = false end
            end
            table.remove(self.cables, i)
        else
            i = i + 1
        end
    end
    self.cables[#self.cables + 1] = {fromNode = fromId, fromPort = fromPort, toNode = toId, toPort = toPort}
    for _, inp in ipairs(self.nodes[toId].inputs) do
        if inp.name == toPort then inp.connected = true end
    end
    self:invalidateCache()
end

--------------------------------------------------------------------------------
-- GRAPH EVALUATION
--------------------------------------------------------------------------------

function Editor:evaluateNode(nodeId, visited, portName)
    local node = self.nodes[nodeId]
    if not node then return Curve.const(0) end

    -- Debug stats tracking
    if self.debugStats then
        self.debugStats.evalCount = (self.debugStats.evalCount or 0) + 1
    end

    visited = visited or {}
    if visited[nodeId] then
        self.cycleNodes[nodeId] = true
        return Curve.const(0)
    end
    visited[nodeId] = true

    if node.type == "xy_output" then
        local inputPort = portName or "x"
        local cable = self:findCableToInput(nodeId, inputPort)
        if cable then
            return self:evaluateNode(cable.fromNode, visited)
        end
        return Curve.const(0)
    end

    if node._cachedCurve then
        -- Debug: track cache hits
        if self.debugStats then
            self.debugStats.cacheHits = (self.debugStats.cacheHits or 0) + 1
        end
        -- For multi-output nodes, return the specific port's curve if requested
        if portName and type(node._cachedCurve) == "table" and not node._cachedCurve._isColor and not node._cachedCurve._isFieldSource then
            if node._cachedCurve[portName] then
                return node._cachedCurve[portName]
            end
        end
        return node._cachedCurve
    end

    -- Special handling for macro nodes (subgraphs)
    if node.type == "macro" and node.macroData then
        -- Lazy create sub-editor
        if not node._subEditor then
            node._subEditor = self:_createSubEditor(node.macroData)
        end

        local subEditor = node._subEditor
        local editor = self
        local macroData = node.macroData

        -- Build input curves from parent wiring
        local parentInputCurves = {}
        for _, inp in ipairs(node.inputs) do
            local cable = self:findCableToInput(nodeId, inp.name)
            if cable then
                parentInputCurves[inp.name] = self:evaluateNode(cable.fromNode, visited, cable.fromPort)
            end
        end

        -- Inject parent inputs into sub-editor nodes via _injectedCurve
        for inputName, mapping in pairs(macroData.inputMap or {}) do
            local internalNode = subEditor.nodes[mapping.nodeId]
            if internalNode and parentInputCurves[inputName] then
                -- Mark the internal node's input port to use the injected curve
                internalNode._injectedInputs = internalNode._injectedInputs or {}
                internalNode._injectedInputs[mapping.port] = parentInputCurves[inputName]
            end
        end

        -- Invalidate sub-editor cache to pick up injected curves
        subEditor:invalidateCache()

        -- Evaluate the output node(s) in sub-editor
        local outputCurves = {}
        for outputName, mapping in pairs(macroData.outputMap or {}) do
            outputCurves[outputName] = subEditor:evaluateNode(mapping.nodeId, {}, mapping.port)
        end

        -- Return single curve or table of curves
        if #node.outputs == 1 then
            node._cachedCurve = outputCurves[node.outputs[1].name]
        else
            node._cachedCurve = outputCurves
        end
        return node._cachedCurve
    end

    -- Special handling for modulation nodes that read entity transforms
    if node.type == "sample" then
        local entityCable = self:findCableToInput(nodeId, "entity")
        local entityNodeId = entityCable and entityCable.fromNode
        local editor = self
        local axis = node.toggleValues and node.toggleValues.axis or 1
        local curve = function(t, ctx)
            if entityNodeId then
                local cx, cy, rot, _ = editor:getTransform(entityNodeId, t, ctx)
                if axis == 1 then return cx end      -- x
                if axis == 2 then return cy end      -- y
                if axis == 3 then return rot * 180 / math.pi end  -- rot (degrees)
            end
            return 0
        end
        node._cachedCurve = curve
        return curve
    end

    if node.type == "distance" then
        local cableA = self:findCableToInput(nodeId, "entityA")
        local cableB = self:findCableToInput(nodeId, "entityB")
        local nodeIdA = cableA and cableA.fromNode
        local nodeIdB = cableB and cableB.fromNode
        local editor = self
        local curve = function(t, ctx)
            if nodeIdA and nodeIdB then
                local ax, ay = editor:getTransform(nodeIdA, t, ctx)
                local bx, by = editor:getTransform(nodeIdB, t, ctx)
                return math.sqrt((ax - bx)^2 + (ay - by)^2)
            end
            return 0
        end
        node._cachedCurve = curve
        return curve
    end

    if node.type == "angle_to" then
        local cableFrom = self:findCableToInput(nodeId, "from")
        local cableTo = self:findCableToInput(nodeId, "to")
        local nodeIdFrom = cableFrom and cableFrom.fromNode
        local nodeIdTo = cableTo and cableTo.fromNode
        local editor = self
        local curve = function(t, ctx)
            if nodeIdFrom and nodeIdTo then
                local fx, fy = editor:getTransform(nodeIdFrom, t, ctx)
                local tx, ty = editor:getTransform(nodeIdTo, t, ctx)
                return math.atan2(ty - fy, tx - fx) * 180 / math.pi  -- Return degrees
            end
            return 0
        end
        node._cachedCurve = curve
        return curve
    end

    if node.type == "signal" then
        local key = node.signalKey or "x"
        local default = node.knobValues.default or 0
        local curve = Signal.new(key, default)
        node._cachedCurve = curve
        return curve
    end

    -- Field source: adds a source to a field at a point position
    if node.type == "field_source" then
        local fieldCable = self:findCableToInput(nodeId, "fieldIn")
        local pointCable = self:findCableToInput(nodeId, "point")
        local fieldNodeId = fieldCable and fieldCable.fromNode
        local pointNodeId = pointCable and pointCable.fromNode
        local editor = self
        local k = node.knobValues

        -- Create a field wrapper that adds the source when sampled
        local result = {
            _isFieldSource = true,
            sourceNodeId = pointNodeId,
            fieldNodeId = fieldNodeId,
            radius = k.radius,
            value = k.value,
            getField = function(t, ctx)
                -- Get the upstream field
                local baseField
                if fieldNodeId then
                    local upstream = editor:evaluateNode(fieldNodeId, {})
                    if type(upstream) == "table" and upstream._isFieldSource then
                        baseField = upstream.getField(t, ctx)
                    elseif type(upstream) == "table" and upstream.sample then
                        baseField = upstream
                    else
                        baseField = Field.new({falloff = "smooth", blend = "add"})
                    end
                else
                    baseField = Field.new({falloff = "smooth", blend = "add"})
                end

                -- Get source position from connected point
                if pointNodeId then
                    -- Note: Field:add modifies in place, so we'd need to clone or rebuild
                    -- For now, return a sampling function that includes this source
                    return {
                        sample = function(x, y)
                            -- BUG FIX: Re-evaluate point position per-sample, not once at getField() time
                            -- This ensures animated point sources are properly tracked
                            local px, py = editor:getTransform(pointNodeId, t, ctx)
                            local base = baseField:sample(x, y)
                            local dist = math.sqrt((x - px)^2 + (y - py)^2)
                            if dist < k.radius then
                                local norm = dist / k.radius
                                local falloff = (1 - norm) * (1 - norm)  -- smooth falloff
                                return base + falloff * k.value
                            end
                            return base
                        end,
                        gradient = function(x, y)
                            return baseField:gradient(x, y)
                        end
                    }
                end
                return baseField
            end
        }
        node._cachedCurve = result
        return result
    end

    -- Field sample: samples field value at a point position
    if node.type == "field_sample" then
        local fieldCable = self:findCableToInput(nodeId, "field")
        local pointCable = self:findCableToInput(nodeId, "point")
        local fieldNodeId = fieldCable and fieldCable.fromNode
        local pointNodeId = pointCable and pointCable.fromNode
        local editor = self

        local curve = function(t, ctx)
            if not fieldNodeId or not pointNodeId then return 0 end

            -- Get field (could be raw Field or wrapped)
            local fieldObj = editor:evaluateNode(fieldNodeId, {})
            local field
            if type(fieldObj) == "table" and fieldObj._isFieldSource then
                field = fieldObj.getField(t, ctx)
            elseif type(fieldObj) == "table" and fieldObj.sample then
                field = fieldObj
            else
                return 0
            end

            -- Get sample position
            local px, py = editor:getTransform(pointNodeId, t, ctx)
            return field:sample(px, py)
        end
        node._cachedCurve = curve
        return curve
    end

    -- Field gradient: returns gradient direction at a point position
    if node.type == "field_gradient" then
        local fieldCable = self:findCableToInput(nodeId, "field")
        local pointCable = self:findCableToInput(nodeId, "point")
        local fieldNodeId = fieldCable and fieldCable.fromNode
        local pointNodeId = pointCable and pointCable.fromNode
        local editor = self
        local isGx = (portName == "gx" or portName == nil)

        local curve = function(t, ctx)
            if not fieldNodeId or not pointNodeId then return 0 end

            local fieldObj = editor:evaluateNode(fieldNodeId, {})
            local field
            if type(fieldObj) == "table" and fieldObj._isFieldSource then
                field = fieldObj.getField(t, ctx)
            elseif type(fieldObj) == "table" and (fieldObj.gradient or fieldObj.sample) then
                field = fieldObj
            else
                return 0
            end

            local px, py = editor:getTransform(pointNodeId, t, ctx)
            local gx, gy = 0, 0
            if field.gradient then
                gx, gy = field:gradient(px, py)
            end
            return isGx and gx or gy
        end
        node._cachedCurve = curve
        return curve
    end

    -- Color split: extracts r/g/b/a from a color input
    if node.type == "color_split" then
        local colorCable = self:findCableToInput(nodeId, "colorIn")
        local colorNodeId = colorCable and colorCable.fromNode
        local editor = self
        local component = portName or "r"

        local curve = function(t, ctx)
            if not colorNodeId then return 0 end
            local colorObj = editor:evaluateNode(colorNodeId, {})
            if type(colorObj) == "function" then
                colorObj = colorObj(t, ctx)
            end
            if type(colorObj) == "table" and colorObj._isColor then
                return colorObj[component] or 0
            end
            return 0
        end
        node._cachedCurve = curve
        return curve
    end

    -- Color mix: lerp between two colors by a scalar
    if node.type == "color_mix" then
        local cableA = self:findCableToInput(nodeId, "colorA")
        local cableB = self:findCableToInput(nodeId, "colorB")
        local cableMix = self:findCableToInput(nodeId, "mix")
        local nodeIdA = cableA and cableA.fromNode
        local nodeIdB = cableB and cableB.fromNode

        -- BUG FIX: Evaluate at build time with visited, not at runtime with {}
        local colorACurve = nodeIdA and self:evaluateNode(nodeIdA, visited) or nil
        local colorBCurve = nodeIdB and self:evaluateNode(nodeIdB, visited) or nil
        local mixCurve = cableMix and self:evaluateNode(cableMix.fromNode, visited) or Curve.const(0.5)

        local curve = function(t, ctx)
            local colorA = {r=0, g=0, b=0, a=1}
            local colorB = {r=1, g=1, b=1, a=1}

            if colorACurve then
                local ca = type(colorACurve) == "function" and colorACurve(t, ctx) or colorACurve
                if type(ca) == "table" and ca._isColor then colorA = ca end
            end

            if colorBCurve then
                local cb = type(colorBCurve) == "function" and colorBCurve(t, ctx) or colorBCurve
                if type(cb) == "table" and cb._isColor then colorB = cb end
            end

            local mix = mixCurve(t, ctx)
            if mix < 0 then mix = 0 elseif mix > 1 then mix = 1 end

            return {
                r = colorA.r + (colorB.r - colorA.r) * mix,
                g = colorA.g + (colorB.g - colorA.g) * mix,
                b = colorA.b + (colorB.b - colorA.b) * mix,
                a = colorA.a + (colorB.a - colorA.a) * mix,
                _isColor = true
            }
        end
        node._cachedCurve = curve
        return curve
    end

    -- Color pulse: oscillate between two colors
    if node.type == "color_pulse" then
        local cableA = self:findCableToInput(nodeId, "colorA")
        local cableB = self:findCableToInput(nodeId, "colorB")
        local nodeIdA = cableA and cableA.fromNode
        local nodeIdB = cableB and cableB.fromNode
        local freq = node.knobValues.freq

        -- BUG FIX: Evaluate at build time with visited, not at runtime with {}
        local colorACurve = nodeIdA and self:evaluateNode(nodeIdA, visited) or nil
        local colorBCurve = nodeIdB and self:evaluateNode(nodeIdB, visited) or nil

        local curve = function(t, ctx)
            local colorA = {r=0, g=0, b=0, a=1}
            local colorB = {r=1, g=1, b=1, a=1}

            if colorACurve then
                local ca = type(colorACurve) == "function" and colorACurve(t, ctx) or colorACurve
                if type(ca) == "table" and ca._isColor then colorA = ca end
            end

            if colorBCurve then
                local cb = type(colorBCurve) == "function" and colorBCurve(t, ctx) or colorBCurve
                if type(cb) == "table" and cb._isColor then colorB = cb end
            end

            local mix = (sin(t * freq * PI2) + 1) / 2

            return {
                r = colorA.r + (colorB.r - colorA.r) * mix,
                g = colorA.g + (colorB.g - colorA.g) * mix,
                b = colorA.b + (colorB.b - colorA.b) * mix,
                a = colorA.a + (colorB.a - colorA.a) * mix,
                _isColor = true
            }
        end
        node._cachedCurve = curve
        return curve
    end

    -- Audio color: hue cycling driven by audio input
    if node.type == "color_audio" then
        local audioCable = self:findCableToInput(nodeId, "audio")
        local audioCurve = audioCable and self:evaluateNode(audioCable.fromNode, visited) or Curve.const(0)
        local s = node.knobValues.saturation
        local l = node.knobValues.lightness
        local speed = node.knobValues.hueSpeed

        local curve = function(t, ctx)
            local audioVal = audioCurve(t, ctx)
            -- Normalize audio (assume 0-1 range, or scale if larger)
            if audioVal > 1 then audioVal = audioVal / 100 end
            local hue = (t * speed + audioVal) % 1
            local r, g, b = hslToRgb(hue, s, l)
            return {r=r, g=g, b=b, a=1, _isColor=true}
        end
        node._cachedCurve = curve
        return curve
    end

    local inputCurves = {}
    for _, inp in ipairs(node.inputs) do
        -- Check for injected curves from macro parent first
        if node._injectedInputs and node._injectedInputs[inp.name] then
            inputCurves[inp.name] = node._injectedInputs[inp.name]
        else
            local cable = self:findCableToInput(nodeId, inp.name)
            if cable then
                -- Pass cable.fromPort for multi-output nodes (e.g., dataset_loader.total)
                inputCurves[inp.name] = self:evaluateNode(cable.fromNode, visited, cable.fromPort)
            end
        end
    end

    local curve = node.buildCurve(inputCurves, node.knobValues, node)

    -- Handle multi-output nodes (buildCurve returns table of curves)
    -- e.g., audio_bands3 returns {low=curve, mid=curve, high=curve}
    if type(curve) == "table" and not curve._isColor and not curve._isFieldSource then
        node._cachedCurve = curve
        -- If portName specified, return specific output curve
        if portName and curve[portName] then
            return curve[portName]
        end
        return curve
    end

    node._cachedCurve = curve
    return curve
end

function Editor:resolveFormInput(nodeId, portName, default)
    local cable = self:findCableToInput(nodeId, portName)
    if cable then
        local curve = self:evaluateNode(cable.fromNode, {}, cable.fromPort)
        local ok, val = pcall(curve, 0, {})
        if ok then return val end
    end
    return default
end

--- Resolve an input curve at a specific time t with context ctx.
--- Returns the evaluated value or the default.
function Editor:resolveInputCurve(nodeId, portName, t, ctx, default)
    local cable = self:findCableToInput(nodeId, portName)
    if not cable then return default end
    local curve = self:evaluateNode(cable.fromNode, {}, cable.fromPort)
    local ok, val = pcall(curve, t or 0, ctx or {})
    return ok and val or default
end

--- Get the transform (cx, cy, rotation, scale) for an entity/form/point node at time t.
--- Returns cx, cy, rotation (radians), scale.
function Editor:getTransform(nodeId, t, ctx)
    local node = self.nodes[nodeId]
    if not node then return 0, 0, 0, 1 end

    -- Try cx/cy first (forms), then x/y (points)
    local cx = self:resolveInputCurve(nodeId, "cx", t, ctx, nil)
    if cx == nil then
        cx = self:resolveInputCurve(nodeId, "x", t, ctx, 0)
    end
    local cy = self:resolveInputCurve(nodeId, "cy", t, ctx, nil)
    if cy == nil then
        cy = self:resolveInputCurve(nodeId, "y", t, ctx, 0)
    end

    local rotDeg = self:resolveInputCurve(nodeId, "rotation", t, ctx, 0)
    local scale = self:resolveInputCurve(nodeId, "scale", t, ctx, 1)

    return cx, cy, rotDeg * math.pi / 180, scale
end

--- Evaluate a form node at time t with context ctx.
--- Returns (form, cx, cy, rotation, scale) where form is centered at origin.
--- The caller can apply cx/cy/rotation/scale transforms to the form's points.
function Editor:evaluateFormNode(nodeId, t, ctx)
    local node = self.nodes[nodeId]
    if not node then return nil end

    t = t or 0
    ctx = ctx or {}

    local cx, cy, rot, scale = self:getTransform(nodeId, t, ctx)

    if node.type == "form_circle" then
        local r = self:resolveInputCurve(nodeId, "r", t, ctx, 80) * scale
        return Forms.circle(0, 0, abs(r)), cx, cy, rot, scale
    elseif node.type == "form_rect" then
        local w = self:resolveInputCurve(nodeId, "w", t, ctx, 80) * scale
        local h = self:resolveInputCurve(nodeId, "h", t, ctx, 60) * scale
        return Forms.rect(0, 0, abs(w), abs(h)), cx, cy, rot, scale
    elseif node.type == "form_polygon" then
        local sides = math.floor(node.knobValues.sides or 6)
        local r = self:resolveInputCurve(nodeId, "r", t, ctx, 80) * scale
        return Forms.polygon(0, 0, sides, abs(r), 0), cx, cy, rot, scale
    end
    return nil
end

--- Generate distribution points at time t with context ctx.
--- Applies rotation/scale from distribution node inputs to the generated points.
function Editor:generateDistributionPoints(nodeId, t, ctx)
    local node = self.nodes[nodeId]
    if not node then return {} end

    t = t or 0
    ctx = ctx or {}

    local formCable = self:findCableToInput(nodeId, "form")
    if not formCable then return {} end
    local form, formCx, formCy, formRot, formScale = self:evaluateFormNode(formCable.fromNode, t, ctx)
    if not form then return {} end

    -- Get distribution-level rotation and scale
    local distRot = self:resolveInputCurve(nodeId, "rotation", t, ctx, 0) * math.pi / 180
    local distScale = self:resolveInputCurve(nodeId, "scale", t, ctx, 1)

    local points = {}
    local function push(x, y)
        points[#points + 1] = {x = x, y = y}
    end

    local k = node.knobValues
    local pattern = node.toggleValues and node.toggleValues.pattern or 1
    if pattern == 1 then      -- random
        Distribution.random(form, math.floor(k.count), push)
    elseif pattern == 2 then  -- grid
        Distribution.grid(form, math.floor(k.count), push)
    elseif pattern == 3 then  -- poisson
        Distribution.poisson(form, k.spacing, push)
    elseif pattern == 4 then  -- hex
        Distribution.hexGrid(form, k.spacing, push)
    end

    -- Apply combined rotation and scale to all points
    -- Total rotation = form rotation + distribution rotation
    -- Total scale = form scale * distribution scale (already applied to form, so just distScale here)
    local totalRot = (formRot or 0) + distRot
    local cos_r, sin_r = cos(totalRot), sin(totalRot)

    for _, pt in ipairs(points) do
        -- Apply distribution scale
        local x, y = pt.x * distScale, pt.y * distScale
        -- Apply total rotation
        pt.x = x * cos_r - y * sin_r + (formCx or 0)
        pt.y = x * sin_r + y * cos_r + (formCy or 0)
    end

    return points
end

--- Build a Motion.xy from the xy_output node in the graph.
--- Also returns scatter points from any connected distribution.
function Editor:buildMotion()
    local curveX = Curve.const(0)
    local curveY = Curve.const(0)

    for id, node in pairs(self.nodes) do
        if node.type == "xy_output" then
            local cableX = self:findCableToInput(id, "x")
            local cableY = self:findCableToInput(id, "y")
            if cableX then curveX = self:evaluateNode(cableX.fromNode) end
            if cableY then curveY = self:evaluateNode(cableY.fromNode) end
            break
        end
    end

    local scatterPoints = {}
    for id, node in pairs(self.nodes) do
        if node.type == "dist" then
            local points = self:generateDistributionPoints(id)
            if #points > 0 then
                scatterPoints = points
                break
            end
        end
    end

    return Motion.xy(curveX, curveY), scatterPoints
end

function Editor:_notifyGraphChanged()
    self:invalidateCache()
    if self._onGraphChanged then
        self._onGraphChanged(self)
    end
end

--------------------------------------------------------------------------------
-- MACRO (SUBGRAPH) OPERATIONS
--------------------------------------------------------------------------------

--- Deep copy a table (for knobValues, toggleValues)
function Editor:_deepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = self:_deepCopy(v)
    end
    return copy
end

--- Create a macro from currently selected nodes
function Editor:createMacroFromSelection()
    if not next(self.selectedNodes) then return end

    -- 1. Collect selected node IDs
    local selectedIds = {}
    for id in pairs(self.selectedNodes) do
        selectedIds[#selectedIds + 1] = id
    end
    if #selectedIds < 2 then return end  -- Need at least 2 nodes

    -- 2. Find boundary cables (crossing selection boundary)
    local inputMap = {}   -- {macroInputName → {nodeId, port}}
    local outputMap = {}  -- {macroOutputName → {nodeId, port}}
    local internalCables = {}
    local inputCounter, outputCounter = 1, 1

    for _, cable in ipairs(self.cables) do
        local fromInside = self.selectedNodes[cable.fromNode]
        local toInside = self.selectedNodes[cable.toNode]

        if fromInside and toInside then
            -- Internal cable - copy it
            internalCables[#internalCables + 1] = {
                fromNode = cable.fromNode,
                fromPort = cable.fromPort,
                toNode = cable.toNode,
                toPort = cable.toPort
            }
        elseif fromInside and not toInside then
            -- Output: internal → external
            local name = "out" .. (outputCounter > 1 and tostring(outputCounter) or "")
            outputMap[name] = {nodeId = cable.fromNode, port = cable.fromPort}
            outputCounter = outputCounter + 1
        elseif not fromInside and toInside then
            -- Input: external → internal
            local name = "in" .. (inputCounter > 1 and tostring(inputCounter) or "")
            inputMap[name] = {nodeId = cable.toNode, port = cable.toPort}
            inputCounter = inputCounter + 1
        end
    end

    -- 3. Compute macro position (center of selection)
    local cx, cy = 0, 0
    for id in pairs(self.selectedNodes) do
        cx = cx + self.nodes[id].x
        cy = cy + self.nodes[id].y
    end
    cx = cx / #selectedIds
    cy = cy / #selectedIds

    -- 4. Snapshot internal nodes (relative positions)
    local nodeSnapshots = {}
    for id in pairs(self.selectedNodes) do
        local node = self.nodes[id]
        nodeSnapshots[#nodeSnapshots + 1] = {
            id = node.id,
            type = node.type,
            label = node.label,
            x = node.x - cx,  -- Relative position
            y = node.y - cy,
            knobValues = self:_deepCopy(node.knobValues),
            toggleValues = self:_deepCopy(node.toggleValues or {}),
            signalKey = node.signalKey,
        }
    end

    -- 5. Create macro node
    local macroDef
    for _, def in ipairs(self.nodeDefs) do
        if def.type == "macro" then macroDef = def; break end
    end
    local macroNode = self:createNode(macroDef, cx, cy)
    local macroId = macroNode.id
    macroNode.label = "Macro"
    macroNode.macroData = {
        nodes = nodeSnapshots,
        cables = internalCables,
        inputMap = inputMap,
        outputMap = outputMap
    }

    -- 6. Set dynamic inputs/outputs
    macroNode.inputs = {}
    for name in pairs(inputMap) do
        macroNode.inputs[#macroNode.inputs + 1] = {name = name, connected = false}
    end
    macroNode.outputs = {}
    for name in pairs(outputMap) do
        macroNode.outputs[#macroNode.outputs + 1] = {name = name}
    end

    -- 7. Rewire external cables to macro
    for _, cable in ipairs(self.cables) do
        if not self.selectedNodes[cable.fromNode] and self.selectedNodes[cable.toNode] then
            -- External → internal becomes External → macro
            for inputName, mapping in pairs(inputMap) do
                if mapping.nodeId == cable.toNode and mapping.port == cable.toPort then
                    cable.toNode = macroId
                    cable.toPort = inputName
                    break
                end
            end
        elseif self.selectedNodes[cable.fromNode] and not self.selectedNodes[cable.toNode] then
            -- Internal → external becomes macro → external
            for outputName, mapping in pairs(outputMap) do
                if mapping.nodeId == cable.fromNode and mapping.port == cable.fromPort then
                    cable.fromNode = macroId
                    cable.fromPort = outputName
                    break
                end
            end
        end
    end

    -- 8. Remove internal cables from main graph
    local newCables = {}
    for _, cable in ipairs(self.cables) do
        local fromInside = self.selectedNodes[cable.fromNode]
        local toInside = self.selectedNodes[cable.toNode]
        if not (fromInside and toInside) then
            newCables[#newCables + 1] = cable
        end
    end
    self.cables = newCables

    -- 9. Delete selected nodes from main graph
    for id in pairs(self.selectedNodes) do
        self.nodes[id] = nil
        for i = #self.drawOrder, 1, -1 do
            if self.drawOrder[i] == id then
                table.remove(self.drawOrder, i)
                break
            end
        end
    end

    -- 10. Clear selection, select macro
    self.selectedNodes = {[macroId] = true}
    self:invalidateCache()
    self:_notifyGraphChanged()
end

--- Ungroup a macro, restoring its internal nodes to the main graph
function Editor:ungroupMacro(macroId)
    local macroNode = self.nodes[macroId]
    if not macroNode or macroNode.type ~= "macro" or not macroNode.macroData then return end

    local macroData = macroNode.macroData
    local cx, cy = macroNode.x, macroNode.y
    local idRemap = {}  -- old internal ID → new ID

    -- 1. Restore internal nodes with new IDs
    for _, snapshot in ipairs(macroData.nodes or {}) do
        -- Find the node definition by type
        local def
        for _, d in ipairs(self.nodeDefs) do
            if d.type == snapshot.type then def = d; break end
        end
        if not def then
            -- Skip unknown node types
            goto continue
        end
        local newNode = self:createNode(def, cx + (snapshot.x or 0), cy + (snapshot.y or 0))
        idRemap[snapshot.id] = newNode.id
        newNode.knobValues = self:_deepCopy(snapshot.knobValues or {})
        newNode.toggleValues = self:_deepCopy(snapshot.toggleValues or {})
        newNode.signalKey = snapshot.signalKey
        ::continue::
    end

    -- 2. Restore internal cables with remapped IDs
    for _, cable in ipairs(macroData.cables or {}) do
        if idRemap[cable.fromNode] and idRemap[cable.toNode] then
            self:addCable(
                idRemap[cable.fromNode], cable.fromPort,
                idRemap[cable.toNode], cable.toPort
            )
        end
    end

    -- 3. Rewire external cables from macro to restored nodes
    for _, cable in ipairs(self.cables) do
        if cable.toNode == macroId then
            -- Find internal target via inputMap
            local mapping = macroData.inputMap and macroData.inputMap[cable.toPort]
            if mapping and idRemap[mapping.nodeId] then
                cable.toNode = idRemap[mapping.nodeId]
                cable.toPort = mapping.port
            end
        elseif cable.fromNode == macroId then
            -- Find internal source via outputMap
            local mapping = macroData.outputMap and macroData.outputMap[cable.fromPort]
            if mapping and idRemap[mapping.nodeId] then
                cable.fromNode = idRemap[mapping.nodeId]
                cable.fromPort = mapping.port
            end
        end
    end

    -- 4. Delete macro node
    self.nodes[macroId] = nil
    for i = #self.drawOrder, 1, -1 do
        if self.drawOrder[i] == macroId then
            table.remove(self.drawOrder, i)
            break
        end
    end

    -- 5. Select restored nodes
    self.selectedNodes = {}
    for _, newId in pairs(idRemap) do
        self.selectedNodes[newId] = true
    end

    self:invalidateCache()
    self:_notifyGraphChanged()
end

--------------------------------------------------------------------------------
-- PRESETS
--------------------------------------------------------------------------------

--- Create a preset macro node
---@param name string Preset name (e.g., "orbit", "breathe", "beatPulse")
---@param x number X position
---@param y number Y position
---@return table|nil macroNode The created macro node, or nil if not found
function Editor:createPreset(name, x, y)
    return Presets.create(self, name, x, y)
end

--- Get list of available preset names
function Editor:listPresets()
    return Presets.list()
end

--------------------------------------------------------------------------------
-- LOAD / UPDATE
--------------------------------------------------------------------------------

function Editor:load(screenW, screenH)
    self.screenW = screenW
    self.screenH = screenH
    self.nodes = {}
    self.drawOrder = {}
    self.cables = {}
    self.nextNodeId = 1
    self.time = 0
    self.dragging = nil
    self.wiring = nil
    self.knobDrag = nil
    self.spawnDrag = nil
    self.trail = {}

    -- Initialize live co-pilot integration
    Live.init(self)
end

function Editor:update(dt)
    self.time = self.time + dt

    -- Reset debug stats each frame (so we see per-frame counts)
    if self.debugStats then
        self.debugStats.evalCount = 0
        self.debugStats.cacheHits = 0
    end

    -- Update live co-pilot (polls for edits)
    Live.update(dt)

    -- audio_out: fill QueueableSource buffers from connected curve
    local TARGET_AHEAD = 4
    for _, node in pairs(self.nodes) do
        if node.type == "audio_out" then
            local sr     = math.floor(node.knobValues.sr     or 44100)
            local bufN   = math.floor(node.knobValues.buffer or 2048)
            local gain   = node.knobValues.gain or 1.0

            -- create source once (or if sr changed)
            if not node._source or node._sr ~= sr then
                if node._source then node._source:stop() end
                node._source   = love.audio.newQueueableSource(sr, 16, 1)
                node._audioTime = 0
                node._ctx       = {}  -- one persistent ctx per node, never reset
                node._sr        = sr
            end

            local curve = self:evalNode(node, "left")
            if curve then
                -- fill queue up to TARGET_AHEAD buffers proactively
                local filled = 0
                while node._source:getFreeBufferCount() > 0 and filled < TARGET_AHEAD do
                    local sd = love.sound.newSoundData(bufN, sr, 16, 1)
                    local t0 = node._audioTime
                    local ctx = node._ctx
                    for i = 0, bufN - 1 do
                        local v = curve(t0 + i / sr, ctx)
                        sd:setSample(i, 1, math.max(-1, math.min(1, v * gain)))
                    end
                    node._audioTime = t0 + bufN / sr
                    node._source:queue(sd)
                    filled = filled + 1
                end
                if not node._source:isPlaying() then node._source:play() end
            end
        end
    end

    -- Check for async stem separation jobs
    local AudioStems = require("spatula.audio_stems")
    for _, node in pairs(self.nodes) do
        if node.type == "audio_stems" and node._separating and node._jobId then
            local status = AudioStems.checkJob(node._jobId)
            if status.status == "complete" then
                node._separating = false
                node._stems = status.stems
                node._statusMsg = status.cached and "Loaded (cached)" or "Separation complete"
                -- Load sound data for each stem
                node._stemSoundData = {}
                for stemName, stemPath in pairs(status.stems) do
                    local ok, soundData = pcall(love.sound.newSoundData, stemPath)
                    if ok then
                        node._stemSoundData[stemName] = soundData
                    end
                end
                node._cachedCurve = nil
                self:_notifyGraphChanged()
            elseif status.status == "error" then
                node._separating = false
                node._statusMsg = "Error: " .. (status.error or "unknown")
            end
        end
    end
end

--------------------------------------------------------------------------------
-- DRAWING
--------------------------------------------------------------------------------

-- Check if a knob should be visible based on toggle state
local function isKnobVisible(node, knobName)
    -- Distribution: count for random/grid, spacing for poisson/hex
    if node.type == "dist" then
        local pattern = node.toggleValues and node.toggleValues.pattern or 1
        if knobName == "count" then return pattern <= 2 end    -- random, grid
        if knobName == "spacing" then return pattern >= 3 end  -- poisson, hex
    end
    -- Transform: value only for scale/offset, not abs/neg
    if node.type == "transform" then
        local op = node.toggleValues and node.toggleValues.op or 1
        if knobName == "value" then return op <= 2 end  -- scale, offset
    end
    -- Stats: scale only for integral
    if node.type == "stats" then
        local stat = node.toggleValues and node.toggleValues.stat or 1
        if knobName == "scale" then return stat == 3 end  -- integral only
    end
    return true
end

local function drawPort(px, py, isInput, connected, hot, snap)
    if snap then
        love.graphics.setColor(0.4, 1, 0.5, 0.3)
        love.graphics.circle("fill", px, py, PORT_R + 6)
        love.graphics.setColor(0.4, 1, 0.5, 1)
    elseif hot then
        love.graphics.setColor(1, 1, 0.6, 1)
    elseif connected then
        love.graphics.setColor(1.0, 0.9, 0.4, 1)
    else
        love.graphics.setColor(0.4, 0.4, 0.45, 1)
    end
    love.graphics.circle("fill", px, py, PORT_R)
    love.graphics.setColor(0.2, 0.2, 0.2, 1)
    love.graphics.circle("line", px, py, PORT_R)
end

local function drawCable(x1, y1, x2, y2, alpha, cableColor)
    alpha = alpha or 0.8
    local dx = abs(x2 - x1) * 0.5
    local cr, cg, cb = 0.9, 0.85, 0.4
    if cableColor then cr, cg, cb = cableColor[1], cableColor[2], cableColor[3] end
    love.graphics.setColor(cr, cg, cb, alpha)
    love.graphics.setLineWidth(2)
    local segments = 20
    local pts = {}
    for i = 0, segments do
        local t = i / segments
        local it = 1 - t
        local bx = it*it*it*x1 + 3*it*it*t*(x1+dx) + 3*it*t*t*(x2-dx) + t*t*t*x2
        local by = it*it*it*y1 + 3*it*it*t*y1 + 3*it*t*t*y2 + t*t*t*y2
        pts[#pts+1] = bx
        pts[#pts+1] = by
    end
    if #pts >= 4 then
        love.graphics.line(pts)
    end
    love.graphics.setLineWidth(1)
end

function Editor:drawNode(node)
    local h = nodeHeightWithPreview(node)

    -- Shadow
    love.graphics.setColor(0, 0, 0, 0.3)
    love.graphics.rectangle("fill", node.x + 3, node.y + 3, NODE_W, h, 6)

    -- Body
    local r, g, b = node.color[1], node.color[2], node.color[3]
    love.graphics.setColor(r, g, b, 0.95)
    love.graphics.rectangle("fill", node.x, node.y, NODE_W, h, 6)

    -- Header
    love.graphics.setColor(r + 0.1, g + 0.1, b + 0.1, 1)
    love.graphics.rectangle("fill", node.x, node.y, NODE_W, 22, 6)
    love.graphics.rectangle("fill", node.x, node.y + 12, NODE_W, 10)

    -- Label
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(node.label, node.x + 8, node.y + 4)

    -- Macro badge
    if node.type == "macro" then
        love.graphics.setColor(0.6, 0.7, 0.9, 1)
        love.graphics.rectangle("fill", node.x + NODE_W - 24, node.y + 4, 18, 14, 3)
        love.graphics.setColor(0.1, 0.15, 0.25, 1)
        love.graphics.print("M", node.x + NODE_W - 20, node.y + 4)
        -- Dashed border effect (corner accents)
        love.graphics.setColor(0.6, 0.7, 0.9, 0.8)
        love.graphics.setLineWidth(2)
        love.graphics.line(node.x, node.y + 12, node.x, node.y)
        love.graphics.line(node.x, node.y, node.x + 12, node.y)
        love.graphics.line(node.x + NODE_W - 12, node.y, node.x + NODE_W, node.y)
        love.graphics.line(node.x + NODE_W, node.y, node.x + NODE_W, node.y + 12)
        love.graphics.line(node.x, node.y + h - 12, node.x, node.y + h)
        love.graphics.line(node.x, node.y + h, node.x + 12, node.y + h)
        love.graphics.line(node.x + NODE_W - 12, node.y + h, node.x + NODE_W, node.y + h)
        love.graphics.line(node.x + NODE_W, node.y + h - 12, node.x + NODE_W, node.y + h)
        love.graphics.setLineWidth(1)
    end

    -- Inputs
    for _, inp in ipairs(node.inputs) do
        local px, py = portPos(node, inp.name, true)
        local hot = self.hoverPort and self.hoverPort.nodeId == node.id and self.hoverPort.portName == inp.name and self.hoverPort.isInput
        local snap = self.snapPort and self.snapPort.nodeId == node.id and self.snapPort.portName == inp.name
        drawPort(px, py, true, inp.connected, hot, snap)
        love.graphics.setColor(0.85, 0.85, 0.85, 1)
        love.graphics.print(inp.name, px + PORT_R + 4, py - 7)
    end

    -- Outputs
    for _, out in ipairs(node.outputs) do
        local px, py = portPos(node, out.name, false)
        local hot = self.hoverPort and self.hoverPort.nodeId == node.id and self.hoverPort.portName == out.name and not self.hoverPort.isInput
        drawPort(px, py, false, true, hot)
        love.graphics.setColor(0.85, 0.85, 0.85, 1)
        local tw = love.graphics.getFont():getWidth(out.name)
        love.graphics.print(out.name, px - PORT_R - tw - 4, py - 7)
    end

    -- Knobs (skip hidden knobs based on toggle state)
    local knobY = node.y + 30 + math.max(#node.inputs, #node.outputs) * PORT_SPACING + 4
    local visibleKnobIdx = 0
    for i, knob in ipairs(node.knobs) do
        if isKnobVisible(node, knob.name) then
            visibleKnobIdx = visibleKnobIdx + 1
            local val = node.knobValues[knob.name]
            local frac = (val - knob.min) / (knob.max - knob.min)
            local kx = node.x + 8
            local ky = knobY + (visibleKnobIdx - 1) * 20

            love.graphics.setColor(0.75, 0.75, 0.75, 1)
            love.graphics.print(string.format("%s: %.1f", knob.name, val), kx, ky - 1)

            local sx = kx + 70
            local sw = NODE_W - 86
            love.graphics.setColor(0.2, 0.2, 0.25, 1)
            love.graphics.rectangle("fill", sx, ky + 2, sw, 8, 3)
            love.graphics.setColor(0.5, 0.6, 0.8, 1)
            love.graphics.rectangle("fill", sx, ky + 2, sw * frac, 8, 3)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.circle("fill", sx + sw * frac, ky + 6, 5)
        end
    end

    -- Toggles (after visible knobs)
    local toggleY = knobY + visibleKnobIdx * 20
    for i, toggle in ipairs(node.toggles or {}) do
        local ty = toggleY + (i - 1) * 20
        local tx = node.x + 8
        local val = node.toggleValues[toggle.name]

        if toggle.options then
            -- Multi-option toggle: render as pill buttons
            love.graphics.setColor(0.6, 0.6, 0.65, 1)
            love.graphics.print(toggle.label .. ":", tx, ty)
            local optX = tx + 45
            local optW = math.floor((NODE_W - 60) / #toggle.options)
            for j, opt in ipairs(toggle.options) do
                local selected = (val == j)
                local bx = optX + (j - 1) * optW
                if selected then
                    love.graphics.setColor(0.4, 0.6, 0.9, 1)
                else
                    love.graphics.setColor(0.25, 0.25, 0.3, 1)
                end
                love.graphics.rectangle("fill", bx, ty + 1, optW - 2, 14, 4)
                love.graphics.setColor(selected and 1 or 0.7, selected and 1 or 0.7, selected and 1 or 0.7, 1)
                local font = love.graphics.getFont()
                local tw = font:getWidth(opt)
                love.graphics.print(opt, bx + (optW - 2 - tw) / 2, ty + 1)
            end
        else
            -- Boolean toggle: render as checkbox
            love.graphics.setColor(0.6, 0.6, 0.65, 1)
            love.graphics.print(toggle.label, tx, ty)
            local cbX = node.x + NODE_W - 24
            love.graphics.setColor(0.25, 0.25, 0.3, 1)
            love.graphics.rectangle("fill", cbX, ty + 1, 14, 14, 3)
            if val then
                love.graphics.setColor(0.4, 0.8, 0.5, 1)
                love.graphics.rectangle("fill", cbX + 2, ty + 3, 10, 10, 2)
            end
        end
    end

    -- Buttons (after toggles)
    local buttonY = toggleY + (#node.toggles or 0) * 20
    if node.buttons and #node.buttons > 0 then
        local btnW = math.floor((NODE_W - 16) / #node.buttons)
        for i, btn in ipairs(node.buttons) do
            local bx = node.x + 8 + (i - 1) * btnW
            -- Highlight button if separating
            if node.type == "audio_stems" and node._separating and btn.name == "separate" then
                love.graphics.setColor(0.5, 0.4, 0.2, 1)
            else
                love.graphics.setColor(0.3, 0.35, 0.4, 1)
            end
            love.graphics.rectangle("fill", bx, buttonY + 2, btnW - 4, 18, 4)
            love.graphics.setColor(0.9, 0.9, 0.9, 1)
            local font = love.graphics.getFont()
            local tw = font:getWidth(btn.label)
            love.graphics.print(btn.label, bx + (btnW - 4 - tw) / 2, buttonY + 3)
        end
    end

    -- Audio stems custom preview
    if node.type == "audio_stems" then
        local previewY = node.y + nodeHeight(node)
        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)

        -- Show source path
        local srcPath = node.sourcePath or "(no file)"
        if #srcPath > 25 then srcPath = "..." .. srcPath:sub(-22) end
        love.graphics.setColor(0.6, 0.65, 0.7, 0.9)
        love.graphics.print("Src: " .. srcPath, node.x + 8, previewY + 6)

        -- Show status
        local status = node._statusMsg or (node._separating and "Separating..." or "Ready")
        local statusColor = node._separating and {0.9, 0.8, 0.3} or
                           (node._stems and {0.4, 0.9, 0.5} or {0.5, 0.5, 0.55})
        love.graphics.setColor(statusColor[1], statusColor[2], statusColor[3], 0.9)
        love.graphics.print(status, node.x + 8, previewY + 22)

        -- Show available stems
        if node._stems then
            local stemList = {}
            for name, _ in pairs(node._stems) do
                stemList[#stemList + 1] = name
            end
            love.graphics.setColor(0.5, 0.7, 0.6, 0.8)
            love.graphics.print(table.concat(stemList, ", "), node.x + 8, previewY + 38)
        end

        -- Show loading indicator
        if node._separating then
            local dots = string.rep(".", math.floor(self.time * 3) % 4)
            love.graphics.setColor(0.9, 0.8, 0.3, 0.9)
            love.graphics.print(dots, node.x + NODE_W - 30, previewY + 22)
        end
        return  -- Skip standard preview for audio_stems
    end

    -- Source/combinator preview: waveform
    if not node.type:match("^form_") and node.type ~= "dist" and not node.type:match("^color_") and node.type ~= "xy_output" and node.type ~= "point" then
        local previewY = node.y + nodeHeight(node)
        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)
        self:setWorldScissor(node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4)

        local midY = previewY + NODE_PREVIEW_H / 2
        love.graphics.setColor(0.25, 0.25, 0.3, 0.4)
        love.graphics.line(node.x + 6, midY, node.x + NODE_W - 6, midY)

        local curve = self:evaluateNode(node.id, {})
        -- Handle multi-output nodes: use first output for preview
        if type(curve) == "table" and not curve._isColor and not curve._isFieldSource then
            local firstOutput = node.outputs and node.outputs[1] and node.outputs[1].name
            if firstOutput and curve[firstOutput] then
                curve = curve[firstOutput]
            end
        end

        -- Check if output is text (returns textManager)
        local ok, testVal = pcall(curve, 0, {})
        if ok and type(testVal) == "table" and testVal._isTextManager then
            -- Draw text preview for dataset_loader
            local buf = testVal.buffer
            if buf and #buf > 0 then
                local text = buf[#buf].text or ""
                local maxLen = 50
                if #text > maxLen then text = text:sub(1, maxLen) .. "..." end
                love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                love.graphics.printf(text, node.x + 6, previewY + 4, NODE_W - 12, "left")
                -- Show index info for dataset_loader
                if node.type == "dataset_loader" and node._dataset then
                    local ds = node._dataset
                    love.graphics.setColor(0.5, 0.6, 0.7, 0.8)
                    local label = ds.labels and ds.labels[ds.currentIdx] or "?"
                    local info = string.format("[%d/%d] %s", ds.currentIdx, #ds.samples, label)
                    love.graphics.print(info, node.x + 6, previewY + NODE_PREVIEW_H - 18)
                end
            else
                love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                love.graphics.print("(no text)", node.x + 6, previewY + 4)
            end
        elseif node._textPreview or node.type == "text_to_curve" then
            -- Call curve to update animation
            if type(curve) == "function" then
                pcall(curve, self.time or 0, {})
            end

            local tp = node._textPreview or {}
            local fullText = tp.text or ""
            local unit = tp.unit or {start = 1, stop = 1}
            local idx = tp.idx or 1
            local total = tp.total or 1
            local mode = tp.mode or 0
            local modeNames = {"char", "word", "token", "sent"}
            local synced = tp.synced

            local font = self.smallFont or love.graphics.getFont()
            love.graphics.setFont(font)
            local textX = node.x + 6
            local textY = previewY + 4

            if #fullText > 0 then
                -- Calculate visible window around current unit
                local maxLen = 35
                local unitStart = unit.start or 1
                local unitStop = unit.stop or unitStart
                local windowStart = math.max(1, unitStart - 10)
                local windowEnd = math.min(#fullText, windowStart + maxLen - 1)

                -- Adjust window if unit is near end
                if unitStop > windowEnd then
                    windowEnd = math.min(#fullText, unitStop + 5)
                    windowStart = math.max(1, windowEnd - maxLen + 1)
                end

                local displayText = fullText:sub(windowStart, windowEnd)
                local hlStart = unitStart - windowStart + 1
                local hlEnd = unitStop - windowStart + 1

                -- Draw text with highlighted unit
                if hlStart >= 1 and hlEnd <= #displayText then
                    local before = displayText:sub(1, hlStart - 1)
                    local highlight = displayText:sub(hlStart, hlEnd)
                    local after = displayText:sub(hlEnd + 1)

                    love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                    love.graphics.print(before, textX, textY)

                    local beforeW = font:getWidth(before)
                    local hlW = math.max(font:getWidth(highlight), 4)
                    love.graphics.setColor(1, 0.8, 0.2, 0.8)
                    love.graphics.rectangle("fill", textX + beforeW, textY, hlW, font:getHeight())
                    love.graphics.setColor(0.1, 0.1, 0.15, 1)
                    love.graphics.print(highlight, textX + beforeW, textY)

                    love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                    love.graphics.print(after, textX + beforeW + hlW, textY)
                else
                    love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                    love.graphics.print(displayText, textX, textY)
                end

                -- Show mode, position, and debug values
                love.graphics.setColor(0.5, 0.5, 0.6, 0.6)
                local unitText = unit.text or ""
                local charVal = fullText:byte(unit.start) or 0
                local speed = tp.speed or 0
                local rev = tp.reverse and "◀" or ""
                local syncStr = synced and " ⚡sync" or ""
                local speedStr = synced and "" or (speed > 0 and string.format(" spd=%.1f%s", speed, rev) or " (paused)")
                local debugInfo = string.format("%s [%d/%d] '%s'=%d%s%s",
                    modeNames[mode + 1] or "?", idx, total, unitText:sub(1,5), charVal, speedStr, syncStr)
                love.graphics.print(debugInfo, textX, textY + font:getHeight() + 2)
                -- Show all output values
                love.graphics.setColor(0.4, 0.7, 0.9, 0.7)
                local outInfo = string.format("out: char=%d idx=%d total=%d pos=%.3f", charVal, idx, total, idx/total)
                love.graphics.print(outInfo, textX, textY + font:getHeight() * 2 + 4)
            else
                love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
                love.graphics.print("(no text)", textX, textY)
            end
        elseif node.type == "debug_monitor" then
            -- Debug monitor: show large formatted value
            if type(curve) == "function" then
                pcall(curve, self.time or 0, {})
            end
            local font = self.smallFont or love.graphics.getFont()
            love.graphics.setFont(font)
            love.graphics.setColor(0.3, 0.9, 0.3, 1)
            local val = node._debugFormatted or "---"
            love.graphics.print(val, node.x + 8, previewY + 8)
            -- Show raw value in smaller text
            love.graphics.setColor(0.5, 0.7, 0.5, 0.7)
            local raw = node._debugValue
            if raw then
                love.graphics.print(string.format("raw: %g", raw), node.x + 8, previewY + 24)
            end
        elseif node.type == "debug_multi" then
            -- Multi-monitor: show all connected values
            if type(curve) == "function" then
                pcall(curve, self.time or 0, {})
            end
            local font = self.smallFont or love.graphics.getFont()
            love.graphics.setFont(font)
            local vals = node._debugValues or {}
            local y = previewY + 4
            for _, name in ipairs({"a", "b", "c", "d"}) do
                if vals[name] then
                    love.graphics.setColor(0.3, 0.9, 0.3, 1)
                    love.graphics.print(string.format("%s: %.3f", name, vals[name]), node.x + 8, y)
                    y = y + 12
                end
            end
            if not next(vals) then
                love.graphics.setColor(0.5, 0.6, 0.5, 0.6)
                love.graphics.print("(no inputs)", node.x + 8, previewY + 8)
            end
        else
            -- Draw curve preview
            love.graphics.setColor(r + 0.3, g + 0.3, b + 0.3, 0.9)
            local pts = {}
            local pw = NODE_W - 12
            local ph = (NODE_PREVIEW_H - 8) / 2
            for i = 0, PREVIEW_STEPS do
                local t = (i / PREVIEW_STEPS) * 4
                local ok2, v = pcall(curve, t, {})
                if ok2 and type(v) == "number" then
                    pts[#pts + 1] = node.x + 6 + (i / PREVIEW_STEPS) * pw
                    pts[#pts + 1] = midY - (v / PREVIEW_NORM) * ph
                end
            end
            if #pts >= 4 then love.graphics.line(pts) end
        end
        love.graphics.setScissor()
    end

    -- Point preview (cross with rotation indicator)
    if node.type == "point" then
        local previewY = node.y + nodeHeight(node)
        local baseCx = node.x + NODE_W / 2
        local baseCy = previewY + NODE_PREVIEW_H / 2
        local previewScale = (NODE_PREVIEW_H / 2 - 8)
        local maxSize = PREVIEW_NORM

        local cx, cy, rot, _ = self:getTransform(node.id, self.time, {})
        local offsetX = (cx or 0) * previewScale / maxSize
        local offsetY = (cy or 0) * previewScale / maxSize

        local pcx = baseCx + offsetX
        local pcy = baseCy + offsetY

        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)
        self:setWorldScissor(node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4)

        -- Draw point as cross
        love.graphics.setColor(0.5, 0.5, 0.8, 0.9)
        local crossSize = 8
        love.graphics.line(pcx - crossSize, pcy, pcx + crossSize, pcy)
        love.graphics.line(pcx, pcy - crossSize, pcx, pcy + crossSize)

        -- Draw rotation indicator (line pointing in rotation direction)
        if rot ~= 0 then
            local rotLen = 15
            local rx = pcx + cos(rot) * rotLen
            local ry = pcy + sin(rot) * rotLen
            love.graphics.setColor(0.8, 0.6, 0.3, 0.8)
            love.graphics.line(pcx, pcy, rx, ry)
            love.graphics.circle("fill", rx, ry, 2)
        end

        -- Origin crosshair (faint)
        love.graphics.setColor(0.4, 0.4, 0.5, 0.3)
        love.graphics.line(baseCx - 6, baseCy, baseCx + 6, baseCy)
        love.graphics.line(baseCx, baseCy - 6, baseCx, baseCy + 6)
        love.graphics.setScissor()
    end

    -- Form preview
    if node.type:match("^form_") then
        local previewY = node.y + nodeHeight(node)
        local baseCx = node.x + NODE_W / 2
        local baseCy = previewY + NODE_PREVIEW_H / 2
        local previewScale = (NODE_PREVIEW_H / 2 - 8)
        local maxSize = PREVIEW_NORM

        local cx, cy, rot, scale = self:getTransform(node.id, self.time, {})
        local offsetX = (cx or 0) * previewScale / maxSize
        local offsetY = (cy or 0) * previewScale / maxSize

        local pcx = baseCx + offsetX
        local pcy = baseCy + offsetY

        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)
        self:setWorldScissor(node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4)

        -- Check for color input
        local formColor = {0.6, 0.45, 0.25, 0.8}  -- Default form color
        local colorCable = self:findCableToInput(node.id, "colorIn")
        if colorCable then
            local colorCurve = self:evaluateNode(colorCable.fromNode, {})
            local ok, col = pcall(function()
                if type(colorCurve) == "function" then
                    return colorCurve(self.time, {})
                elseif type(colorCurve) == "table" and colorCurve._isColor then
                    return colorCurve
                end
                return nil
            end)
            if ok and col and col._isColor then
                formColor = {col.r, col.g, col.b, col.a or 0.8}
            end
        end
        love.graphics.setColor(formColor[1], formColor[2], formColor[3], formColor[4])

        if node.type == "form_circle" then
            local rVal = self:resolveInputCurve(node.id, "r", self.time, {}, 80) * (scale or 1)
            local drawR = math.min(previewScale, abs(rVal) * previewScale / maxSize)
            love.graphics.circle("line", pcx, pcy, math.max(3, drawR))
        elseif node.type == "form_rect" then
            local wVal = self:resolveInputCurve(node.id, "w", self.time, {}, 80) * (scale or 1)
            local hVal = self:resolveInputCurve(node.id, "h", self.time, {}, 60) * (scale or 1)
            local drawW = abs(wVal) * previewScale / maxSize
            local drawH = abs(hVal) * previewScale / maxSize
            -- Apply rotation to rect corners
            if rot and rot ~= 0 then
                local cos_r, sin_r = cos(rot), sin(rot)
                local corners = {
                    {-drawW, -drawH}, {drawW, -drawH},
                    {drawW, drawH}, {-drawW, drawH}
                }
                local pts = {}
                for i, c in ipairs(corners) do
                    local rx = c[1] * cos_r - c[2] * sin_r
                    local ry = c[1] * sin_r + c[2] * cos_r
                    pts[#pts + 1] = pcx + rx
                    pts[#pts + 1] = pcy + ry
                end
                pts[#pts + 1] = pts[1]
                pts[#pts + 1] = pts[2]
                love.graphics.line(pts)
            else
                love.graphics.rectangle("line", pcx - drawW, pcy - drawH, drawW * 2, drawH * 2)
            end
        elseif node.type == "form_polygon" then
            local sides = math.floor(node.knobValues.sides or 6)
            local rVal = self:resolveInputCurve(node.id, "r", self.time, {}, 80) * (scale or 1)
            local drawR = math.max(3, abs(rVal) * previewScale / maxSize)
            local pts = {}
            for i = 1, sides do
                local angle = (rot or 0) + (i - 1) * (math.pi * 2 / sides)
                pts[#pts + 1] = pcx + cos(angle) * drawR
                pts[#pts + 1] = pcy + sin(angle) * drawR
            end
            pts[#pts + 1] = pts[1]
            pts[#pts + 1] = pts[2]
            love.graphics.line(pts)
        end

        -- Draw rotation indicator
        if rot and rot ~= 0 then
            local rotLen = 12
            local rx = pcx + cos(rot) * rotLen
            local ry = pcy + sin(rot) * rotLen
            love.graphics.setColor(0.8, 0.6, 0.3, 0.6)
            love.graphics.line(pcx, pcy, rx, ry)
            love.graphics.circle("fill", rx, ry, 2)
        end

        love.graphics.setColor(0.4, 0.35, 0.25, 0.3)
        love.graphics.line(baseCx - 6, baseCy, baseCx + 6, baseCy)
        love.graphics.line(baseCx, baseCy - 6, baseCx, baseCy + 6)
        love.graphics.setScissor()
    end

    -- Distribution preview
    if node.type == "dist" then
        local previewY = node.y + nodeHeight(node)
        local baseCx = node.x + NODE_W / 2
        local baseCy = previewY + NODE_PREVIEW_H / 2
        local previewScale = (NODE_PREVIEW_H / 2 - 8)
        local maxSize = PREVIEW_NORM

        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)
        self:setWorldScissor(node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4)

        -- Generate points with current time for animated rotation/scale
        local points = self:generateDistributionPoints(node.id, self.time, {})

        local formCable = self:findCableToInput(node.id, "form")
        if formCable then
            local formNode = self.nodes[formCable.fromNode]
            if formNode then
                local _, formCx, formCy, formRot, formScale = self:evaluateFormNode(formCable.fromNode, self.time, {})
                local distRot = self:resolveInputCurve(node.id, "rotation", self.time, {}, 0) * math.pi / 180
                local distScale = self:resolveInputCurve(node.id, "scale", self.time, {}, 1)
                local totalScale = (formScale or 1) * distScale

                love.graphics.setColor(0.3, 0.35, 0.4, 0.4)
                if formNode.type == "form_circle" then
                    local rVal = self:resolveInputCurve(formCable.fromNode, "r", self.time, {}, 80) * totalScale
                    love.graphics.circle("line", baseCx, baseCy, math.max(3, abs(rVal) * previewScale / maxSize))
                elseif formNode.type == "form_rect" then
                    local wVal = self:resolveInputCurve(formCable.fromNode, "w", self.time, {}, 80) * totalScale
                    local hVal = self:resolveInputCurve(formCable.fromNode, "h", self.time, {}, 60) * totalScale
                    local drawW = abs(wVal) * previewScale / maxSize
                    local drawH = abs(hVal) * previewScale / maxSize
                    local totalRot = (formRot or 0) + distRot
                    if totalRot ~= 0 then
                        local cos_r, sin_r = cos(totalRot), sin(totalRot)
                        local corners = {
                            {-drawW, -drawH}, {drawW, -drawH},
                            {drawW, drawH}, {-drawW, drawH}
                        }
                        local pts = {}
                        for i, c in ipairs(corners) do
                            local rx = c[1] * cos_r - c[2] * sin_r
                            local ry = c[1] * sin_r + c[2] * cos_r
                            pts[#pts + 1] = baseCx + rx
                            pts[#pts + 1] = baseCy + ry
                        end
                        pts[#pts + 1] = pts[1]
                        pts[#pts + 1] = pts[2]
                        love.graphics.line(pts)
                    else
                        love.graphics.rectangle("line", baseCx - drawW, baseCy - drawH, drawW * 2, drawH * 2)
                    end
                elseif formNode.type == "form_polygon" then
                    local sides = math.floor(formNode.knobValues.sides or 6)
                    local rVal = self:resolveInputCurve(formCable.fromNode, "r", self.time, {}, 80) * totalScale
                    local drawR = math.max(3, abs(rVal) * previewScale / maxSize)
                    local totalRot = (formRot or 0) + distRot
                    local pts = {}
                    for i = 1, sides do
                        local angle = totalRot + (i - 1) * (math.pi * 2 / sides)
                        pts[#pts + 1] = baseCx + cos(angle) * drawR
                        pts[#pts + 1] = baseCy + sin(angle) * drawR
                    end
                    pts[#pts + 1] = pts[1]
                    pts[#pts + 1] = pts[2]
                    love.graphics.line(pts)
                end
            end
        end

        -- Check for color input for points
        local pointColor = {0.3, 0.7, 0.9, 0.9}  -- Default point color
        local distColorCable = self:findCableToInput(node.id, "colorIn")
        if distColorCable then
            local colorCurve = self:evaluateNode(distColorCable.fromNode, {})
            local ok, col = pcall(function()
                if type(colorCurve) == "function" then
                    return colorCurve(self.time, {})
                elseif type(colorCurve) == "table" and colorCurve._isColor then
                    return colorCurve
                end
                return nil
            end)
            if ok and col and col._isColor then
                pointColor = {col.r, col.g, col.b, col.a or 0.9}
            end
        end

        love.graphics.setColor(pointColor[1], pointColor[2], pointColor[3], pointColor[4])
        for _, pt in ipairs(points) do
            love.graphics.circle("fill", baseCx + pt.x * previewScale / maxSize, baseCy + pt.y * previewScale / maxSize, 1.5)
        end
        love.graphics.setColor(0.5, 0.6, 0.7, 0.6)
        love.graphics.print(tostring(#points), node.x + 8, previewY + 4)
        love.graphics.setScissor()
    end

    -- Color preview: shows color swatch or gradient
    if node.type:match("^color_") then
        local previewY = node.y + nodeHeight(node)
        love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        love.graphics.rectangle("fill", node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4, 4)
        self:setWorldScissor(node.x + 4, previewY + 2, NODE_W - 8, NODE_PREVIEW_H - 4)

        local curve = self:evaluateNode(node.id, {}, "color")
        local swatchX = node.x + 8
        local swatchY = previewY + 8
        local swatchW = NODE_W - 16
        local swatchH = NODE_PREVIEW_H - 16

        if node.type == "color_const" then
            -- Static color swatch
            local col = node.knobValues
            love.graphics.setColor(col.r, col.g, col.b, col.a or 1)
            love.graphics.rectangle("fill", swatchX, swatchY, swatchW, swatchH, 4)
            -- Checkerboard for alpha
            if col.a and col.a < 1 then
                love.graphics.setColor(1, 1, 1, 0.3)
                love.graphics.print(string.format("a=%.2f", col.a), swatchX + 4, swatchY + swatchH - 14)
            end
        elseif node.type == "color_ramp" then
            -- Gradient swatch (show the gradient across time)
            local steps = 20
            local stepW = swatchW / steps
            for i = 0, steps - 1 do
                local t = i / steps
                local ok, col = pcall(curve, t, {})
                if ok and type(col) == "table" and col._isColor then
                    love.graphics.setColor(col.r, col.g, col.b, col.a or 1)
                else
                    love.graphics.setColor(0.5, 0.5, 0.5, 1)
                end
                love.graphics.rectangle("fill", swatchX + i * stepW, swatchY, stepW + 1, swatchH)
            end
        elseif node.type == "color_hsl" or node.type == "color_compose" or node.type == "color_mix" or node.type == "color_pulse" or node.type == "color_audio" then
            -- Animated color swatch over time
            local steps = 20
            local stepW = swatchW / steps
            for i = 0, steps - 1 do
                local t = (i / steps) * 4  -- 4 seconds like waveform preview
                local ok, col = pcall(curve, t, {})
                if ok and type(col) == "table" and col._isColor then
                    love.graphics.setColor(col.r, col.g, col.b, col.a or 1)
                else
                    love.graphics.setColor(0.5, 0.5, 0.5, 1)
                end
                love.graphics.rectangle("fill", swatchX + i * stepW, swatchY, stepW + 1, swatchH)
            end
            -- Draw current time indicator
            local timePos = (self.time % 4) / 4 * swatchW
            love.graphics.setColor(1, 1, 1, 0.8)
            love.graphics.line(swatchX + timePos, swatchY, swatchX + timePos, swatchY + swatchH)
        elseif node.type == "color_split" then
            -- Show the input color if connected, else gray
            local colorCable = self:findCableToInput(node.id, "colorIn")
            if colorCable then
                local colorCurve = self:evaluateNode(colorCable.fromNode, {})
                local ok, col = pcall(function()
                    if type(colorCurve) == "function" then
                        return colorCurve(self.time, {})
                    elseif type(colorCurve) == "table" and colorCurve._isColor then
                        return colorCurve
                    end
                    return nil
                end)
                if ok and col and col._isColor then
                    love.graphics.setColor(col.r, col.g, col.b, col.a or 1)
                    love.graphics.rectangle("fill", swatchX, swatchY, swatchW, swatchH, 4)
                    -- Show RGBA values
                    love.graphics.setColor(1, 1, 1, 0.8)
                    love.graphics.print(string.format("R%.2f G%.2f B%.2f", col.r, col.g, col.b), swatchX + 2, swatchY + 2)
                else
                    love.graphics.setColor(0.3, 0.3, 0.35, 1)
                    love.graphics.rectangle("fill", swatchX, swatchY, swatchW, swatchH, 4)
                    love.graphics.setColor(0.5, 0.5, 0.5, 1)
                    love.graphics.print("No color", swatchX + 20, swatchY + swatchH/2 - 6)
                end
            else
                love.graphics.setColor(0.3, 0.3, 0.35, 1)
                love.graphics.rectangle("fill", swatchX, swatchY, swatchW, swatchH, 4)
                love.graphics.setColor(0.5, 0.5, 0.5, 1)
                love.graphics.print("No input", swatchX + 20, swatchY + swatchH/2 - 6)
            end
        else
            -- Default: try to sample the color over time
            love.graphics.setColor(0.3, 0.3, 0.35, 1)
            love.graphics.rectangle("fill", swatchX, swatchY, swatchW, swatchH, 4)
        end

        love.graphics.setScissor()
    end
end

function Editor:drawPalette()
    love.graphics.setColor(0.12, 0.12, 0.16, 0.95)
    love.graphics.rectangle("fill", 0, 0, PALETTE_W, self.screenH)
    love.graphics.setColor(0.25, 0.25, 0.3, 1)
    love.graphics.line(PALETTE_W, 0, PALETTE_W, self.screenH)

    local py = 8
    love.graphics.setColor(0.8, 0.8, 0.8, 1)
    love.graphics.print("CURVES", 10, py)
    py = py + 22

    local lastCat = nil
    for i, d in ipairs(self.nodeDefs) do
        if d.category ~= lastCat then
            lastCat = d.category
            love.graphics.setColor(0.5, 0.5, 0.5, 1)
            local catLabels = {source="-- sources --", combine="-- combinators --", trigger="-- triggers --", entity="-- entities --", dist="-- distributions --", modulate="-- modulation --", tempo="-- tempo --", audio="-- audio --", trig="-- event trig --", field="-- fields --", color="-- color --", preset="-- presets --"}
            love.graphics.print(catLabels[lastCat] or ("-- " .. lastCat .. " --"), 10, py)
            py = py + 18
        end

        local hover = self.paletteHover == i
        if hover then
            love.graphics.setColor(0.25, 0.25, 0.3, 1)
            love.graphics.rectangle("fill", 2, py - 1, PALETTE_W - 4, PALETTE_ITEM_H - 2, 3)
        end

        local r, g, b = d.color[1], d.color[2], d.color[3]
        love.graphics.setColor(r + 0.15, g + 0.15, b + 0.15, 1)
        love.graphics.rectangle("fill", 10, py + 2, 10, 14, 2)
        love.graphics.setColor(0.9, 0.9, 0.9, hover and 1 or 0.7)
        love.graphics.print(d.label, 26, py + 1)
        py = py + PALETTE_ITEM_H
    end
end

function Editor:drawChainPreview(node)
    if not node then return end
    local cpR = 55
    local cpCx = node.x + NODE_W / 2
    local cpCy = node.y - cpR - 12

    love.graphics.setColor(0.05, 0.05, 0.09, 0.85)
    love.graphics.circle("fill", cpCx, cpCy, cpR)
    love.graphics.setColor(0.35, 0.35, 0.4, 0.6)
    love.graphics.circle("line", cpCx, cpCy, cpR)
    self:setWorldScissor(cpCx - cpR, cpCy - cpR, cpR * 2, cpR * 2)

    local previewScale = cpR - 4
    local maxSize = PREVIEW_NORM

    if node.type == "point" then
        -- Point preview in chain
        local cx, cy, rot, _ = self:getTransform(node.id, self.time, {})
        local offsetX = (cx or 0) * previewScale / maxSize
        local offsetY = (cy or 0) * previewScale / maxSize
        local pcx = cpCx + offsetX
        local pcy = cpCy + offsetY

        -- Draw point as cross
        love.graphics.setColor(0.5, 0.5, 0.8, 0.9)
        local crossSize = 10
        love.graphics.line(pcx - crossSize, pcy, pcx + crossSize, pcy)
        love.graphics.line(pcx, pcy - crossSize, pcx, pcy + crossSize)

        -- Draw rotation indicator
        if rot and rot ~= 0 then
            local rotLen = 18
            local rx = pcx + cos(rot) * rotLen
            local ry = pcy + sin(rot) * rotLen
            love.graphics.setColor(0.8, 0.6, 0.3, 0.8)
            love.graphics.line(pcx, pcy, rx, ry)
            love.graphics.circle("fill", rx, ry, 3)
        end

    elseif node.type:match("^form_") then
        local cx, cy, rot, scale = self:getTransform(node.id, self.time, {})
        local offsetX = (cx or 0) * previewScale / maxSize
        local offsetY = (cy or 0) * previewScale / maxSize

        love.graphics.setColor(0.6, 0.45, 0.25, 0.8)
        if node.type == "form_circle" then
            local rVal = self:resolveInputCurve(node.id, "r", self.time, {}, 80) * (scale or 1)
            love.graphics.circle("line", cpCx + offsetX, cpCy + offsetY, math.max(3, abs(rVal) * previewScale / maxSize))
        elseif node.type == "form_rect" then
            local wVal = self:resolveInputCurve(node.id, "w", self.time, {}, 80) * (scale or 1)
            local hVal = self:resolveInputCurve(node.id, "h", self.time, {}, 60) * (scale or 1)
            local dw = abs(wVal) * previewScale / maxSize
            local dh = abs(hVal) * previewScale / maxSize
            local pcx_f = cpCx + offsetX
            local pcy_f = cpCy + offsetY
            if rot and rot ~= 0 then
                local cos_r, sin_r = cos(rot), sin(rot)
                local corners = {
                    {-dw, -dh}, {dw, -dh}, {dw, dh}, {-dw, dh}
                }
                local pts = {}
                for _, c in ipairs(corners) do
                    pts[#pts + 1] = pcx_f + c[1] * cos_r - c[2] * sin_r
                    pts[#pts + 1] = pcy_f + c[1] * sin_r + c[2] * cos_r
                end
                pts[#pts + 1] = pts[1]
                pts[#pts + 1] = pts[2]
                love.graphics.line(pts)
            else
                love.graphics.rectangle("line", pcx_f - dw, pcy_f - dh, dw*2, dh*2)
            end
        elseif node.type == "form_polygon" then
            local sides = math.floor(node.knobValues.sides or 6)
            local rVal = self:resolveInputCurve(node.id, "r", self.time, {}, 80) * (scale or 1)
            local drawR = math.max(3, abs(rVal) * previewScale / maxSize)
            local pcx_f = cpCx + offsetX
            local pcy_f = cpCy + offsetY
            local pts = {}
            for i = 1, sides do
                local angle = (rot or 0) + (i - 1) * (math.pi * 2 / sides)
                pts[#pts + 1] = pcx_f + cos(angle) * drawR
                pts[#pts + 1] = pcy_f + sin(angle) * drawR
            end
            pts[#pts + 1] = pts[1]
            pts[#pts + 1] = pts[2]
            love.graphics.line(pts)
        end
        -- Rotation indicator
        if rot and rot ~= 0 then
            local rotLen = 15
            love.graphics.setColor(0.8, 0.6, 0.3, 0.6)
            love.graphics.line(cpCx + offsetX, cpCy + offsetY, cpCx + offsetX + cos(rot)*rotLen, cpCy + offsetY + sin(rot)*rotLen)
        end

    elseif node.type == "dist" then
        local points = self:generateDistributionPoints(node.id, self.time, {})
        local formCable = self:findCableToInput(node.id, "form")
        if formCable then
            local formNode = self.nodes[formCable.fromNode]
            if formNode then
                local _, formCx, formCy, formRot, formScale = self:evaluateFormNode(formCable.fromNode, self.time, {})
                local distRot = self:resolveInputCurve(node.id, "rotation", self.time, {}, 0) * math.pi / 180
                local distScale = self:resolveInputCurve(node.id, "scale", self.time, {}, 1)
                local totalScale = (formScale or 1) * distScale
                local totalRot = (formRot or 0) + distRot

                love.graphics.setColor(0.3, 0.35, 0.4, 0.3)
                if formNode.type == "form_circle" then
                    local rVal = self:resolveInputCurve(formCable.fromNode, "r", self.time, {}, 80) * totalScale
                    love.graphics.circle("line", cpCx, cpCy, math.max(3, abs(rVal) * previewScale / maxSize))
                elseif formNode.type == "form_rect" then
                    local wVal = self:resolveInputCurve(formCable.fromNode, "w", self.time, {}, 80) * totalScale
                    local hVal = self:resolveInputCurve(formCable.fromNode, "h", self.time, {}, 60) * totalScale
                    local dw = abs(wVal) * previewScale / maxSize
                    local dh = abs(hVal) * previewScale / maxSize
                    if totalRot ~= 0 then
                        local cos_r, sin_r = cos(totalRot), sin(totalRot)
                        local corners = {{-dw, -dh}, {dw, -dh}, {dw, dh}, {-dw, dh}}
                        local pts = {}
                        for _, c in ipairs(corners) do
                            pts[#pts + 1] = cpCx + c[1] * cos_r - c[2] * sin_r
                            pts[#pts + 1] = cpCy + c[1] * sin_r + c[2] * cos_r
                        end
                        pts[#pts + 1] = pts[1]
                        pts[#pts + 1] = pts[2]
                        love.graphics.line(pts)
                    else
                        love.graphics.rectangle("line", cpCx - dw, cpCy - dh, dw*2, dh*2)
                    end
                elseif formNode.type == "form_polygon" then
                    local sides = math.floor(formNode.knobValues.sides or 6)
                    local rVal = self:resolveInputCurve(formCable.fromNode, "r", self.time, {}, 80) * totalScale
                    local drawR = math.max(3, abs(rVal) * previewScale / maxSize)
                    local pts = {}
                    for i = 1, sides do
                        local angle = totalRot + (i - 1) * (math.pi * 2 / sides)
                        pts[#pts + 1] = cpCx + cos(angle) * drawR
                        pts[#pts + 1] = cpCy + sin(angle) * drawR
                    end
                    pts[#pts + 1] = pts[1]
                    pts[#pts + 1] = pts[2]
                    love.graphics.line(pts)
                end
            end
        end
        love.graphics.setColor(0.3, 0.7, 0.9, 0.9)
        for _, pt in ipairs(points) do
            love.graphics.circle("fill", cpCx + pt.x * previewScale / maxSize, cpCy + pt.y * previewScale / maxSize, 1.5)
        end

    elseif node.type == "xy_output" then
        love.graphics.setColor(0.25, 0.25, 0.3, 0.3)
        love.graphics.line(cpCx - 8, cpCy, cpCx + 8, cpCy)
        love.graphics.line(cpCx, cpCy - 8, cpCx, cpCy + 8)
        for i = 1, #self.trail do
            local alpha = i / #self.trail
            local pt = self.trail[i]
            local dx = math.max(-previewScale, math.min(previewScale, pt.x * previewScale / maxSize))
            local dy = math.max(-previewScale, math.min(previewScale, pt.y * previewScale / maxSize))
            love.graphics.setColor(0.5, 0.75, 1.0, alpha * 0.6)
            love.graphics.circle("fill", cpCx + dx, cpCy + dy, 1)
        end

    else
        local curve = self:evaluateNode(node.id, {})
        -- Handle multi-output nodes: use first output for preview
        if type(curve) == "table" and not curve._isColor and not curve._isFieldSource then
            local firstOutput = node.outputs and node.outputs[1] and node.outputs[1].name
            if firstOutput and curve[firstOutput] then
                curve = curve[firstOutput]
            end
        end
        love.graphics.setColor(0.25, 0.25, 0.3, 0.3)
        love.graphics.line(cpCx - previewScale, cpCy, cpCx + previewScale, cpCy)
        love.graphics.setColor(0.5, 0.8, 0.5, 0.8)
        local pts = {}
        for i = 0, PREVIEW_STEPS do
            local t = (i / PREVIEW_STEPS) * 4
            local ok, v = pcall(curve, t, {})
            if ok and type(v) == "number" then
                pts[#pts + 1] = cpCx - previewScale + (i / PREVIEW_STEPS) * previewScale * 2
                pts[#pts + 1] = cpCy - v * previewScale / maxSize
            end
        end
        if #pts >= 4 then love.graphics.line(pts) end
    end

    love.graphics.setScissor()
    love.graphics.setColor(0.5, 0.5, 0.55, 0.7)
    love.graphics.print("chain", cpCx - 15, cpCy + cpR + 2)
end

function Editor:draw()
    -- Apply camera transform for canvas content
    love.graphics.push()
    love.graphics.translate(self.camera.x, self.camera.y)
    love.graphics.scale(self.camera.zoom)

    -- Cables
    for _, c in ipairs(self.cables) do
        local fn = self.nodes[c.fromNode]
        local tn = self.nodes[c.toNode]
        if fn and tn then
            local x1, y1 = portPos(fn, c.fromPort, false)
            local x2, y2 = portPos(tn, c.toPort, true)
            local color = (self.cycleNodes[c.fromNode] or self.cycleNodes[c.toNode]) and {0.9, 0.25, 0.2} or nil
            drawCable(x1, y1, x2, y2, nil, color)
        end
    end

    -- Active wiring cable (convert mouse to world coords for end point)
    if self.wiring then
        local mx, my = love.mouse.getPosition()
        local wx, wy = self:screenToWorld(mx, my)
        if self.snapPort then
            drawCable(self.wiring.startX, self.wiring.startY, self.snapPort.x, self.snapPort.y, 0.8)
        else
            drawCable(self.wiring.startX, self.wiring.startY, wx, wy, 0.5)
        end
    end

    -- Nodes (z-ordered with viewport culling)
    for _, id in ipairs(self.drawOrder) do
        local node = self.nodes[id]
        if node then
            -- Viewport culling: skip nodes that are off-screen
            local h = nodeHeightWithPreview(node)
            if self.camera:isVisible(node.x, node.y, NODE_W, h, self.screenW, self.screenH) then
                self:drawNode(node)
                -- Draw selection highlight
                if self.selectedNodes[id] then
                    love.graphics.setColor(0.3, 0.8, 1, 0.6)
                    love.graphics.setLineWidth(2)
                    love.graphics.rectangle("line", node.x - 2, node.y - 2, NODE_W + 4, h + 4, 8)
                    love.graphics.setLineWidth(1)
                end
            end
        end
    end

    -- Chain preview above hovered node (in world space)
    if self.hoveredNode and self.hoveredNode.y > 130 then
        self:drawChainPreview(self.hoveredNode)
    end

    -- Box select rectangle (in world space)
    if self.boxSelect then
        love.graphics.setColor(0.3, 0.7, 1, 0.2)
        local x = math.min(self.boxSelect.startX, self.boxSelect.endX)
        local y = math.min(self.boxSelect.startY, self.boxSelect.endY)
        local w = math.abs(self.boxSelect.endX - self.boxSelect.startX)
        local h = math.abs(self.boxSelect.endY - self.boxSelect.startY)
        love.graphics.rectangle("fill", x, y, w, h)
        love.graphics.setColor(0.3, 0.7, 1, 0.6)
        love.graphics.rectangle("line", x, y, w, h)
    end

    -- End camera transform
    love.graphics.pop()

    -- UI elements drawn in screen space (not affected by camera)

    -- Palette
    self:drawPalette()

    -- Spawn drag preview (screen space)
    if self.spawnDrag then
        love.graphics.setColor(0.4, 0.4, 0.5, 0.6)
        local mx, my = love.mouse.getPosition()
        love.graphics.rectangle("fill", mx - NODE_W/2, my - 15, NODE_W, 30, 6)
        love.graphics.setColor(1, 1, 1, 0.8)
        love.graphics.print(self.spawnDrag.def.label, mx - NODE_W/2 + 8, my - 10)
    end

    -- Help text
    love.graphics.setColor(0.45, 0.45, 0.5, 1)
    love.graphics.print("Drag palette | Wire ports | Shift+click multi-select | Scroll zoom | Middle-drag pan | Ctrl+A all | Del remove", PALETTE_W + 10, self.screenH - 22)

    -- Stats + zoom level
    local nodeCount = #self.drawOrder
    local selCount = 0
    for _ in pairs(self.selectedNodes) do selCount = selCount + 1 end
    love.graphics.setColor(0.4, 0.4, 0.45, 0.7)
    local zoomPct = math.floor(self.camera.zoom * 100 + 0.5)
    local statsText = string.format("%d fps | %d nodes | %d cables | %d%% zoom", love.timer.getFPS(), nodeCount, #self.cables, zoomPct)
    if selCount > 0 then
        statsText = statsText .. string.format(" | %d selected", selCount)
    end
    love.graphics.print(statsText, self.screenW - 320, 30)

    -- Debug overlay (F3 to toggle)
    if self.showDebugOverlay then
        love.graphics.setColor(0, 0, 0, 0.7)
        love.graphics.rectangle("fill", self.screenW - 280, 50, 270, 150, 6)
        love.graphics.setColor(0.3, 1, 0.3, 1)
        love.graphics.print("DEBUG (F3 to hide)", self.screenW - 270, 55)
        love.graphics.setColor(0.7, 0.9, 0.7, 0.9)
        local y = 75
        local stats = self.debugStats
        love.graphics.print(string.format("Time: %.2f", self.time or 0), self.screenW - 270, y); y = y + 16
        love.graphics.print(string.format("Camera: x=%.0f y=%.0f z=%.2f", self.camera.x, self.camera.y, self.camera.zoom), self.screenW - 270, y); y = y + 16
        love.graphics.print(string.format("Eval count: %d", stats.evalCount or 0), self.screenW - 270, y); y = y + 16
        love.graphics.print(string.format("Cache hits: %d", stats.cacheHits or 0), self.screenW - 270, y); y = y + 16
        -- Show hovered node info
        if self.hoveredNode then
            local n = self.hoveredNode
            love.graphics.setColor(0.9, 0.9, 0.5, 0.9)
            love.graphics.print(string.format("Hover: %s (%s)", n.type, n.id), self.screenW - 270, y); y = y + 16
            if n.knobValues then
                local kStr = ""
                for k, v in pairs(n.knobValues) do
                    kStr = kStr .. string.format("%s=%.2f ", k, v)
                end
                if #kStr > 0 then
                    love.graphics.print(kStr:sub(1, 35), self.screenW - 270, y)
                end
            end
        end
    end

    -- Live co-pilot overlay (status, confirmation UI)
    Live.draw()
end

--------------------------------------------------------------------------------
-- HIT TESTING
--------------------------------------------------------------------------------

-- Hit testing (delegates to Hit module)
function Editor:hitPort(mx, my)
    local wx, wy = self:screenToWorld(mx, my)
    return Hit.port(self.nodes, wx, wy)
end

function Editor:hitNode(mx, my)
    local wx, wy = self:screenToWorld(mx, my)
    return Hit.node(self.nodes, self.drawOrder, wx, wy)
end

function Editor:hitKnob(mx, my)
    local wx, wy = self:screenToWorld(mx, my)
    return Hit.knob(self.nodes, wx, wy)
end

function Editor:hitToggle(mx, my)
    local wx, wy = self:screenToWorld(mx, my)
    return Hit.toggle(self.nodes, wx, wy)
end

function Editor:hitButton(mx, my)
    local wx, wy = self:screenToWorld(mx, my)
    return Hit.button(self.nodes, wx, wy)
end

function Editor:hitPaletteItem(mx, my)
    return Hit.paletteItem(self.nodeDefs, mx, my)
end

--------------------------------------------------------------------------------
-- INPUT
--------------------------------------------------------------------------------

function Editor:mousepressed(mx, my, button)
    local wx, wy = self:screenToWorld(mx, my)
    local shift = love.keyboard.isDown("lshift", "rshift")

    if button == 1 then
        -- Palette (screen space, not affected by camera)
        local palIdx = self:hitPaletteItem(mx, my)
        if palIdx then
            self.spawnDrag = {def = self.nodeDefs[palIdx]}
            return
        end

        -- Knobs (use world coords internally via hitKnob)
        local k = self:hitKnob(mx, my)
        if k then
            local node = self.nodes[k.nodeId]
            self.knobDrag = {nodeId = k.nodeId, knobName = k.knobName, knobIdx = k.knobIdx, sliderX = k.sliderX, sliderW = k.sliderW}
            -- Convert slider position to world coords for accurate fraction
            local sliderWx = k.sliderX
            local frac = math.max(0, math.min(1, (wx - sliderWx) / k.sliderW))
            local knobDef = node.knobs[k.knobIdx]
            node.knobValues[k.knobName] = knobDef.min + frac * (knobDef.max - knobDef.min)
            return
        end

        -- Toggles
        local tog = self:hitToggle(mx, my)
        if tog then
            local node = self.nodes[tog.nodeId]
            if tog.isBoolean then
                -- Boolean toggle: flip value
                node.toggleValues[tog.toggleName] = not node.toggleValues[tog.toggleName]
            else
                -- Multi-option: select the clicked option
                node.toggleValues[tog.toggleName] = tog.optionIdx
            end
            -- Invalidate cache since toggle affects node behavior
            node._cachedCurve = nil
            self:_notifyGraphChanged()
            return
        end

        -- Buttons
        local btn = self:hitButton(mx, my)
        if btn then
            local node = self.nodes[btn.nodeId]
            -- Handle button action based on node type and button name
            if node.type == "dataset_loader" then
                local ds = node._dataset
                if ds and ds.loaded and #ds.samples > 0 then
                    local random = node.toggleValues and node.toggleValues.random
                    if btn.buttonName == "prev" then
                        if random then
                            ds.currentIdx = math.random(1, #ds.samples)
                        else
                            ds.currentIdx = ds.currentIdx - 1
                            if ds.currentIdx < 1 then ds.currentIdx = #ds.samples end
                        end
                    elseif btn.buttonName == "next" then
                        if random then
                            ds.currentIdx = math.random(1, #ds.samples)
                        else
                            ds.currentIdx = ds.currentIdx + 1
                            if ds.currentIdx > #ds.samples then ds.currentIdx = 1 end
                        end
                    end
                    -- Update text buffer with new sample
                    if ds.samples[ds.currentIdx] then
                        ds.textManager.buffer = {{text = ds.samples[ds.currentIdx], time = love.timer.getTime()}}
                    end
                end
            elseif node.type == "audio_stems" then
                -- Audio stems separation node
                local AudioStems = require("spatula.audio_stems")
                if btn.buttonName == "separate" then
                    -- Start separation process
                    if node.sourcePath and node.sourcePath ~= "" then
                        local outputDir = AudioStems.defaultOutputDir(node.sourcePath)
                        local model = node.toggleValues.model == 2 and AudioStems.MODELS.QUALITY or AudioStems.MODELS.FAST
                        -- Run async separation
                        node._separating = true
                        node._jobId = AudioStems.separateAsync(node.sourcePath, outputDir, model)
                        node._statusMsg = "Separating..."
                    else
                        node._statusMsg = "No source file"
                    end
                elseif btn.buttonName == "load" then
                    -- Load stems if they exist
                    if node.sourcePath and node.sourcePath ~= "" then
                        local outputDir = AudioStems.defaultOutputDir(node.sourcePath)
                        local result = AudioStems.checkCached(node.sourcePath, outputDir)
                        if result and result.stems then
                            node._stems = result.stems
                            node._statusMsg = "Stems loaded"
                            -- Load sound data for each stem
                            node._stemSoundData = {}
                            for stemName, stemPath in pairs(result.stems) do
                                local ok, soundData = pcall(love.sound.newSoundData, stemPath)
                                if ok then
                                    node._stemSoundData[stemName] = soundData
                                end
                            end
                        else
                            node._statusMsg = "No cached stems"
                        end
                    end
                end
            end
            -- Other node types can add button handlers here
            node._cachedCurve = nil
            self:_notifyGraphChanged()
            return
        end

        -- Ports
        local port = self:hitPort(mx, my)
        if port then
            if not port.isInput then
                self.wiring = {fromNodeId = port.nodeId, fromPort = port.portName, startX = port.x, startY = port.y}
                return
            else
                local cable = self:findCableToInput(port.nodeId, port.portName)
                if cable then
                    local srcNode = self.nodes[cable.fromNode]
                    local sx, sy = portPos(srcNode, cable.fromPort, false)
                    self.wiring = {fromNodeId = cable.fromNode, fromPort = cable.fromPort, startX = sx, startY = sy}
                    for i = #self.cables, 1, -1 do
                        if self.cables[i].toNode == port.nodeId and self.cables[i].toPort == port.portName then
                            table.remove(self.cables, i)
                            break
                        end
                    end
                    for _, inp in ipairs(self.nodes[port.nodeId].inputs) do
                        if inp.name == port.portName then inp.connected = false end
                    end
                    self:_notifyGraphChanged()
                    return
                end
            end
        end

        -- Nodes - handle selection and dragging
        local node = self:hitNode(mx, my)
        if node then
            self:bringToFront(node.id)

            if shift then
                -- Shift-click: toggle selection (no drag)
                if self.selectedNodes[node.id] then
                    self.selectedNodes[node.id] = nil
                else
                    self.selectedNodes[node.id] = true
                end
            else
                -- Normal click: select node and start drag
                if not self.selectedNodes[node.id] then
                    -- Click on unselected node: clear selection, select just this one
                    self.selectedNodes = {[node.id] = true}
                end
                -- Start group drag for all selected nodes (works for single or multiple)
                self.groupDrag = {offsets = {}}
                for id in pairs(self.selectedNodes) do
                    local n = self.nodes[id]
                    if n then
                        self.groupDrag.offsets[id] = {offX = wx - n.x, offY = wy - n.y}
                    end
                end
            end
            return
        end

        -- Clicked empty canvas (not palette): start box select
        if mx > PALETTE_W then
            if not shift then
                self.selectedNodes = {}  -- Clear selection unless shift held
            end
            self.boxSelect = {startX = wx, startY = wy, endX = wx, endY = wy}
        end

    elseif button == 2 then
        -- Right-click: disconnect port or delete node
        local port = self:hitPort(mx, my)
        if port and port.isInput then
            local cable = self:findCableToInput(port.nodeId, port.portName)
            if cable then
                for i = #self.cables, 1, -1 do
                    if self.cables[i].toNode == port.nodeId and self.cables[i].toPort == port.portName then
                        table.remove(self.cables, i)
                        break
                    end
                end
                for _, inp in ipairs(self.nodes[port.nodeId].inputs) do
                    if inp.name == port.portName then inp.connected = false end
                end
                self:_notifyGraphChanged()
                return
            end
        end
        local node = self:hitNode(mx, my)
        if node and node.type ~= "xy_output" then
            self:removeNode(node.id)
            self.selectedNodes[node.id] = nil
            self:_notifyGraphChanged()
        end

    elseif button == 3 then
        -- Middle-click: start panning
        self.panning = {startX = mx, startY = my, camX = self.camera.x, camY = self.camera.y}
    end
end

function Editor:mousemoved(mx, my)
    local wx, wy = self:screenToWorld(mx, my)

    self.hoverPort = self:hitPort(mx, my)
    self.paletteHover = self:hitPaletteItem(mx, my)
    self.hoveredNode = self:hitNode(mx, my)

    -- Panning (screen space)
    if self.panning then
        self.camera.x = self.panning.camX + (mx - self.panning.startX)
        self.camera.y = self.panning.camY + (my - self.panning.startY)
        return
    end

    -- Box select update (world space)
    if self.boxSelect then
        self.boxSelect.endX = wx
        self.boxSelect.endY = wy
        return
    end

    -- Snap-to-port (type-aware, world coords)
    self.snapPort = nil
    if self.wiring then
        local srcType = portWireType(self.wiring.fromPort)
        local snapDist = 25 / self.camera.zoom  -- Scale snap radius with zoom
        local bestDist = snapDist * snapDist
        for _, node in pairs(self.nodes) do
            if node.id ~= self.wiring.fromNodeId then
                for _, inp in ipairs(node.inputs) do
                    if portWireType(inp.name) == srcType then
                        local px, py = portPos(node, inp.name, true)
                        local d2 = (wx - px) * (wx - px) + (wy - py) * (wy - py)
                        if d2 < bestDist then
                            bestDist = d2
                            self.snapPort = {nodeId = node.id, portName = inp.name, x = px, y = py}
                        end
                    end
                end
            end
        end
    end

    -- Group drag (world coords)
    if self.groupDrag then
        for id, off in pairs(self.groupDrag.offsets) do
            local node = self.nodes[id]
            if node then
                node.x = wx - off.offX
                node.y = wy - off.offY
            end
        end
        return
    end

    -- Single node drag (world coords)
    if self.dragging then
        local node = self.nodes[self.dragging.nodeId]
        if node then
            node.x = wx - self.dragging.offX
            node.y = wy - self.dragging.offY
        end
        return
    end

    -- Knob drag (world coords)
    if self.knobDrag then
        local node = self.nodes[self.knobDrag.nodeId]
        if node then
            local rawFrac = (wx - self.knobDrag.sliderX) / self.knobDrag.sliderW
            if love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift") then
                local curVal = node.knobValues[self.knobDrag.knobName]
                local knobDef = node.knobs[self.knobDrag.knobIdx]
                local curFrac = (curVal - knobDef.min) / (knobDef.max - knobDef.min)
                rawFrac = curFrac + (rawFrac - curFrac) * 0.15
            end
            local frac = math.max(0, math.min(1, rawFrac))
            local knobDef = node.knobs[self.knobDrag.knobIdx]
            node.knobValues[self.knobDrag.knobName] = knobDef.min + frac * (knobDef.max - knobDef.min)
            if node.type:match("^form_") or node.type == "dist" then
                self:_notifyGraphChanged()
            end
        end
    end
end

function Editor:mousereleased(mx, my, button)
    local wx, wy = self:screenToWorld(mx, my)

    if button == 1 then
        -- Spawn drag release
        if self.spawnDrag and mx > PALETTE_W then
            local def = self.spawnDrag.def
            if def.isPreset then
                -- Create preset macro
                self:createPreset(def.presetName, wx - NODE_W/2, wy - 15)
            else
                -- Create regular node
                self:createNode(def, wx - NODE_W/2, wy - 15)
            end
            self.spawnDrag = nil
            return
        end
        self.spawnDrag = nil

        -- Box select release: select all nodes in box
        if self.boxSelect then
            local minX = math.min(self.boxSelect.startX, self.boxSelect.endX)
            local maxX = math.max(self.boxSelect.startX, self.boxSelect.endX)
            local minY = math.min(self.boxSelect.startY, self.boxSelect.endY)
            local maxY = math.max(self.boxSelect.startY, self.boxSelect.endY)

            local shift = love.keyboard.isDown("lshift", "rshift")
            for id, node in pairs(self.nodes) do
                local h = nodeHeightWithPreview(node)
                local nodeCx = node.x + NODE_W / 2
                local nodeCy = node.y + h / 2
                -- Select if node center is inside box
                if nodeCx >= minX and nodeCx <= maxX and nodeCy >= minY and nodeCy <= maxY then
                    self.selectedNodes[id] = true
                end
            end
            self.boxSelect = nil
            return
        end

        -- Wiring release
        if self.wiring then
            local target = self.snapPort
            if not target then
                local port = self:hitPort(mx, my)
                if port and port.isInput then target = port end
            end
            if target and target.nodeId ~= self.wiring.fromNodeId
               and portWireType(self.wiring.fromPort) == portWireType(target.portName) then
                self:addCable(self.wiring.fromNodeId, self.wiring.fromPort, target.nodeId, target.portName)
                self:_notifyGraphChanged()
            end
            self.wiring = nil
            self.snapPort = nil
        end

        -- Clear drags
        self.dragging = nil
        self.groupDrag = nil
        self.knobDrag = nil

    elseif button == 3 then
        -- Pan release
        self.panning = nil
    end
end

function Editor:keypressed(key)
    -- Let live co-pilot handle keys first (E=export, R=refresh, M=mode, Y/N=confirm, Z=undo)
    if Live.keypressed(key) then
        return
    end

    local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")

    if key == "escape" then
        if self.wiring then
            self.wiring = nil
        else
            -- Clear selection
            self.selectedNodes = {}
        end

    elseif key == "a" and ctrl then
        -- Select all nodes
        for id in pairs(self.nodes) do
            self.selectedNodes[id] = true
        end

    elseif key == "g" and ctrl then
        -- Group/Ungroup macro
        if next(self.selectedNodes) then
            -- Check if selection is a single macro → ungroup
            local singleMacro = nil
            local count = 0
            for id in pairs(self.selectedNodes) do
                count = count + 1
                if self.nodes[id] and self.nodes[id].type == "macro" then
                    singleMacro = id
                end
            end
            if count == 1 and singleMacro then
                self:ungroupMacro(singleMacro)
            else
                self:createMacroFromSelection()
            end
        end

    elseif key == "delete" or key == "backspace" then
        -- Delete selected nodes
        local deleted = false
        for nodeId in pairs(self.selectedNodes) do
            local node = self.nodes[nodeId]
            if node and node.type ~= "xy_output" then
                self:removeNode(nodeId)
                deleted = true
            end
        end
        self.selectedNodes = {}
        if deleted then
            self:_notifyGraphChanged()
        end

    elseif key == "home" then
        -- Reset camera to default view
        self:resetCamera()

    elseif key == "f3" then
        -- Toggle debug overlay
        self.showDebugOverlay = not self.showDebugOverlay
    end
end

function Editor:wheelmoved(dx, dy)
    local mx, my = love.mouse.getPosition()

    -- Only zoom when mouse is over canvas (not palette)
    if mx <= PALETTE_W then return end

    -- Get world position under mouse before zoom
    local wxBefore, wyBefore = self:screenToWorld(mx, my)

    -- Apply zoom
    local zoomFactor = 1.1
    if dy > 0 then
        self.camera.zoom = math.min(2.0, self.camera.zoom * zoomFactor)
    elseif dy < 0 then
        self.camera.zoom = math.max(0.25, self.camera.zoom / zoomFactor)
    end

    -- Adjust camera to keep the same world position under mouse
    -- wx = (sx - cam.x) / zoom  =>  cam.x = sx - wx * zoom
    self.camera.x = mx - wxBefore * self.camera.zoom
    self.camera.y = my - wyBefore * self.camera.zoom
end

--- Expose constants for consumers
Editor.NODE_W = NODE_W
Editor.PALETTE_W = PALETTE_W

return Editor
