-- Hands-free looting: the same sweep, started by a timer instead of a key.

local Stub = require("tests/support/game.lua")

local function setup(configOverrides)
    local world = Stub.install()
    local log = Stub.log()

    local overrides = { autoLoot = true, autoLootInterval = 0.5 }
    for key, value in pairs(configOverrides or {}) do
        overrides[key] = value
    end
    local config = Stub.config(overrides)

    local State = Stub.load("Modules/State.lua")
    State.Init({ Log = log })

    local Scanner = Stub.load("Modules/Scanner.lua")
    Scanner.Init({ Log = log, Config = config, State = State })

    local Looter = Stub.load("Modules/Looter.lua")
    Looter.Init({ Log = log, Config = config, Scanner = Scanner, State = State })

    local Auto = Stub.load("Modules/Auto.lua")
    Auto.Init({ Log = log, Config = config, State = State, Scanner = Scanner, Looter = Looter })

    return Auto, world, log, config
end

local function loot(world, name)
    world.targeting = { Stub.container({ items = { Stub.item({ name = name or "eddies" }) } }) }
end

describe("Auto.Tick", function()
    it("does nothing at all while the option is off", function()
        local Auto, world = setup({ autoLoot = false })
        loot(world)

        isFalse(Auto.Tick(10.0))
        eq(#world.player.__items, 0)
        eq(Auto.lastReason, "off")
    end)

    it("waits for the interval before the first sweep", function()
        local Auto, world = setup({ autoLootInterval = 0.5 })
        loot(world)

        isFalse(Auto.Tick(0.3))
        eq(#world.player.__items, 0)

        isTrue(Auto.Tick(0.3))
        eq(#world.player.__items, 1)
    end)

    it("keeps sweeping as loot keeps appearing", function()
        local Auto, world = setup()
        loot(world, "first")
        isTrue(Auto.Tick(0.5))

        loot(world, "second")
        isTrue(Auto.Tick(0.5))

        eq(#world.player.__items, 2)
    end)

    it("costs nothing but a scan when the radius is empty", function()
        local Auto, world = setup()
        world.targeting = {}

        isFalse(Auto.Tick(0.5))
        eq(Auto.lastReason, "nothing in radius")
    end)

    it("stays out of menus", function()
        local Auto, world = setup()
        loot(world)
        world.blackboard.isInMenu = true

        isFalse(Auto.Tick(0.5))
        eq(Auto.lastReason, "menu")
        eq(#world.player.__items, 0)
    end)

    it("ignores the vanilla prompt gate", function()
        -- Looking at loot is what puts a prompt on screen, so honouring that gate
        -- would switch automatic looting off exactly when it is wanted. There is
        -- no key to conflict with here.
        local Auto, world = setup()
        loot(world)
        world.setHub({ choices = { "Take" } })

        isTrue(Auto.Tick(0.5))
        eq(#world.player.__items, 1)
    end)

    it("leaves the roadside alone while driving", function()
        local Auto, world = setup({ autoLootInVehicle = false })
        loot(world)
        world.mounted = true

        isFalse(Auto.Tick(0.5))
        eq(Auto.lastReason, "in a vehicle")
    end)

    it("loots from the car when the player asks for that", function()
        local Auto, world = setup({ autoLootInVehicle = true })
        loot(world)
        world.mounted = true

        isTrue(Auto.Tick(0.5))
    end)

    it("backs off when a sweep collects nothing it was promised", function()
        -- Otherwise an object that cannot be emptied is retried twice a second
        -- for as long as the player stands near it.
        local Auto, world, log = setup()
        world.targeting = {
            Stub.container({
                items = { Stub.item({ name = "eddies" }) },
                transferAllNoop = true,
                transferItemFails = true,
            }),
        }

        isFalse(Auto.Tick(0.5))
        eq(Auto.lastReason, "sweep collected nothing, pausing")
        contains(log.text(), "pausing")

        -- Still quiet a second later, working again after the backoff.
        isFalse(Auto.Tick(1.0))
        eq(Auto.lastReason, "backing off")

        world.targeting = {}
        isFalse(Auto.Tick(2.5))
        isFalse(Auto.Tick(0.5))
        eq(Auto.lastReason, "nothing in radius")
    end)

    it("refuses an interval too short to be sane", function()
        local Auto, world = setup({ autoLootInterval = 0.0 })
        loot(world)

        isFalse(Auto.Tick(0.05))
        isTrue(Auto.Tick(0.05))
    end)

    it("forgets its timer when the option is switched off and on", function()
        local Auto, world, _, config = setup()
        loot(world)
        Auto.Tick(0.4)

        config.values.autoLoot = false
        Auto.Tick(1.0)
        config.values.autoLoot = true

        isFalse(Auto.Tick(0.3), "the previous partial interval must not carry over")
        isTrue(Auto.Tick(0.3))
    end)
end)
