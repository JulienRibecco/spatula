# Claude Live Co-Pilot Guide for Spatula Editor

Quick reference for using the Live system to edit the node graph while the editor runs.

## File Locations

```
~/Library/Application Support/LOVE/editor/live/
├── edits.json     # Write commands here, editor polls and executes
├── graph.json     # Current graph state (read-only)
├── preview.png    # Screenshot of editor (read-only)
├── heartbeat.json # Timestamp updated every 0.5s when editor running
└── errors.json    # Errors from last edit batch (if any)
```

## Check If Editor Is Running

**ALWAYS check heartbeat.json before sending commands.**

Read `heartbeat.json` and check if `timestamp` is within the last 2 seconds:
```json
{"timestamp": 1769707500, "editorTime": 123.45, "mode": "auto"}
```

If `os.time() - timestamp > 2`, the editor is NOT running - don't send commands.

## Command Format (edits.json)

```json
{
  "commands": [
    {"op": "add_node", "type": "sin", "x": 200, "y": 200, "tempId": "myNode"},
    {"op": "add_node", "type": "scale", "x": 400, "y": 200, "tempId": "scaler", "knobs": {"factor": 2.0}},
    {"op": "add_cable", "fromNode": "myNode", "fromPort": "out", "toNode": "scaler", "toPort": "in"},
    {"op": "set_knob", "nodeId": 1, "knob": "freq", "value": 2.5},
    {"op": "delete_node", "nodeId": 1},
    {"op": "remove_cable", "toNode": 2, "toPort": "in"},
    {"op": "move_node", "nodeId": 1, "x": 300, "y": 400}
  ]
}
```

### Operations

| Op | Required Params | Optional |
|----|-----------------|----------|
| `add_node` | type, x, y | tempId, knobs |
| `add_cable` | fromNode, fromPort, toNode, toPort | |
| `set_knob` | nodeId, knob, value | |
| `delete_node` | nodeId | |
| `remove_cable` | toNode, toPort | |
| `move_node` | nodeId | x, y |
| `reload` | (none) | Clears module caches, invalidates node curves |

### Node References

- Use `tempId` string when creating nodes in the same batch
- Use numeric `nodeId` for existing nodes (get from graph.json)
- TempIds are batch-scoped - don't persist across edit batches

## Workflow

1. Read `preview.png` to see current state
2. Read `graph.json` to get node IDs and structure
3. Write `edits.json` with your commands
4. Wait 1-2 seconds for editor to poll
5. Check `preview.png` again to verify
6. If errors, check `errors.json`

## Hot Reload (F5)

Press F5 in the editor to reload all Lua code without restarting:
- Preserves current graph nodes and cables
- Rebuilds node definitions from updated code
- Useful when modifying node buildCurve functions

## Debugging Tips

1. **Flat preview lines**: Either zero values or constant values (expected for statistics)
2. **Commands failed**: Check errors.json for details
3. **Nodes not updating**: May need to disconnect/reconnect cables to rebuild curves
4. **Dataset not loading**: Check file path, use LOVE save directory for relative paths

## Common Node Types

### Sources
sin, cos, triangle, saw, noise, linear, const, square

### Combinators
add, mul, scale, offset, timeScale, abs, neg, clamp

### Text/Classification
dataset_loader, text_to_curve, text_source, text_sentiment, text_stance

### Statistics
curve_mean, curve_variance, curve_integral, curve_fit_sine

### Audio
audio_fft, audio_beat, audio_beat_env, audio_bands3

### Math
sigmoid, invert

## Example: Build Classification Pipeline

```json
{
  "commands": [
    {"op": "add_node", "type": "dataset_loader", "x": 150, "y": 200, "tempId": "ds"},
    {"op": "add_node", "type": "text_to_curve", "x": 350, "y": 200, "tempId": "t2c"},
    {"op": "add_node", "type": "curve_mean", "x": 550, "y": 150, "tempId": "mean"},
    {"op": "add_node", "type": "scale", "x": 750, "y": 150, "tempId": "w1", "knobs": {"factor": 2.0}},
    {"op": "add_node", "type": "sigmoid", "x": 950, "y": 200, "tempId": "sig"},
    {"op": "add_cable", "fromNode": "ds", "fromPort": "text", "toNode": "t2c", "toPort": "text"},
    {"op": "add_cable", "fromNode": "t2c", "fromPort": "char", "toNode": "mean", "toPort": "in"},
    {"op": "add_cable", "fromNode": "mean", "fromPort": "out", "toNode": "w1", "toPort": "in"},
    {"op": "add_cable", "fromNode": "w1", "fromPort": "out", "toNode": "sig", "toPort": "in"}
  ]
}
```

## Key Insight: Text as Curve

The text classification system treats text as a curve:
- Character position = time axis (t ∈ [0,1])
- text_to_curve outputs: char (byte values), vowel (0/1), word (boundary markers)
- Curve statistics (mean, variance) become text features
- Classification = weighted sum → sigmoid
