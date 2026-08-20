-- Opening the door in front of the player, and every reason not to.

local Stub = require("tests/support/game.lua")

local function setup(configOverrides)
    local world = Stub.install()
    local log = Stub.log()

    local overrides = { autoOpenDoors = true, autoOpenDoorDistance = 3.0 }
    for key, value in pairs(configOverrides or {}) do
        overrides[key] = value
    end
    local config = Stub.config(overrides)

    local State = Stub.load("Modules/State.lua")
    State.Init({ Log = log })

    local Doors = Stub.load("Modules/Doors.lua")
    Doors.Init({ Log = log, Config = config, State = State })

    return Doors, world, log, config, State
end

-- One tick past the check interval, which is what a spec almost always wants.
local TICK = 0.25

local function face(world, spec)
    local door = Stub.door(spec)
    world.lookAt = door
    return door
end

describe("Doors.Tick", function()
    it("does nothing at all while the option is off", function()
        local Doors, world = setup({ autoOpenDoors = false })
        face(world, {})

        isFalse(Doors.Tick(10.0))
        eq(#world.doorEvents, 0)
        eq(Doors.lastReason, "off")
    end)

    it("opens the closed door the player is looking at", function()
        local Doors, world = setup()
        local door = face(world, {})

        isTrue(Doors.Tick(TICK))
        eq(#world.doorEvents, 1)
        eq(Doors.lastReason, "opened a door")

        -- The game fills both of these in when it queues the same action itself,
        -- and the door's own handler reads the executor back out.
        local action = world.doorEvents[1]
        isTrue(action.__toggleOpen)
        eq(action.executor, world.player)
        eq(action.requester.hash, door.__hash)
    end)

    it("waits for its own interval rather than running every frame", function()
        local Doors, world = setup()
        face(world, {})

        isFalse(Doors.Tick(0.1))
        eq(#world.doorEvents, 0)

        isTrue(Doors.Tick(0.15))
    end)

    it("stays quiet in combat", function()
        local Doors, world = setup()
        face(world, {})
        world.inCombat = true

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "in combat")
        eq(#world.doorEvents, 0)
    end)

    it("treats stealth as out of combat", function()
        -- gamePSMCombat.Stealth is its own state, not a combat one, and a player
        -- sneaking about is exactly who needs the door opened for them.
        local Doors, world = setup()
        face(world, {})
        world.psmCombat = 3

        isTrue(Doors.Tick(TICK))
    end)

    it("keeps quiet when neither combat signal can be read", function()
        local Doors, world, log, _, State = setup()
        face(world, {})
        world.combatApiBroken = true
        world.psmCombatBroken = true

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "in combat")
        isTrue(State.combatCheckBroken)
        contains(log.text(), "cannot tell whether the player is in combat")
    end)

    it("still works when only the blackboard answers", function()
        local Doors, world, _, _, State = setup()
        face(world, {})
        world.combatApiBroken = true

        isTrue(Doors.Tick(TICK))
        isFalse(State.combatCheckBroken)
    end)

    it("leaves locked and sealed doors alone", function()
        for _, case in ipairs({
            { spec = { locked = true }, reason = "door is locked" },
            { spec = { sealed = true }, reason = "door is sealed" },
        }) do
            local Doors, world = setup()
            face(world, case.spec)

            isFalse(Doors.Tick(TICK), case.reason)
            eq(Doors.lastReason, case.reason)
            eq(#world.doorEvents, 0)
        end
    end)

    it("never closes a door that is already open", function()
        -- ToggleOpen is a toggle, so a wrong answer here is the one destructive
        -- thing this feature could do.
        local Doors, world = setup()
        face(world, { closed = false })

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "door is not closed")
        eq(#world.doorEvents, 0)
    end)

    it("refuses to act when the states it must be sure of are unreadable", function()
        for _, key in ipairs({ "closed", "locked", "sealed" }) do
            local Doors, world = setup()
            face(world, { unreadable = { [key] = true } })

            isFalse(Doors.Tick(TICK), key)
            eq(Doors.lastReason, key .. " state unreadable")
        end
    end)

    it("still opens when only the advisory states are unreadable", function()
        -- None of these can make the action unsafe: at worst the game refuses it.
        local Doors, world = setup()
        face(world, {
            unreadable = {
                disabled = true, unpowered = true, secured = true,
                lift = true, skillcheck = true, on = true, doortype = true,
            },
        })

        isTrue(Doors.Tick(TICK))
    end)

    it("leaves the doors that are somebody else's business", function()
        for _, case in ipairs({
            { spec = { disabled = true }, reason = "door is disabled" },
            { spec = { unpowered = true }, reason = "door is unpowered" },
            { spec = { secured = true }, reason = "door is secured" },
            { spec = { lift = true }, reason = "door is lift" },
            { spec = { skillCheck = true }, reason = "door is skillcheck" },
            { spec = { off = true }, reason = "door is off" },
        }) do
            local Doors, world = setup()
            face(world, case.spec)

            isFalse(Doors.Tick(TICK), case.reason)
            eq(Doors.lastReason, case.reason)
            eq(#world.doorEvents, 0)
        end
    end)

    it("skips doors that open themselves or answer to a terminal", function()
        for _, doorType in ipairs({ EDoorType.AUTOMATIC, EDoorType.REMOTELY_CONTROLLED }) do
            local Doors, world = setup()
            face(world, { doorType = doorType })

            isFalse(Doors.Tick(TICK), tostring(doorType))
            eq(Doors.lastReason, "door opens on its own or is remotely controlled")
        end
    end)

    it("opens an ordinary physical door", function()
        local Doors, world = setup()
        face(world, { doorType = EDoorType.PHYSICAL })

        isTrue(Doors.Tick(TICK))
    end)

    it("ignores anything that is not a door", function()
        local Doors, world = setup()
        world.lookAt = Stub.container({ items = { Stub.item({}) } })

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "not looking at a door")
    end)

    it("ignores blinds and wall screens, which are doors only by inheritance", function()
        for _, class in ipairs({ "Window", "MovableWallScreen" }) do
            local Doors, world = setup()
            face(world, { class = class })

            isFalse(Doors.Tick(TICK), class)
            eq(Doors.lastReason, "not looking at a door")
            eq(#world.doorEvents, 0)
        end
    end)

    it("ignores a door across the street", function()
        local Doors, world = setup({ autoOpenDoorDistance = 3.0 })
        face(world, { pos = { x = 12.0, y = 0.0, z = 0.0 } })

        isFalse(Doors.Tick(TICK))
        contains(Doors.lastReason, "away")
    end)

    it("opens nothing when the player is not looking at anything", function()
        local Doors, world = setup()
        world.lookAt = nil

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "not looking at a door")
    end)

    it("survives a look-at query that is not answering", function()
        local Doors, world, log = setup()
        world.lookAtFails = true

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "not looking at a door")
        contains(log.text(), "look-at query failed")
    end)

    it("does not open the same door twice while the player stands there", function()
        local Doors, world = setup()
        face(world, {})

        isTrue(Doors.Tick(TICK))
        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "already opened this door")
        eq(#world.doorEvents, 1)
    end)

    it("opens a different door standing right next to the first", function()
        local Doors, world = setup()
        face(world, {})
        isTrue(Doors.Tick(TICK))

        face(world, {})
        isTrue(Doors.Tick(TICK))
        eq(#world.doorEvents, 2)
    end)

    it("is willing to open the same door again later", function()
        -- Doors that close themselves are common; the cooldown is a guard against
        -- fighting the game, not a one-shot per session.
        local Doors, world = setup()
        local door = face(world, {})
        isTrue(Doors.Tick(TICK))

        world.lookAt = door
        isTrue(Doors.Tick(30.0))
        eq(#world.doorEvents, 2)
    end)

    it("stays out of menus, photo mode and vehicles", function()
        for _, case in ipairs({
            { apply = function(world) world.blackboard.isInMenu = true end, reason = "menu" },
            { apply = function(world) world.photoMode = true end, reason = "photo mode" },
            { apply = function(world) world.mounted = true end, reason = "in a vehicle" },
        }) do
            local Doors, world = setup()
            face(world, {})
            case.apply(world)

            isFalse(Doors.Tick(TICK), case.reason)
            eq(Doors.lastReason, case.reason)
        end
    end)

    it("acts despite the vanilla prompt being up, because it always is", function()
        local Doors, world = setup()
        face(world, {})
        world.setHub({ choices = { "Open" } })

        isTrue(Doors.Tick(TICK))
    end)

    it("reports a door whose state object is missing instead of throwing", function()
        local Doors, world, log = setup()
        face(world, { noPS = true })

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "door state unavailable")
        contains(log.text(), "GetDevicePS failed")
    end)

    it("survives a refused device event and remembers nothing", function()
        local Doors, world, log = setup()
        face(world, { queueFails = true })

        isFalse(Doors.Tick(TICK))
        eq(Doors.lastReason, "opening failed")
        contains(log.text(), "could not open the door")

        -- A failed attempt must not put the door on the cooldown list, or one
        -- transient error would lock it out for the next ten seconds.
        world.lookAt.__queueFails = false
        isTrue(Doors.Tick(TICK))
        eq(#world.doorEvents, 1)
    end)

    it("forgets its timer when the option is switched off and on", function()
        local Doors, world, _, config = setup()
        face(world, {})
        Doors.Tick(0.15)

        config.values.autoOpenDoors = false
        Doors.Tick(1.0)
        config.values.autoOpenDoors = true

        isFalse(Doors.Tick(0.1), "the previous partial interval must not carry over")
        isTrue(Doors.Tick(0.15))
    end)
end)
