-- The inventory dump and the cleanup, which exist because the backpack UI does
-- not show everything the inventory actually holds.

local Stub = require("tests/support/game.lua")

local function setup()
    local world = Stub.install()
    local log = Stub.log()
    local State = { GetPlayer = function() return world.player end }

    local Scanner = Stub.load("Modules/Scanner.lua")
    Scanner.Init({ Log = log, Config = Stub.config(), State = State })

    local Audit = Stub.load("Modules/Audit.lua")
    Audit.Init({ Log = log, State = State, Scanner = Scanner })

    return Audit, world, log
end

describe("Audit.DumpInventory", function()
    it("writes one line per item plus a summary", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "pistol", weight = 3.0 }),
            Stub.item({ name = "shard", weight = 0.0 }),
        }

        eq(Audit.DumpInventory(), 2)
        contains(log.text(), "inventory dump: 2 entries")
        contains(log.text(), "Items.pistol")
        contains(log.text(), "Items.shard")
    end)

    it("multiplies weight by the size of the stack", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.item({ name = "ammo", weight = 0.5, quantity = 10 }) }

        Audit.DumpInventory()
        contains(log.text(), "5.0 known weight")
    end)

    it("reports the carry capacity next to the weight", function()
        local Audit, world, log = setup()
        world.carryCapacity = 200.0
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        contains(log.text(), "carry capacity 200")
    end)

    it("records what the game says an item is, so a real filter can be built", function()
        -- Nothing decides anything on these today. They are in the dump because
        -- an item the backpack refuses to draw is classified as something,
        -- somewhere, and guessing which field is what cost a day already.
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({
                name = "pistol",
                weight = 3.0,
                equipArea = "EquipmentArea.Weapon",
                itemType = "ItemType.Wea_Handgun",
                category = "ItemCategory.Weapon",
                recordTags = { "Weapon", "SaveableItem" },
            }),
        }

        Audit.DumpInventory()
        contains(log.text(), "area=EquipmentArea.Weapon")
        contains(log.text(), "type=ItemType.Wea_Handgun")
        contains(log.text(), "cat=ItemCategory.Weapon")
        contains(log.text(), "tags=Weapon+SaveableItem")
    end)

    it("flags both kinds of stuck item", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "shard", weight = 0.0 }),
            Stub.heavyWeapon({ weight = 11.0 }),
            Stub.vehicleWeapon({}),
        }

        Audit.DumpInventory()
        contains(log.text(), "2 entries (22.5 weight) do not belong in a backpack")
    end)

    it("says nothing alarming when the inventory is clean", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        isNil(log.find("do not belong in a backpack"))
    end)

    it("lists the heaviest item first", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "feather", weight = 0.1 }),
            Stub.item({ name = "anvil", weight = 40.0 }),
        }

        Audit.DumpInventory()
        local text = log.text()
        isTrue(text:find("Items.anvil", 1, true) < text:find("Items.feather", 1, true),
            "the thing eating the carry limit should be the first thing read")
    end)

    it("reports an unknown weight as unknown rather than as zero", function()
        -- Zero is the exact claim under suspicion, so it must never be invented.
        local Audit, world, log = setup()
        world.noItemWeightApi = true
        world.player.__items = { Stub.item({ name = "mystery" }) }

        Audit.DumpInventory()
        contains(log.text(), "1 entries of unknown weight")
        contains(log.text(), "?")
    end)

    it("falls back to the item stat when the weight helper is missing", function()
        local Audit, world, log = setup()
        world.noItemWeightApi = true
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        contains(log.text(), "3.0 known weight")
    end)

    it("says so instead of throwing when there is no player", function()
        local Audit, world, log = setup()
        world.player = nil

        eq(Audit.DumpInventory(), 0)
        contains(log.text(), "no player")
    end)
end)

describe("Audit.FindStuckItems", function()
    it("finds nothing in an ordinary inventory", function()
        local Audit, world = setup()
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        local stuck, weight = Audit.FindStuckItems()
        eq(#stuck, 0)
        eq(weight, 0.0)
    end)

    it("finds vehicle weapons and heavy weapons, and adds up their weight", function()
        local Audit, world = setup()
        world.player.__items = {
            Stub.vehicleWeapon({}),
            Stub.vehicleWeapon({ name = "Items.Vehicle_Power_Weapon_Right_A" }),
            Stub.heavyWeapon({ weight = 11.0 }),
            Stub.item({ name = "pistol", weight = 3.0 }),
        }

        local stuck, weight = Audit.FindStuckItems()
        eq(#stuck, 3)
        eq(weight, 34.0)
    end)

    it("never counts installed cyberware, whatever it is tagged with", function()
        local Audit, world = setup()
        world.player.__items = {
            Stub.item({ name = "Items.AdvancedBioConductorsUncommon",
                equipArea = "EquipmentArea.FrontalCortexCW", tags = { "HideInBackpackUI" } }),
            Stub.item({ name = "Items.AdvancedSmartLinkUncommonPlus",
                equipArea = "EquipmentArea.HandsCW" }),
        }

        eq(#Audit.FindStuckItems(), 0)
        eq(Audit.RemoveStuckItems(), 0)
        eq(#world.player.__items, 2)
    end)

    it("never counts the weapon in the player's hands", function()
        local Audit, world = setup()
        world.player.__items = { Stub.heavyWeapon({ weight = 11.0, equipped = true }) }

        eq(#Audit.FindStuckItems(), 0)
    end)
end)

describe("Audit.RemoveStuckItems", function()
    it("deletes exactly the stuck entries and leaves everything else", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.vehicleWeapon({}),
            Stub.item({ name = "pistol", weight = 3.0 }),
            Stub.heavyWeapon({ weight = 11.0 }),
        }

        local removed, freed = Audit.RemoveStuckItems()
        eq(removed, 2)
        eq(freed, 22.5)
        eq(#world.player.__items, 1)
        eq(world.player.__items[1].__id.value, "pistol")
    end)

    it("names every item it deletes", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.vehicleWeapon({}) }

        Audit.RemoveStuckItems()
        contains(log.text(), "removed Items.Vehicle_Power_Weapon_Left_A x1")
    end)

    it("does nothing when there is nothing stuck", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        eq(Audit.RemoveStuckItems(), 0)
        contains(log.text(), "nothing to remove")
        eq(#world.player.__items, 1)
    end)

    it("reports a removal the game refuses instead of counting it", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.vehicleWeapon({}) }
        world.removeFails = true

        local removed = Audit.RemoveStuckItems()
        eq(removed, 0)
        contains(log.text(), "could not remove")
    end)

    it("recomputes rather than trusting a stale preview", function()
        -- The preview is cached for the settings window; deleting from a cache
        -- built before the inventory changed would delete the wrong things.
        local Audit, world = setup()
        world.player.__items = { Stub.vehicleWeapon({}) }
        eq(#Audit.FindStuckItems(), 1)

        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }
        eq(Audit.RemoveStuckItems(), 0)
        eq(#world.player.__items, 1)
    end)
end)
