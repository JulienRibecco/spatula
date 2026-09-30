# Spatula Visual Node Editor

A complete visual graph editor for composing Spatula curves, motions, forms, and distributions.

## Quick Start

```lua
local Editor = require("spatula.editor")
local editor = Editor.new()

function love.load()
    editor:load(love.graphics.getWidth(), love.graphics.getHeight())
end

function love.update(dt)
    editor:update(dt)
end

function love.draw()
    editor:draw()
end

-- Forward all input callbacks
function love.mousepressed(x, y, btn) editor:mousepressed(x, y, btn) end
function love.mousereleased(x, y, btn) editor:mousereleased(x, y, btn) end
function love.mousemoved(x, y) editor:mousemoved(x, y) end
function love.keypressed(key) editor:keypressed(key) end
function love.wheelmoved(dx, dy) editor:wheelmoved(dx, dy) end
```

## Controls

| Action | Control |
|--------|---------|
| Add node | Drag from palette |
| Wire ports | Drag from output to input |
| Pan canvas | Middle-drag or right-drag |
| Zoom | Scroll wheel |
| Select | Click node |
| Multi-select | Shift+click or box select |
| Select all | Ctrl+A |
| Delete | Delete/Backspace |
| Reset view | Home |

### Live Co-Pilot Keys

| Key | Action |
|-----|--------|
| E | Export graph state |
| R | Refresh (check for edits) |
| M | Toggle mode (auto/confirm) |
| Z | Undo last edit batch |
| F3 | Toggle debug overlay |

## Node Categories

### Sources (no inputs)

| Node | Description | Knobs |
|------|-------------|-------|
| `sin` | Sine oscillator | freq, amp |
| `cos` | Cosine oscillator | freq, amp |
| `triangle` | Triangle wave | freq, amp |
| `saw` | Sawtooth wave | freq, amp |
| `square` | Square wave | freq, amp |
| `noise` | Pseudo-random noise | scale |
| `linear` | Unbounded ramp | speed |
| `const` | Fixed value | value |

### Combinators

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `add` | Add two curves | a, b | - |
| `mul` | Multiply two curves | a, b | - |
| `scale` | Multiply by constant | in | factor |
| `offset` | Add constant | in | amount |
| `timeScale` | Warp time axis | in | speed |
| `abs` | Absolute value | in | - |
| `neg` | Negate | in | - |
| `clamp` | Restrict range | in | min, max |
| `invert` | Compute 1/x | in | epsilon |
| `sigmoid` | S-curve | in | steepness |

### Triggers

All trigger nodes take `in` (signal) and `t` (clock) inputs:

| Node | Description | Knobs |
|------|-------------|-------|
| `trig_gate` | Pass during duty phase | duty |
| `trig_snh` | Sample & hold on clock crossing | - |
| `trig_reset` | Restart from t=0 each cycle | - |
| `trig_env` | Attack/release envelope | attack, release |

### Entity & Modulation

| Node | Description | Inputs | Outputs |
|------|-------------|--------|---------|
| `point` | Carrier with transform | x, y, rotation | (entity) |
| `sample_x` | Extract X position | entity | out |
| `sample_y` | Extract Y position | entity | out |
| `sample_rot` | Extract rotation | entity | out |
| `distance` | Distance between entities | entityA, entityB | out |
| `angle_to` | Angle from A to B | entityA, entityB | out |

### Forms

| Node | Description | Inputs |
|------|-------------|--------|
| `form_circle` | Circle containment | cx, cy, r, rotation, scale, colorIn |
| `form_rect` | Rectangle containment | cx, cy, w, h, rotation, scale, colorIn |

### Distributions

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `dist_random` | Random points | form | count |
| `dist_grid` | Grid pattern | form | count |
| `dist_poisson` | Poisson disk sampling | form | spacing |
| `dist_hex` | Hexagonal grid | form | spacing |

### Tempo (Musical Timing)

| Node | Description | Knobs | Outputs |
|------|-------------|-------|---------|
| `tempo` | Create tempo object | bpm, beats | (tempo) |
| `tempo_sin` | Synced sine | amp, div | out |
| `tempo_cos` | Synced cosine | amp, div | out |
| `tempo_saw` | Synced sawtooth | amp, div | out |
| `tempo_tri` | Synced triangle | amp, div | out |
| `tempo_phase` | Phase ramp | div | out |
| `tempo_pulse` | Decay on beat | decay, div | out |

### Audio Reactive

| Node | Description | Knobs | Outputs |
|------|-------------|-------|---------|
| `audio_env` | Audio envelope | window, smooth | out |
| `audio_bands3` | Frequency bands | window | low, mid, high |
| `audio_fft` | FFT bin tracking | bin, smooth, scale | out |
| `audio_beat` | Beat detection | threshold, decay | out |

