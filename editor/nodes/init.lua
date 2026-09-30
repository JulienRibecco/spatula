--- editor.nodes - Node definition catalog
--- @module spatula.editor.nodes
---
--- Contains all 66+ node definitions for the visual editor.
--- Each node specifies type, inputs, outputs, knobs, and buildCurve function.

-- Dependencies
local Curve = require("spatula.curve")
local Signal = require("spatula.signal")
local Tempo = require("spatula.tempo")
local Audio = require("spatula.audio")
local Trigger = require("spatula.trigger")
local Field = require("spatula.field")
local TextInput = require("spatula.src.text.input")
local TextNodes = require("spatula.src.text.nodes")
local ClockNodes = require("spatula.src.clock.nodes")
local OSC = require("spatula.osc")
local FileWatcher = require("spatula.file_watcher")
local AudioFFT = require("spatula.audio_fft")
local AudioStems = require("spatula.audio_stems")
local Stream = require("spatula.stream")
local External = require("spatula.external")
local Constants = require("spatula.editor.constants")

local PI2 = Constants.PI2
local sin, cos, abs = math.sin, math.cos, math.abs

local Nodes = {}

--- Build all node definitions
--- @return table Array of node definition tables
function Nodes.buildDefs()
    local defs = {}
    local function def(t) defs[#defs + 1] = t end

    -- Sources

    -- Unified oscillator with waveform selection
    def{type="osc", label="Oscillator", category="source",
        color={0.2, 0.42, 0.35}, outputs={"out"},
        knobs={{name="freq", min=0.1, max=5, default=0.5}, {name="amp", min=5, max=200, default=80}},
        toggles={{name="wave", options={"sin", "cos", "tri", "saw", "sqr"}, default=1, label="Wave"}},
        buildCurve=function(_, k, node)
            local wave = node.toggleValues and node.toggleValues.wave or 1
            return function(t)
                local phase = (t * k.freq) % 1
                if wave == 1 then  -- sin
                    return sin(t * k.freq * PI2) * k.amp
                elseif wave == 2 then  -- cos
                    return cos(t * k.freq * PI2) * k.amp
                elseif wave == 3 then  -- triangle
                    local v = phase < 0.5 and (phase * 4 - 1) or (3 - phase * 4)
                    return v * k.amp
                elseif wave == 4 then  -- saw
                    return (phase * 2 - 1) * k.amp
                else  -- square
                    return (phase < 0.5 and 1 or -1) * k.amp
                end
            end
        end}

    -- Deterministic pseudo-noise: sum of incommensurate sines.
    -- Smooth and repeatable (no RNG), useful for organic wobble.
    def{type="noise", label="Noise", category="source",
        color={0.38, 0.42, 0.2}, outputs={"out"},
        knobs={{name="scale", min=5, max=150, default=40}},
        buildCurve=function(_, k)
            return function(t)
                local n = sin(t * 1.0) * 0.5 + sin(t * 2.3) * 0.3 + sin(t * 5.7) * 0.2
                return n * k.scale
            end
        end}

    def{type="linear", label="Linear", category="source",
        color={0.25, 0.35, 0.32}, outputs={"out"},
        knobs={{name="speed", min=-100, max=100, default=20}},
        buildCurve=function(_, k)
            return function(t) return t * k.speed end
        end}

    def{type="const", label="Const", category="source",
        color={0.28, 0.28, 0.35}, outputs={"out"},
        knobs={{name="value", min=-200, max=200, default=0}},
        buildCurve=function(_, k)
            return function() return k.value end
        end}

    -- Unified math combinator with operation toggle
    def{type="math", label="Math", category="combine",
        color={0.35, 0.3, 0.5}, inputs={"a", "b"}, outputs={"out"},
        toggles={{name="op", options={"+", "*", "-", "/", "min", "max"}, default=1, label="Op"}},
        buildCurve=function(inp, _, node)
            local a = inp.a or Curve.const(0)
            local b = inp.b or Curve.const(0)
            local op = node.toggleValues and node.toggleValues.op or 1
            if op == 1 then  -- add
                return function(t, ctx) return a(t, ctx) + b(t, ctx) end
            elseif op == 2 then  -- mul
                return function(t, ctx) return a(t, ctx) * b(t, ctx) end
            elseif op == 3 then  -- sub
                return function(t, ctx) return a(t, ctx) - b(t, ctx) end
            elseif op == 4 then  -- div
                return function(t, ctx)
                    local bv = b(t, ctx)
                    if math.abs(bv) < 0.0001 then bv = 0.0001 end
                    return a(t, ctx) / bv
                end
            elseif op == 5 then  -- min
                return function(t, ctx) return math.min(a(t, ctx), b(t, ctx)) end
            else  -- max
                return function(t, ctx) return math.max(a(t, ctx), b(t, ctx)) end
            end
        end}

    -- Unified transform with operation toggle
    -- value knob used for scale (factor) and offset (amount)
    def{type="transform", label="Transform", category="combine",
        color={0.35, 0.3, 0.5}, inputs={"in"}, outputs={"out"},
        knobs={{name="value", min=-200, max=200, default=1}},
        toggles={{name="op", options={"scale", "offset", "abs", "neg"}, default=1, label="Op"}},
        buildCurve=function(inp, k, node)
            local c = inp["in"] or Curve.const(0)
            local op = node.toggleValues and node.toggleValues.op or 1
            if op == 1 then  -- scale
                return function(t, ctx) return c(t, ctx) * k.value end
            elseif op == 2 then  -- offset
                return function(t, ctx) return c(t, ctx) + k.value end
            elseif op == 3 then  -- abs
                return function(t, ctx) return abs(c(t, ctx)) end
            else  -- neg
                return function(t, ctx) return -c(t, ctx) end
            end
        end}

    def{type="timeScale", label="timeScale", category="combine",
        color={0.35, 0.3, 0.5}, inputs={"in"}, outputs={"out"},
        knobs={{name="factor", min=0.1, max=5, default=1}},
        buildCurve=function(inp, k)
            local c = inp["in"] or Curve.const(0)
            return function(t, ctx) return c(t * k.factor, ctx) end
        end}

    def{type="clamp", label="clamp", category="combine",
        color={0.35, 0.3, 0.5}, inputs={"in"}, outputs={"out"},
        knobs={{name="min", min=-200, max=200, default=-80}, {name="max", min=-200, max=200, default=80}},
        buildCurve=function(inp, k)
            local c = inp["in"] or Curve.const(0)
            return function(t, ctx)
                local v = c(t, ctx)
                if v < k["min"] then return k["min"] end
                if v > k["max"] then return k["max"] end
                return v
            end
        end}

    -- Split: fan out one input to multiple outputs
    def{type="split", label="Split", category="combine",
        color={0.4, 0.35, 0.5}, inputs={"in"}, outputs={"a", "b", "c"},
        buildCurve=function(inp)
            local c = inp["in"] or Curve.const(0)
            return {a = c, b = c, c = c}
        end}

    -- Triggers: time-driven curve modulators.
    -- The "t" input is a clock curve — fire conditions depend on its value.
    -- Wire a linear/saw for steady tempo, an oscillator for swing, etc.

    def{type="trig_gate", label="gate", category="trigger",
        color={0.5, 0.25, 0.35}, inputs={"in", "t"}, outputs={"out"},
        knobs={{name="duty", min=0.05, max=0.95, default=0.5}},
        buildCurve=function(inp, k)
            local c = inp["in"] or Curve.const(0)
            local clock = inp["t"] or Curve.const(0)
            return function(t, ctx)
                local phase = clock(t, ctx) % 1
                if phase < k.duty then return c(t, ctx) end
                return 0
            end
        end}

    -- Note: S&H state (lastInt, held) resets on cache invalidation (cable changes).
    -- This is intentional — held value "forgets" on rewire.
    def{type="trig_snh", label="S&H", category="trigger",
        color={0.5, 0.25, 0.35}, inputs={"in", "t"}, outputs={"out"},
        buildCurve=function(inp)
            local c = inp["in"] or Curve.const(0)
            local clock = inp["t"] or Curve.const(0)
            local lastInt = -1
            local held = 0
            return function(t, ctx)
                local tv = clock(t, ctx)
                local intPart = math.floor(tv)
                if intPart ~= lastInt then
                    lastInt = intPart
                    held = c(t, ctx)
                end
                return held
            end
        end}

    def{type="trig_reset", label="reset", category="trigger",
        color={0.5, 0.25, 0.35}, inputs={"in", "t"}, outputs={"out"},
        buildCurve=function(inp)
            local c = inp["in"] or Curve.const(0)
            local clock = inp["t"] or Curve.const(0)
            return function(t, ctx)
                local tv = clock(t, ctx)
                local localT = tv % 1  -- restart curve each integer crossing
                return c(localT, ctx)
            end
        end}

    def{type="trig_env", label="envelope", category="trigger",
        color={0.5, 0.25, 0.35}, inputs={"in", "t"}, outputs={"out"},
        knobs={{name="attack", min=0.01, max=0.5, default=0.05}, {name="release", min=0.05, max=0.95, default=0.4}},
        buildCurve=function(inp, k)
            local c = inp["in"] or Curve.const(0)
            local clock = inp["t"] or Curve.const(0)
            return function(t, ctx)
                local phase = clock(t, ctx) % 1
                local env
                if phase < k.attack then
                    env = phase / k.attack  -- ramp up
                elseif phase < k.attack + k.release then
                    env = 1 - (phase - k.attack) / k.release  -- ramp down
                else
                    env = 0
                end
                return c(t, ctx) * env
            end
        end}

    -- Entity: Point carrier
    def{type="point", label="Point", category="entity",
        color={0.4, 0.4, 0.6}, inputs={"x", "y", "rotation"}, outputs={"point"},
        buildCurve=function() return Curve.const(0) end}

    -- Forms (now with rotation/scale inputs and point output for center)
    def{type="form_circle", label="circle", category="entity",
        color={0.45, 0.35, 0.2}, inputs={"cx", "cy", "r", "rotation", "scale", "colorIn"}, outputs={"form", "point"},
        buildCurve=function() return Curve.const(0) end}

    def{type="form_rect", label="rect", category="entity",
        color={0.45, 0.35, 0.2}, inputs={"cx", "cy", "w", "h", "rotation", "scale", "colorIn"}, outputs={"form", "point"},
        buildCurve=function() return Curve.const(0) end}

    def{type="form_polygon", label="polygon", category="entity",
        color={0.45, 0.35, 0.2}, inputs={"cx", "cy", "r", "rotation", "scale", "colorIn"}, outputs={"form", "point"},
        knobs={{name="sides", min=3, max=12, default=6}},
        buildCurve=function() return Curve.const(0) end}

    -- Unified distribution with pattern toggle
    -- count used for random/grid, spacing used for poisson/hex
    def{type="dist", label="Distribute", category="dist",
        color={0.2, 0.4, 0.45}, inputs={"form", "rotation", "scale", "colorIn"}, outputs={"pts"},
        knobs={{name="count", min=10, max=300, default=60}, {name="spacing", min=8, max=60, default=20}},
        toggles={{name="pattern", options={"random", "grid", "poisson", "hex"}, default=1, label="Pattern"}},
        buildCurve=function() return Curve.const(0) end}

    -- Unified sample node: extracts x/y/rotation from entity
    -- Note: uses special evaluation in buildMotion/buildScene
    def{type="sample", label="Sample", category="modulate",
        color={0.5, 0.4, 0.55}, inputs={"entity"}, outputs={"out"},
        toggles={{name="axis", options={"x", "y", "rot"}, default=1, label="Axis"}},
        buildCurve=function() return Curve.const(0) end}

    -- Distance between two entities
    def{type="distance", label="Distance", category="modulate",
        color={0.5, 0.45, 0.5}, inputs={"entityA", "entityB"}, outputs={"out"},
        buildCurve=function() return Curve.const(0) end}

    -- Angle from one entity to another (in degrees)
    def{type="angle_to", label="Angle To", category="modulate",
        color={0.5, 0.45, 0.5}, inputs={"from", "to"}, outputs={"out"},
        buildCurve=function() return Curve.const(0) end}

    -- Signal node: reads from context by name
    def{type="signal", label="Signal", category="modulate",
        color={0.5, 0.5, 0.4}, inputs={}, outputs={"out"},
        knobs={{name="default", min=-500, max=500, default=0}},
        signalKey="x",  -- Will be editable via text input later
        buildCurve=function(_, k, node)
            local key = node and node.signalKey or "x"
            return Signal.new(key, k.default)
        end}

    -- Tempo: musical timing nodes
    -- Division indices: 1=1/1, 2=1/2, 3=1/4, 4=1/8, 5=1/16, 6=1/32
    local divisions = {"1/1", "1/2", "1/4", "1/8", "1/16", "1/32"}

    -- Tempo source: creates a tempo object
    def{type="tempo", label="Tempo", category="tempo",
        color={0.6, 0.3, 0.4}, inputs={}, outputs={"tempo"},
        knobs={{name="bpm", min=60, max=200, default=120}, {name="beats", min=2, max=8, default=4}},
        buildCurve=function(_, k)
            return Tempo.new(k.bpm, math.floor(k.beats))
        end}

    -- Unified tempo-synced oscillator with waveform selection
    def{type="tempo_osc", label="Tempo Osc", category="tempo",
        color={0.55, 0.35, 0.4}, inputs={"tempo"}, outputs={"out"},
        knobs={{name="amp", min=0, max=200, default=50}, {name="div", min=1, max=6, default=3}},
        toggles={{name="wave", options={"sin", "cos", "tri", "saw"}, default=1, label="Wave"}},
        buildCurve=function(inp, k, node)
            local tempoObj = inp.tempo
            if not tempoObj then return Curve.const(0) end
            local div = divisions[math.floor(k.div)] or "1/4"
            local wave = node.toggleValues and node.toggleValues.wave or 1
            if wave == 1 then return Tempo.sin(tempoObj, div, k.amp)
            elseif wave == 2 then return Tempo.cos(tempoObj, div, k.amp)
            elseif wave == 3 then return Tempo.triangle(tempoObj, div, k.amp)
            else return Tempo.saw(tempoObj, div, k.amp)
            end
        end}

    -- Tempo phase (0-1 ramp per division)
    def{type="tempo_phase", label="Phase", category="tempo",
        color={0.55, 0.35, 0.4}, inputs={"tempo"}, outputs={"out"},
        knobs={{name="div", min=1, max=6, default=3}},
        buildCurve=function(inp, k)
            local tempoObj = inp.tempo
            if not tempoObj then return Curve.const(0) end
            local div = divisions[math.floor(k.div)] or "1/4"
            return function(t, ctx)
                return tempoObj:phase(t, div)
            end
        end}

    -- Tempo pulse (exponential decay on each division)
    def{type="tempo_pulse", label="Pulse", category="tempo",
        color={0.6, 0.35, 0.35}, inputs={"tempo"}, outputs={"out"},
        knobs={{name="decay", min=0.1, max=2, default=0.5}, {name="div", min=1, max=6, default=3}},
        buildCurve=function(inp, k)
            local tempoObj = inp.tempo
            if not tempoObj then return Curve.const(0) end
            local div = divisions[math.floor(k.div)] or "1/4"
            return Tempo.pulse(tempoObj, div, k.decay)
        end}

    -- Beat trigger (1 on boundary, 0 otherwise)
    def{type="tempo_trig", label="Beat Trig", category="tempo",
        color={0.6, 0.35, 0.35}, inputs={"tempo"}, outputs={"out"},
        knobs={{name="div", min=1, max=6, default=3}},
        buildCurve=function(inp, k)
            local tempoObj = inp.tempo
            if not tempoObj then return Curve.const(0) end
            local div = divisions[math.floor(k.div)] or "1/4"
            return Tempo.trigger(tempoObj, div)
        end}

    -- Audio: audio-reactive curves
    -- Audio source: extracts envelope from audio data (SoundData set externally on node.soundData)
    def{type="audio_env", label="Audio Env", category="audio",
        color={0.3, 0.5, 0.4}, inputs={}, outputs={"out"},
        knobs={{name="window", min=256, max=4096, default=1024}, {name="smooth", min=0, max=1, default=0.5}},
        buildCurve=function(_, k, node)
            -- node.soundData must be set externally by the consumer
            if not node or not node.soundData then return Curve.const(0) end
            return Audio.toCurve(node.soundData, {
                windowSize = math.floor(k.window),
                smooth = k.smooth
            })
        end}

    -- Audio scale: multiplies audio envelope by an amplitude factor
    def{type="audio_scale", label="Audio Scale", category="audio",
        color={0.3, 0.5, 0.4}, inputs={"audio"}, outputs={"out"},
        knobs={{name="scale", min=0, max=500, default=100}},
        buildCurve=function(inp, k)
            local audio = inp.audio or Curve.const(0)
            return function(t, ctx)
                return audio(t, ctx) * k.scale
            end
        end}

    -- Multi-output frequency bands (low/mid/high curves)
    -- Uses existing Audio.bands() which approximates frequency bands from amplitude analysis
    def{type="audio_bands3", label="Bands 3", category="audio",
        color={0.3, 0.5, 0.35}, inputs={}, outputs={"low", "mid", "high"},
        knobs={{name="window", min=512, max=4096, default=2048}},
        buildCurve=function(_, k, node)
            if not node or not node.soundData then
                return {low=Curve.const(0), mid=Curve.const(0), high=Curve.const(0)}
            end
            local bands = Audio.bands(node.soundData, {windowSize = math.floor(k.window)})
            return {
                low = Curve.envelope(bands.low, "smooth"),
                mid = Curve.envelope(bands.mid, "smooth"),
                high = Curve.envelope(bands.high, "smooth")
            }
        end}

    -- FFT frequency bin: track magnitude of specific frequency
    def{type="audio_fft", label="FFT Bin", category="audio",
        color={0.25, 0.55, 0.4}, inputs={}, outputs={"out"},
        knobs={{name="bin", min=1, max=64, default=8},
               {name="smooth", min=0, max=0.95, default=0.3},
               {name="scale", min=1, max=500, default=100}},
        buildCurve=function(_, k, node)
            if not node or not node.soundData then return Curve.const(0) end
            return AudioFFT.binToCurve(node.soundData, math.floor(k.bin), {
                smooth = k.smooth,
                scale = k.scale,
                numBins = 64
            })
        end}

    -- Beat detection: pulses on audio onsets
    def{type="audio_beat", label="Beat", category="audio",
        color={0.35, 0.55, 0.3}, inputs={}, outputs={"out"},
        knobs={{name="threshold", min=0.5, max=3, default=1.5},
               {name="decay", min=0.05, max=0.5, default=0.15}},
        buildCurve=function(_, k, node)
            if not node or not node.soundData then return Curve.const(0) end
            return AudioFFT.beatDetect(node.soundData, {
                threshold = k.threshold,
                decay = k.decay
            })
        end}

    -- Beat envelope: smoother attack/decay envelope on beats
    def{type="audio_beat_env", label="Beat Env", category="audio",
        color={0.32, 0.52, 0.35}, inputs={}, outputs={"out"},
        knobs={{name="threshold", min=0.5, max=3, default=1.5},
               {name="attack", min=0.001, max=0.1, default=0.01},
               {name="decay", min=0.05, max=1, default=0.2}},
        buildCurve=function(_, k, node)
            if not node or not node.soundData then return Curve.const(0) end
            return AudioFFT.beatEnvelope(node.soundData, {
                threshold = k.threshold,
                attack = k.attack,
                decay = k.decay
            })
        end}

    -- Audio output: renders a curve to system audio via QueueableSource.
    -- Wire any curve to 'left' (and optionally 'right' for stereo).
    -- ctx is persistent across samples and frames — stateful nodes (filters,
    -- envelopes) store their state there. Never reset between samples.
    def{type="audio_out", label="Audio Out", category="audio",
        color={0.55, 0.35, 0.25}, inputs={"left", "right"}, outputs={},
        knobs={
            {name="gain",   min=0,     max=2,     default=1.0},
            {name="sr",     min=22050, max=48000, default=44100},
            {name="buffer", min=256,   max=4096,  default=2048},
        },
        -- No buildCurve — this node is a sink, handled in Editor:update
        buildCurve=function() return nil end}

    -- Audio Stems: AI-powered stem separation
    -- Separates audio into vocals, instrumental, drums, bass, etc.
    -- Requires Python with audio-separator: pip install audio-separator[cpu]
    def{type="audio_stems", label="Stems", category="audio",
        color={0.3, 0.5, 0.45}, inputs={}, outputs={"vocals", "instrumental", "drums", "bass"},
        toggles={{name="model", options={"Fast", "Quality"}, default=1, label="Model"}},
        buttons={{name="separate", label="Separate"}, {name="load", label="Load"}},
        sourcePath = "",  -- Path to source audio file
        buildCurve=function(_, k, node, portName)
            -- Each output returns a curve that plays the separated stem
            -- The actual stem audio is loaded into node._stems by button handler
            if not node._stems then return Curve.const(0) end

            local stemName = portName or "vocals"
            local stemPath = node._stems[stemName]
            if not stemPath then return Curve.const(0) end

            -- If we have soundData for this stem, use it for analysis
            local soundData = node._stemSoundData and node._stemSoundData[stemName]
            if not soundData then return Curve.const(0) end

            -- Return an envelope follower curve for the stem
            return AudioFFT.envelope(soundData, {
                attack = 0.01,
                release = 0.1,
                scale = 100
            })
        end}

    -- Trigger: timing × selection → action
    -- Timing strategies (when to fire)
    -- All timing nodes accept optional "clock" input for domain-independent timing
    def{type="timing_interval", label="Interval", category="trig",
        color={0.5, 0.3, 0.3}, inputs={"clock"}, outputs={"timing"},
        knobs={{name="seconds", min=0.05, max=5, default=0.5}},
        buildCurve=function(inp, k)
            local clockStream = inp.clock and Stream.from(inp.clock) or nil
            return Trigger.timing.interval(k.seconds, clockStream)
        end}

    def{type="timing_prob", label="Probability", category="trig",
        color={0.5, 0.3, 0.3}, inputs={}, outputs={"timing"},
        knobs={{name="chance", min=0, max=1, default=0.3}},
        buildCurve=function(_, k)
            return Trigger.timing.probability(k.chance)
        end}

    def{type="timing_burst", label="Burst", category="trig",
        color={0.5, 0.3, 0.3}, inputs={"clock"}, outputs={"timing"},
        knobs={{name="count", min=1, max=20, default=5}, {name="interval", min=0.01, max=1, default=0.1}, {name="delay", min=0.1, max=5, default=2}},
        buildCurve=function(inp, k)
            local clockStream = inp.clock and Stream.from(inp.clock) or nil
            return Trigger.timing.burst(math.floor(k.count), k.interval, k.delay, clockStream)
        end}

    def{type="timing_once", label="Once", category="trig",
        color={0.5, 0.3, 0.3}, inputs={"clock"}, outputs={"timing"},
        knobs={{name="delay", min=0, max=5, default=0}},
        buildCurve=function(inp, k)
            local clockStream = inp.clock and Stream.from(inp.clock) or nil
            return Trigger.timing.once(k.delay, clockStream)
        end}

    -- Event-based timing: fires on beat/pulse crossings
    def{type="timing_on_beat", label="On Beat", category="trig",
        color={0.5, 0.35, 0.3}, inputs={"pulse"}, outputs={"timing"},
        knobs={{name="threshold", min=0.1, max=0.9, default=0.5}},
        buildCurve=function(inp, k)
            if not inp.pulse then
                return function() return false end
            end
            local eventStream = Stream.fromPulse(inp.pulse, k.threshold)
            return Trigger.timing.onEvent(eventStream)
        end}

    -- Phase-based timing: fires when clock phase crosses threshold
    def{type="timing_on_phase", label="On Phase", category="trig",
        color={0.5, 0.35, 0.3}, inputs={"clock"}, outputs={"timing"},
        knobs={{name="phase", min=0, max=1, default=0}},
        buildCurve=function(inp, k)
            if not inp.clock then
                return function() return false end
            end
            local clockStream = Stream.from(inp.clock)
            return Trigger.timing.onPhase(clockStream, k.phase)
        end}

    -- Unified selection strategy with mode toggle
    def{type="select", label="Select", category="trig",
        color={0.5, 0.35, 0.35}, inputs={}, outputs={"select"},
        knobs={{name="count", min=1, max=20, default=3}},
        toggles={{name="mode", options={"all", "random", "seq", "first"}, default=1, label="Mode"}},
        buildCurve=function(_, k, node)
            local mode = node.toggleValues and node.toggleValues.mode or 1
            local count = math.floor(k.count)
            if mode == 1 then return Trigger.select.all()
            elseif mode == 2 then return Trigger.select.random(count)
            elseif mode == 3 then return Trigger.select.sequential()
            else return Trigger.select.first(count)
            end
        end}

    -- Trigger compose: combines timing + selection + points
    -- The trigger object is returned for external use; the node itself outputs a pulse curve
    def{type="trigger", label="Trigger", category="trig",
        color={0.55, 0.3, 0.3}, inputs={"timing", "select", "pts"}, outputs={"trig", "pulse"},
        buildCurve=function(inp, k)
            local timing = inp.timing
            local sel = inp.select
            if not timing or not sel then return Curve.const(0) end
            -- Return a table containing the trigger config for external use
            return {
                timing = timing,
                select = sel,
                _isTrigger = true
            }
        end}

    -- Field: spatial value modulation
    -- Falloff indices: 1=linear, 2=smooth, 3=gaussian, 4=spike, 5=constant
    local falloffs = {"linear", "smooth", "gaussian", "spike", "constant"}
    -- Blend indices: 1=add, 2=max, 3=min
    local blends = {"add", "max", "min"}

    -- Field node: creates a new field
    def{type="field", label="Field", category="field",
        color={0.35, 0.45, 0.35}, inputs={}, outputs={"field"},
        knobs={{name="falloff", min=1, max=5, default=2}, {name="blend", min=1, max=3, default=1}, {name="base", min=0, max=1, default=0}},
        buildCurve=function(_, k)
            return Field.new({
                falloff = falloffs[math.floor(k.falloff)] or "smooth",
                blend = blends[math.floor(k.blend)] or "add",
                base = k.base
            })
        end}

    -- Field source: adds a source to a field at a point position
    -- The field is modified in place, so this is a pass-through with side effects
    def{type="field_source", label="Add Source", category="field",
        color={0.35, 0.5, 0.35}, inputs={"fieldIn", "point"}, outputs={"field"},
        knobs={{name="radius", min=10, max=200, default=50}, {name="value", min=0, max=2, default=1}},
        buildCurve=function(inp, k)
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Field sample: samples field value at a point position, returns as curve
    def{type="field_sample", label="Sample", category="field",
        color={0.4, 0.5, 0.4}, inputs={"field", "point"}, outputs={"out"},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Field gradient: returns gradient direction at a point position
    def{type="field_gradient", label="Gradient", category="field",
        color={0.4, 0.5, 0.4}, inputs={"field", "point"}, outputs={"gx", "gy"},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Color: vec4 color operations
    -- Colors are {r, g, b, a} tables with values 0-1

    -- Constant color picker
    def{type="color_const", label="Color", category="color",
        color={0.5, 0.3, 0.5}, inputs={}, outputs={"color"},
        knobs={{name="r", min=0, max=1, default=1}, {name="g", min=0, max=1, default=0.5}, {name="b", min=0, max=1, default=0}, {name="a", min=0, max=1, default=1}},
        buildCurve=function(_, k)
            return {r=k.r, g=k.g, b=k.b, a=k.a, _isColor=true}
        end}

    -- ColorRamp: maps scalar 0-1 → gradient color (2-stop gradient for simplicity)
    def{type="color_ramp", label="Ramp", category="color",
        color={0.5, 0.35, 0.55}, inputs={"in"}, outputs={"color"},
        knobs={{name="r1", min=0, max=1, default=0}, {name="g1", min=0, max=1, default=0}, {name="b1", min=0, max=1, default=0},
               {name="r2", min=0, max=1, default=1}, {name="g2", min=0, max=1, default=1}, {name="b2", min=0, max=1, default=1}},
        buildCurve=function(inp, k)
            local c = inp["in"] or Curve.const(0)
            return function(t, ctx)
                local v = c(t, ctx)
                -- Clamp to 0-1
                if v < 0 then v = 0 elseif v > 1 then v = 1 end
                -- Lerp between color1 and color2
                return {
                    r = k.r1 + (k.r2 - k.r1) * v,
                    g = k.g1 + (k.g2 - k.g1) * v,
                    b = k.b1 + (k.b2 - k.b1) * v,
                    a = 1,
                    _isColor = true
                }
            end
        end}

    -- HSL to RGB: takes H, S, L curves (0-1) and outputs color
    def{type="color_hsl", label="HSL", category="color",
        color={0.55, 0.3, 0.5}, inputs={"h", "s", "l"}, outputs={"color"},
        knobs={{name="a", min=0, max=1, default=1}},
        buildCurve=function(inp, k)
            local hCurve = inp.h or Curve.const(0)
            local sCurve = inp.s or Curve.const(1)
            local lCurve = inp.l or Curve.const(0.5)
            return function(t, ctx)
                local h = hCurve(t, ctx) % 1  -- Wrap hue
                local s = sCurve(t, ctx)
                local l = lCurve(t, ctx)
                if s < 0 then s = 0 elseif s > 1 then s = 1 end
                if l < 0 then l = 0 elseif l > 1 then l = 1 end
                -- HSL to RGB conversion
                local r, g, b
                if s == 0 then
                    r, g, b = l, l, l
                else
                    local function hue2rgb(p, q, t)
                        if t < 0 then t = t + 1 end
                        if t > 1 then t = t - 1 end
                        if t < 1/6 then return p + (q - p) * 6 * t end
                        if t < 1/2 then return q end
                        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
                        return p
                    end
                    local q = l < 0.5 and l * (1 + s) or l + s - l * s
                    local p = 2 * l - q
                    r = hue2rgb(p, q, h + 1/3)
                    g = hue2rgb(p, q, h)
                    b = hue2rgb(p, q, h - 1/3)
                end
                return {r=r, g=g, b=b, a=k.a, _isColor=true}
            end
        end}

    -- Compose vec4 from curves
    def{type="color_compose", label="Compose", category="color",
        color={0.5, 0.35, 0.5}, inputs={"r", "g", "b", "a"}, outputs={"color"},
        buildCurve=function(inp)
            local rCurve = inp.r or Curve.const(1)
            local gCurve = inp.g or Curve.const(1)
            local bCurve = inp.b or Curve.const(1)
            local aCurve = inp.a or Curve.const(1)
            return function(t, ctx)
                local r = rCurve(t, ctx)
                local g = gCurve(t, ctx)
                local b = bCurve(t, ctx)
                local a = aCurve(t, ctx)
                -- Clamp all to 0-1
                if r < 0 then r = 0 elseif r > 1 then r = 1 end
                if g < 0 then g = 0 elseif g > 1 then g = 1 end
                if b < 0 then b = 0 elseif b > 1 then b = 1 end
                if a < 0 then a = 0 elseif a > 1 then a = 1 end
                return {r=r, g=g, b=b, a=a, _isColor=true}
            end
        end}

    -- Split color into curves
    def{type="color_split", label="Split", category="color",
        color={0.5, 0.35, 0.5}, inputs={"colorIn"}, outputs={"r", "g", "b", "a"},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Mix two colors by a scalar
    def{type="color_mix", label="Mix", category="color",
        color={0.5, 0.3, 0.55}, inputs={"colorA", "colorB", "mix"}, outputs={"color"},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Color pulse: oscillate between two colors at given frequency
    def{type="color_pulse", label="Pulse", category="color",
        color={0.55, 0.35, 0.55}, inputs={"colorA", "colorB"}, outputs={"color"},
        knobs={{name="freq", min=0.1, max=5, default=1}},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- Audio-reactive hue cycling: audio input modulates hue offset
    def{type="color_audio", label="Audio Color", category="color",
        color={0.5, 0.4, 0.55}, inputs={"audio"}, outputs={"color"},
        knobs={{name="saturation", min=0, max=1, default=0.8},
               {name="lightness", min=0.2, max=0.8, default=0.5},
               {name="hueSpeed", min=0.1, max=3, default=1}},
        buildCurve=function()
            -- This node is special - handled in evaluateNode
            return Curve.const(0)
        end}

    -- ===== TIME SERIES ANOMALY NODE =====

    -- Anomaly detector: monitors input signal for anomalies
    def{type="ts_anomaly", label="Anomaly", category="text",
        color={0.5, 0.3, 0.4}, inputs={"in"}, outputs={"out"},
        knobs={{name="window", min=50, max=500, default=288},
               {name="resetSilence", min=0, max=1, default=0}},
        buildCurve=function(inp, k)
            local signal = inp["in"] or Curve.const(0)
            local bufSize = math.floor(k.window)
            local buffer, idx, filled = {}, 1, false
            local TSAnomaly = nil

            -- Lazy load anomaly detector
            pcall(function()
                TSAnomaly = require("spatula.classifier.problems.ts_anomaly")
            end)

            return function(t, ctx)
                local sample = signal(t, ctx)

                -- Reset on silence if enabled
                if k.resetSilence > 0.5 and math.abs(sample) < 0.001 then
                    idx, filled = 1, false
                    return 0
                end

                buffer[idx] = sample
                idx = idx + 1
                if idx > bufSize then idx, filled = 1, true end
                if not filled or not TSAnomaly then return 0 end

                -- Reorder buffer to chronological
                local window = {}
                for i = 1, bufSize do
                    window[i] = buffer[((idx - 2 + i) % bufSize) + 1]
                end

                local ok, _, prob = pcall(function()
                    return TSAnomaly.predict(TSAnomaly.DEFAULT_MODEL, window, 0.5)
                end)
                return ok and prob or 0
            end
        end}

    -- ===== EXTERNAL DATA NODES =====

    -- OSC receiver: receives UDP messages as curve values
    def{type="osc_recv", label="OSC In", category="external",
        color={0.4, 0.5, 0.35}, inputs={}, outputs={"out"},
        knobs={{name="port", min=8000, max=9999, default=8080}},
        oscAddress = "/value",
        buildCurve=function(_, k, node)
            local osc = node._osc
            if not osc or osc.port ~= math.floor(k.port) then
                osc = OSC.new(math.floor(k.port))
                node._osc = osc
            end
            local address = node.oscAddress or "/value"
            return function(t, ctx)
                OSC.update(osc)
                return OSC.get(osc, address, 0)
            end
        end}

    -- Twitch chat: receives chat messages via OSC bridge
    -- Start bridge: python tools/twitch_bridge.py --channel CHANNEL
    def{type="twitch_chat", label="Twitch", category="external",
        color={0.55, 0.3, 0.6}, inputs={}, outputs={"rate", "count", "event"},
        knobs={{name="port", min=8000, max=9999, default=8080}},
        buildCurve=function(_, k, node)
            local tw = node._twitch
            if not tw or tw.osc.port ~= math.floor(k.port) then
                tw = External.twitch(math.floor(k.port))
                node._twitch = tw
            end
            return {
                rate = function(t, ctx)
                    External.update(tw)
                    return tw.messageRate
                end,
                count = function(t, ctx)
                    return tw.messageCount
                end,
                event = External.twitchMessageStream(tw)
            }
        end}

    -- Twitch message text: outputs latest message to text pipeline
    def{type="twitch_text", label="Twitch Text", category="external",
        color={0.55, 0.3, 0.6}, inputs={}, outputs={"text"},
        knobs={{name="port", min=8000, max=9999, default=8080}},
        buildCurve=function(_, k, node)
            local tw = node._twitch
            if not tw or tw.osc.port ~= math.floor(k.port) then
                tw = External.twitch(math.floor(k.port))
                node._twitch = tw
            end
            -- Create a text manager that receives Twitch messages
            local textMgr = TextInput.new()
            node._textMgr = textMgr
            node._lastMsg = ""

            return function(t, ctx)
                External.update(tw)
                local msg = tw.lastMessage
                if msg ~= node._lastMsg and msg ~= "" then
                    TextInput.push(textMgr, msg)
                    node._lastMsg = msg
                end
                return textMgr
            end
        end}

    -- File watcher: monitors a JSON/CSV file for changes
    def{type="file_watch", label="File In", category="external",
        color={0.35, 0.5, 0.4}, inputs={}, outputs={"out"},
        knobs={{name="key", min=0, max=10, default=0}},
        filePath = "data.json",
        buildCurve=function(_, k, node)
            local watcher = node._watcher
            if not watcher or watcher.path ~= node.filePath then
                watcher = FileWatcher.new(node.filePath or "data.json")
                node._watcher = watcher
            end
            local keyIndex = math.floor(k.key)
            return function(t, ctx)
                local data = FileWatcher.update(watcher, t)
                -- Try numeric index first, then "value" key
                if keyIndex > 0 and data[keyIndex] then
                    local v = data[keyIndex]
                    return type(v) == "number" and v or 0
                end
                local v = data.value
                return type(v) == "number" and v or 0
            end
        end}

    -- ===== CURVE STATISTICS NODES =====

    -- Unified stats node: computes mean, variance, or integral over sampled window
    def{type="stats", label="Stats", category="math",
        color={0.4, 0.45, 0.5}, inputs={"in"}, outputs={"out"},
        knobs={{name="samples", min=10, max=200, default=50},
               {name="window", min=0.1, max=2, default=1},
               {name="scale", min=0.1, max=10, default=1}},
        toggles={{name="stat", options={"mean", "var", "int"}, default=1, label="Stat"}},
        buildCurve=function(inp, k, node)
            local signal = inp["in"] or Curve.const(0)
            local stat = node.toggleValues and node.toggleValues.stat or 1

            if stat == 1 then  -- mean
                return function(t, ctx)
                    local n = math.floor(k.samples)
                    local win = k.window
                    local sum = 0
                    for i = 0, n - 1 do
                        local sampleT = t - win + (i / n) * win
                        sum = sum + signal(sampleT, ctx)
                    end
                    return sum / n
                end
            elseif stat == 2 then  -- variance
                return function(t, ctx)
                    local n = math.floor(k.samples)
                    local win = k.window
                    local sum = 0
                    local samplesArr = {}
                    for i = 0, n - 1 do
                        local sampleT = t - win + (i / n) * win
                        local v = signal(sampleT, ctx)
                        samplesArr[i + 1] = v
                        sum = sum + v
                    end
                    local mean = sum / n
                    local variance = 0
                    for i = 1, n do
                        local diff = samplesArr[i] - mean
                        variance = variance + diff * diff
                    end
                    return variance / n
                end
            else  -- integral
                return function(t, ctx)
                    local n = math.floor(k.samples)
                    local win = k.window
                    local sum = 0
                    local dt = win / n
                    for i = 0, n - 1 do
                        local sampleT = t - win + (i / n) * win
                        sum = sum + signal(sampleT, ctx) * dt
                    end
                    return sum * k.scale
                end
            end
        end}

    -- Fit Sine: finds dominant frequency in curve (for periodic feature detection)
    def{type="curve_fit_sine", label="Fit Sine", category="math",
        color={0.45, 0.5, 0.5}, inputs={"in"}, outputs={"freq", "amp", "fit"},
        knobs={{name="samples", min=20, max=100, default=40},
               {name="maxFreq", min=1, max=20, default=10}},
        buildCurve=function(inp, k)
            local signal = inp["in"] or Curve.const(0)

            local function analyze(t, ctx)
                local n = math.floor(k.samples)
                local maxF = math.floor(k.maxFreq)
                local samples = {}

                -- Sample the curve over t ∈ [0, 1]
                for i = 0, n - 1 do
                    local sampleT = i / (n - 1)
                    samples[i + 1] = signal(sampleT, ctx)
                end

                -- DFT to find dominant frequency
                local bestFreq, bestAmp = 1, 0
                local PI2_local = math.pi * 2
                for freq = 1, maxF do
                    local real, imag = 0, 0
                    for i = 1, n do
                        local angle = PI2_local * freq * (i - 1) / n
                        real = real + samples[i] * math.cos(angle)
                        imag = imag - samples[i] * math.sin(angle)
                    end
                    local amp = math.sqrt(real * real + imag * imag) / n
                    if amp > bestAmp then
                        bestFreq, bestAmp = freq, amp
                    end
                end

                return bestFreq, bestAmp
            end

            -- Cache results per frame
            local lastT, cachedFreq, cachedAmp = -1000, 1, 0

            return {
                freq = function(t, ctx)
                    if t ~= lastT then
                        cachedFreq, cachedAmp = analyze(t, ctx)
                        lastT = t
                    end
                    return cachedFreq
                end,
                amp = function(t, ctx)
                    if t ~= lastT then
                        cachedFreq, cachedAmp = analyze(t, ctx)
                        lastT = t
                    end
                    return cachedAmp
                end,
                fit = function(t, ctx)
                    if t ~= lastT then
                        cachedFreq, cachedAmp = analyze(t, ctx)
                        lastT = t
                    end
                    -- Return goodness of fit (amplitude as ratio of max possible)
                    return cachedAmp * 2  -- Normalized: pure sine → 1.0
                end
            }
        end}

    -- ===== INVERT COMBINATOR (for sigmoid) =====

    -- Invert: computes 1/x (with protection against division by zero)
    def{type="invert", label="1/x", category="math",
        color={0.5, 0.4, 0.45}, inputs={"in"}, outputs={"out"},
        knobs={{name="epsilon", min=0.001, max=0.1, default=0.01}},
        buildCurve=function(inp, k)
            local signal = inp["in"] or Curve.const(1)
            return function(t, ctx)
                local v = signal(t, ctx)
                local eps = k.epsilon
                if math.abs(v) < eps then
                    v = v >= 0 and eps or -eps
                end
                return 1 / v
            end
        end}

    -- Sigmoid: classic S-curve for classification output
    def{type="sigmoid", label="Sigmoid", category="math",
        color={0.5, 0.45, 0.45}, inputs={"in"}, outputs={"out"},
        knobs={{name="steepness", min=0.5, max=10, default=1}},
        buildCurve=function(inp, k)
            local signal = inp["in"] or Curve.const(0)
            return function(t, ctx)
                local v = signal(t, ctx) * k.steepness
                return 1 / (1 + math.exp(-v))
            end
        end}

    -- ===== DEBUG NODES =====

    -- Monitor: displays live value of connected curve (useful for debugging)
    def{type="debug_monitor", label="Monitor", category="debug",
        color={0.3, 0.5, 0.3}, inputs={"in"}, outputs={"out"},
        knobs={{name="precision", min=0, max=4, default=2}},
        buildCurve=function(inp, k, node)
            local signal = inp["in"] or Curve.const(0)
            return function(t, ctx)
                local v = signal(t, ctx)
                -- Store for preview display
                local prec = math.floor(k.precision)
                node._debugValue = v
                node._debugFormatted = string.format("%." .. prec .. "f", v)
                return v  -- Pass through unchanged
            end
        end}

    -- Multi-Monitor: displays values from up to 4 inputs
    def{type="debug_multi", label="Multi-Mon", category="debug",
        color={0.35, 0.5, 0.35}, inputs={"a", "b", "c", "d"}, outputs={},
        knobs={},
        buildCurve=function(inp, k, node)
            return function(t, ctx)
                local values = {}
                for _, name in ipairs({"a", "b", "c", "d"}) do
                    local sig = inp[name]
                    if sig then
                        values[name] = sig(t, ctx)
                    end
                end
                node._debugValues = values
                return 0
            end
        end}

    -- Merge text source nodes from src/text/nodes.lua
    local textDefs = TextNodes.buildDefs(Curve, TextInput)
    for _, d in ipairs(textDefs) do
        defs[#defs + 1] = d
    end

    -- Merge clock nodes from src/clock/nodes.lua
    local clockDefs = ClockNodes.buildDefs(Curve)
    for _, d in ipairs(clockDefs) do
        defs[#defs + 1] = d
    end

    -- ── Nav Clock: receive Navigator DAW transport over OSC ──────────────────────
    -- Connects to the WebSocket→UDP OSC relay that navigator.html emits to.
    -- Navigator sends /transport/beat, /transport/bpm, /transport/play every ~25ms.
    -- This node extrapolates beat position between packets for smooth curves.
    --
    -- Outputs:
    --   beat       — absolute beat counter (monotonic while playing)
    --   beat_phase — fractional beat position in [0, 1)
    --   bar_phase  — fractional bar position in [0, 1)  (4/4 assumed)
    --   bpm        — current BPM as reported by Navigator
    --   playing    — 1.0 while Navigator is playing, 0.0 when stopped
    def{type="nav_clock", label="Nav Clock", category="external",
        color={0.4, 0.3, 0.6}, inputs={}, outputs={"beat","beat_phase","bar_phase","bpm","playing"},
        knobs={{name="port", min=8000, max=9999, default=9000}},
        buildCurve=function(_, k, node)
            local port = math.floor(k.port)
            if not node._osc or node._osc.port ~= port then
                node._osc      = OSC.new(port)
                node._lastBpm  = 120.0
                node._playing  = 0.0
                node._recvT    = 0.0
                node._recvBeat = 0.0
                node._lastT    = nil
            end
            local function updateOSC(t)
                if t == node._lastT then return end
                node._lastT = t
                OSC.update(node._osc)
                local newBeat = OSC.get(node._osc, '/transport/beat', node._recvBeat)
                if newBeat ~= node._recvBeat then
                    node._recvBeat = newBeat
                    node._recvT    = t
                end
                node._lastBpm = OSC.get(node._osc, '/transport/bpm',  node._lastBpm)
                node._playing = OSC.get(node._osc, '/transport/play', node._playing)
            end
            local function extrapolatedBeat(t)
                return node._recvBeat + (t - node._recvT) * node._lastBpm / 60.0
            end
            return {
                beat = function(t, ctx)
                    updateOSC(t)
                    return extrapolatedBeat(t)
                end,
                beat_phase = function(t, ctx)
                    updateOSC(t)
                    return extrapolatedBeat(t) % 1.0
                end,
                bar_phase = function(t, ctx)
                    updateOSC(t)
                    return (extrapolatedBeat(t) / 4.0) % 1.0
                end,
                bpm = function(t, ctx)
                    updateOSC(t)
                    return node._lastBpm
                end,
                playing = function(t, ctx)
                    updateOSC(t)
                    return node._playing
                end,
            }
        end}

    -- ── Data In: curve file → f(t) modulation source ────────────────────────────
    -- Loads a .curve JSON file (music_lab format) and presents it as a curve.
    -- Compatible with any signal produced by curve.py (signalfault features,
    -- anomaly scores, envelopes, physics outputs — anything 1D over time).
    --
    -- Knobs:
    --   speed  — time multiplier (1=realtime, 2=2x faster, 0.5=half speed)
    --   offset — time shift in seconds (positive = delay, negative = advance)
    --   scale  — output multiplier (use to rescale the curve to your parameter range)
    --
    -- The curve loops when t * speed + offset exceeds the curve duration.
    -- Set speed=0 to freeze at the start (useful for static parameter offsets).
    def{type="data_in", label="Curve In", category="external",
        color={0.45, 0.35, 0.6}, inputs={}, outputs={"out"},
        filePath = "data.curve",
        knobs={
            {name="speed",  min=0,  max=10,  default=1.0},
            {name="offset", min=-60, max=60, default=0.0},
            {name="scale",  min=-10, max=10, default=1.0},
        },
        buildCurve=function(_, k, node)
            -- Create or reuse watcher, keyed to filePath
            local path = node.filePath or "data.curve"
            if not node._watcher or node._watcher.path ~= path then
                node._watcher   = FileWatcher.new(path)
                node._curveData = nil   -- flush cache on path change
            end

            return function(t, ctx)
                -- Poll for file changes (cheap: cached for 0.5s between checks)
                local raw = FileWatcher.update(node._watcher, t)

                -- Rebuild value cache when data changes
                if raw ~= node._curveData then
                    node._curveData = raw
                    node._cv        = raw.values      -- Lua 1-indexed array
                    node._cvSr      = raw.sr or 100.0
                    node._cvN       = raw.values and #raw.values or 0
                end

                local cv = node._cv
                local n  = node._cvN
                if not cv or n == 0 then return 0 end

                -- Map t → index (with speed/offset, looping)
                local sr  = node._cvSr
                local dur = n / sr
                local ti  = ((t * k.speed + k.offset) % dur) * sr
                if ti < 0 then ti = ti + n end

                local i    = math.floor(ti)
                local frac = ti - i
                local i1   = (i % n) + 1          -- Lua 1-indexed, wrapping
                local i2   = ((i + 1) % n) + 1
                return (cv[i1] * (1 - frac) + cv[i2] * frac) * k.scale
            end
        end}

    -- Macro node: collapsible subgraph
    -- inputs/outputs are dynamic, set per instance from macroData
    def{type="macro", label="Macro", category="macro",
        color={0.5, 0.5, 0.5}, inputs={}, outputs={},
        buildCurve=function() return Curve.const(0) end}

    return defs
end

return Nodes
