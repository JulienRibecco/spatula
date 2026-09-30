--- Editor Presets
--- Reusable macro presets for common node patterns

local Presets = {}

--------------------------------------------------------------------------------
-- Helper: Build a macro node directly from preset definition
--------------------------------------------------------------------------------

local function buildPreset(editor, x, y, presetDef)
    -- Find macro node definition
    local macroDef
    for _, def in ipairs(editor.nodeDefs) do
        if def.type == "macro" then macroDef = def; break end
    end
    if not macroDef then return nil end

    -- Create macro node
    local macroNode = editor:createNode(macroDef, x, y)
    macroNode.label = presetDef.name

    -- Build node snapshots with generated IDs
    local nodeSnapshots = {}
    local idMap = {}  -- preset node name → generated ID
    local nextId = 1

    for _, nodeDef in ipairs(presetDef.nodes) do
        local id = nextId
        nextId = nextId + 1
        idMap[nodeDef.name] = id

        nodeSnapshots[#nodeSnapshots + 1] = {
            id = id,
            type = nodeDef.type,
            label = nodeDef.label or nodeDef.type,
            x = nodeDef.x or 0,
            y = nodeDef.y or 0,
            knobValues = nodeDef.knobs or {},
            toggleValues = nodeDef.toggles or {},
        }
    end

    -- Build internal cables with remapped IDs
    local internalCables = {}
    for _, cable in ipairs(presetDef.cables or {}) do
        internalCables[#internalCables + 1] = {
            fromNode = idMap[cable.from],
            fromPort = cable.fromPort,
            toNode = idMap[cable.to],
            toPort = cable.toPort,
        }
    end

    -- Build input/output maps
    local inputMap = {}
    for portName, mapping in pairs(presetDef.inputs or {}) do
        inputMap[portName] = {
            nodeId = idMap[mapping.node],
            port = mapping.port,
        }
    end

    local outputMap = {}
    for portName, mapping in pairs(presetDef.outputs or {}) do
        outputMap[portName] = {
            nodeId = idMap[mapping.node],
            port = mapping.port,
        }
    end

    -- Set macro data
    macroNode.macroData = {
        nodes = nodeSnapshots,
        cables = internalCables,
        inputMap = inputMap,
        outputMap = outputMap,
    }

    -- Set dynamic inputs/outputs on the macro node
    macroNode.inputs = {}
    for name in pairs(inputMap) do
        macroNode.inputs[#macroNode.inputs + 1] = {name = name, connected = false}
    end
    macroNode.outputs = {}
    for name in pairs(outputMap) do
        macroNode.outputs[#macroNode.outputs + 1] = {name = name}
    end

    return macroNode
end

--------------------------------------------------------------------------------
-- Preset Definitions
--------------------------------------------------------------------------------

local presetDefs = {}

-- 1. Orbit: Circular orbital motion
presetDefs.orbit = {
    name = "Orbit",
    nodes = {
        {name = "linear", type = "linear", knobs = {speed = 1}, x = -200, y = 0},
        {name = "mulSpeed", type = "math", toggles = {op = 2}, x = -50, y = 0},  -- mul (*)
        {name = "oscCos", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 2}, x = 100, y = -50},  -- cos
        {name = "oscSin", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 1}, x = 100, y = 50},   -- sin
        {name = "mulX", type = "math", toggles = {op = 2}, x = 250, y = -50},  -- mul (*)
        {name = "mulY", type = "math", toggles = {op = 2}, x = 250, y = 50},   -- mul (*)
    },
    cables = {
        {from = "linear", fromPort = "out", to = "mulSpeed", toPort = "a"},
        {from = "mulSpeed", fromPort = "out", to = "oscCos", toPort = "freq"},
        {from = "mulSpeed", fromPort = "out", to = "oscSin", toPort = "freq"},
        {from = "oscCos", fromPort = "out", to = "mulX", toPort = "a"},
        {from = "oscSin", fromPort = "out", to = "mulY", toPort = "a"},
    },
    inputs = {
        speed = {node = "mulSpeed", port = "b"},
        radius = {node = "mulX", port = "b"},
        -- Note: radius connects to both mulX and mulY (need external wiring)
    },
    outputs = {
        x = {node = "mulX", port = "out"},
        y = {node = "mulY", port = "out"},
    },
}