### Fields

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `field` | Create spatial field | - | falloff, blend, base |
| `field_source` | Add source to field | field, point | radius, value |
| `field_sample` | Sample field at point | field, point | - |
| `field_gradient` | Get gradient direction | field, point | (gx, gy outputs) |

### Color

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `color_const` | Constant color | - | r, g, b, a |
| `color_ramp` | 2-stop gradient | in | r1,g1,b1,r2,g2,b2 |
| `color_hsl` | HSL to RGB | h, s, l | a |
| `color_compose` | From curves | r, g, b, a | - |
| `color_split` | Extract channels | colorIn | r, g, b, a |
| `color_mix` | Lerp colors | colorA, colorB, mix | - |
| `color_pulse` | Oscillate colors | colorA, colorB | freq |
| `color_audio` | Audio-reactive hue | audio | sat, light, hueSpeed |

### Text Processing

| Node | Description | Inputs | Outputs | UI |
|------|-------------|--------|---------|---|
| `dataset_loader` | Load text samples | - | text, label, idx, total | toggles: auto, random; buttons: prev, next |
| `text_to_curve` | Text as curve | text, sync | char, idx, total, pos | toggles: mode (chr/wrd/tok/snt), reverse; knob: speed |
| `text_sentiment` | Sentiment analysis | text | out | knob: smooth |
| `text_stance` | Stance detection | text | favor, against, neutral | - |
| `keyword_match` | Keyword detection | text, clock | gate, score | toggles: case, whole; knob: decay; property: keywords |
| `rolling_buffer` | Stream message buffer | text, clock | buffer_text, buffer_time, message_age, recency_weight | toggles: sep (space/newline), decay (linear/exp); knobs: duration, max_msgs |

#### Keyword Match

Detects keywords in text with weighted scoring. The `keywords` property uses inline weight syntax:

```
"hype:2, pog:1.5, gg, lul:-0.5"
```

- `word:weight` - explicit weight (positive or negative)
- `word` alone - defaults to weight 1.0

**Outputs:**
- `gate` - 1.0 on any match, decays smoothly (for visual triggers)
- `score` - weighted sum of all matches, decays (for sentiment-like signals)

**Toggles:**
- `case` - case-sensitive matching (default: off)
- `whole` - match whole words only (default: on)

**Clock input (optional):**
Wire a clock node to enable domain-independent decay timing. Without clock, decay happens in real-time. With clock_text wired, decay happens in text-position space.

**Example usage:**
```
[dataset_loader] → [keyword_match: "good:1,great:2,bad:-1"] → score → [sigmoid] → color
```

#### Rolling Buffer

Bridges discrete chat messages to continuous audio/video time for live streams. Maintains a time-windowed buffer of recent messages.

**Outputs:**
- `buffer_text` - Concatenated recent messages as text manager
- `buffer_time` - Normalized 0-1 over buffer duration (for clock input)
- `message_age` - Average age of messages (0-1)
- `recency_weight` - Higher values for newer messages

**Knobs:**
- `duration` - Buffer time window in seconds (10-120)
- `max_msgs` - Maximum message count (fallback cap)

**Toggles:**
- `sep` - Message separator (space or newline)
- `decay` - Recency decay mode (linear or exponential)

**Stream sync usage:**
```
[chat_source] → [rolling_buffer] → buffer_text → [text_to_curve] → [keyword_match]
                      ↓ buffer_time
                [keyword_match.clock]
```

### Statistics

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `curve_mean` | Windowed mean | in | samples, window |
| `curve_variance` | Windowed variance | in | samples, window |
| `curve_integral` | Running integral | in | samples, window, scale |
| `curve_fit_sine` | Dominant frequency | in | samples, maxFreq |

### External Data

| Node | Description | Knobs | Properties |
|------|-------------|-------|------------|
| `osc_recv` | UDP/OSC receiver | port | oscAddress |
| `file_watch` | JSON file monitor | key | filePath |
| `ts_anomaly` | Time series anomaly | window, resetSilence | - |

### Debug

| Node | Description | Inputs |
|------|-------------|--------|
| `debug_monitor` | Display single value | in |
| `debug_multi` | Display 4 values | a, b, c, d |

### Clock (Domain-Independent Time)

Clock nodes provide time abstraction for different domains. All output a single `clock` port returning `{t, dt}` table.

| Node | Description | Inputs | Knobs |
|------|-------------|--------|-------|
| `clock_realtime` | Wall clock | - | speed |
| `clock_text` | Text position | pos | - |
| `clock_tempo` | Beat-synced | phase | div |
| `clock_manual` | User scrub | - | pos |

**Usage:** Wire clock output to `clock` input on supported nodes (e.g., `keyword_match`). When connected, decay/timing operates in clock-space instead of real-time.

