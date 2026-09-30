--- spatula.file_watcher - JSON/CSV file watcher for external data
---
--- Monitors a file for changes and parses its contents.
--- Supports JSON and simple key=value formats.
---
--- Usage:
---   local FileWatcher = require("spatula.file_watcher")
---   local watcher = FileWatcher.new("data.json")
---   -- In update:
---   local data = FileWatcher.update(watcher, t)
---   local value = data.value or data[1] or 0

local FileWatcher = {}

local fromJSON = require("spatula.json").decode

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function FileWatcher.new(path, mode)
    return {
        path = path or "data.json",
        mode = mode or "json",  -- "json", "csv", "line"
        lastMod = 0,
        data = {},
        checkTimer = 0,
        checkInterval = 0.5,  -- Check every 0.5 seconds
        _isFileWatcher = true,
    }
end

--------------------------------------------------------------------------------
-- PARSING
--------------------------------------------------------------------------------

--- Parse CSV content (first row = headers, subsequent rows = data)
function FileWatcher.parseCSV(content)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then return {} end

    -- Parse header
    local headers = {}
    for field in lines[1]:gmatch("[^,]+") do
        headers[#headers + 1] = field:match("^%s*(.-)%s*$")  -- Trim
    end

    -- Parse data rows (use last row for current values)
    local result = {}
    if #lines > 1 then
        local lastLine = lines[#lines]
        local col = 1
        for field in lastLine:gmatch("[^,]+") do
            local value = field:match("^%s*(.-)%s*$")
            local num = tonumber(value)
            if headers[col] then
                result[headers[col]] = num or value
            end
            result[col] = num or value
            col = col + 1
        end
    end

    return result
end

--- Parse simple key=value format
function FileWatcher.parseKeyValue(content)
    local result = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)%s*=%s*(.+)$")
        if key and value then
            local num = tonumber(value)
            result[key] = num or value
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------------------

--- Update watcher and return current data
function FileWatcher.update(watcher, t)
    t = t or (love and love.timer.getTime() or os.time())

    -- Rate limit checks
    if t - watcher.checkTimer < watcher.checkInterval then
        return watcher.data
    end
    watcher.checkTimer = t

    -- Check file modification time
    local info = love and love.filesystem.getInfo(watcher.path)
    if not info then
        -- Try standard Lua file check
        local f = io.open(watcher.path, "r")
        if f then
            f:close()
            info = {modtime = os.time()}  -- Can't get actual modtime easily
        end
    end

    if not info then
        return watcher.data
    end

    -- Only reload if modified
    if info.modtime and info.modtime <= watcher.lastMod then
        return watcher.data
    end
    watcher.lastMod = info.modtime or os.time()

    -- Read file content
    local content
    if love and love.filesystem then
        content = love.filesystem.read(watcher.path)
    end
    if not content then
        local f = io.open(watcher.path, "r")
        if f then
            content = f:read("*all")
            f:close()
        end
    end

    if not content or content == "" then
        return watcher.data
    end

    -- Parse based on mode
    local ok, parsed
    if watcher.mode == "json" then
        ok, parsed = pcall(fromJSON, content)
    elseif watcher.mode == "csv" then
        ok, parsed = pcall(FileWatcher.parseCSV, content)
    elseif watcher.mode == "kv" or watcher.mode == "line" then
        ok, parsed = pcall(FileWatcher.parseKeyValue, content)
    else
        -- Try JSON first, then key=value
        ok, parsed = pcall(fromJSON, content)
        if not ok then
            ok, parsed = pcall(FileWatcher.parseKeyValue, content)
        end
    end

    if ok and parsed then
        watcher.data = parsed
    end

    return watcher.data
end

--- Get a specific value from the data
function FileWatcher.get(watcher, key, default)
    local data = watcher.data
    if type(key) == "number" then
        return data[key] or default
    elseif type(key) == "string" then
        return data[key] or default
    end
    return data.value or default
end

return FileWatcher
