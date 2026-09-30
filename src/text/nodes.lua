--- src.text.nodes - Text source node definitions for the visual editor
---
--- Domain adapter nodes that transform text signals into curve space.
--- These nodes bridge text data (chat, datasets, files) into the curve
--- composition system where they can be processed like any other signal.
---
--- Usage (in editor/init.lua):
---   local TextNodes = require("spatula.src.text.nodes")
---   local textDefs = TextNodes.buildDefs(Curve, TextInput)
---   for _, d in ipairs(textDefs) do defs[#defs+1] = d end

local TextNodes = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--- Get time from clock input or fallback to realtime
--- @param inp table Input connections table
--- @param t number Current curve time parameter
--- @param ctx table Context (with dt)
--- @return number clockT Current clock time
--- @return number clockDt Clock delta time
local function getClock(inp, t, ctx)
    if inp.clock then
        local ok, clock = pcall(inp.clock, t, ctx)
        if ok and type(clock) == "table" then
            return clock.t or 0, clock.dt or 0
        elseif ok and type(clock) == "number" then
            return clock, 0  -- scalar clock input (legacy)
        end
    end
    -- Fallback to realtime
    return love and love.timer.getTime() or os.time(),
           love and love.timer.getDelta() or 0.016
end

--- Parse keyword string with optional weights
--- Format: "hype:2, pog:1.5, gg, lul:-0.5"
--- @param str string Comma-separated keywords with optional :weight suffix
--- @return table Array of {word=string, weight=number}
local function parseKeywords(str)
    if not str or str == "" then return {} end
    local kws = {}
    for item in str:gmatch("[^,]+") do
        local part = item:match("^%s*(.-)%s*$")  -- trim whitespace
        if part ~= "" then
            local word, weight = part:match("^(%S+):([%d%.%-]+)$")
            if word then
                kws[#kws + 1] = {word = word:lower(), weight = tonumber(weight) or 1.0}
            else
                kws[#kws + 1] = {word = part:lower(), weight = 1.0}
            end
        end
    end
    return kws
end

--- Match keywords in text and return gate/score
--- @param text string Text to search
--- @param keywords table Array of {word, weight} from parseKeywords
--- @param caseSensitive boolean Whether to match case
--- @param wholeWord boolean Whether to match whole words only
--- @return number gate 1 if any match, 0 otherwise
--- @return number score Weighted sum of matches
local function matchAndScore(text, keywords, caseSensitive, wholeWord)
    if not text or text == "" or #keywords == 0 then
        return 0, 0
    end

    local searchText = caseSensitive and text or text:lower()
    local gate, score = 0, 0

    for _, kw in ipairs(keywords) do
        local searchWord = caseSensitive and kw.word or kw.word:lower()
        local found = false

        if wholeWord then
            -- Match whole words only
            for word in searchText:gmatch("%S+") do
                -- Strip punctuation from word edges for matching
                local cleanWord = word:match("^%p*(.-)%p*$") or word
                if cleanWord == searchWord then
                    found = true
                    break
                end
            end
        else
            -- Substring match
            found = searchText:find(searchWord, 1, true) ~= nil
        end

        if found then
            gate = 1
            score = score + kw.weight
        end
    end

    return gate, score
end

--------------------------------------------------------------------------------
-- NODE DEFINITIONS
--------------------------------------------------------------------------------

--- Build text node definitions
--- @param Curve table The Curve module
--- @param TextInput table The TextInput manager module
--- @return table Array of node definition tables
function TextNodes.buildDefs(Curve, TextInput)
    local defs = {}

    local function def(d)
        defs[#defs + 1] = d
    end

    -- Text source: creates a text buffer manager for manual/file input
    def{type="text_source", label="Text Source", category="text",
        color={0.4, 0.35, 0.5}, inputs={}, outputs={"text"},
        knobs={{name="buffer", min=20, max=200, default=50}},
        sourcePath = "",
        buildCurve=function(_, k, node)
            local mgr = TextInput.new({maxSize = math.floor(k.buffer)})
            node._textManager = mgr
            return mgr
        end}

    -- Text sentiment: outputs sentiment score (0=negative, 1=positive)
    def{type="text_sentiment", label="Sentiment", category="text",
        color={0.45, 0.35, 0.55}, inputs={"text"}, outputs={"out"},
        knobs={{name="smooth", min=0, max=0.5, default=0.15}},
        buildCurve=function(inp, k)
            local textMgr = inp.text
            if not textMgr or not textMgr._isTextManager then
                return Curve.const(0.5)
            end
            -- Ensure sentiment classifier is loaded
            if not textMgr.classifiers.sentiment then
                pcall(function()
                    textMgr.classifiers.sentiment = require("spatula.classifier.problems.yelp_sentiment")
                end)
            end
            return function(t, ctx)
                TextInput.process(textMgr, ctx and ctx.dt or 0.016)
                return TextInput.getScore(textMgr, "sentiment")
            end
        end}

    -- Text stance: outputs 3 curves for favor/against/neutral
    def{type="text_stance", label="Stance", category="text",
        color={0.45, 0.4, 0.55}, inputs={"text"}, outputs={"favor", "against", "neutral"},
        knobs={},
        buildCurve=function(inp)
            local textMgr = inp.text
            if not textMgr or not textMgr._isTextManager then
                return {
                    favor = Curve.const(0.33),
                    against = Curve.const(0.33),
                    neutral = Curve.const(0.33)
                }
            end
            -- Ensure stance classifier is loaded
            if not textMgr.classifiers.stance then
                pcall(function()
                    textMgr.classifiers.stance = require("spatula.classifier.problems.stance_detector")
                end)
            end
            return {
                favor = function(t, ctx)
                    TextInput.process(textMgr, ctx and ctx.dt or 0.016)
                    return TextInput.getScore(textMgr, "favor")
                end,
                against = function(t, ctx)
                    return TextInput.getScore(textMgr, "against")
                end,
                neutral = function(t, ctx)
                    return TextInput.getScore(textMgr, "neutral")
                end
            }
        end}

    -- Text to Curve: bridges text into curve space
    -- Treats character position as time axis, enabling curve statistics on text
    def{type="text_to_curve", label="Text→Curve", category="text",
        color={0.5, 0.45, 0.55}, inputs={"text", "sync"}, outputs={"char", "idx", "total", "pos"},
        knobs={{name="speed", min=0, max=2, default=0.5}},
        toggles={{name="mode", options={"chr", "wrd", "tok", "snt"}, default=1, label="mode"},
                 {name="reverse", default=false, label="reverse"}},
        buildCurve=function(inp, k, node)
            local textInput = inp.text
            local syncInput = inp.sync  -- Optional: char index from another text_to_curve

            -- Parse text into units based on mode (1=char, 2=word, 3=token, 4=sentence)
            local function parseUnits(text, modeIdx)
                if modeIdx == 1 then
                    -- Char mode: each character is a unit
                    local units = {}
                    for i = 1, #text do
                        units[#units + 1] = {start = i, stop = i, text = text:sub(i, i)}
                    end
                    return units
                elseif modeIdx == 2 then
                    -- Word mode: split on whitespace
                    local units = {}
                    local i = 1
                    while i <= #text do
                        while i <= #text and text:sub(i, i):match("%s") do i = i + 1 end
                        if i > #text then break end
                        local start = i
                        while i <= #text and not text:sub(i, i):match("%s") do i = i + 1 end
                        units[#units + 1] = {start = start, stop = i - 1, text = text:sub(start, i - 1)}
                    end
                    return units
                elseif modeIdx == 3 then
                    -- Token mode: split on whitespace and punctuation
                    local units = {}
                    local i = 1
                    while i <= #text do
                        while i <= #text and text:sub(i, i):match("%s") do i = i + 1 end
                        if i > #text then break end
                        local start = i
                        local c = text:sub(i, i)
                        if c:match("%p") then
                            units[#units + 1] = {start = i, stop = i, text = c}
                            i = i + 1
                        else
                            while i <= #text and not text:sub(i, i):match("[%s%p]") do i = i + 1 end
                            units[#units + 1] = {start = start, stop = i - 1, text = text:sub(start, i - 1)}
                        end
                    end
                    return units
                else
                    -- Sentence mode: split on sentence-ending punctuation
                    local units = {}
                    local i = 1
                    while i <= #text do
                        -- Skip leading whitespace
                        while i <= #text and text:sub(i, i):match("%s") do i = i + 1 end
                        if i > #text then break end
                        local start = i
                        -- Find sentence end (.!?) followed by space or end
                        while i <= #text do
                            local c = text:sub(i, i)
                            if c:match("[%.%!%?]") then
                                local next = text:sub(i + 1, i + 1)
                                if next == "" or next:match("%s") then
                                    i = i + 1
                                    break
                                end
                            end
                            i = i + 1
                        end
                        if start <= #text then
                            local sentText = text:sub(start, i - 1):match("^%s*(.-)%s*$") or ""
                            if #sentText > 0 then
                                units[#units + 1] = {start = start, stop = i - 1, text = sentText}
                            end
                        end
                    end
                    -- If no sentences found, treat whole text as one
                    if #units == 0 and #text > 0 then
                        units[1] = {start = 1, stop = #text, text = text}
                    end
                    return units
                end
            end

            -- Find which unit contains a given character index
            local function findUnitByCharIdx(units, charIdx)
                for i, unit in ipairs(units) do
                    if charIdx >= unit.start and charIdx <= unit.stop then
                        return i
                    end
                end
                -- If char is in whitespace between units, find nearest
                for i, unit in ipairs(units) do
                    if charIdx < unit.start then
                        return math.max(1, i - 1)
                    end
                end
                return #units
            end

            -- Animation state
            local animIdx = 1
            local lastTime = love and love.timer.getTime() or os.time()
            local cachedUnits = nil
            local cachedText = ""
            local cachedMode = -1

            -- Get current state
            local function getState(t, ctx)
                local textMgr = textInput and textInput(t, ctx)
                if not textMgr or not textMgr._isTextManager then
                    return "", {}, 1, 1
                end
                local buf = textMgr.buffer
                if not buf or #buf == 0 then return "", {}, 1, 1 end
                local text = buf[#buf].text or ""

                -- Read from toggleValues and knobValues dynamically
                local speed = node.knobValues and node.knobValues.speed or k.speed
                local reverse = node.toggleValues and node.toggleValues.reverse or false
                local modeIdx = node.toggleValues and node.toggleValues.mode or 1

                -- Reparse if text or mode changed
                if text ~= cachedText or modeIdx ~= cachedMode then
                    cachedText = text
                    cachedMode = modeIdx
                    cachedUnits = parseUnits(text, modeIdx)
                    animIdx = 1
                end
                local units = cachedUnits or {}
                local total = math.max(1, #units)

                local idx
                -- Check for sync input (char index from another node)
                if syncInput then
                    local ok, syncCharIdx = pcall(syncInput, t, ctx)
                    if ok and type(syncCharIdx) == "number" and syncCharIdx > 0 then
                        idx = findUnitByCharIdx(units, math.floor(syncCharIdx))
                    else
                        idx = 1  -- Fallback if sync fails or returns invalid value
                    end
                else
                    -- Self-animate if speed > 0
                    local now = love and love.timer.getTime() or os.time()
                    local dt = now - lastTime
                    lastTime = now

                    if speed > 0 and #units > 0 then
                        local unitsPerSec = speed * 5  -- speed 1 = 5 units/sec
                        local advance = unitsPerSec * dt
                        if reverse then
                            animIdx = animIdx - advance
                            if animIdx < 1 then animIdx = total end
                        else
                            animIdx = animIdx + advance
                            if animIdx > total then animIdx = 1 end
                        end
                    end
                    idx = math.floor(animIdx)
                end

                idx = math.max(1, math.min(idx, total))

                -- Store for preview (including debug info)
                local unit = units[idx] or {start = 1, stop = 1, text = ""}
                local modeNames = {"char", "word", "token", "sent"}
                node._textPreview = {
                    text = text,
                    units = units,
                    idx = idx,
                    total = total,
                    mode = modeIdx - 1,  -- 0-indexed for display
                    unit = unit,
                    speed = speed,
                    reverse = reverse,
                    animIdx = animIdx,
                    synced = syncInput ~= nil
                }

                return text, units, idx, total
            end

            return {
                char = function(t, ctx)
                    local text, units, idx = getState(t, ctx)
                    local unit = units[idx]
                    if not unit then return 0 end
                    return text:byte(unit.start) or 0
                end,
                idx = function(t, ctx)
                    local _, units, idx = getState(t, ctx)
                    -- Return the char index (start of current unit) for syncing
                    local unit = units[idx]
                    return unit and unit.start or 1
                end,
                total = function(t, ctx)
                    local _, _, _, total = getState(t, ctx)
                    return total
                end,
                pos = function(t, ctx)
                    local _, _, idx, total = getState(t, ctx)
                    return idx / total
                end
            }
        end}

    -- Dataset: loads text samples with navigation controls
    -- Supports TSV format: label<tab>text or label<tab>topic<tab>text
    def{type="dataset_loader", label="Dataset", category="text",
        color={0.55, 0.45, 0.5}, inputs={}, outputs={"text", "label", "idx", "total"},
        knobs={},  -- No continuous knobs
        toggles={{name="auto", default=false, label="auto"},
                 {name="random", default=false, label="random"}},
        buttons={{name="prev", label="◀ Prev"},
                 {name="next", label="Next ▶"}},
        -- Default to test dataset in LÖVE save directory
        datasetPath = "test_data.tsv",
        buildCurve=function(_, k, node)
            -- Dataset storage (persisted on node)
            if not node._dataset then
                node._dataset = {
                    samples = {},
                    labels = {},
                    loaded = false,
                    currentIdx = 1,
                    textManager = TextInput.new({maxSize = 1}),
                    lastAdvanceTime = love and love.timer.getTime() or os.time()
                }
            end
            local ds = node._dataset

            -- Load dataset from file if path is set and not yet loaded
            local function loadDataset()
                if ds.loaded then return end

                local content = nil
                if love and love.filesystem then
                    content = love.filesystem.read(node.datasetPath)
                end
                if not content then
                    local f = io.open(node.datasetPath, "r")
                    if f then
                        content = f:read("*all")
                        f:close()
                    end
                end

                if content then
                    ds.samples = {}
                    ds.labels = {}
                    for line in content:gmatch("[^\r\n]+") do
                        local label, _, text = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
                        if not label then
                            label, text = line:match("^([^\t]+)\t(.+)$")
                        end
                        if label and text then
                            ds.samples[#ds.samples + 1] = text
                            ds.labels[#ds.labels + 1] = label
                        end
                    end
                end

                -- Fallback test samples
                if #ds.samples == 0 then
                    ds.samples = {
                        "This is a positive test message with good vibes!",
                        "Negative spam alert: buy now limited offer!!!",
                        "Neutral informational text about weather today.",
                        "URGENT: You have won a prize claim now FREE",
                        "Thanks for the great service, really appreciated.",
                    }
                    ds.labels = {"favor", "against", "neutral", "against", "favor"}
                end

                ds.loaded = true

                -- Initialize with first sample
                if #ds.samples > 0 then
                    ds.textManager.buffer = {{text = ds.samples[1], time = love and love.timer.getTime() or os.time()}}
                    ds.currentIdx = 1
                end
            end

            -- Update text manager with current sample
            local function updateTextManager()
                loadDataset()
                if ds.currentIdx >= 1 and ds.currentIdx <= #ds.samples then
                    ds.textManager.buffer = {{text = ds.samples[ds.currentIdx], time = love and love.timer.getTime() or os.time()}}
                end
            end

            return {
                text = function(t, ctx)
                    loadDataset()

                    -- Auto-advance if auto toggle is on
                    local auto = node.toggleValues and node.toggleValues.auto
                    local random = node.toggleValues and node.toggleValues.random
                    if auto and #ds.samples > 0 then
                        local now = love and love.timer.getTime() or os.time()
                        local interval = 2  -- 2 seconds per sample in auto mode
                        if now - ds.lastAdvanceTime > interval then
                            ds.lastAdvanceTime = now
                            if random then
                                ds.currentIdx = math.random(1, #ds.samples)
                            else
                                ds.currentIdx = ds.currentIdx + 1
                                if ds.currentIdx > #ds.samples then ds.currentIdx = 1 end
                            end
                            updateTextManager()
                        end
                    end

                    return ds.textManager
                end,
                label = function(t, ctx)
                    loadDataset()
                    local idx = ds.currentIdx
                    idx = math.max(1, math.min(idx, #ds.labels))
                    local lbl = ds.labels[idx] or ""
                    if lbl == "favor" or lbl == "ham" or lbl == "positive" then return 1
                    elseif lbl == "against" or lbl == "spam" or lbl == "negative" then return 0
                    elseif lbl == "neutral" then return 0.5
                    else return tonumber(lbl) or 0 end
                end,
                idx = function(t, ctx)
                    return ds.currentIdx
                end,
                total = function(t, ctx)
                    loadDataset()
                    return #ds.samples
                end
            }
        end}

    -- Keyword match: detects keywords with weighted scoring
    -- Outputs gate (trigger) and score (weighted sum with decay)
    -- Optional clock input for domain-independent decay timing
    def{type="keyword_match", label="Keywords", category="text",
        color={0.45, 0.5, 0.55}, inputs={"text", "clock"}, outputs={"gate", "score"},
        knobs={{name="decay", min=0.01, max=0.5, default=0.1}},
        toggles={{name="case", default=false, label="case"},
                 {name="whole", default=true, label="whole"}},
        keywords = "positive:2, good:1.5, great:1, thanks:1, service:1, negative:-2, spam:-1.5, urgent:-1, free:-1, buy:-1",  -- inline weights syntax
        buildCurve=function(inp, k, node)
            local textInput = inp.text

            -- Parse keywords once at build time
            local keywords = parseKeywords(node.keywords or "")

            -- State persisted across evaluations
            local gateLevel = 0
            local scoreLevel = 0
            local lastMsgCount = 0
            local lastClockT = 0

            -- Shared update function (called by both outputs)
            local lastUpdateT = -1
            local function update(t, ctx)
                -- Only update once per evaluation cycle
                if t == lastUpdateT then return end
                lastUpdateT = t

                -- Get clock time (from wired clock or realtime fallback)
                local clockT, clockDt = getClock(inp, t, ctx)

                local textMgr = textInput and textInput(t, ctx)
                if not textMgr or not textMgr._isTextManager then return end

                local msgCount = #textMgr.buffer
                if msgCount > lastMsgCount then
                    -- Process new messages
                    local caseSensitive = node.toggleValues and node.toggleValues.case or false
                    local wholeWord = node.toggleValues and node.toggleValues.whole
                    if wholeWord == nil then wholeWord = true end

                    for i = lastMsgCount + 1, msgCount do
                        local msg = textMgr.buffer[i]
                        if msg and msg.text then
                            local g, s = matchAndScore(msg.text, keywords, caseSensitive, wholeWord)
                            if g > 0 then
                                gateLevel = 1  -- Spike to 1 on any match
                                scoreLevel = scoreLevel + s  -- Accumulate weighted score
                            end
                        end
                    end
                    lastMsgCount = msgCount
                end

                -- Apply decay based on clock delta
                -- When clock is wired, decay happens in clock-space (e.g., text position)
                -- When clock is not wired, decay happens in real-time
                local decay = node.knobValues and node.knobValues.decay or k.decay
                local elapsed = clockT - lastClockT
                lastClockT = clockT

                -- Scale decay by elapsed time (clamp to prevent explosion)
                local decayFactor
                if inp.clock then
                    -- Clock-based decay: decay operates in normalized space
                    -- elapsed is typically 0-1 change in position
                    decayFactor = math.exp(-decay * elapsed * 10)
                else
                    -- Real-time decay: decay operates per-frame (original behavior)
                    decayFactor = 1 - decay
                end

                gateLevel = gateLevel * decayFactor
                scoreLevel = scoreLevel * decayFactor

                -- Store for preview
                node._keywordPreview = {
                    keywords = keywords,
                    gate = gateLevel,
                    score = scoreLevel,
                    lastMsgCount = lastMsgCount,
                    clockT = clockT,
                    clockWired = inp.clock ~= nil
                }
            end

            return {
                gate = function(t, ctx)
                    update(t, ctx)
                    return gateLevel
                end,
                score = function(t, ctx)
                    update(t, ctx)
                    return scoreLevel
                end
            }
        end}

    -- Rolling Buffer: bridges discrete messages to continuous audio/video time
    -- Maintains a time-windowed buffer of messages for live stream sync
    def{type="rolling_buffer", label="Rolling Buffer", category="text",
        color={0.5, 0.4, 0.55}, inputs={"text", "clock"}, outputs={"buffer_text", "buffer_time", "message_age", "recency_weight"},
        knobs={{name="duration", min=10, max=120, default=60},
               {name="max_msgs", min=10, max=500, default=100}},
        toggles={{name="separator", options={"space", "newline"}, default=1, label="sep"},
                 {name="decay", options={"linear", "exp"}, default=1, label="decay"}},
        buildCurve=function(inp, k, node)
            local textInput = inp.text

            -- Buffer state: array of {text, timestamp}
            local buffer = {}
            local lastMsgCount = 0
            local startTime = love and love.timer.getTime() or os.time()

            -- Build concatenated text from buffer
            local function buildBufferText(sep)
                if #buffer == 0 then return "" end
                local parts = {}
                for _, entry in ipairs(buffer) do
                    parts[#parts + 1] = entry.text
                end
                return table.concat(parts, sep)
            end

            -- Prune old entries based on duration and max_msgs
            local function pruneBuffer(now, duration, maxMsgs)
                local cutoff = now - duration
                -- Remove by time
                while #buffer > 0 and buffer[1].timestamp < cutoff do
                    table.remove(buffer, 1)
                end
                -- Remove by count
                while #buffer > maxMsgs do
                    table.remove(buffer, 1)
                end
            end

            -- Calculate weights for recency
            local function calcRecencyWeight(entryIdx, total, decayMode, now, duration)
                if total == 0 then return 0 end
                local entry = buffer[entryIdx]
                if not entry then return 0 end

                local age = now - entry.timestamp
                local normalizedAge = math.min(1, age / duration)

                if decayMode == 2 then
                    -- Exponential decay: newer = higher
                    return math.exp(-normalizedAge * 3)
                else
                    -- Linear decay: newer = higher
                    return 1 - normalizedAge
                end
            end

            -- Create a text manager wrapper for buffer output
            local function createBufferTextManager(sep)
                local text = buildBufferText(sep)
                return {
                    _isTextManager = true,
                    buffer = {{text = text, time = love and love.timer.getTime() or os.time()}}
                }
            end

            -- Shared update function
            local cachedText = ""
            local cachedSep = " "
            local lastUpdateT = -1

            local function update(t, ctx)
                if t == lastUpdateT then return end
                lastUpdateT = t

                local now = love and love.timer.getTime() or os.time()
                local duration = node.knobValues and node.knobValues.duration or k.duration
                local maxMsgs = node.knobValues and node.knobValues.max_msgs or k.max_msgs
                local sepMode = node.toggleValues and node.toggleValues.separator or 1
                local sep = sepMode == 2 and "\n" or " "
                cachedSep = sep

                -- Get new messages from input
                local textMgr = textInput and textInput(t, ctx)
                if textMgr and textMgr._isTextManager then
                    local msgCount = #textMgr.buffer
                    if msgCount > lastMsgCount then
                        for i = lastMsgCount + 1, msgCount do
                            local msg = textMgr.buffer[i]
                            if msg and msg.text then
                                buffer[#buffer + 1] = {
                                    text = msg.text,
                                    timestamp = now
                                }
                            end
                        end
                        lastMsgCount = msgCount
                    end
                end

                -- Prune old entries
                pruneBuffer(now, duration, maxMsgs)

                -- Rebuild cached text
                cachedText = buildBufferText(sep)

                -- Store for preview
                node._bufferPreview = {
                    entryCount = #buffer,
                    textLength = #cachedText,
                    duration = duration,
                    oldestAge = #buffer > 0 and (now - buffer[1].timestamp) or 0
                }
            end

            return {
                buffer_text = function(t, ctx)
                    update(t, ctx)
                    return createBufferTextManager(cachedSep)
                end,
                buffer_time = function(t, ctx)
                    update(t, ctx)
                    -- Normalized time: 0 at buffer start, 1 at end
                    local now = love and love.timer.getTime() or os.time()
                    local duration = node.knobValues and node.knobValues.duration or k.duration
                    if #buffer == 0 then return 0 end
                    local oldest = buffer[1].timestamp
                    local elapsed = now - oldest
                    return math.min(1, elapsed / duration)
                end,
                message_age = function(t, ctx)
                    update(t, ctx)
                    -- Return average message age (0-1 normalized)
                    local now = love and love.timer.getTime() or os.time()
                    local duration = node.knobValues and node.knobValues.duration or k.duration
                    if #buffer == 0 then return 0 end
                    local totalAge = 0
                    for _, entry in ipairs(buffer) do
                        totalAge = totalAge + (now - entry.timestamp)
                    end
                    local avgAge = totalAge / #buffer
                    return math.min(1, avgAge / duration)
                end,
                recency_weight = function(t, ctx)
                    update(t, ctx)
                    -- Return average recency weight (higher for newer messages)
                    local now = love and love.timer.getTime() or os.time()
                    local duration = node.knobValues and node.knobValues.duration or k.duration
                    local decayMode = node.toggleValues and node.toggleValues.decay or 1
                    if #buffer == 0 then return 0 end
                    local totalWeight = 0
                    for i = 1, #buffer do
                        totalWeight = totalWeight + calcRecencyWeight(i, #buffer, decayMode, now, duration)
                    end
                    return totalWeight / #buffer
                end
            }
        end}

    return defs
end

return TextNodes