-- 2. Breathe: Smooth scale breathing animation
presetDefs.breathe = {
    name = "Breathe",
    nodes = {
        {name = "tempoOsc", type = "tempo_osc", knobs = {amp = 0.2, div = 2}, toggles = {wave = 1}, x = -100, y = 0},  -- sin, 1/2
        {name = "offset", type = "transform", knobs = {value = 1}, toggles = {op = 2}, x = 100, y = 0},  -- offset
    },
    cables = {
        {from = "tempoOsc", fromPort = "out", to = "offset", toPort = "in"},
    },
    inputs = {
        tempo = {node = "tempoOsc", port = "tempo"},
    },
    outputs = {
        out = {node = "offset", port = "out"},
    },
}

-- 3. Beat Pulse: Sharp attack, exponential decay on beat
presetDefs.beatPulse = {
    name = "Beat Pulse",
    nodes = {
        {name = "pulse", type = "tempo_pulse", knobs = {decay = 0.3, div = 3}, x = 0, y = 0},  -- 1/4
    },
    cables = {},
    inputs = {
        tempo = {node = "pulse", port = "tempo"},
    },
    outputs = {
        out = {node = "pulse", port = "out"},
    },
}

-- 4. Audio Scale: Scale a value by audio amplitude
presetDefs.audioScale = {
    name = "Audio Scale",
    nodes = {
        {name = "env", type = "audio_env", knobs = {window = 1024, smooth = 0.1}, x = -150, y = -50},
        {name = "mulSens", type = "math", toggles = {op = 2}, x = 0, y = -50},  -- mul
        {name = "mulOut", type = "math", toggles = {op = 2}, x = 150, y = 0},   -- mul
    },
    cables = {
        {from = "env", fromPort = "out", to = "mulSens", toPort = "a"},
        {from = "mulSens", fromPort = "out", to = "mulOut", toPort = "b"},
    },
    inputs = {
        ["in"] = {node = "mulOut", port = "a"},
        sensitivity = {node = "mulSens", port = "b"},
    },
    outputs = {
        out = {node = "mulOut", port = "out"},
    },
}

-- 5. Frequency Bands: Split audio into low/mid/high
presetDefs.freqBands = {
    name = "Freq Bands",
    nodes = {
        {name = "bands", type = "audio_bands3", knobs = {window = 2048}, x = -100, y = 0},
        {name = "scaleLow", type = "transform", knobs = {value = 100}, toggles = {op = 1}, x = 100, y = -80},
        {name = "scaleMid", type = "transform", knobs = {value = 100}, toggles = {op = 1}, x = 100, y = 0},
        {name = "scaleHigh", type = "transform", knobs = {value = 100}, toggles = {op = 1}, x = 100, y = 80},
    },
    cables = {
        {from = "bands", fromPort = "low", to = "scaleLow", toPort = "in"},
        {from = "bands", fromPort = "mid", to = "scaleMid", toPort = "in"},
        {from = "bands", fromPort = "high", to = "scaleHigh", toPort = "in"},
    },
    inputs = {},
    outputs = {
        low = {node = "scaleLow", port = "out"},
        mid = {node = "scaleMid", port = "out"},
        high = {node = "scaleHigh", port = "out"},
    },
}

-- 6. Wobble: Organic random offset (position jitter)
presetDefs.wobble = {
    name = "Wobble",
    nodes = {
        {name = "noiseX", type = "noise", knobs = {scale = 2}, x = -100, y = -50},
        {name = "noiseY", type = "noise", knobs = {scale = 3}, x = -100, y = 50},
        {name = "mulX", type = "math", toggles = {op = 2}, x = 100, y = -50},
        {name = "mulY", type = "math", toggles = {op = 2}, x = 100, y = 50},
    },
    cables = {
        {from = "noiseX", fromPort = "out", to = "mulX", toPort = "a"},
        {from = "noiseY", fromPort = "out", to = "mulY", toPort = "a"},
    },
    inputs = {
        amount = {node = "mulX", port = "b"},
        -- Note: amount should connect to both mulX and mulY (need external wiring or second input)
    },
    outputs = {
        x = {node = "mulX", port = "out"},
        y = {node = "mulY", port = "out"},
    },
}

