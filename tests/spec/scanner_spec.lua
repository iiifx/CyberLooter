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

    it("refuses a weapon that belongs to a vehicle", function()
        -- These carry the ordinary Weapon equip area, so nothing in the record
        -- marks them as unusable; the record path is the only signal there is.
        local Scanner = setup()
        isTrue(Scanner.IsRestrictedItem(Stub.vehicleWeapon({})))
        isTrue(Scanner.IsRestrictedItem(Stub.vehicleWeapon({ name = "Items.Vehicle_Power_Weapon_Right_A" })))
    end)

    it("does not mistake an ordinary weapon for vehicle hardware", function()
        local Scanner = setup()
        isFalse(Scanner.IsRestrictedItem(Stub.item({
            name = "Items.Preset_Lexington_Default",
            equipArea = "EquipmentArea.Weapon",
        })))
    end)

    it("refuses anything the game's own inventory filter hides", function()
        -- UIInventoryItemsManager.GetBlacklistedTags(): an item carrying one of
        -- these never enters the player's item map at all, so it cannot be seen,
        -- equipped, sold or dropped - only carried.
        local Scanner = setup()
        for _, tag in ipairs({ "HideInUI", "TppHead", "base_fists" }) do
            isTrue(Scanner.IsRestrictedItem(Stub.item({ name = "hidden_" .. tag, tags = { tag } })),
                tag .. " should be refused")
        end
    end)

    it("still takes cyberware, which is hidden from the backpack but not from the game", function()
        -- HideInBackpackUI means "this screen is not where this item lives", not
        -- "this item is junk". Reading it as junk classified every implant in the
        -- player's body as garbage and the cleanup tool deleted them.
        local Scanner = setup()
        isFalse(Scanner.IsRestrictedItem(Stub.item({
            name = "Items.AdvancedBioConductorsUncommon",
            tags = { "HideInBackpackUI" },
            equipArea = "EquipmentArea.FrontalCortexCW",
        })))
    end)

    it("still takes money and ammo, which are hidden for a different reason", function()
        -- Currency and Ammo are on the same blacklist, but they are hidden
        -- because they have their own counters, not because they are junk.
        local Scanner = setup()
        isFalse(Scanner.IsRestrictedItem(Stub.item({ name = "money", tags = { "Currency" } })))
        isFalse(Scanner.IsRestrictedItem(Stub.item({ name = "rounds", tags = { "Ammo" } })))
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

    it("does not cache a verdict that no probe could answer", function()
        -- One transient API failure must not whitelist an item type for the rest
        -- of the session.
        local Scanner = setup()
        local broken = Stub.item({ name = "Items.flaky", recordMissing = true, brokenTags = true })
        isFalse(Scanner.IsRestrictedItem(broken))

        -- Same record path, now answerable and genuinely restricted.
        local working = Stub.heavyWeapon({ name = "Items.flaky", tags = {} })
        isTrue(Scanner.IsRestrictedItem(working), "the shrug must not have been cached")
    end)

    it("reports the filter as working once any item has been judged", function()
        local Scanner = setup()
        Scanner.IsRestrictedItem(Stub.item({ name = "pistol", equipArea = "EquipmentArea.Weapon" }))
        isTrue(Scanner.restrictedCheckAnswered)
    end)
end)

