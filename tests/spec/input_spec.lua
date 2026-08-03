-- The hold, and the binding the indicator depends on.

local Stub = require("tests/support/game.lua")

local function setup(options)
    options = options or {}

    local log = Stub.log()
    local config = Stub.config({ holdTime = 0.35 })

    local swept = { count = 0 }
    local gate = { actionable = options.actionable ~= false, reason = options.reason }

    local bindings = { bound = options.bound ~= false }

    local callback = nil
    _G.registerInput = function(_, _, fn)
        callback = fn
    end
    _G.IsBound = function()
        return bindings.bound
    end
    _G.GetBind = function()
        return "F"
    end

    local Input = Stub.load("Modules/Input.lua")
    Input.Init({
        Log = log,
        Config = config,
        State = {
            IsActionable = function()
                return gate.actionable, gate.reason
            end,
        },
        onSweep = function()
            swept.count = swept.count + 1
        end,
    })

    return Input, {
        press = function() callback(true) end,
        release = function() callback(false) end,
        swept = swept,
        gate = gate,
        bindings = bindings,
        log = log,
    }
end

describe("Input hold handling", function()
    it("does nothing before the hold threshold", function()
        local Input, harness = setup()
        harness.press()
        Input.Tick(0.2)
        eq(harness.swept.count, 0)
    end)

    it("sweeps once the key has been held long enough", function()
        local Input, harness = setup()
        harness.press()
        Input.Tick(0.4)
        eq(harness.swept.count, 1)
    end)

    it("sweeps once per hold, however long the key stays down", function()
        local Input, harness = setup()
        harness.press()
        Input.Tick(0.4)
        Input.Tick(5.0)
        eq(harness.swept.count, 1)
    end)

    it("sweeps again after the key is released and pressed once more", function()
        local Input, harness = setup()
        harness.press()
        Input.Tick(0.4)
        harness.release()
        harness.press()
        Input.Tick(0.4)
        eq(harness.swept.count, 2)
    end)

    it("keeps a blocked hold armed instead of burning it", function()
        -- Starting the hold during a vanilla prompt must not cost the player a
        -- second press; the sweep fires the moment the prompt goes away.
        local Input, harness = setup({ actionable = false, reason = "vanilla interaction" })
        harness.press()
        Input.Tick(0.4)
        eq(harness.swept.count, 0)

        harness.gate.actionable = true
        Input.Tick(0.1)
        eq(harness.swept.count, 1)
    end)

    it("survives a sweep that throws", function()
        local log = Stub.log()
        _G.registerInput = function(_, _, fn) _G.__callback = fn end
        _G.IsBound = function() return true end
        _G.GetBind = function() return "F" end

        local Input = Stub.load("Modules/Input.lua")
        Input.Init({
            Log = log,
            Config = Stub.config({ holdTime = 0.35 }),
            State = { IsActionable = function() return true end },
            onSweep = function() error("boom") end,
        })

        _G.__callback(true)
        Input.Tick(0.4)

        contains(log.text(), "sweep failed")
    end)
end)

describe("Input.IsBound", function()
    it("is false until a key has been assigned", function()
        local Input = setup({ bound = false })
        isFalse(Input.IsBound())
    end)

    it("keeps trusting a binding CET has once confirmed", function()
        -- The sweep runs off the input callback, not off this answer, so a
        -- momentary "not bound" must not blank the indicator for the session.
        local Input, harness = setup({ bound = true })
        isTrue(Input.IsBound())

        harness.bindings.bound = false
        isTrue(Input.IsBound())
    end)

    it("survives CET withdrawing the function entirely", function()
        local Input = setup({ bound = false })
        _G.IsBound = nil
        isFalse(Input.IsBound())
    end)
end)