-- 7. Smooth Follow: Eased value following
presetDefs.smoothFollow = {
    name = "Smooth Follow",
    nodes = {
        {name = "gate", type = "const", knobs = {value = 1}, x = -100, y = 50},
        {name = "env", type = "trig_env", knobs = {attack = 0.2, release = 0.5}, x = 100, y = 0},
    },
    cables = {
        {from = "gate", fromPort = "out", to = "env", toPort = "t"},
    },
    inputs = {
        target = {node = "env", port = "in"},
    },
    outputs = {
        out = {node = "env", port = "out"},
    },
}

-- 8. Color Cycle: Hue cycling through spectrum
presetDefs.colorCycle = {
    name = "Color Cycle",
    nodes = {
        {name = "linear", type = "linear", knobs = {speed = 0.1}, x = -150, y = 0},
        {name = "mulSpeed", type = "math", toggles = {op = 2}, x = 0, y = 0},
        {name = "hsl", type = "color_hsl", knobs = {a = 1}, x = 150, y = 0},
    },
    cables = {
        {from = "linear", fromPort = "out", to = "mulSpeed", toPort = "a"},
        {from = "mulSpeed", fromPort = "out", to = "hsl", toPort = "h"},
    },
    inputs = {
        speed = {node = "mulSpeed", port = "b"},
        saturation = {node = "hsl", port = "s"},
    },
    outputs = {
        colorOut = {node = "hsl", port = "colorOut"},
    },
}

-- 9. Beat Color Flash: Flash accent color on beat
presetDefs.beatColor = {
    name = "Beat Color",
    nodes = {
        {name = "pulse", type = "tempo_pulse", knobs = {decay = 0.2, div = 3}, x = -100, y = 0},
        {name = "mix", type = "color_mix", x = 100, y = 0},
    },
    cables = {
        {from = "pulse", fromPort = "out", to = "mix", toPort = "mix"},
    },
    inputs = {
        tempo = {node = "pulse", port = "tempo"},
        colorA = {node = "mix", port = "colorA"},
        colorB = {node = "mix", port = "colorB"},
    },
    outputs = {
        colorOut = {node = "mix", port = "colorOut"},
    },
}

-- 10. Lissajous: Complex figure-8 motion
presetDefs.lissajous = {
    name = "Lissajous",
    nodes = {
        {name = "oscX", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 1}, x = -100, y = -50},
        {name = "oscY", type = "osc", knobs = {freq = 2, amp = 1}, toggles = {wave = 1}, x = -100, y = 50},
        {name = "mulX", type = "math", toggles = {op = 2}, x = 100, y = -50},
        {name = "mulY", type = "math", toggles = {op = 2}, x = 100, y = 50},
    },
    cables = {
        {from = "oscX", fromPort = "out", to = "mulX", toPort = "a"},
        {from = "oscY", fromPort = "out", to = "mulY", toPort = "a"},
    },
    inputs = {
        freqX = {node = "oscX", port = "freq"},
        freqY = {node = "oscY", port = "freq"},
        radius = {node = "mulX", port = "b"},
    },
    outputs = {
        x = {node = "mulX", port = "out"},
        y = {node = "mulY", port = "out"},
    },
}

