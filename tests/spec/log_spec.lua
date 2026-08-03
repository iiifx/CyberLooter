-- The log is the only channel back from the machine the game runs on, so what it
-- does and does not write is behaviour worth pinning down.

local Stub = require("tests/support/game.lua")

local function setup()
    local written = {}
    local clock = { now = 0.0 }

    local realOpen, realPrint, realClock = io.open, print, os.clock

    io.open = function(_, mode)
        if mode == "w" then
            written = {}
        end
        return {
            write = function(_, line)
                written[#written + 1] = line
            end,
            close = function() end,
        }
    end

    print = function() end
    os.clock = function()
        return clock.now
    end

    local Log = Stub.load("Modules/Log.lua")

    local function restore()
        io.open, print, os.clock = realOpen, realPrint, realClock
    end

    local function text()
        return table.concat(written, "")
    end

    return Log, { text = text, lines = function() return #written end, clock = clock, restore = restore }
end

-- pcall so a failing assertion still puts the real io.open back.
local function withLog(fn)
    local Log, harness = setup()
    local ok, err = pcall(fn, Log, harness)
    harness.restore()
    if not ok then
        error(err, 0)
    end
end

describe("Log levels", function()
    it("always writes info, warnings and errors", function()
        withLog(function(Log, harness)
            Log.SetEnabled(false)

            Log.Info("started")
            Log.Warn("careful")
            Log.Error("broken")

            eq(harness.lines(), 3)
            contains(harness.text(), "INFO  started")
            contains(harness.text(), "WARN  careful")
            contains(harness.text(), "ERROR broken")
        end)
    end)

    it("writes debug detail only while the switch is on", function()
        withLog(function(Log, harness)
            Log.SetEnabled(false)
            Log.Debug("noise")
            eq(harness.lines(), 0)

            Log.SetEnabled(true)
            Log.Debug("detail")
            eq(harness.lines(), 1)
        end)
    end)
end)

describe("Log.DebugThrottled", function()
    it("writes the first message and swallows repeats inside the window", function()
        withLog(function(Log, harness)
            Log.SetEnabled(true)

            Log.DebugThrottled("scan", 5.0, "first")
            Log.DebugThrottled("scan", 5.0, "second")

            eq(harness.lines(), 1)
        end)
    end)

    it("writes again once the window has passed", function()
        withLog(function(Log, harness)
            Log.SetEnabled(true)

            Log.DebugThrottled("scan", 5.0, "first")
            harness.clock.now = 6.0
            Log.DebugThrottled("scan", 5.0, "second")

            eq(harness.lines(), 2)
        end)
    end)

    it("throttles each key on its own clock", function()
        withLog(function(Log, harness)
            Log.SetEnabled(true)

            Log.DebugThrottled("scan", 5.0, "scan detail")
            Log.DebugThrottled("sweep", 5.0, "sweep detail")

            eq(harness.lines(), 2)
        end)
    end)

    it("stays silent while the switch is off, however long the window", function()
        withLog(function(Log, harness)
            Log.SetEnabled(false)
            Log.DebugThrottled("scan", 5.0, "detail")
            eq(harness.lines(), 0)
        end)
    end)
end)
