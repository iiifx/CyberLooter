-- Whether a sweep did what it says it did.
--
-- Every case here is about honesty: the mod reports success only when items
-- actually moved, because the log is the only thing that can be read back from
-- the machine the game runs on.

local Stub = require("tests/support/game.lua")

local function setup(configOverrides)
    local world = Stub.install()
    local log = Stub.log()
    local config = Stub.config(configOverrides)

    local Scanner = Stub.load("Modules/Scanner.lua")
    local State = { GetPlayer = function() return world.player end }
    Scanner.Init({ Log = log, Config = config, State = State })

    local Looter = Stub.load("Modules/Looter.lua")
    Looter.Init({ Log = log, Config = config, Scanner = Scanner, State = State })

    return Looter, Scanner, world, log
end

describe("Looter.Sweep", function()
    it("empties a container through the game's own bulk transfer", function()
        local Looter, _, world = setup()
        local container = Stub.container({ items = { Stub.item({ name = "eddies" }), Stub.item({ name = "shard" }) } })
        world.targeting = { container }

        eq(Looter.Sweep(), 1)
        eq(#container.__items, 0)
        eq(#world.player.__items, 2)
        eq(world.transferKinds(), "all")
    end)

    it("reports nothing found when the radius is empty", function()
        local Looter = setup()
        eq(Looter.Sweep(), 0)
        eq(Looter.lastSweep, "nothing in radius")
    end)

    it("falls back to item-by-item when the bulk transfer moves nothing", function()
        local Looter, _, world, log = setup()
        world.targeting = {
            Stub.container({ items = { Stub.item({ name = "eddies" }) }, transferAllNoop = true }),
        }

        eq(Looter.Sweep(), 1)
        eq(world.transferKinds(), "all,one")
        contains(log.text(), "item-by-item")
    end)

    it("never bulk-transfers an object holding a hand-carried weapon", function()
        -- Bulk-transferring one leaves the player in the carrying pose with an
        -- invisible weapon and no way to drop it short of firing it dry.
        local Looter, _, world = setup()
        local container = Stub.container({
            items = { Stub.heavyWeapon({}), Stub.item({ name = "eddies" }) },
        })
        world.targeting = { container }

        eq(Looter.Sweep(), 1)
        eq(world.transferKinds(), "one", "the bulk path must not be used at all")
        eq(#container.__items, 1, "the weapon stays where it was")
        eq(container.__items[1].__id.value, "heavy_machine_gun")
        eq(#world.player.__items, 1)
    end)

    it("takes everything but the quest item off a mixed body", function()
        local Looter, _, world = setup({ skipQuestItems = true })
        local corpse = Stub.corpse({ items = {
            Stub.item({ name = "evidence", quest = true }),
            Stub.item({ name = "eddies" }),
        } })
        world.targeting = { corpse }

        eq(Looter.Sweep(), 1)
        eq(world.transferKinds(), "one", "the bulk path would have taken the quest item")
        eq(#corpse.__items, 1)
        eq(corpse.__items[1].__id.value, "evidence")
        eq(#world.player.__items, 1)
    end)

    it("counts an object emptied by someone else as skipped, not failed", function()
        local Looter, Scanner, world = setup()
        local container = Stub.container({ items = { Stub.item({ name = "eddies" }) } })
        world.targeting = { container }

        -- Scanned, then emptied before the hold completed: the cache is up to
        -- 0.3 s old, so this is a normal race rather than a malfunction.
        Scanner.Get()
        container.__items = {}

        eq(Looter.Sweep(), 0)
        contains(Looter.lastSweep, "0/0 objects")
    end)

    it("does not claim success when the count is unreadable and loot is left behind", function()
        local Looter, _, world = setup()
        world.targeting = {
            Stub.container({
                items = { Stub.item({ name = "eddies" }) },
                quantityUnknown = true,
                transferAllNoop = true,
                transferItemFails = true,
            }),
        }

        eq(Looter.Sweep(), 0)
        contains(Looter.lastSweep, "0/1 objects")
    end)

    it("stops at the per-sweep object limit and says how much is left", function()
        local Looter, _, world, log = setup({ maxObjectsPerSweep = 2 })
        world.targeting = {}
        for index = 1, 5 do
            world.targeting[index] = Stub.container({
                items = { Stub.item({ name = "eddies" .. index }) },
                pos = { x = index * 0.1, y = 0.0, z = 0.0 },
            })
        end

        eq(Looter.Sweep(), 2)
        contains(log.text(), "3 left for the next hold")
    end)

    it("invalidates the scan cache so the indicator does not linger", function()
        local Looter, Scanner, world = setup()
        world.targeting = { Stub.container({ items = { Stub.item({ name = "eddies" }) } }) }

        Looter.Sweep()

        local _, stacks = Scanner.Get()
        eq(stacks, 0)
    end)
end)