-- 11. Ping Pong: Bounce between min and max values (triangle wave)
presetDefs.pingPong = {
    name = "Ping Pong",
    nodes = {
        {name = "osc", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 3}, x = -100, y = 0},  -- triangle
        {name = "scale", type = "transform", knobs = {value = 0.5}, toggles = {op = 1}, x = 50, y = 0},   -- scale by 0.5
        {name = "offset", type = "transform", knobs = {value = 0.5}, toggles = {op = 2}, x = 200, y = 0}, -- offset by 0.5
    },
    cables = {
        {from = "osc", fromPort = "out", to = "scale", toPort = "in"},
        {from = "scale", fromPort = "out", to = "offset", toPort = "in"},
    },
    inputs = {
        speed = {node = "osc", port = "freq"},
    },
    outputs = {
        out = {node = "offset", port = "out"},  -- outputs 0-1 range
    },
}

-- 12. Spiral: Expanding circular motion
presetDefs.spiral = {
    name = "Spiral",
    nodes = {
        {name = "linear", type = "linear", knobs = {speed = 1}, x = -200, y = 0},
        {name = "oscCos", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 2}, x = -50, y = -50},
        {name = "oscSin", type = "osc", knobs = {freq = 1, amp = 1}, toggles = {wave = 1}, x = -50, y = 50},
        {name = "mulX", type = "math", toggles = {op = 2}, x = 100, y = -50},
        {name = "mulY", type = "math", toggles = {op = 2}, x = 100, y = 50},
    },
    cables = {
        {from = "linear", fromPort = "out", to = "oscCos", toPort = "freq"},
        {from = "linear", fromPort = "out", to = "oscSin", toPort = "freq"},
        {from = "oscCos", fromPort = "out", to = "mulX", toPort = "a"},
        {from = "oscSin", fromPort = "out", to = "mulY", toPort = "a"},
        {from = "linear", fromPort = "out", to = "mulX", toPort = "b"},  -- radius grows with time
        {from = "linear", fromPort = "out", to = "mulY", toPort = "b"},
    },
    inputs = {
        speed = {node = "linear", port = "speed"},
    },
    outputs = {
        x = {node = "mulX", port = "out"},
        y = {node = "mulY", port = "out"},
    },
}

-- 13. Stutter: Rhythmic gating for glitch effects
presetDefs.stutter = {
    name = "Stutter",
    nodes = {
        {name = "gate", type = "trig_gate", knobs = {duty = 0.5}, x = 0, y = 0},
    },
    cables = {},
    inputs = {
        ["in"] = {node = "gate", port = "in"},
        clock = {node = "gate", port = "t"},
    },
    outputs = {
        out = {node = "gate", port = "out"},
    },
}

-- 14. Ramp Reset: Linear ramp that resets on clock
presetDefs.rampReset = {
    name = "Ramp Reset",
    nodes = {
        {name = "linear", type = "linear", knobs = {speed = 1}, x = -100, y = 0},
        {name = "reset", type = "trig_reset", x = 100, y = 0},
    },
    cables = {
        {from = "linear", fromPort = "out", to = "reset", toPort = "in"},
    },
    inputs = {
        speed = {node = "linear", port = "speed"},
        clock = {node = "reset", port = "t"},
    },
    outputs = {
        out = {node = "reset", port = "out"},
    },
}

-- 15. Value Map: Remap 0-1 input to custom min/max range
presetDefs.valueMap = {
    name = "Value Map",
    nodes = {
        {name = "clampIn", type = "clamp", knobs = {min = 0, max = 1}, x = -150, y = 0},
        {name = "scale", type = "math", toggles = {op = 2}, x = 0, y = 0},   -- mul by range
        {name = "offset", type = "math", toggles = {op = 1}, x = 150, y = 0}, -- add min
    },
    cables = {
        {from = "clampIn", fromPort = "out", to = "scale", toPort = "a"},
        {from = "scale", fromPort = "out", to = "offset", toPort = "a"},
    },
    inputs = {
        ["in"] = {node = "clampIn", port = "in"},
        range = {node = "scale", port = "b"},   -- (max - min)
        min = {node = "offset", port = "b"},
    },
    outputs = {
        out = {node = "offset", port = "out"},
    },
}

