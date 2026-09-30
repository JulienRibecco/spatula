--- spatula.osc - Simple UDP/OSC receiver
---
--- Receives UDP messages (simple OSC-like protocol) and stores values by address.
--- Uses LOVE's built-in socket or falls back to luasocket.
---
--- Usage:
---   local OSC = require("spatula.osc")
---   local osc = OSC.new(8080)
---   -- In update:
---   OSC.update(osc)
---   local value = OSC.get(osc, "/bass", 0)

local OSC = {}

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function OSC.new(port)
    port = port or 8080
    local udp = nil
    local ok = false

    -- Try LOVE's socket first
    if love and love.thread then
        -- Note: LOVE doesn't have built-in UDP, we need luasocket
        ok, udp = pcall(function()
            local socket = require("socket")
            local u = socket.udp()
            u:setsockname("*", port)
            u:settimeout(0)  -- Non-blocking
            return u
        end)
    end

    -- Fallback to luasocket directly
    if not ok or not udp then
        ok, udp = pcall(function()
            local socket = require("socket")
            local u = socket.udp()
            u:setsockname("*", port)
            u:settimeout(0)
            return u
        end)
    end

    return {
        udp = ok and udp or nil,
        port = port,
        values = {},  -- {[address] = value}
        _isOSC = true,
    }
end

--------------------------------------------------------------------------------
-- OSC MESSAGE PARSING
--------------------------------------------------------------------------------

--- Parse a simple OSC message (address + float value)
--- Format: "/address,f\0\0\0\0[4-byte float]" or simple text "/address value"
function OSC.parse(data)
    if not data or #data < 2 then return nil, nil end

    -- Try simple text format first: "/address value"
    local addr, val = data:match("^(/[%w_/]+)%s+([%d%.%-]+)")
    if addr and val then
        return addr, tonumber(val)
    end

    -- Try OSC binary format
    if data:sub(1, 1) == "/" then
        -- Find null terminator
        local nullPos = data:find("\0")
        if nullPos then
            local address = data:sub(1, nullPos - 1)
            -- Skip to data section (aligned to 4 bytes)
            local dataStart = math.ceil(nullPos / 4) * 4 + 1
            -- Look for type tag
            local typeTag = data:sub(dataStart, dataStart)
            if typeTag == "," then
                local types = data:sub(dataStart + 1, dataStart + 1)
                if types == "f" then
                    -- Float value (4 bytes, big-endian)
                    local floatStart = math.ceil((dataStart + 3) / 4) * 4 + 1
                    if #data >= floatStart + 3 then
                        local b1, b2, b3, b4 = data:byte(floatStart, floatStart + 3)
                        -- Big-endian IEEE 754 float
                        local sign = (b1 >= 128) and -1 or 1
                        local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
                        local mant = ((b2 % 128) * 65536) + (b3 * 256) + b4
                        if exp == 0 then
                            return address, 0
                        elseif exp == 255 then
                            return address, sign * math.huge
                        else
                            return address, sign * math.ldexp(1 + mant / 8388608, exp - 127)
                        end
                    end
                elseif types == "i" then
                    -- Integer value (4 bytes, big-endian)
                    local intStart = math.ceil((dataStart + 3) / 4) * 4 + 1
                    if #data >= intStart + 3 then
                        local b1, b2, b3, b4 = data:byte(intStart, intStart + 3)
                        local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
                        -- Handle signed
                        if val >= 2147483648 then val = val - 4294967296 end
                        return address, val
                    end
                end
            end
            -- Fallback: try to find a number after the address
            local remaining = data:sub(nullPos + 1)
            local numStr = remaining:match("([%d%.%-]+)")
            if numStr then
                return address, tonumber(numStr)
            end
        end
    end

    return nil, nil
end

--------------------------------------------------------------------------------
-- UPDATE / GET
--------------------------------------------------------------------------------

--- Process all pending UDP messages
function OSC.update(osc)
    if not osc.udp then return end

    local count = 0
    while count < 100 do  -- Process up to 100 messages per frame
        local data, ip, port = osc.udp:receivefrom()
        if not data then break end
        local addr, val = OSC.parse(data)
        if addr and val then
            osc.values[addr] = val
        end
        count = count + 1
    end
end

--- Get value for an address
function OSC.get(osc, address, default)
    return osc.values[address] or default
end

--- Set value manually (for testing)
function OSC.set(osc, address, value)
    osc.values[address] = value
end

--- Get all current values
function OSC.getAll(osc)
    return osc.values
end

--- Close the UDP socket
function OSC.close(osc)
    if osc.udp then
        osc.udp:close()
        osc.udp = nil
    end
end

return OSC
