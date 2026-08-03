-- What the mod is willing to take, and what it is able to find.

local Stub = require("tests/support/game.lua")

local function setup(configOverrides)
    local world = Stub.install()
    local log = Stub.log()
    local config = Stub.config(configOverrides)

    local Scanner = Stub.load("Modules/Scanner.lua")
    Scanner.Init({ Log = log, Config = config, State = { GetPlayer = function() return world.player end } })

    return Scanner, world, log, config
end

describe("Scanner.IsRestrictedItem", function()
    it("leaves ordinary items alone", function()
        local Scanner = setup()
        isFalse(Scanner.IsRestrictedItem(Stub.item({ name = "pistol", equipArea = "EquipmentArea.Weapon" })))
    end)

    it("refuses a weapon that equips into the WeaponHeavy area", function()
        local Scanner = setup()
        isTrue(Scanner.IsRestrictedItem(Stub.heavyWeapon({ tags = {} })))
    end)

    it("refuses a weapon tagged DiscardOnEmpty even without a record", function()
        local Scanner = setup()
        local item = Stub.item({ name = "borrowed_gun", tags = { "DiscardOnEmpty" }, recordMissing = true })
        isTrue(Scanner.IsRestrictedItem(item))
    end)

    it("asks for the record with the ItemID, not the TweakDBID inside it", function()
        -- The stub rejects a TweakDBID the way the engine does. This is the exact
        -- call that threw on every item in 0.2.3 and silenced the mod.
        local Scanner, _, log = setup()
        Scanner.IsRestrictedItem(Stub.heavyWeapon({ tags = {} }))
        isNil(log.find("must be gameItemID"), "the record lookup rejected its own argument")
    end)

    it("treats an unanswerable item as allowed rather than forbidden", function()
        -- Failing the other way turns one unavailable API into a dead mod: every
        -- item restricted, every object empty, nothing to loot anywhere.
        local Scanner = setup()
        local item = Stub.item({ name = "mystery", recordMissing = true, brokenTags = true })
        isFalse(Scanner.IsRestrictedItem(item))
    end)

    it("says so in the log when it cannot judge an item at all", function()
        local Scanner, _, log = setup()
        Scanner.IsRestrictedItem(Stub.item({ name = "mystery", recordMissing = true, brokenTags = true }))
        contains(log.text(), "heavy weapons will not be filtered")
        isFalse(Scanner.restrictedCheckAnswered)
    end)

    it("reports the filter as working once any item has been judged", function()
        local Scanner = setup()
        Scanner.IsRestrictedItem(Stub.item({ name = "pistol", equipArea = "EquipmentArea.Weapon" }))
        isTrue(Scanner.restrictedCheckAnswered)
    end)
end)