-- 16. Swell: Attack-sustain envelope for dramatic builds
presetDefs.swell = {
    name = "Swell",
    nodes = {
        {name = "phase", type = "tempo_phase", knobs = {div = 1}, x = -100, y = 0},  -- 1/1 = full bar
        {name = "clamp", type = "clamp", knobs = {min = 0, max = 1}, x = 100, y = 0},
    },
    cables = {
        {from = "phase", fromPort = "out", to = "clamp", toPort = "in"},
    },
    inputs = {
        tempo = {node = "phase", port = "tempo"},
    },
    outputs = {
        out = {node = "clamp", port = "out"},
    },
}

--------------------------------------------------------------------------------
-- Audio Presets
--------------------------------------------------------------------------------

-- 17. Beat Detect: Simple beat detection pulse
presetDefs.beatDetect = {
    name = "Beat Detect",
    nodes = {
        {name = "beat", type = "audio_beat", knobs = {threshold = 0.5, decay = 0.1}, x = 0, y = 0},
    },
    cables = {},
    inputs = {},
    outputs = {
        out = {node = "beat", port = "out"},
    },
}

-- 18. Ducking: Reduce signal when audio is loud (sidechain compression)
presetDefs.ducking = {
    name = "Ducking",
    nodes = {
        {name = "env", type = "audio_env", knobs = {window = 1024, smooth = 0.1}, x = -200, y = 0},
        {name = "neg", type = "transform", knobs = {value = 1}, toggles = {op = 4}, x = -50, y = 0},  -- neg
        {name = "offset", type = "transform", knobs = {value = 1}, toggles = {op = 2}, x = 100, y = 0},  -- offset +1
        {name = "scale", type = "math", toggles = {op = 2}, x = 250, y = 0},  -- mul
    },
    cables = {
        {from = "env", fromPort = "out", to = "neg", toPort = "in"},
        {from = "neg", fromPort = "out", to = "offset", toPort = "in"},
        {from = "offset", fromPort = "out", to = "scale", toPort = "b"},
    },
    inputs = {
        ["in"] = {node = "scale", port = "a"},
    },
    outputs = {
        out = {node = "scale", port = "out"},
    },
}

-- 19. Audio Gate: Pass signal only when audio exceeds threshold
presetDefs.audioGate = {
    name = "Audio Gate",
    nodes = {
        {name = "env", type = "audio_env", knobs = {window = 512, smooth = 0.05}, x = -150, y = -50},
        {name = "scale", type = "transform", knobs = {value = 10}, toggles = {op = 1}, x = 0, y = -50},  -- amplify
        {name = "clamp", type = "clamp", knobs = {min = 0, max = 1}, x = 150, y = -50},  -- clamp to 0-1
        {name = "mul", type = "math", toggles = {op = 2}, x = 150, y = 50},  -- gate multiply
    },
    cables = {
        {from = "env", fromPort = "out", to = "scale", toPort = "in"},
        {from = "scale", fromPort = "out", to = "clamp", toPort = "in"},
        {from = "clamp", fromPort = "out", to = "mul", toPort = "b"},
    },
    inputs = {
        ["in"] = {node = "mul", port = "a"},
    },
    outputs = {
        out = {node = "mul", port = "out"},
    },
}

--------------------------------------------------------------------------------
-- Form Presets
--------------------------------------------------------------------------------

-- 20. Pulsing Circle: Circle that pulses with tempo
presetDefs.pulsingCircle = {
    name = "Pulsing Circle",
    nodes = {
        {name = "pulse", type = "tempo_pulse", knobs = {decay = 0.3, div = 3}, x = -200, y = 0},
        {name = "scale", type = "transform", knobs = {value = 0.3}, toggles = {op = 1}, x = -50, y = 0},
        {name = "offset", type = "transform", knobs = {value = 1}, toggles = {op = 2}, x = 100, y = 0},
        {name = "mul", type = "math", toggles = {op = 2}, x = 250, y = 0},
        {name = "circle", type = "form_circle", x = 400, y = 0},
    },
    cables = {
        {from = "pulse", fromPort = "out", to = "scale", toPort = "in"},
        {from = "scale", fromPort = "out", to = "offset", toPort = "in"},
        {from = "offset", fromPort = "out", to = "mul", toPort = "a"},
        {from = "mul", fromPort = "out", to = "circle", toPort = "r"},
    },
    inputs = {
        tempo = {node = "pulse", port = "tempo"},
        baseRadius = {node = "mul", port = "b"},
    },
    outputs = {
        form = {node = "circle", port = "form"},
    },
}

