--- Spatula Tempo Grid System
--- @module spatula.tempo
---
--- Musical time system where all game time is quantized to tempo divisions.
--- Supports note values from 1/1 (whole note) to 1/128.
---
--- Usage:
---   local tempo = Tempo.new(120)              -- manual BPM
---   local tempo = Tempo.detect(soundData)     -- detect from audio
---
---   -- Time queries
---   tempo:beat(t)                    -- current beat (float)
---   tempo:bar(t)                     -- current bar (float)
---   tempo:phase(t, "1/16")           -- 0-1 phase within division
---   tempo:next(t, "1/8")             -- time of next division boundary
---   tempo:quantize(t, "1/128")       -- snap to nearest grid point
---
---   -- Curve wrappers
---   Tempo.curve(tempo, "1/4", curve)      -- curve loops every quarter note
---   Tempo.trigger(tempo, "1/16")          -- returns 1 on 16th boundaries, 0 otherwise

local Curve = require("spatula.curve")
local Util = require("spatula.util")

local Tempo = {}
Tempo.__index = Tempo

local floor, ceil, abs, min, max, exp = Util.floor, Util.ceil, Util.abs, Util.min, Util.max, Util.exp
local random = Util.random

--------------------------------------------------------------------------------
-- DIVISION PARSING
-- Convert note division strings to ratios
--------------------------------------------------------------------------------

local divisionCache = {}

--- Parse a division string like "1/16" into a ratio
--- @param div string|number Division string or number
--- @return number Ratio (e.g., 1/16 = 0.0625)
local function parseDivision(div)
    if type(div) == "number" then
        return div
    end

    if divisionCache[div] then
        return divisionCache[div]
    end

    local num, denom = div:match("(%d+)/(%d+)")
    if num and denom then
        local ratio = tonumber(num) / tonumber(denom)
        divisionCache[div] = ratio
        return ratio
    end

    -- Fallback: try to parse as number
    local n = tonumber(div)
    if n then
        divisionCache[div] = n
        return n
    end

    error("Invalid division: " .. tostring(div))
end

--- Get duration of a division in seconds
--- @param self table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @return number Duration in seconds
local function divisionDuration(self, div)
    local ratio = parseDivision(div)
    -- ratio of 1/4 means quarter note = 1 beat
    -- At 120 BPM, 1 beat = 0.5 seconds
    -- 1/4 = 1 beat, 1/8 = 0.5 beats, 1/16 = 0.25 beats
    return (ratio * 4) * self.beatDuration
end

--------------------------------------------------------------------------------
-- CORE TEMPO OBJECT
--------------------------------------------------------------------------------

--- Create a new tempo grid with manual BPM
--- @param bpm number Beats per minute
--- @param beatsPerBar number Beats per bar (default 4)
--- @return table Tempo instance
function Tempo.new(bpm, beatsPerBar)
    local self = setmetatable({}, Tempo)
    self.bpm = bpm
    self.beatsPerBar = beatsPerBar or 4
    self.beatDuration = 60 / bpm  -- seconds per beat
    self.barDuration = self.beatDuration * self.beatsPerBar

    -- Input buffer for quantization
    self.inputBuffer = {}

    return self
end

--- Get the beat duration for this tempo
--- @return number Beat duration in seconds
function Tempo:getBeatDuration()
    return self.beatDuration
end

--- Get the bar duration for this tempo
--- @return number Bar duration in seconds
function Tempo:getBarDuration()
    return self.barDuration
end

--- Convert a division to seconds at current BPM
--- @param div string|number Division (e.g., "1/4")
--- @return number Duration in seconds
function Tempo:seconds(div)
    return divisionDuration(self, div)
end

--------------------------------------------------------------------------------
-- TIME QUERIES
--------------------------------------------------------------------------------

--- Get current beat as float (0-indexed)
--- @param t number Time in seconds
--- @return number Beat number (float)
function Tempo:beat(t)
    return t / self.beatDuration
end

--- Get current bar as float (0-indexed)
--- @param t number Time in seconds
--- @return number Bar number (float)
function Tempo:bar(t)
    return t / self.barDuration
end

--- Get phase within a division (0 to 1)
--- @param t number Time in seconds
--- @param div string|number Division (e.g., "1/16")
--- @return number Phase from 0 to 1
function Tempo:phase(t, div)
    local duration = divisionDuration(self, div)
    return (t % duration) / duration
end

--- Get time of next division boundary
--- @param t number Current time in seconds
--- @param div string|number Division (e.g., "1/8")
--- @return number Time of next boundary
function Tempo:next(t, div)
    local duration = divisionDuration(self, div)
    local current = floor(t / duration)
    return (current + 1) * duration
end

--- Get time of previous division boundary
--- @param t number Current time in seconds
--- @param div string|number Division (e.g., "1/8")
--- @return number Time of previous boundary
function Tempo:prev(t, div)
    local duration = divisionDuration(self, div)
    return floor(t / duration) * duration
end

