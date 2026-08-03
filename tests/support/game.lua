-- A stand-in for the parts of the game the mod talks to.
--
-- The point is not to simulate Cyberpunk. It is to make the mod's assumptions
-- executable: every stub here refuses the same things the engine refuses. The
-- item record lookup, for instance, rejects a TweakDBID exactly as the real one
-- does, because passing it a TweakDBID is a bug this mod has actually shipped.
--
-- Anything the stub cannot honestly reproduce is left out rather than faked
-- loosely, so a passing suite never implies more than it checked.

local Stub = {}

local _nextHash = 0
local _records = {}

local function nextHash()
    _nextHash = _nextHash + 1
    return _nextHash
end

-- Items -----------------------------------------------------------------------

-- spec: name, quantity, tags {}, equipArea, itemType, quest
function Stub.item(spec)
    spec = spec or {}

    local id = { __itemid = true, value = spec.name or ("item" .. tostring(nextHash())) }

    _records[id.value] = {
        equipArea = spec.equipArea,
        itemType = spec.itemType,
        -- A missing record is a real possibility for some world objects.
        missing = spec.recordMissing == true,
    }

    local item = {
        __id = id,
        __quantity = spec.quantity or 1,
        __tags = spec.tags or {},
        __quest = spec.quest == true,
        -- Lets a spec reproduce an item whose API is simply not answering.
        __brokenTags = spec.brokenTags == true,
    }

    function item:GetID()
        return self.__id
    end

    function item:GetQuantity()
        return self.__quantity
    end

    function item:HasTag(tag)
        if self.__brokenTags then
            error("HasTag is unavailable on this build")
        end

        local name = type(tag) == "table" and tag.value or tostring(tag)

        if name == "Quest" then
            return self.__quest
        end

        for _, own in ipairs(self.__tags) do
            if own == name then
                return true
            end
        end

        return false
    end

    return item
end

function Stub.heavyWeapon(spec)
    spec = spec or {}
    spec.name = spec.name or "heavy_machine_gun"
    spec.equipArea = "EquipmentArea.WeaponHeavy"
    spec.itemType = "ItemType.Wea_HeavyMachineGun"
    spec.tags = spec.tags or { "DiscardOnEmpty" }
    return Stub.item(spec)
end

-- Entities ---------------------------------------------------------------------

-- spec: class, parents {}, items {}, pos {x,y,z}, dead, defeated, quest, drop,
--       owner, quantityUnknown, transferAllNoop, transferItemFails
function Stub.entity(spec)
    spec = spec or {}

    local entity = {
        __class = spec.class or "gameObject",
        __parents = spec.parents or {},
        __items = spec.items or {},
        __pos = spec.pos or { x = 0.0, y = 0.0, z = 0.0 },
        __hash = nextHash(),
        __dead = spec.dead == true,
        __defeated = spec.defeated == true,
        __quest = spec.quest == true,
        __drop = spec.drop,
        __owner = spec.owner,
        __quantityUnknown = spec.quantityUnknown == true,
        __transferAllNoop = spec.transferAllNoop == true,
        __transferItemFails = spec.transferItemFails == true,
    }

    function entity:IsA(name)
        if name == self.__class then
            return true
        end
        return self.__parents[name] == true
    end

    function entity:GetClassName()
        return { value = self.__class }
    end

    function entity:GetEntityID()
        return { hash = self.__hash }
    end

    function entity:GetWorldPosition()
        return self.__pos
    end

    function entity:IsDead()
        return self.__dead
    end

    function entity:IsQuest()
        return self.__quest
    end

    function entity:GetConnectedItemDrop()
        return self.__drop
    end

    function entity:GetOwner()
        return self.__owner
    end

    return entity
end

function Stub.corpse(spec)
    spec = spec or {}
    spec.class = spec.class or "NPCPuppet"
    spec.parents = spec.parents or { ScriptedPuppet = true, gameObject = true }
    spec.dead = spec.dead ~= false
    return Stub.entity(spec)
end

function Stub.livingNpc(spec)
    spec = spec or {}
    spec.class = spec.class or "NPCPuppet"
    spec.parents = spec.parents or { ScriptedPuppet = true, gameObject = true }
    spec.dead = false
    spec.defeated = false
    return Stub.entity(spec)
end

function Stub.container(spec)
    spec = spec or {}
    spec.class = spec.class or "Container"
    spec.parents = spec.parents or { gameLootContainerBase = true, gameObject = true }
    return Stub.entity(spec)
end

