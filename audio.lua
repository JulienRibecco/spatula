--- Spatula Audio Analyzer
--- @module spatula.audio
---
--- Extracts amplitude envelopes from audio data for use as Curves.
--- Designed for LÖVE2D's SoundData API.
---
--- Usage:
---   local soundData = love.sound.newSoundData("music.ogg")
---   local keyframes = Audio.analyze(soundData, { windowSize = 1024 })
---   local envelope = Curve.envelope(keyframes, "smooth")
---
---   -- In update:
---   local amplitude = envelope(musicTime, {})
---   particle.scale = 1 + amplitude * 0.5

local Curve = require("spatula.curve")
local Util = require("spatula.util")

local Audio = {}

local sqrt, abs, floor = Util.sqrt, Util.abs, Util.floor

--------------------------------------------------------------------------------
-- ANALYSIS: Extract amplitude envelope from SoundData
--------------------------------------------------------------------------------

--- Analyze audio and extract amplitude keyframes
--- @param soundData userdata LÖVE SoundData object
--- @param config table Optional configuration
--- @return table Keyframes array of {time, value} pairs, normalized 0-1
function Audio.analyze(soundData, config)
    config = config or {}

    local windowSize = config.windowSize or 1024      -- samples per window
    local hopSize = config.hopSize or windowSize / 2  -- overlap
    local mode = config.mode or "rms"                 -- "rms" or "peak"
    local normalize = config.normalize ~= false       -- normalize to 0-1
    local smooth = config.smooth or 0                 -- attack/release smoothing (0-1)

    local sampleRate = soundData:getSampleRate()
    local sampleCount = soundData:getSampleCount()
    local channels = soundData:getChannelCount()

    local keyframes = {}
    local maxValue = 0
    local smoothedValue = 0

    local i = 0
    while i <= sampleCount - windowSize do
        local sum = 0
        local peak = 0

        -- Process window
        for j = 0, windowSize - 1 do
            local sample = 0
            -- Mix channels to mono
            for c = 1, channels do
                sample = sample + soundData:getSample(i + j, c)
            end
            sample = sample / channels

            if mode == "rms" then
                sum = sum + sample * sample
            else -- peak
                local absSample = abs(sample)
                if absSample > peak then
                    peak = absSample
                end
            end
        end

        local value
        if mode == "rms" then
            value = sqrt(sum / windowSize)
        else
            value = peak
        end

        -- Apply smoothing (simple envelope follower)
        if smooth > 0 then
            if value > smoothedValue then
                -- Attack: fast rise
                smoothedValue = smoothedValue + (value - smoothedValue) * (1 - smooth * 0.5)
            else
                -- Release: slow fall
                smoothedValue = smoothedValue + (value - smoothedValue) * (1 - smooth)
            end
            value = smoothedValue
        end

        -- Track max for normalization
        if value > maxValue then
            maxValue = value
        end

        local time = i / sampleRate
        table.insert(keyframes, {time, value})

        i = i + hopSize
    end

    -- Normalize to 0-1
    if normalize and maxValue > 0 then
        for _, kf in ipairs(keyframes) do
            kf[2] = kf[2] / maxValue
        end
    end

    return keyframes
end

--------------------------------------------------------------------------------
-- BAND ANALYSIS: Split into frequency bands (simple approximation)
-- Uses amplitude in different sample-rate ranges as proxy for frequency content
--------------------------------------------------------------------------------

--- Analyze audio and extract per-band amplitude keyframes
--- Note: This is a simple approximation, not true frequency analysis (no FFT)
--- For accurate frequency separation, use Ableton export
--- @param soundData userdata LÖVE SoundData object
--- @param config table Optional configuration
--- @return table {low, mid, high} each containing keyframes
function Audio.bands(soundData, config)
    config = config or {}

    local windowSize = config.windowSize or 2048
    local hopSize = config.hopSize or windowSize / 2

    local sampleRate = soundData:getSampleRate()
    local sampleCount = soundData:getSampleCount()
    local channels = soundData:getChannelCount()

    -- Simple band separation using sample differences
    -- Low: slow changes (average), Mid: medium changes, High: fast changes
    local lowFrames, midFrames, highFrames = {}, {}, {}
    local maxLow, maxMid, maxHigh = 0, 0, 0

    local i = 0
    while i <= sampleCount - windowSize do
        local avgSample = 0
        local diffSum = 0
        local highDiffSum = 0
        local prevSample = 0
        local prevDiff = 0

        for j = 0, windowSize - 1 do
            local sample = 0
            for c = 1, channels do
                sample = sample + soundData:getSample(i + j, c)
            end
            sample = sample / channels

            avgSample = avgSample + abs(sample)

            local diff = abs(sample - prevSample)
            diffSum = diffSum + diff

            local highDiff = abs(diff - prevDiff)
            highDiffSum = highDiffSum + highDiff

            prevDiff = diff
            prevSample = sample
        end

        local low = avgSample / windowSize
        local mid = diffSum / windowSize
        local high = highDiffSum / windowSize

        if low > maxLow then maxLow = low end
        if mid > maxMid then maxMid = mid end
        if high > maxHigh then maxHigh = high end

        local time = i / sampleRate
        table.insert(lowFrames, {time, low})
        table.insert(midFrames, {time, mid})
        table.insert(highFrames, {time, high})

        i = i + hopSize
    end

    -- Normalize
    for _, kf in ipairs(lowFrames) do kf[2] = maxLow > 0 and kf[2] / maxLow or 0 end
    for _, kf in ipairs(midFrames) do kf[2] = maxMid > 0 and kf[2] / maxMid or 0 end
    for _, kf in ipairs(highFrames) do kf[2] = maxHigh > 0 and kf[2] / maxHigh or 0 end

    return {
        low = lowFrames,
        mid = midFrames,
        high = highFrames,
    }
end

--------------------------------------------------------------------------------
-- CONVENIENCE: Create Curve directly from audio
--------------------------------------------------------------------------------

--- Analyze audio and return a Curve directly
--- @param soundData userdata LÖVE SoundData object
--- @param config table Analysis config (see Audio.analyze)
--- @param interpolation string "linear", "step", or "smooth"
--- @return function Curve f(t, ctx) -> amplitude
function Audio.toCurve(soundData, config, interpolation)
    local keyframes = Audio.analyze(soundData, config)
    return Curve.envelope(keyframes, interpolation or "smooth")
end

--- Get audio duration in seconds
--- @param soundData userdata LÖVE SoundData object
--- @return number Duration in seconds
function Audio.duration(soundData)
    return soundData:getSampleCount() / soundData:getSampleRate()
end

return Audio
