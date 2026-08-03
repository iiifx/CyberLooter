-- Diagnostic log. This is the primary feedback channel from the player's machine
-- back to development, since the game cannot be run where the mod is written.

local Log = {}

local LOG_FILE = "cyberlooter.log"
local PREFIX = "[CyberLooter] "

local _enabled = false
local _throttled = {}

function Log.SetEnabled(enabled)
    _enabled = enabled and true or false
end

function Log.IsEnabled()
    return _enabled
end

-- The CET sandbox does not guarantee the whole os library, so the timestamp
-- degrades to a session clock rather than taking the log down with it.
local function timestamp()
    local ok, stamp = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if ok and stamp ~= nil then
        return stamp
    end

    local clockOk, clock = pcall(os.clock)
    if clockOk and clock ~= nil then
        return string.format("t+%.1fs", clock)
    end

    return "?"
end

local function write(level, message)
    local line = string.format("[%s] %-5s %s", timestamp(), level, message)

    local ok, file = pcall(io.open, LOG_FILE, "a")
    if ok and file ~= nil then
        file:write(line .. "\n")
        file:close()
    end
end

-- Always written: startup banner, strategy resolution, failures.
function Log.Info(message)
    write("INFO", message)
    print(PREFIX .. message)
end

function Log.Warn(message)
    write("WARN", message)
    print(PREFIX .. "WARN: " .. message)
end

function Log.Error(message)
    write("ERROR", message)
    print(PREFIX .. "ERROR: " .. message)
end

-- Only written when the debug switch is on: per-scan and per-sweep detail.
function Log.Debug(message)
    if not _enabled then
        return
    end
    write("DEBUG", message)
end

-- Same message repeated at most once per `seconds`. Keeps per-frame paths from
-- flooding the file while still surfacing a persistent problem.
function Log.DebugThrottled(key, seconds, message)
    if not _enabled then
        return
    end

    local clockOk, now = pcall(os.clock)
    if not clockOk or now == nil then
        write("DEBUG", message)
        return
    end

    local last = _throttled[key]
    if last ~= nil and (now - last) < seconds then
        return
    end

    _throttled[key] = now
    write("DEBUG", message)
end

function Log.Reset()
    local ok, file = pcall(io.open, LOG_FILE, "w")
    if ok and file ~= nil then
        file:close()
    end
    _throttled = {}
end

return Log
