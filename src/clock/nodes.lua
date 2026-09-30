--- src.clock.nodes - Clock node definitions for domain-independent time
---
--- Clock nodes provide time abstraction for different domains:
--- - realtime: Wall clock (seconds)
--- - text: Document position (0-1)
--- - tempo: Beat-synced (bars/beats)
--- - manual: User-controlled scrub
---
--- All clocks output {t, dt} tables for consistent consumption.

local ClockNodes = {}

--------------------------------------------------------------------------------
-- NODE DEFINITIONS
--------------------------------------------------------------------------------

--- Build clock node definitions
--- @param Curve table The Curve module (for fallback const curves)
--- @return table Array of node definition tables
function ClockNodes.buildDefs(Curve)
    local defs = {}

    local function def(d)
        defs[#defs + 1] = d
    end

    -- Clock Realtime: wall clock with speed multiplier
    def{type="clock_realtime", label="Real Time", category="clock",
        color={0.3, 0.5, 0.6}, inputs={}, outputs={"clock"},
        knobs={{name="speed", min=0.1, max=4, default=1}},
        buildCurve=function(_, k, node)
            local startTime = love and love.timer.getTime() or os.time()
            local lastT = startTime
            local lastDt = 0

            return {
                clock = function(t, ctx)
                    local now = love and love.timer.getTime() or os.time()
                    local speed = node.knobValues and node.knobValues.speed or k.speed
                    local elapsed = (now - startTime) * speed
                    local dt = (now - lastT) * speed
                    lastT = now
                    lastDt = dt
                    return {t = elapsed, dt = dt}
                end
            }
        end}

    -- Clock Text: driven by position input (0-1)
    def{type="clock_text", label="Text Clock", category="clock",
        color={0.35, 0.5, 0.55}, inputs={"pos"}, outputs={"clock"},
        knobs={},
        buildCurve=function(inp, k, node)
            local lastPos = 0

            return {
                clock = function(t, ctx)
                    local pos = 0
                    if inp.pos then
                        local ok, val = pcall(inp.pos, t, ctx)
                        if ok and type(val) == "number" then
                            pos = val
                        end
                    end
                    local delta = pos - lastPos
                    -- Handle wrap-around (reset negative deltas to 0)
                    if delta < 0 then delta = 0 end
                    lastPos = pos
                    return {t = pos, dt = delta}
                end
            }
        end}

    -- Clock Tempo: driven by tempo phase
    def{type="clock_tempo", label="Tempo Clock", category="clock",
        color={0.4, 0.5, 0.5}, inputs={"phase"}, outputs={"clock"},
        knobs={{name="div", min=1, max=16, default=4, step=1}},
        buildCurve=function(inp, k, node)
            local lastPhase = 0

            return {
                clock = function(t, ctx)
                    local phase = 0
                    if inp.phase then
                        local ok, val = pcall(inp.phase, t, ctx)
                        if ok and type(val) == "number" then
                            phase = val
                        end
                    end
                    local div = node.knobValues and node.knobValues.div or k.div
                    local normalizedPhase = phase / div
                    local delta = normalizedPhase - lastPhase
                    -- Handle wrap-around
                    if delta < 0 then delta = 0 end
                    lastPhase = normalizedPhase
                    return {t = normalizedPhase, dt = delta}
                end
            }
        end}

    -- Clock Manual: user scrub via knob
    def{type="clock_manual", label="Manual Clock", category="clock",
        color={0.45, 0.5, 0.45}, inputs={}, outputs={"clock"},
        knobs={{name="pos", min=0, max=1, default=0}},
        buildCurve=function(_, k, node)
            local lastPos = k.pos

            return {
                clock = function(t, ctx)
                    local pos = node.knobValues and node.knobValues.pos or k.pos
                    local delta = pos - lastPos
                    lastPos = pos
                    return {t = pos, dt = math.abs(delta)}
                end
            }
        end}

    return defs
end

return ClockNodes