-- A loose item on a table: the visual object holds nothing, the drop it points
-- at is where the inventory actually lives.
function Stub.worldItem(spec)
    spec = spec or {}

    local drop = Stub.entity({
        class = "gameItemDropObject",
        parents = { gameObject = true },
        items = spec.items or {},
        pos = spec.pos,
    })

    local visual = Stub.entity({
        class = "gameItemObject",
        parents = { ItemObject = true, gameObject = true },
        items = {},
        pos = spec.pos,
        drop = spec.orphan and nil or drop,
    })

    return visual, drop
end

-- World -------------------------------------------------------------------------

function Stub.install()
    _nextHash = 0
    _records = {}

    local world = {
        player = nil,
        targeting = {},          -- what the general query returns
        corpses = {},            -- what the dead-filtered query returns
        targetingFails = false,
        byId = {},               -- for Game.FindEntityByID
        photoMode = false,
        blackboard = {
            isInMenu = false,
            hubVariant = nil,    -- see Stub.hub
            readable = true,
        },
        observers = {},
        transfers = {},          -- log of every transaction, for assertions
    }

    local function parts(entities)
        local list = {}
        for _, entity in ipairs(entities) do
            list[#list + 1] = {
                component = {
                    GetEntity = function()
                        return entity
                    end,
                },
            }
        end
        return list
    end

    local transactionSystem = {}

    function transactionSystem:GetItemList(holder)
        return true, holder.__items
    end

    function transactionSystem:GetTotalItemQuantity(holder)
        if holder.__quantityUnknown then
            error("quantity unavailable")
        end

        local total = 0
        for _, item in ipairs(holder.__items) do
            total = total + item.__quantity
        end
        return total
    end

    function transactionSystem:TransferAllItems(source, target)
        world.transfers[#world.transfers + 1] = { kind = "all", source = source }

        if source.__transferAllNoop then
            return
        end

        for _, item in ipairs(source.__items) do
            target.__items[#target.__items + 1] = item
        end
        source.__items = {}
    end

    function transactionSystem:TransferItem(source, target, itemID, quantity)
        world.transfers[#world.transfers + 1] = { kind = "one", source = source, id = itemID.value }

        if source.__transferItemFails then
            return false
        end

        for index, item in ipairs(source.__items) do
            if item.__id.value == itemID.value then
                table.remove(source.__items, index)
                target.__items[#target.__items + 1] = item
                return true
            end
        end

        return false
    end

    local blackboards = {}

    local function blackboardFor(defs)
        if blackboards[defs] == nil then
            blackboards[defs] = {
                GetBool = function(_, _)
                    return world.blackboard.isInMenu
                end,
                GetVariant = function(_, _)
                    if not world.blackboard.readable then
                        error("blackboard read failed")
                    end
                    return world.blackboard.hubVariant
                end,
            }
        end
        return blackboards[defs]
    end

    local defs = {
        UI_System = { IsInMenu = "IsInMenu" },
        UIInteractions = { InteractionChoiceHub = "InteractionChoiceHub" },
    }

    -- Globals the mod reaches for ------------------------------------------------

    _G.Game = {
        GetPlayer = function()
            return world.player
        end,

        GetTransactionSystem = function()
            return transactionSystem
        end,

        GetTargetingSystem = function()
            return {
                GetTargetParts = function(_, _, query)
                    if world.targetingFails then
                        error("targeting system unavailable")
                    end

                    -- The corpse source is the only one that sets a filter, which
                    -- is what makes it a different question from the general one.
                    if query.searchFilter ~= nil then
                        return true, parts(world.corpses)
                    end

                    return true, parts(world.targeting)
                end,
            }
        end,

        GetBlackboardSystem = function()
            return {
                Get = function(_, requested)
                    return blackboardFor(requested)
                end,
            }
        end,

        GetPhotoModeSystem = function()
            return {
                IsPhotoModeActive = function()
                    return world.photoMode
                end,
            }
        end,

        FindEntityByID = function(id)
            return world.byId[id.hash]
        end,

        SendInputHintData = function() end,
    }

    _G.GetAllBlackboardDefs = function()
        return defs
    end

    _G.FromVariant = function(variant)
        if variant == nil then
            return nil
        end
        if variant.__throwsOnUnpack then
            error("cannot unpack variant")
        end
        return variant.unpacked
    end

    _G.RPGManager = {
        GetItemRecord = function(itemID)
            -- The engine is strict about this and so is the stub: handing it the
            -- TweakDBID out of an ItemID is precisely the bug this guards.
            if type(itemID) ~= "table" or itemID.__itemid ~= true then
                error("Function 'GetItemRecord' parameter 1 must be gameItemID.")
            end

            local record = _records[itemID.value]
            if record == nil or record.missing then
                return nil
            end

            return {
                EquipArea = function()
                    if record.equipArea == nil then
                        return nil
                    end
                    return {
                        Type = function()
                            return record.equipArea
                        end,
                    }
                end,

                ItemType = function()
                    if record.itemType == nil then
                        return nil
                    end
                    return {
                        Type = function()
                            return record.itemType
                        end,
                    }
                end,
            }
        end,
    }

    _G.ItemID = {
        GetTDBID = function(itemID)
            return { __tweakdbid = true, value = itemID.value }
        end,
    }

    -- Nil arguments are a programming error in the engine too, so the stub throws
    -- rather than quietly answering false.
    _G.Equals = function(a, b)
        if a == nil or b == nil then
            error("Equals: nil argument")
        end
        return a == b
    end

    _G.CName = {
        new = function(value)
            return { value = value }
        end,
    }

    _G.gamedataEquipmentArea = {
        WeaponHeavy = "EquipmentArea.WeaponHeavy",
        Weapon = "EquipmentArea.Weapon",
    }

    _G.gamedataItemType = {
        Wea_HeavyMachineGun = "ItemType.Wea_HeavyMachineGun",
        Wea_LightMachineGun = "ItemType.Wea_LightMachineGun",
        Wea_Handgun = "ItemType.Wea_Handgun",
    }

    _G.gamedataMappinVariant = { LootVariant = "LootVariant" }

    _G.ScriptedPuppet = {
        IsDefeated = function(entity)
            return entity.__defeated == true
        end,
    }

    _G.TSQ_ALL = function()
        return {}
    end

    _G.gameTargetSearchQuery = {
        new = function()
            return {}
        end,
    }

    _G.TSF_All = function(mask) return { all = mask } end
    _G.TSF_Any = function(mask) return { any = mask } end
    _G.TSF_And = function(a, b) return { andOf = { a, b } } end

    _G.gameTargetingSet = { Complete = "Complete" }

    _G.gametargetingTargetPartInfo = {
        GetComponent = function(part)
            return part.component
        end,
    }

    _G.Vector4 = {
        Distance = function(a, b)
            local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            return math.sqrt(dx * dx + dy * dy + dz * dz)
        end,
    }

    _G.ObserveAfter = function(class, method, fn)
        world.observers[#world.observers + 1] = { class = class, method = method, fn = fn }
    end

    _G.GetDisplayResolution = function()
        return 1920, 1080
    end

    -- Helpers used by the specs ---------------------------------------------------

    -- Wraps a hub the way the blackboard does, so specs never build Variants by hand.
    function world.setHub(hub)
        if hub == nil then
            world.blackboard.hubVariant = nil
            return
        end
        world.blackboard.hubVariant = { unpacked = hub }
    end

    function world.place(entity)
        world.byId[entity.__hash] = entity
        return entity
    end

    function world.transferKinds()
        local kinds = {}
        for _, transfer in ipairs(world.transfers) do
            kinds[#kinds + 1] = transfer.kind
        end
        return table.concat(kinds, ",")
    end

    world.player = Stub.entity({
        class = "PlayerPuppet",
        parents = { ScriptedPuppet = true, gameObject = true },
        pos = { x = 0.0, y = 0.0, z = 0.0 },
    })

    return world
end

-- Modules keep session state (scan caches, timers, one-shot warnings), so each
-- spec gets its own copy rather than inheriting whatever the last one left.
function Stub.load(path)
    return freshRequire(path)
end

-- A recording stand-in for the Log module, injected through the same deps table
-- the real modules already use.
function Stub.log()
    local log = { lines = {} }

    local function record(level)
        return function(message)
            log.lines[#log.lines + 1] = level .. " " .. tostring(message)
        end
    end

    log.Info = record("INFO")
    log.Warn = record("WARN")
    log.Error = record("ERROR")
    log.Debug = record("DEBUG")

    log.DebugThrottled = function(_, _, message)
        log.lines[#log.lines + 1] = "DEBUG " .. tostring(message)
    end

    log.IsEnabled = function()
        return true
    end

    log.SetEnabled = function() end

    log.Reset = function()
        log.lines = {}
    end

    function log.find(needle)
        for _, line in ipairs(log.lines) do
            if line:find(needle, 1, true) then
                return line
            end
        end
        return nil
    end

    function log.text()
        return table.concat(log.lines, "\n")
    end

    return log
end

-- Config carries no behaviour the specs need, only values, so it is a plain table.
function Stub.config(overrides)
    local values = {
        radius = 5.0,
        holdTime = 0.35,
        skipQuestItems = true,
        respectInteraction = true,
        maxObjectsPerSweep = 24,
        showIndicator = true,
        hintShowKeyName = false,
        hintLabel = "Loot All",
        hintRefreshHack = false,
        useImGuiFallback = false,
        indicatorOffsetX = 0.0,
        indicatorOffsetY = 60.0,
        debugLog = true,
    }

    for key, value in pairs(overrides or {}) do
        values[key] = value
    end

    return { values = values }
end

return Stub
