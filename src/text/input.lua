--- src.text.input - Text buffer manager for text source nodes
---
--- Manages a buffer of text messages with rate-limited classifier processing.
--- Used by text_to_curve, dataset_loader, and classifier nodes.
---
--- Usage:
---   local TextInput = require("spatula.src.text.input")
---   local mgr = TextInput.new({maxSize = 100, smoothing = 0.15})
---   TextInput.push(mgr, "Hello world")
---   local sentiment = TextInput.getScore(mgr, "sentiment")

local TextInput = {}

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function TextInput.new(config)
    config = config or {}
    return {
        buffer = {},                           -- Array of {text, time} entries
        maxSize = config.maxSize or 100,       -- Max messages in buffer
        smoothedScores = {},                   -- {sentiment=0, favor=0, against=0, ...}
        smoothing = config.smoothing or 0.15,  -- EMA smoothing factor
        lastProcess = 0,                       -- Last processing time
        processInterval = config.processInterval or 0.1,  -- Rate limit: 10 Hz max
        classifiers = {},                      -- Loaded classifier modules
        _isTextManager = true,                 -- Type marker
    }
end

--------------------------------------------------------------------------------
-- MESSAGE BUFFER
--------------------------------------------------------------------------------

--- Push a new message to the buffer
function TextInput.push(mgr, text)
    if not text or text == "" then return end
    local time = love and love.timer.getTime() or os.time()
    table.insert(mgr.buffer, {text = text, time = time})
    -- Trim buffer if too large
    while #mgr.buffer > mgr.maxSize do
        table.remove(mgr.buffer, 1)
    end
end

--- Get recent messages within time window
function TextInput.getRecent(mgr, windowSeconds)
    windowSeconds = windowSeconds or 5
    local now = love and love.timer.getTime() or os.time()
    local recent = {}
    for _, msg in ipairs(mgr.buffer) do
        if now - msg.time < windowSeconds then
            recent[#recent + 1] = msg
        end
    end
    return recent
end

--- Clear all messages
function TextInput.clear(mgr)
    mgr.buffer = {}
    mgr.smoothedScores = {}
end

--------------------------------------------------------------------------------
-- SCORE ACCESS
--------------------------------------------------------------------------------

--- Get smoothed score for a key
function TextInput.getScore(mgr, key)
    return mgr.smoothedScores[key] or 0
end

--- Set score directly (for manual/testing use)
function TextInput.setScore(mgr, key, value)
    mgr.smoothedScores[key] = value
end

--------------------------------------------------------------------------------
-- CLASSIFIER PROCESSING
--------------------------------------------------------------------------------

--- Load a classifier module
function TextInput.loadClassifier(mgr, name, modulePath)
    local ok, module = pcall(require, modulePath)
    if ok and module then
        mgr.classifiers[name] = module
        return true
    end
    return false
end

--- Process buffer with loaded classifiers (rate-limited)
function TextInput.process(mgr, dt)
    local now = love and love.timer.getTime() or os.time()
    if now - mgr.lastProcess < mgr.processInterval then
        return -- Rate limited
    end
    mgr.lastProcess = now

    -- Get recent messages
    local recent = TextInput.getRecent(mgr, 5)
    if #recent == 0 then return end

    -- Process with each loaded classifier
    for name, classifier in pairs(mgr.classifiers) do
        if classifier.predict then
            local totalScore = 0
            local count = 0

            for _, msg in ipairs(recent) do
                local ok, result, score = pcall(classifier.predict, classifier.DEFAULT_MODEL or classifier, msg.text)
                if ok and score then
                    totalScore = totalScore + score
                    count = count + 1
                end
            end

            if count > 0 then
                local avgScore = totalScore / count
                local prev = mgr.smoothedScores[name] or avgScore
                mgr.smoothedScores[name] = prev + (avgScore - prev) * mgr.smoothing
            end
        end
    end
end

--- Update function to call each frame
function TextInput.update(mgr, dt)
    TextInput.process(mgr, dt)
end

return TextInput
