-- Shared JSON codec for IR, editor graphs, and external data. No runtime deps.
local JSON = {}
JSON.null = setmetatable({}, {__tostring = function() return "null" end})
local arrayTag = {}
local escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

function JSON.encode(value)
    local active = {}
    local function encode(v, depth)
        if depth > 128 then error("JSON nesting exceeds 128 levels") end
        local kind = type(v)
        if v == JSON.null or kind == "nil" then return "null" end
        if kind == "string" then return quote(v) end
        if kind == "boolean" then return tostring(v) end
        if kind == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return "null" end
            if math.type and math.type(v) == "integer" then return tostring(v) end
            return string.format("%.17g", v)
        end
        -- Editor snapshots can contain runtime-only values.
        if kind ~= "table" then return "null" end
        if active[v] then error("Cannot encode a cyclic JSON value") end
        active[v] = true
        local count, highest, isArray = 0, 0, true
        for key in pairs(v) do
            count = count + 1
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                isArray = false
            else
                highest = math.max(highest, key)
            end
        end
        isArray = isArray and highest == count and (count > 0 or getmetatable(v) == arrayTag)
        local items = {}
        if isArray then
            for i = 1, count do items[i] = encode(v[i], depth + 1) end
        else
            local keys, seen = {}, {}
            for key in pairs(v) do
                if type(key) ~= "string" and type(key) ~= "number" then
                    error("JSON object keys must be strings or numbers")
                end
                local name = tostring(key)
                if seen[name] then error("Duplicate JSON object key: " .. name) end
                seen[name] = true
                keys[#keys + 1] = {name, key}
            end
            table.sort(keys, function(a, b) return a[1] < b[1] end)
            for _, key in ipairs(keys) do
                items[#items + 1] = quote(key[1]) .. ":" .. encode(v[key[2]], depth + 1)
            end
        end
        active[v] = nil
        return (isArray and "[" or "{") .. table.concat(items, ",") .. (isArray and "]" or "}")
    end
    return encode(value, 0)
end

local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then
        return string.char(0xe0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

function JSON.decode(source)
    assert(type(source) == "string", "JSON input must be a string")
    local pos, length = 1, #source
    local function fail(message) error(message .. " at byte " .. pos, 0) end
    local function whitespace()
        local _, finish = source:find("^[ \t\r\n]*", pos)
        pos = finish + 1
    end
    local function hex()
        local digits = source:sub(pos, pos + 3)
        if #digits ~= 4 or digits:find("[^%da-fA-F]") then fail("Invalid Unicode escape") end
        pos = pos + 4
        return tonumber(digits, 16)
    end
    local unescape = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
    local function stringValue()
        pos = pos + 1
        local parts, start = {}, pos
        while pos <= length do
            local c = source:sub(pos, pos)
            if c == '"' then
                parts[#parts + 1] = source:sub(start, pos - 1)
                pos = pos + 1
                return table.concat(parts)
            elseif c == '\\' then
                parts[#parts + 1] = source:sub(start, pos - 1)
                pos = pos + 1
                local escape = source:sub(pos, pos)
                pos = pos + 1
                if escape == 'u' then
                    local code = hex()
                    if code >= 0xd800 and code <= 0xdbff then
                        if source:sub(pos, pos + 1) ~= '\\u' then fail("Missing low surrogate") end
                        pos = pos + 2
                        local low = hex()
                        if low < 0xdc00 or low > 0xdfff then fail("Invalid low surrogate") end
                        code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00
                    elseif code >= 0xdc00 and code <= 0xdfff then
                        fail("Unexpected low surrogate")
                    end
                    parts[#parts + 1] = utf8(code)
                elseif unescape[escape] then
                    parts[#parts + 1] = unescape[escape]
                else
                    fail("Invalid string escape")
                end
                start = pos
            else
                if c:byte() < 32 then fail("Unescaped control character") end
                pos = pos + 1
            end
        end
        fail("Unterminated string")
    end
    local function digits()
        local start = pos
        while source:sub(pos, pos):match("%d") do pos = pos + 1 end
        if start == pos then fail("Expected digit") end
    end
    local function numberValue()
        local start = pos
        if source:sub(pos, pos) == '-' then pos = pos + 1 end
        if source:sub(pos, pos) == '0' then pos = pos + 1 else digits() end
        if source:sub(pos, pos) == '.' then pos = pos + 1; digits() end
        local c = source:sub(pos, pos)
        if c == 'e' or c == 'E' then
            pos = pos + 1
            c = source:sub(pos, pos)
            if c == '+' or c == '-' then pos = pos + 1 end
            digits()
        end
        local number = tonumber(source:sub(start, pos - 1))
        if not number or number == math.huge or number == -math.huge then fail("Number out of range") end
        return number
    end
    local parse
    parse = function(depth)
        if depth > 128 then fail("JSON nesting exceeds 128 levels") end
        whitespace()
        local c = source:sub(pos, pos)
        if c == '"' then return stringValue() end
        if c == '-' or c:match("%d") then return numberValue() end
        if c == '{' or c == '[' then
            local isArray, result = c == '[', {}
            local closing = isArray and ']' or '}'
            if isArray then setmetatable(result, arrayTag) end
            pos = pos + 1
            whitespace()
            if source:sub(pos, pos) == closing then pos = pos + 1; return result end
            while true do
                local key
                if isArray then key = #result + 1 else
                    if source:sub(pos, pos) ~= '"' then fail("Expected object key") end
                    key = stringValue()
                    whitespace()
                    if source:sub(pos, pos) ~= ':' then fail("Expected colon") end
                    pos = pos + 1
                end
                result[key] = parse(depth + 1)
                whitespace()
                c = source:sub(pos, pos)
                pos = pos + 1
                if c == closing then return result end
                if c ~= ',' then fail("Expected comma or " .. closing) end
                whitespace()
            end
        end
        for _, literal in ipairs({"true", "false", "null"}) do
            if source:sub(pos, pos + #literal - 1) == literal then
                pos = pos + #literal
                if literal == "null" then return JSON.null end
                return literal == "true"
            end
        end
        fail("Expected JSON value")
    end
    local value = parse(0)
    whitespace()
    if pos <= length then fail("Unexpected trailing data") end
    return value
end

return JSON