describe("Scanner.IsStuckInInventory", function()
    -- This one decides what a destructive button deletes, so its job is to say
    -- no. Everything it is unsure about stays in the inventory.

    it("recognises a hand-carried weapon that ended up in the backpack", function()
        local Scanner = setup()
        isTrue(Scanner.IsStuckInInventory(Stub.heavyWeapon({})))
    end)

    it("recognises a vehicle weapon", function()
        local Scanner = setup()
        isTrue(Scanner.IsStuckInInventory(Stub.vehicleWeapon({})))
    end)

    it("never touches cyberware", function()
        local Scanner = setup()
        for _, area in ipairs({ "FrontalCortexCW", "HandsCW", "LegsCW", "SystemReplacementCW" }) do
            isFalse(Scanner.IsStuckInInventory(Stub.item({
                name = "implant_" .. area,
                equipArea = "EquipmentArea." .. area,
                tags = { "HideInBackpackUI" },
            })), area .. " must survive")
        end
    end)

    it("never touches quest items", function()
        local Scanner = setup()
        isFalse(Scanner.IsStuckInInventory(Stub.item({ name = "evidence", quest = true })))
    end)

    it("never touches ordinary gear", function()
        local Scanner = setup()
        isFalse(Scanner.IsStuckInInventory(Stub.item({
            name = "Items.Preset_Lexington_Default",
            equipArea = "EquipmentArea.Weapon",
        })))
        isFalse(Scanner.IsStuckInInventory(Stub.item({ name = "Items.Jacket_05_old_01" })))
    end)

    it("is narrower than the loot filter, not equal to it", function()
        -- An item the mod declines to pick up is not thereby an item worth
        -- deleting: refusing a pickup costs nothing, deleting is irreversible.
        local Scanner = setup()
        local hidden = Stub.item({ name = "internal_thing", tags = { "HideInUI" } })
        isTrue(Scanner.IsRestrictedItem(hidden))
        isFalse(Scanner.IsStuckInInventory(hidden))
    end)

    it("keeps anything it cannot classify", function()
        local Scanner = setup()
        isFalse(Scanner.IsStuckInInventory(Stub.item({
            name = "mystery", recordMissing = true, brokenTags = true })))
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

    it("loots an enemy that was knocked out rather than killed", function()
        -- A non-lethal takedown leaves a body that vanilla F empties without
        -- complaint. The mod asked only "is it dead or defeated" and walked past
        -- it, which in play was one body in a cleared camp that refused to be
        -- looted while everything around it worked.
        local Scanner, world = setup()
        world.targeting = { Stub.unconsciousNpc({ items = { Stub.item({ name = "eddies" }) } }) }

        eq(#Scanner.Get(), 1)
    end)

    it("loots a robot that has been shut down", function()
        local Scanner, world = setup()
        world.targeting = {
            Stub.corpse({ dead = false, turnedOff = true, items = { Stub.item({ name = "parts" }) } }),
        }

        eq(#Scanner.Get(), 1)
    end)

    it("falls back to the individual state checks when IsActive is missing", function()
        local Scanner, world = setup()
        world.noIsActiveApi = true
        world.targeting = { Stub.unconsciousNpc({ items = { Stub.item({ name = "eddies" }) } }) }

        eq(#Scanner.Get(), 1)
    end)

    it("leaves a puppet alone when its state cannot be read at all", function()
        local Scanner, world = setup()
        world.noIsActiveApi = true
        local puppet = Stub.livingNpc({ items = { Stub.item({ name = "eddies" }) } })
        -- Every state question throws: unreadable must mean untouched.
        puppet.IsDead = function() error("no") end
        puppet.IsIncapacitated = function() error("no") end
        _G.ScriptedPuppet.IsDefeated = function() error("no") end
        _G.ScriptedPuppet.IsUnconscious = function() error("no") end
        _G.ScriptedPuppet.IsTurnedOff = function() error("no") end
        world.targeting = { puppet }

        eq(#Scanner.Get(), 0)
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

    it("never empties the player's own stash", function()
        -- Stash extends InteractiveDevice and has a real inventory, so the
        -- "does it hold items" fallback would have taken the lot: hundreds of
        -- items into a 200 unit backpack, with no way to put them back.
        local Scanner, world = setup()
        world.targeting = { Stub.stash({ items = {
            Stub.item({ name = "stored_rifle" }), Stub.item({ name = "stored_shard" }) } }) }

        eq(#Scanner.Get(), 0)
    end)

    it("leaves every other device alone as well", function()
        local Scanner, world = setup()
        for _, class in ipairs({ "Wardrobe", "DropPoint", "VendingMachine", "Computer", "AccessPoint" }) do
            world.targeting = { Stub.entity({
                class = class,
                parents = { InteractiveDevice = true, Device = true, gameObject = true },
                items = { Stub.item({ name = "contents_" .. class }) },
            }) }
            Scanner.Invalidate()
            eq(#Scanner.Get(), 0, class .. " must not be looted")
        end
    end)

    it("recognises a device even when only its own class name is known", function()
        local Scanner, world = setup()
        world.targeting = { Stub.entity({
            class = "Stash",
            parents = { gameObject = true },
            items = { Stub.item({ name = "stored" }) },
        }) }

        eq(#Scanner.Get(), 0)
    end)

    it("leaves locked containers locked", function()
        local Scanner, world = setup()
        world.targeting = { Stub.container({ locked = true, items = { Stub.item({ name = "prize" }) } }) }

        eq(#Scanner.Get(), 0)
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

    it("leaves a car's mounted weapons on the car", function()
        local Scanner, world = setup()
        world.targeting = {
            Stub.container({ items = { Stub.vehicleWeapon({}), Stub.vehicleWeapon({
                name = "Items.Vehicle_Power_Weapon_Right_A" }) } }),
        }

        local objects, stacks = Scanner.Get()
        eq(#objects, 0)
        eq(stacks, 0)
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

    it("takes the ordinary loot off a body that also carries a quest item", function()
        -- One quest-tagged item used to make the entire body untouchable, which
        -- in play looked like a single corpse refusing to be looted for no
        -- reason while everything around it worked.
        local Scanner, world = setup({ skipQuestItems = true })
        world.targeting = {
            Stub.corpse({ items = {
                Stub.item({ name = "evidence", quest = true }),
                Stub.item({ name = "eddies" }),
            } }),
        }

        local objects, stacks = Scanner.Get()
        eq(#objects, 1)
        eq(stacks, 1, "the quest item is not on offer")
        isTrue(objects[1].restricted, "mixed contents must go item by item")
    end)

    it("still leaves a scripted quest object entirely alone", function()
        local Scanner, world = setup({ skipQuestItems = true })
        world.targeting = {
            Stub.container({ quest = true, items = { Stub.item({ name = "eddies" }) } }),
        }

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