**Position-aware text analysis:**
```
[text_to_curve] → pos → [clock_text] → clock ─┐
       │                                       │
       └──────────────── text ─────────────────┴→ [keyword_match]
```

## UI Elements

### Knobs (Continuous)

Sliders for continuous values. Shift+drag for fine control (0.15x sensitivity).

### Toggles (Discrete)

Two types:
- **Multi-option:** Pill buttons (e.g., mode: `chr | wrd | tok | snt`)
- **Boolean:** Checkbox (e.g., reverse: on/off)

### Buttons (Actions)

Clickable buttons for immediate actions (e.g., Prev/Next on dataset_loader).

## Text-as-Curve System

The editor treats text as a curve where character position maps to time.

### Modes

| Mode | Splits on | Example "Hello, world!" |
|------|-----------|-------------------------|
| `chr` | Each character | H, e, l, l, o, ... (12 units) |
| `wrd` | Whitespace | Hello,, world! (2 units) |
| `tok` | Whitespace + punctuation | Hello, ,, world, ! (4 units) |
| `snt` | Sentence endings (.!?) | Hello, world! (1 unit) |

### Syncing Nodes

Wire the `idx` output of one text_to_curve to the `sync` input of another:

```
dataset_loader ──text──> text_to_curve (char mode, speed=0.5)
       │                      │
       │                      └──idx──> text_to_curve (word mode)
       │                                     └──sync
       └──text─────────────────────────────────┘
```

When the char-mode node reaches character 'D' in "ABC DE", the word-mode node automatically advances to word 2.

### Outputs

| Output | Description |
|--------|-------------|
| `char` | Byte value of current unit's first character |
| `idx` | Character position of current unit start (for syncing) |
| `total` | Total number of units |
| `pos` | Normalized position (idx/total, 0-1) |

## Live Co-Pilot Integration

### File Locations

All files in `love.filesystem.getSaveDirectory()/editor/live/`:

| File | Purpose |
|------|---------|
| `graph.json` | Complete node/cable state |
| `preview.png` | Screenshot |
| `heartbeat.json` | Editor status + timestamp |
| `edits.json` | Commands from Claude Code |
| `errors.json` | Failed command details |

### Command Format

```json
{
  "version": "1.0.0",
  "description": "Add oscillator chain",
  "commands": [
    {"op": "add_node", "type": "sin", "x": 200, "y": 100, "tempId": "osc1"},
    {"op": "add_node", "type": "scale", "right_of": "osc1", "tempId": "scale1"},
    {"op": "add_cable", "fromNode": "osc1", "fromPort": "out", "toNode": "scale1", "toPort": "in"},
    {"op": "set_knob", "nodeId": "osc1", "knob": "freq", "value": 2.0}
  ]
}
```

### Operations

| Op | Parameters |
|----|------------|
| `add_node` | type, x/y OR relative (right_of, left_of, below, above), tempId, knobs |
| `delete_node` | nodeId |
| `move_node` | nodeId, x, y |
| `set_knob` | nodeId, knob, value |
| `set_toggle` | nodeId, toggle, value (bool or int for multi-option) |
| `set_property` | nodeId, property, value (for keywords, datasetPath, etc.) |
| `click_button` | nodeId, button (e.g., "prev", "next") |
| `add_cable` | fromNode, fromPort, toNode, toPort |
| `remove_cable` | toNode, toPort |
| `reload` | (none) - hot-reload all code |

### Modes

- **auto** (default): Apply edits immediately
- **confirm**: Show dialog, Y to accept, N to reject

## Architecture Notes

### Evaluation

Nodes are evaluated lazily with caching (`node._cachedCurve`). Cache invalidates on:
- Cable changes
- Toggle changes
- Button actions
- Hot reload

### Type Safety

Port connections are type-checked by name pattern:
- `form` → form type
- `entity`, `point`, `entityA/B` → point type
- `pts` → points array
- `color*` → color type
- `field` → field type
- Everything else → curve type

### Multi-Output Nodes

Some nodes return tables of curves instead of single curves:
- `audio_bands3` → {low, mid, high}
- `text_to_curve` → {char, idx, total, pos}
- `color_split` → {r, g, b, a}
- `field_gradient` → {gx, gy}

### Preview System

Every node (except xy_output) has an inline preview:
- **Curves:** Waveform plot (4 seconds, normalized)
- **Forms:** Animated shape outline
- **Distributions:** Scatter dots
- **Text:** Highlighted current unit with debug info
- **Debug:** Large formatted values

## Known Limitations

1. **No undo for manual edits** - Only Live co-pilot edits have undo
2. **Hard-coded dimensions** - No DPI scaling
3. **Single audio source** - Must set `node.soundData` externally
4. **No save/load** - Graph persists only through Live export
