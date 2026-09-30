--- spatula.audio_fft - FFT analysis and beat detection for audio reactivity
---
--- Provides frequency-domain analysis of audio data:
---   - DFT: Direct Fourier Transform for frequency bins
---   - binToCurve: Track magnitude of specific frequency bin over time
---   - beatDetect: Onset detection for beat-reactive effects
---
--- Usage:
---   local AudioFFT = require("spatula.audio_fft")
---   local curve = AudioFFT.binToCurve(soundData, 8, {smooth = 0.3})
---   local beatCurve = AudioFFT.beatDetect(soundData, {threshold = 1.2})

local AudioFFT = {}

local sin, cos, sqrt, floor, abs = math.sin, math.cos, math.sqrt, math.floor, math.abs
local PI2 = math.pi * 2

--------------------------------------------------------------------------------
-- DFT (Direct Fourier Transform)
--------------------------------------------------------------------------------

--- Compute DFT magnitudes for a window of samples
--- O(n²) but acceptable for small windows (512-2048)
--- @param samples array of sample values
--- @param numBins number of frequency bins to compute
--- @param fast boolean - if true, downsample by 2x for speed
--- @return array of magnitude values (0 to numBins-1)
function AudioFFT.dft(samples, numBins, fast)
    local n = #samples
    if n == 0 then return {} end

    -- Downsample for fast mode
    if fast and n > 256 then
        local downsampled = {}
        for i = 1, n, 2 do
            downsampled[#downsampled + 1] = samples[i]
        end
        samples = downsampled
        n = #samples
    end

    numBins = numBins or floor(n / 2)
    local mags = {}

    for k = 0, numBins - 1 do
        local real, imag = 0, 0
        local freq = PI2 * k / n

        for i = 1, n do
            local angle = freq * (i - 1)
            real = real + samples[i] * cos(angle)
            imag = imag - samples[i] * sin(angle)
        end

        -- Magnitude (normalized)
        mags[k + 1] = sqrt(real * real + imag * imag) / n
    end

    return mags
end

--- Compute DFT with Hann window applied (reduces spectral leakage)
function AudioFFT.dftWindowed(samples, numBins, fast)
    local n = #samples
    if n == 0 then return {} end

    -- Apply Hann window
    local windowed = {}
    for i = 1, n do
        local w = 0.5 * (1 - cos(PI2 * (i - 1) / (n - 1)))
        windowed[i] = samples[i] * w
    end

    return AudioFFT.dft(windowed, numBins, fast)
end

--------------------------------------------------------------------------------
-- PRE-ANALYSIS (analyze entire audio file upfront)
--------------------------------------------------------------------------------

--- Analyze audio and extract frequency bin magnitudes over time
--- @param soundData LÖVE SoundData object
--- @param config {windowSize, hopSize, numBins, fast}
--- @return table of {time, bins} where bins is array of magnitudes
function AudioFFT.analyze(soundData, config)
    config = config or {}
    local windowSize = config.windowSize or 1024
    local hopSize = config.hopSize or windowSize / 4
    local numBins = config.numBins or 64
    local fast = config.fast or false

    local sampleRate = soundData:getSampleRate()
    local sampleCount = soundData:getSampleCount()
    local channels = soundData:getChannelCount()

    local frames = {}
    local pos = 0

    while pos + windowSize <= sampleCount do
        -- Extract window of samples (mono mix if stereo)
        local samples = {}
        for i = 0, windowSize - 1 do
            local sample = 0
            for c = 1, channels do
                sample = sample + soundData:getSample(pos + i, c)
            end
            samples[i + 1] = sample / channels
        end

        -- Compute FFT
        local bins = AudioFFT.dftWindowed(samples, numBins, fast)

        frames[#frames + 1] = {
            time = pos / sampleRate,
            bins = bins
        }

        pos = pos + hopSize
    end

    return frames
end

--- Get magnitude of a specific bin at a given time
--- Uses linear interpolation between frames
function AudioFFT.sampleBin(frames, binIndex, time)
    if #frames == 0 then return 0 end
    if #frames == 1 then return frames[1].bins[binIndex] or 0 end

    -- Find surrounding frames
    local prev, next = frames[1], frames[#frames]
    for i = 1, #frames - 1 do
        if frames[i].time <= time and frames[i + 1].time > time then
            prev = frames[i]
            next = frames[i + 1]
            break
        end
    end

    -- Interpolate
    local t = 0
    if next.time ~= prev.time then
        t = (time - prev.time) / (next.time - prev.time)
    end

    local v1 = prev.bins[binIndex] or 0
    local v2 = next.bins[binIndex] or 0
    return v1 + (v2 - v1) * t
end

--------------------------------------------------------------------------------
-- CURVE GENERATORS
--------------------------------------------------------------------------------

--- Create a curve that tracks magnitude of a specific frequency bin
--- @param soundData LÖVE SoundData object
--- @param binIndex which frequency bin to track (1-based)
--- @param config {windowSize, hopSize, numBins, smooth, fast, scale}
--- @return curve function(t, ctx) -> value
function AudioFFT.binToCurve(soundData, binIndex, config)
    config = config or {}
    local smooth = config.smooth or 0.3
    local scale = config.scale or 100
    local numBins = config.numBins or 64

    -- Pre-analyze the audio
    local frames = AudioFFT.analyze(soundData, {
        windowSize = config.windowSize or 1024,
        hopSize = config.hopSize or 256,
        numBins = numBins,
        fast = config.fast or false
    })

    -- Smoothed value state
    local smoothedValue = 0

    return function(t, ctx)
        local raw = AudioFFT.sampleBin(frames, binIndex, t)

        -- Apply smoothing (exponential moving average)
        if smooth > 0 then
            smoothedValue = smoothedValue + (raw - smoothedValue) * (1 - smooth)
        else
            smoothedValue = raw
        end

        return smoothedValue * scale
    end
end

--- Create curves for multiple frequency bands
--- @param soundData LÖVE SoundData object
--- @param config {windowSize, smooth, scale}
--- @return {low, mid, high} table of curves
function AudioFFT.bandsToCurves(soundData, config)
    config = config or {}
    local numBins = 32

    local frames = AudioFFT.analyze(soundData, {
        windowSize = config.windowSize or 2048,
        hopSize = config.hopSize or 512,
        numBins = numBins,
        fast = config.fast or false
    })

    local smooth = config.smooth or 0.3
    local scale = config.scale or 100

    -- Define band ranges (in bins)
    local lowEnd = floor(numBins * 0.15)   -- ~0-15% of spectrum
    local midEnd = floor(numBins * 0.5)    -- ~15-50% of spectrum
    -- highEnd = numBins                   -- ~50-100% of spectrum

    local function makeBandCurve(startBin, endBin)
        local smoothed = 0
        return function(t, ctx)
            local sum = 0
            for i = startBin, endBin do
                sum = sum + AudioFFT.sampleBin(frames, i, t)
            end
            local avg = sum / (endBin - startBin + 1)

            if smooth > 0 then
                smoothed = smoothed + (avg - smoothed) * (1 - smooth)
            else
                smoothed = avg
            end

            return smoothed * scale
        end
    end

    return {
        low = makeBandCurve(1, lowEnd),
        mid = makeBandCurve(lowEnd + 1, midEnd),
        high = makeBandCurve(midEnd + 1, numBins)
    }
end

--------------------------------------------------------------------------------
-- BEAT DETECTION
--------------------------------------------------------------------------------

--- Analyze audio for beat onsets using energy flux
--- @param soundData LÖVE SoundData object
--- @param config {windowSize, hopSize, threshold}
--- @return array of {time, strength} for detected beats
function AudioFFT.detectBeats(soundData, config)
    config = config or {}
    local windowSize = config.windowSize or 1024
    local hopSize = config.hopSize or 256
    local threshold = config.threshold or 1.5

    local sampleRate = soundData:getSampleRate()
    local sampleCount = soundData:getSampleCount()
    local channels = soundData:getChannelCount()

    local beats = {}
    local prevEnergy = 0
    local energyHistory = {}
    local historySize = 43  -- ~1 second at typical hop size

    local pos = 0
    while pos + windowSize <= sampleCount do
        -- Compute energy of window
        local energy = 0
        for i = 0, windowSize - 1 do
            local sample = 0
            for c = 1, channels do
                sample = sample + soundData:getSample(pos + i, c)
            end
            sample = sample / channels
            energy = energy + sample * sample
        end
        energy = sqrt(energy / windowSize)

        -- Compute average energy from history
        local avgEnergy = 0
        for _, e in ipairs(energyHistory) do
            avgEnergy = avgEnergy + e
        end
        avgEnergy = #energyHistory > 0 and avgEnergy / #energyHistory or energy

        -- Detect onset: energy significantly above average and rising
        local flux = energy - prevEnergy
        if energy > avgEnergy * threshold and flux > 0 then
            local time = pos / sampleRate
            -- Avoid double-triggering (min 50ms between beats)
            if #beats == 0 or time - beats[#beats].time > 0.05 then
                beats[#beats + 1] = {
                    time = time,
                    strength = energy / (avgEnergy + 0.001)
                }
            end
        end

        -- Update history
        energyHistory[#energyHistory + 1] = energy
        if #energyHistory > historySize then
            table.remove(energyHistory, 1)
        end

        prevEnergy = energy
        pos = pos + hopSize
    end

    return beats
end

--- Create a curve that pulses on beats
--- @param soundData LÖVE SoundData object
--- @param config {threshold, decay}
--- @return curve function(t, ctx) -> value (0-1, spikes to 1 on beat)
function AudioFFT.beatDetect(soundData, config)
    config = config or {}
    local decay = config.decay or 0.15

    -- Pre-detect all beats
    local beats = AudioFFT.detectBeats(soundData, {
        threshold = config.threshold or 1.5,
        windowSize = config.windowSize or 1024,
        hopSize = config.hopSize or 256
    })

    -- Track current beat state
    local lastBeatTime = -1000
    local currentValue = 0

    return function(t, ctx)
        -- Find if we passed a beat
        for _, beat in ipairs(beats) do
            if beat.time > lastBeatTime and beat.time <= t then
                currentValue = 1
                lastBeatTime = beat.time
            end
        end

        -- Decay
        if currentValue > 0 then
            currentValue = currentValue - decay
            if currentValue < 0 then currentValue = 0 end
        end

        return currentValue
    end
end

--- Create a curve that outputs beat strength with configurable attack/decay
--- @param soundData LÖVE SoundData object
--- @param config {threshold, attack, decay}
--- @return curve function(t, ctx) -> value
function AudioFFT.beatEnvelope(soundData, config)
    config = config or {}
    local attack = config.attack or 0.01
    local decay = config.decay or 0.2

    local beats = AudioFFT.detectBeats(soundData, {
        threshold = config.threshold or 1.5
    })

    return function(t, ctx)
        -- Find closest beat before current time
        local closestBeat = nil
        for _, beat in ipairs(beats) do
            if beat.time <= t then
                closestBeat = beat
            else
                break
            end
        end

        if not closestBeat then return 0 end

        local timeSinceBeat = t - closestBeat.time

        -- Attack phase
        if timeSinceBeat < attack then
            return (timeSinceBeat / attack) * closestBeat.strength
        end

        -- Decay phase
        local decayTime = timeSinceBeat - attack
        local value = closestBeat.strength * math.exp(-decayTime / decay)
        return value > 0.01 and value or 0
    end
end

return AudioFFT