--- Quantize time to nearest grid point
--- @param t number Time in seconds
--- @param div string|number Division (e.g., "1/128")
--- @return number Quantized time
function Tempo:quantize(t, div)
    local duration = divisionDuration(self, div)
    return floor(t / duration + 0.5) * duration
end

--- Check if we just crossed a division boundary
--- @param t number Current time
--- @param prevT number Previous frame time
--- @param div string|number Division to check
--- @return boolean True if crossed boundary
function Tempo:crossed(t, prevT, div)
    local duration = divisionDuration(self, div)
    local current = floor(t / duration)
    local prev = floor(prevT / duration)
    return current > prev
end

--------------------------------------------------------------------------------
-- INPUT QUANTIZATION (SNAP FORWARD)
-- Buffer inputs and execute them on the next grid boundary
--------------------------------------------------------------------------------

--- Buffer an input action for quantized execution
--- @param action string Action name
--- @param data table Action data
--- @param inputTime number Time when input was received
function Tempo:bufferInput(action, data, inputTime)
    table.insert(self.inputBuffer, {
        action = action,
        data = data,
        time = inputTime
    })
end

--- Pop buffered inputs that should execute at current time
--- Snap forward: inputs execute on the next grid point after they were received
--- @param t number Current time
--- @param div string|number Division for quantization (e.g., "1/32")
--- @return table|nil Action if one should execute, nil otherwise
function Tempo:popInput(t, div)
    local duration = divisionDuration(self, div)
    local currentGrid = floor(t / duration)

    for i = #self.inputBuffer, 1, -1 do
        local input = self.inputBuffer[i]
        local inputGrid = floor(input.time / duration)

        -- Input should execute on the grid point AFTER it was received
        local executeGrid = inputGrid + 1

        if currentGrid >= executeGrid then
            table.remove(self.inputBuffer, i)
            return input
        end
    end

    return nil
end

--- Get all buffered inputs ready to execute
--- @param t number Current time
--- @param div string|number Division for quantization
--- @return table Array of ready actions
function Tempo:popAllInputs(t, div)
    local ready = {}
    local input = self:popInput(t, div)
    while input do
        table.insert(ready, input)
        input = self:popInput(t, div)
    end
    return ready
end

--- Clear all buffered inputs
function Tempo:clearInputs()
    self.inputBuffer = {}
end

--------------------------------------------------------------------------------
-- BEAT DETECTION FROM AUDIO
-- Simple onset-based detection using energy peaks
--------------------------------------------------------------------------------