describe("Scanner.Get", function()
    it("finds a corpse the general query can still see", function()
        local Scanner, world = setup()
        world.targeting = { Stub.corpse({ items = { Stub.item({ name = "eddies" }) } }) }

        local objects, stacks = Scanner.Get()
        eq(#objects, 1)
        eq(stacks, 1)
    end)

    it("finds a corpse only the dead-filtered query returns", function()
        -- The engine drops dead NPCs from the general query, which is what made
        -- the mod blind straight after a fight until a save and reload.
        local Scanner, world = setup()
        world.targeting = {}
        world.corpses = { Stub.corpse({ items = { Stub.item({ name = "eddies" }) } }) }

        local objects = Scanner.Get()
        eq(#objects, 1)
    end)

    it("never empties a living NPC", function()
        local Scanner, world = setup()
        world.targeting = { Stub.livingNpc({ items = { Stub.item({ name = "eddies" }) } }) }

        local objects = Scanner.Get()
        eq(#objects, 0)
    end)

    it("follows a world item to the drop that holds its inventory", function()
        local Scanner, world = setup()
        local visual = Stub.worldItem({ items = { Stub.item({ name = "shard" }) } })
        world.targeting = { visual }

        local objects = Scanner.Get()
        eq(#objects, 1, "the visual object holds nothing; the drop is the holder")
    end)

    it("counts an object once when several sources return it", function()
        local Scanner, world = setup()
        local corpse = Stub.corpse({ items = { Stub.item({ name = "eddies" }) } })
        world.place(corpse)
        world.targeting = { corpse }
        world.corpses = { corpse }

        local objects, stacks = Scanner.Get()
        eq(#objects, 1)
        eq(stacks, 1)
    end)

    it("ignores anything beyond the radius", function()
        local Scanner, world = setup({ radius = 5.0 })
        world.targeting = {
            Stub.corpse({ items = { Stub.item({ name = "near" }) }, pos = { x = 3.0, y = 0.0, z = 0.0 } }),
            Stub.corpse({ items = { Stub.item({ name = "far" }) }, pos = { x = 9.0, y = 0.0, z = 0.0 } }),
        }

        local objects = Scanner.Get()
        eq(#objects, 1)
    end)

    it("returns the nearest object first", function()
        local Scanner, world = setup()
        world.targeting = {
            Stub.container({ items = { Stub.item({ name = "far" }) }, pos = { x = 4.0, y = 0.0, z = 0.0 } }),
            Stub.container({ items = { Stub.item({ name = "near" }) }, pos = { x = 1.0, y = 0.0, z = 0.0 } }),
        }

        local objects = Scanner.Get()
        eq(#objects, 2)
        isTrue(objects[1].distance < objects[2].distance)
    end)

    it("skips an object that holds nothing but a hand-carried weapon", function()
        local Scanner, world = setup()
        world.targeting = { Stub.container({ items = { Stub.heavyWeapon({}) } }) }

        local objects, stacks = Scanner.Get()
        eq(#objects, 0)
        eq(stacks, 0)
    end)

    it("offers the rest of a mixed object and marks it for item-by-item transfer", function()
        local Scanner, world = setup()
        world.targeting = {
            Stub.container({ items = { Stub.heavyWeapon({}), Stub.item({ name = "eddies" }) } }),
        }

        local objects, stacks = Scanner.Get()
        eq(#objects, 1)
        eq(stacks, 1, "the weapon is not on offer")
        isTrue(objects[1].restricted)
    end)

    it("leaves quest loot alone while the setting is on", function()
        local Scanner, world = setup({ skipQuestItems = true })
        world.targeting = { Stub.container({ items = { Stub.item({ name = "evidence", quest = true }) } }) }

        eq(#Scanner.Get(), 0)
    end)

    it("takes quest loot once the setting is off", function()
        local Scanner, world = setup({ skipQuestItems = false })
        world.targeting = { Stub.container({ items = { Stub.item({ name = "evidence", quest = true }) } }) }

        eq(#Scanner.Get(), 1)
    end)

    it("keeps going when one source throws", function()
        local Scanner, world = setup()
        world.targetingFails = true

        local objects = Scanner.Get()
        eq(#objects, 0, "a failing world query must not take the scan down")
    end)

    it("serves a cached answer within the cache window and a fresh one after it", function()
        local Scanner, world = setup()
        world.targeting = { Stub.container({ items = { Stub.item({ name = "eddies" }) } }) }
        eq(#Scanner.Get(), 1)

        world.targeting = {}
        eq(#Scanner.Get(), 1, "still inside the cache window")

        Scanner.Tick(1.0)
        eq(#Scanner.Get(), 0)
    end)

    it("re-scans immediately after a sweep invalidates the cache", function()
        local Scanner, world = setup()
        world.targeting = { Stub.container({ items = { Stub.item({ name = "eddies" }) } }) }
        eq(#Scanner.Get(), 1)

        world.targeting = {}
        Scanner.Invalidate()
        eq(#Scanner.Get(), 0)
    end)
end)
