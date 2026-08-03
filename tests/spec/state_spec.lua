-- The gates, which are the only thing that can silence the whole mod.

local Stub = require("tests/support/game.lua")

local function setup()
    local world = Stub.install()
    local log = Stub.log()

    local State = Stub.load("Modules/State.lua")
    State.Init({ Log = log })

    return State, world, log
end

local function hub(choices, extra)
    local data = { choices = choices }
    for key, value in pairs(extra or {}) do
        data[key] = value
    end
    return data
end

describe("State.HasVanillaInteraction", function()
    it("sees no prompt when the blackboard is empty", function()
        local State, world = setup()
        world.setHub(nil)
        isFalse(State.HasVanillaInteraction())
    end)

    it("sees no prompt when the hub carries no choices", function()
        local State, world = setup()
        world.setHub(hub({}))
        isFalse(State.HasVanillaInteraction())
    end)

    it("sees a prompt when the hub has choices", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }))
        isTrue(State.HasVanillaInteraction())
    end)

    it("ignores a hub the game has marked inactive", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }, { active = false }))
        isFalse(State.HasVanillaInteraction())
    end)

    it("admits in the log when the blackboard cannot be read", function()
        local State, world, log = setup()
        world.blackboard.readable = false

        isFalse(State.HasVanillaInteraction(), "an unreadable guard must not disable the mod")
        isTrue(State.interactionCheckBroken)
        contains(log.text(), "guard is inactive")
    end)

    it("recovers quietly once the blackboard reads again", function()
        local State, world, log = setup()
        world.blackboard.readable = false
        State.HasVanillaInteraction()

        world.blackboard.readable = true
        world.setHub(nil)
        State.HasVanillaInteraction()

        isFalse(State.interactionCheckBroken)
        contains(log.text(), "guard is active again")
    end)
end)

describe("State's stale prompt valve", function()
    it("keeps believing an unchanged prompt for a while", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }, { id = 7 }))

        isTrue(State.HasVanillaInteraction())
        State.Tick(19.0)
        isTrue(State.HasVanillaInteraction(), "19 s is still a plausible prompt")
    end)

    it("stops believing a prompt that has not changed in 20 s", function()
        -- Nothing guarantees the game clears the hub. A leaked one used to leave
        -- the mod switched off until the save was reloaded.
        local State, world, log = setup()
        world.setHub(hub({ "Open" }, { id = 7 }))

        isTrue(State.HasVanillaInteraction())
        State.Tick(21.0)

        isFalse(State.HasVanillaInteraction())
        contains(log.text(), "leftover blackboard data")
    end)

    it("starts the clock again when the prompt actually changes", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }, { id = 7 }))
        isTrue(State.HasVanillaInteraction())

        State.Tick(19.0)
        world.setHub(hub({ "Take" }, { id = 8 }))
        isTrue(State.HasVanillaInteraction())

        State.Tick(5.0)
        isTrue(State.HasVanillaInteraction(), "this prompt has only been up for 5 s")
    end)

    it("forgets the timer while no prompt is up", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }, { id = 7 }))
        isTrue(State.HasVanillaInteraction())

        State.Tick(19.0)
        world.setHub(nil)
        isFalse(State.HasVanillaInteraction())

        world.setHub(hub({ "Open" }, { id = 7 }))
        State.Tick(5.0)
        isTrue(State.HasVanillaInteraction(), "the same prompt returning is a new prompt")
    end)
end)

describe("State.IsActionable", function()
    it("names the reason it is blocking", function()
        local State, world = setup()

        world.blackboard.isInMenu = true
        local actionable, reason = State.IsActionable(true)
        isFalse(actionable)
        eq(reason, "menu")

        world.blackboard.isInMenu = false
        world.photoMode = true
        actionable, reason = State.IsActionable(true)
        isFalse(actionable)
        eq(reason, "photo mode")

        world.photoMode = false
        world.setHub(hub({ "Open" }))
        actionable, reason = State.IsActionable(true)
        isFalse(actionable)
        eq(reason, "vanilla interaction")
    end)

    it("opens when nothing is in the way", function()
        local State, world = setup()
        world.setHub(nil)
        isTrue(State.IsActionable(true))
    end)

    it("ignores vanilla prompts when the player has turned that guard off", function()
        local State, world = setup()
        world.setHub(hub({ "Open" }))
        isTrue(State.IsActionable(false))
    end)

    it("blocks while there is no player", function()
        local State, world = setup()
        world.player = nil

        local actionable, reason = State.IsActionable(true)
        isFalse(actionable)
        eq(reason, "no player")
    end)
end)