-- 21. Rotating Polygon: Polygon that rotates continuously
presetDefs.rotatingPolygon = {
    name = "Rotating Polygon",
    nodes = {
        {name = "linear", type = "linear", knobs = {speed = 0.5}, x = -150, y = 0},
        {name = "mul", type = "math", toggles = {op = 2}, x = 0, y = 0},
        {name = "polygon", type = "form_polygon", knobs = {sides = 6}, x = 150, y = 0},
    },
    cables = {
        {from = "linear", fromPort = "out", to = "mul", toPort = "a"},
        {from = "mul", fromPort = "out", to = "polygon", toPort = "rotation"},
    },
    inputs = {
        speed = {node = "mul", port = "b"},
    },
    outputs = {
        form = {node = "polygon", port = "form"},
    },
}

-- 22. Breathing Rect: Rectangle that scales with breathing animation
presetDefs.breathingRect = {
    name = "Breathing Rect",
    nodes = {
        {name = "tempoOsc", type = "tempo_osc", knobs = {amp = 0.2, div = 2}, toggles = {wave = 1}, x = -150, y = 0},
        {name = "offset", type = "transform", knobs = {value = 1}, toggles = {op = 2}, x = 0, y = 0},
        {name = "rect", type = "form_rect", x = 150, y = 0},
    },
    cables = {
        {from = "tempoOsc", fromPort = "out", to = "offset", toPort = "in"},
        {from = "offset", fromPort = "out", to = "rect", toPort = "scale"},
    },
    inputs = {
        tempo = {node = "tempoOsc", port = "tempo"},
    },
    outputs = {
        form = {node = "rect", port = "form"},
    },
}

-- 23. Audio Circle: Circle radius driven by audio
presetDefs.audioCircle = {
    name = "Audio Circle",
    nodes = {
        {name = "env", type = "audio_env", knobs = {window = 1024, smooth = 0.1}, x = -200, y = 0},
        {name = "mul", type = "math", toggles = {op = 2}, x = -50, y = 0},
        {name = "add", type = "math", toggles = {op = 1}, x = 100, y = 0},
        {name = "circle", type = "form_circle", x = 250, y = 0},
    },
    cables = {
        {from = "env", fromPort = "out", to = "mul", toPort = "a"},
        {from = "mul", fromPort = "out", to = "add", toPort = "a"},
        {from = "add", fromPort = "out", to = "circle", toPort = "r"},
    },
    inputs = {
        sensitivity = {node = "mul", port = "b"},
        baseRadius = {node = "add", port = "b"},
    },
    outputs = {
        form = {node = "circle", port = "form"},
    },
}

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Get list of available preset names
function Presets.list()
    local names = {}
    for name in pairs(presetDefs) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

--- Get preset definition by name
function Presets.getDef(name)
    return presetDefs[name]
end

--- Create a preset macro node
---@param editor table The editor instance
---@param name string Preset name (e.g., "orbit", "breathe")
---@param x number X position
---@param y number Y position
---@return table|nil macroNode The created macro node, or nil if not found
function Presets.create(editor, name, x, y)
    local def = presetDefs[name]
    if not def then
        return nil
    end
    return buildPreset(editor, x, y, def)
end

--- Create all presets (for testing)
function Presets.createAll(editor, startX, startY, spacing)
    startX = startX or 0
    startY = startY or 0
    spacing = spacing or 200

    local nodes = {}
    local i = 0
    for name in pairs(presetDefs) do
        local node = Presets.create(editor, name, startX + (i % 5) * spacing, startY + math.floor(i / 5) * spacing)
        if node then
            nodes[#nodes + 1] = node
        end
        i = i + 1
    end
    return nodes
end

return Presets