--- Detect tempo from audio data
--- @param soundData userdata LOVE SoundData object
--- @param config table Optional configuration
--- @return table Tempo instance
function Tempo.detect(soundData, config)
    config = config or {}

    local windowSize = config.windowSize or 1024
    local hopSize = config.hopSize or windowSize / 2
    local minBPM = config.minBPM or 60
    local maxBPM = config.maxBPM or 200

    local sampleRate = soundData:getSampleRate()
    local sampleCount = soundData:getSampleCount()
    local channels = soundData:getChannelCount()

    -- Calculate energy in each window
    local energies = {}
    local times = {}
    local i = 0

    while i < sampleCount - windowSize do
        local sum = 0
        for j = 0, windowSize - 1 do
            local sample = 0
            for c = 1, channels do
                sample = sample + soundData:getSample(i + j, c)
            end
            sample = sample / channels
            sum = sum + sample * sample
        end

        local energy = sum / windowSize
        table.insert(energies, energy)
        table.insert(times, i / sampleRate)

        i = i + hopSize
    end

    -- Detect onsets (energy peaks)
    local onsets = {}
    local threshold = 0

    -- Calculate average energy for adaptive threshold
    for _, e in ipairs(energies) do
        threshold = threshold + e
    end
    threshold = (threshold / #energies) * 1.5

    for idx = 2, #energies - 1 do
        local prev = energies[idx - 1]
        local curr = energies[idx]
        local next = energies[idx + 1]

        -- Peak detection with threshold
        if curr > prev and curr > next and curr > threshold then
            table.insert(onsets, times[idx])
        end
    end

    if #onsets < 2 then
        -- Not enough onsets, default to 120 BPM
        return Tempo.new(120)
    end

    -- Calculate inter-onset intervals
    local intervals = {}
    for idx = 2, #onsets do
        local interval = onsets[idx] - onsets[idx - 1]
        -- Filter intervals to reasonable BPM range
        local bpm = 60 / interval
        if bpm >= minBPM and bpm <= maxBPM then
            table.insert(intervals, interval)
        end
    end

    if #intervals == 0 then
        return Tempo.new(120)
    end

    -- Sort intervals and take median
    table.sort(intervals)
    local medianInterval = intervals[floor(#intervals / 2) + 1]

    -- Convert interval to BPM
    local detectedBPM = 60 / medianInterval

    -- Round to nearest integer BPM
    detectedBPM = floor(detectedBPM + 0.5)

    return Tempo.new(detectedBPM)
end

--------------------------------------------------------------------------------
-- CURVE WRAPPERS
-- Loop curves within tempo divisions
--------------------------------------------------------------------------------

--- Create a curve that loops every division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param curve function Curve to loop
--- @return function Tempo-synced curve
function Tempo.curve(tempo, div, curve)
    local duration = divisionDuration(tempo, div)
    return function(t, ctx)
        local localT = t % duration
        return curve(localT, ctx)
    end
end

--- Create a trigger that fires on division boundaries
--- Returns 1 on boundaries (within tolerance), 0 otherwise
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/16")
--- @param tolerance number Time tolerance in seconds (default 0.01)
--- @return function Trigger curve
function Tempo.trigger(tempo, div, tolerance)
    tolerance = tolerance or 0.01
    local duration = divisionDuration(tempo, div)
    return function(t, ctx)
        local phase = (t % duration) / duration
        -- Fire at start of each division
        if phase < (tolerance / duration) or phase > (1 - tolerance / duration) then
            return 1
        end
        return 0
    end
end

--- Create a pulse curve that fires once per division with decay
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param decay number Decay speed (default 5)
--- @return function Pulse curve (0-1)
function Tempo.pulse(tempo, div, decay)
    decay = decay or 5
    local duration = divisionDuration(tempo, div)
    return function(t, ctx)
        local localT = t % duration
        return exp(-localT * decay)
    end
end

--------------------------------------------------------------------------------
-- TEMPO-CURVE CONSTRUCTORS
-- Return standard Curve types that compose with Curve combinators
--------------------------------------------------------------------------------

--- Create a sine wave that completes one cycle per division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param amp number Amplitude (default 1)
--- @param phase number Phase offset (default 0)
--- @return function Curve f(t, ctx) -> value
function Tempo.sin(tempo, div, amp, phase)
    local duration = divisionDuration(tempo, div)
    local freq = 1 / duration
    return Curve.sin(freq, amp or 1, phase or 0)
end

--- Create a cosine wave that completes one cycle per division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param amp number Amplitude (default 1)
--- @param phase number Phase offset (default 0)
--- @return function Curve f(t, ctx) -> value
function Tempo.cos(tempo, div, amp, phase)
    local duration = divisionDuration(tempo, div)
    local freq = 1 / duration
    return Curve.cos(freq, amp or 1, phase or 0)
end

--- Create a triangle wave that completes one cycle per division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param amp number Amplitude (default 1)
--- @return function Curve f(t, ctx) -> value
function Tempo.triangle(tempo, div, amp)
    local duration = divisionDuration(tempo, div)
    local freq = 1 / duration
    return Curve.triangle(freq, amp or 1)
end

--- Create a sawtooth wave that completes one cycle per division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param amp number Amplitude (default 1)
--- @return function Curve f(t, ctx) -> value
function Tempo.saw(tempo, div, amp)
    local duration = divisionDuration(tempo, div)
    local freq = 1 / duration
    return Curve.saw(freq, amp or 1)
end

--- Create a square wave that completes one cycle per division
--- @param tempo table Tempo instance
--- @param div string|number Division (e.g., "1/4")
--- @param amp number Amplitude (default 1)
--- @param duty number Duty cycle 0-1 (default 0.5)
--- @return function Curve f(t, ctx) -> value
function Tempo.square(tempo, div, amp, duty)
    local duration = divisionDuration(tempo, div)
    local freq = 1 / duration
    return Curve.square(freq, amp or 1, duty or 0.5)
end

--------------------------------------------------------------------------------
-- WEIGHTED DIVISION SELECTION
-- Randomly select divisions with configurable weights (bigger = more likely)
--------------------------------------------------------------------------------

--- Default weights biased toward larger divisions
Tempo.defaultWeights = {
    ["1/1"]  = 8,
    ["1/2"]  = 6,
    ["1/4"]  = 4,
    ["1/8"]  = 3,
    ["1/16"] = 2,
    ["1/32"] = 1,
    ["1/64"] = 0.5,
}

--- Select a random division based on weights
--- @param weights table Division -> weight mapping (default: Tempo.defaultWeights)
--- @return string Division string like "1/4"
function Tempo.randomDivision(weights)
    weights = weights or Tempo.defaultWeights

    -- Calculate total weight
    local total = 0
    local divisions = {}
    for div, weight in pairs(weights) do
        total = total + weight
        table.insert(divisions, {div = div, weight = weight})
    end

    -- Pick random point in weight space
    local roll = random() * total
    local cumulative = 0

    for _, entry in ipairs(divisions) do
        cumulative = cumulative + entry.weight
        if roll <= cumulative then
            return entry.div
        end
    end

    -- Fallback (shouldn't happen)
    return "1/4"
end

--- Create a random tempo-synced curve
--- @param tempo table Tempo instance
--- @param weights table Division weights (default: Tempo.defaultWeights)
--- @param curveType function Curve constructor like Tempo.sin (default: Tempo.sin)
--- @return function Curve, string Division used
function Tempo.randomCurve(tempo, weights, curveType)
    curveType = curveType or Tempo.sin
    local div = Tempo.randomDivision(weights)
    return curveType(tempo, div), div
end

return Tempo
