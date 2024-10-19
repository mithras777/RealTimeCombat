Ext.Require("RealTimeCombat/Server/Tables.lua")
local PURunning = false
local Party = {}
local Enemies = {}
local Allies = {}
local combatNPCs = {}
local NPCSpellTable = {}
local castSpellHistory = {}
local IsTurnBased = false
local characterManaPools = {}
local isRegeneratingMana = false
local spellUsageCounter = {}

local function CalculateMana(entity)
    local stats = entity.Stats
    local intelligence = stats.Abilities and stats.Abilities[4] or 0
    local wisdom = stats.Abilities and stats.Abilities[5] or 0
    local charisma = stats.Abilities and stats.Abilities[6] or 0
    local level = entity.EocLevel.Level
    return math.floor(((intelligence * 2) + (wisdom * 2) + (charisma * 2) + (level * 10)))
end
local function SendManaPoolToClient(character)
    local charGuid = character.Uuid.EntityUuid
    local manaPool = characterManaPools[charGuid]
    if manaPool then
        local payload = {
            Character = charGuid,
            TotalMana = manaPool.totalMana,
            CurrentMana = manaPool.currentMana
        }
        Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "UpdateManaPool", Ext.Json.Stringify(payload))
    end
end
local function GetCharacterId(rawId)
    return rawId:match(".*_(.*)") or rawId
end
local function CountAlivePartyMembers()
    local aliveCount = 0
    for uuid, _ in pairs(Party) do
        if IsDead(uuid) == 0 then
            aliveCount = aliveCount + 1
        end
    end
    return aliveCount
end
local function IsUnconsciousOrDead(uuid)
    return IsDead(uuid) == 1 or
           Osi.HasActiveStatus(uuid, "DOWNED") == 1 or
           Osi.HasActiveStatus(uuid, "KNOCKED_OUT") == 1 or
           Osi.HasActiveStatus(uuid, "KNOCKED_OUT_TEMPORARILY") == 1 or
           Osi.HasActiveStatus(uuid, "KNOCKED_OUT_PERMANENTLY") == 1
end
local function SetCanJoinCombatForAll(value)
    local allCharacters = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")
    for _, character in ipairs(allCharacters) do
        local uuid = GetCharacterId(character.Uuid.EntityUuid)
        Osi.SetCanJoinCombat(uuid, value)
    end
end
local function tableContains(tbl, element)
    for _, value in pairs(tbl) do
        if value == element then
            return true
        end
    end
    return false
end
local function CheckIfOrigin(target)
    for i = #ExcludedNPCs, 1, -1 do
        if (ExcludedNPCs[i] == target) then
            return 1
        end
    end
    return 0
end
local function HandleCombatEnded()
    PURunning = false
    castSpellHistory = {}
    SetCanJoinCombatForAll(1)
    Enemies = {}
    Allies = {}
    combatNPCs = {}
    _D("Combat has ended and combat data has been reset.")
end

local function GetManaCost(character, spellID)
    local spellData = Ext.Stats.Get(spellID)
    local spellLevel = spellData.Level or 0
    if tableContains(attack_spells, spellID) then
        return 15
    end
    if spellLevel == 0 then
        return 20
    end
    local baseManaCost = 10
    local levelMultiplier = spellLevel * 5
    local damageTypeCost = 0
    if spellData.DamageType and spellData.DamageType ~= "" then
        damageTypeCost = damageTypeCost + 5
    end
    local spellFlagCost = 0
    if spellData.SpellFlags then
        for _, flag in ipairs(spellData.SpellFlags) do
            if flag == "IsHarmful" then
                spellFlagCost = spellFlagCost + 10
            end
        end
    end
    local actionTypeCost = 0
    if spellData.SpellActionType then
        if spellData.SpellActionType == "Shout" then
            actionTypeCost = 20
        elseif spellData.SpellActionType == "Target" then
            actionTypeCost = 15
        elseif spellData.SpellActionType == "Projectile" then
            actionTypeCost = 10
        elseif spellData.SpellActionType == "Zone" then
            actionTypeCost = 25
        else
            actionTypeCost = 5
        end
    end
    local targetEffectCost = 0
    if spellData.MaximumTargets and tonumber(spellData.MaximumTargets) > 1 then
        targetEffectCost = -10
    end
    local finalManaCost = math.max(baseManaCost + levelMultiplier + damageTypeCost + spellFlagCost + actionTypeCost + targetEffectCost, 15)
    return finalManaCost
end
local function GetDisplayName(guid)
    local entity = Ext.Entity.Get(guid)
    if entity and entity.DisplayName and entity.DisplayName.NameKey and entity.DisplayName.NameKey.Handle then
        return Ext.Loca.GetTranslatedString(entity.DisplayName.NameKey.Handle.Handle)
    end
    return guid
end
local function GetResources(entity)
    if entity and entity.ActionResources then
        return entity.ActionResources.Resources
    end
    return nil
end
local function IsValidPosition(p)
    local epsilon = 0.00000001
    local max = 10000
    local x, y, z = table.unpack(p)
    if math.abs(x) < epsilon and math.abs(y) < epsilon and math.abs(z) < epsilon then
        return false
    end
    if math.abs(x) > max or math.abs(y) > max or math.abs(z) > max then
        return false
    end
    return true
end
local function IsEnemyWithParty(characterUUID)
    for partyUUID, _ in pairs(Party) do
        if IsEnemy(characterUUID, partyUUID) == 1 then
            return true
        end
    end
    return false
end
local function GetCategoryName(spellID)
    if tableContains(attack_spells, spellID) then
        return "attack"
    elseif tableContains(healing_spells, spellID) then
        return "healing"
    elseif tableContains(self_buff_spells, spellID) then
        return "self_buff"
    elseif tableContains(physical_buff_spells, spellID) then
        return "physical_buff"
    elseif tableContains(debuff_spells, spellID) then
        return "debuff"
    elseif tableContains(offense_magic_spells, spellID) then
        return "offense_magic"
    elseif tableContains(summoning_spells, spellID) then
        return "summoning"
    elseif tableContains(wildshape_spells, spellID) then
        return "wildshape"
    else
        return "unknown"
    end
end
local function GetNPCSpells(npc)
    local npcSpellCategories = { Spells = {}, ExcludedSpells = {} }
    local characterId = GetCharacterId(npc)
    local npcLevel = Osi.GetLevel(npc)
    local allSpells = {}
    local spellBookPrepares = Ext.Entity.Get(npc).SpellBookPrepares
    if spellBookPrepares and spellBookPrepares.PreparedSpells then
        for _, preparedSpell in ipairs(spellBookPrepares.PreparedSpells) do
            local spellID = preparedSpell.OriginatorPrototype
            local spellData = Ext.Stats.Get(spellID)
            if spellData and spellData.Level <= (npcLevel + 1) then
                table.insert(allSpells, spellID)
            end
        end
    end
    for _, spellID in ipairs(allSpells) do
        local category = GetCategoryName(spellID)
        if category ~= "unknown" then
            local targetRadius = tonumber(Ext.Stats.Get(spellID).TargetRadius) or 3
            local rawTargetRadius = Ext.Stats.Get(spellID).TargetRadius
            if rawTargetRadius == "RangedMainWeaponRange" then
                targetRadius = 9
            elseif rawTargetRadius == "MeleeMainWeaponRange" then
                targetRadius = 3
            end
            if category == "wildshape" then
                targetRadius = 9
            end
            npcSpellCategories.Spells[spellID] = {
                Name = spellID,
                Level = Ext.Stats.Get(spellID).Level or 0,
                TargetRadius = targetRadius,
                Category = category
            }
        else
            table.insert(npcSpellCategories.ExcludedSpells, spellID)
        end
    end

    -- Add MainHandAttack if no spells are available
    if next(npcSpellCategories.Spells) == nil then
        npcSpellCategories.Spells["Target_MainHandAttack"] = {
            Name = "Target_MainHandAttack",
            Level = 0,
            TargetRadius = 3,
            Category = "attack"
        }
    end

    _D("NPC " .. GetDisplayName(npc) .. " assigned spells: ")
    _D(npcSpellCategories.Spells)
    _D("NPC " .. GetDisplayName(npc) .. " excluded spells: ")
    _D(npcSpellCategories.ExcludedSpells)
    return npcSpellCategories
end

local function CalculateDistance(uuid1, uuid2)
    local x1, y1, z1 = Osi.GetPosition(uuid1)
    local x2, y2, z2 = Osi.GetPosition(uuid2)
    return Ext.Math.Distance({x1, y1, z1}, {x2, y2, z2})
end
local function GetNearbyCharacters(position, radius, ignoreHeight)
    radius = radius or 50
    local nearbyEntities = {}
    for _, character in ipairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
        local charPos = {Osi.GetPosition(character.Uuid.EntityUuid)}
        local distance = math.sqrt((position[1] - charPos[1])^2 + (position[2] - charPos[2])^2 + (ignoreHeight and 0 or (position[3] - charPos[3])^2))
        if distance <= radius then
            table.insert(nearbyEntities, {
                Entity = character,
                Guid = character.Uuid.EntityUuid,
                Distance = distance,
                Name = Ext.Loca.GetTranslatedString(character.DisplayName.NameKey.Handle.Handle)
            })
        end
    end
    table.sort(nearbyEntities, function(a, b) return a.Distance < b.Distance end)
    return nearbyEntities
end
local function UseSpell(caster, spell, target)
    local casterId = GetCharacterId(caster)
    local characterName = GetDisplayName(casterId)

    -- Validate that the target is not nil
    if not target then
        _D("UseSpell called with nil target for caster: " .. GetDisplayName(casterId) .. " and spell: " .. spell)
        return
    end

    -- Purge and flush the Osiris queue before casting the spell
    Osi.PurgeOsirisQueue(caster, 1)
    Osi.FlushOsirisQueue(caster)

    if characterManaPools[casterId] then
        local character = Ext.Entity.Get(casterId)
        local manaCost = GetManaCost(character, spell)
        if characterManaPools[casterId].currentMana >= manaCost then
            Osi.UseSpell(caster, spell, target)
        else
            _D(characterName .. " does not have enough mana to cast " .. spell)
        end
    else
        Osi.UseSpell(caster, spell, target)
    end
end

local function TryExecuteSpellAtPositionOrCharacter(character, spellID, targetPosition)
    local casterId = GetCharacterId(character)
    local characterName = GetDisplayName(casterId)
    local spellData = Ext.Stats.Get(spellID)
    Osi.PurgeOsirisQueue(casterId, 1)
    Osi.FlushOsirisQueue(casterId)
    if characterManaPools[casterId] then
        local characterEntity = Ext.Entity.Get(casterId)
        local manaCost = GetManaCost(characterEntity, spellID)
        if characterManaPools[casterId].currentMana >= manaCost then
            if spellData.SpellType == "Shout" then
                Osi.UseSpell(character, spellID, character)
            else
                local nearbyCharacters = GetNearbyCharacters(targetPosition, 1.7, false)
                if #nearbyCharacters > 0 then
                    local closestCharacter = nearbyCharacters[1].Guid
                    Osi.UseSpell(character, spellID, closestCharacter)
                else
                    Osi.UseSpellAtPosition(character, spellID, targetPosition[1], targetPosition[2], targetPosition[3])
                end
            end
        else
            Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "NotEnoughMana", "{}")
            return
        end
    end
end
local function FindNearestParty(actingEntity)
    local nearestParty = nil
    local smallestDistance = math.huge
    for partyUUID, _ in pairs(Party) do
        if partyUUID ~= actingEntity and IsDead(partyUUID) == 0 and Osi.IsInvisible(partyUUID) == 0 and Osi.HasActiveStatus(partyUUID, "SNEAKING") == 0 then
            local distance = CalculateDistance(actingEntity, partyUUID)
            if distance < smallestDistance then
                smallestDistance = distance
                nearestParty = partyUUID
            end
        end
    end
    return nearestParty
end
local function FindNearestAlly(actingEntity)
    local nearestAlly = nil
    local smallestDistance = math.huge
    if Enemies[actingEntity] then
        for enemyUUID, _ in pairs(Enemies) do
            if enemyUUID ~= actingEntity and IsDead(enemyUUID) == 0 and Osi.IsInvisible(enemyUUID) == 0 and Osi.HasActiveStatus(enemyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, enemyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestAlly = enemyUUID
                end
            end
        end
    else
        for partyUUID, _ in pairs(Party) do
            if partyUUID ~= actingEntity and IsDead(partyUUID) == 0 and Osi.IsInvisible(partyUUID) == 0 and Osi.HasActiveStatus(partyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, partyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestAlly = partyUUID
                end
            end
        end
        for allyUUID, _ in pairs(Allies) do
            if allyUUID ~= actingEntity and IsDead(allyUUID) == 0 and Osi.IsInvisible(allyUUID) == 0 and Osi.HasActiveStatus(allyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, allyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestAlly = allyUUID
                end
            end
        end
    end
    return nearestAlly
end
local function FindNearestEnemy(actingEntity)
    local nearestEnemy = nil
    local smallestDistance = math.huge
    if Enemies[actingEntity] then
        for partyUUID, _ in pairs(Party) do
            if partyUUID ~= actingEntity and not IsUnconsciousOrDead(partyUUID) and Osi.IsInvisible(partyUUID) == 0 and Osi.HasActiveStatus(partyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, partyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestEnemy = partyUUID
                end
            end
        end
        for allyUUID, _ in pairs(Allies) do
            if allyUUID ~= actingEntity and not IsUnconsciousOrDead(allyUUID) and Osi.IsInvisible(allyUUID) == 0 and Osi.HasActiveStatus(allyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, allyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestEnemy = allyUUID
                end
            end
        end
    else
        for enemyUUID, _ in pairs(Enemies) do
            if enemyUUID ~= actingEntity and not IsUnconsciousOrDead(enemyUUID) and Osi.IsInvisible(enemyUUID) == 0 and Osi.HasActiveStatus(enemyUUID, "SNEAKING") == 0 then
                local distance = CalculateDistance(actingEntity, enemyUUID)
                if distance < smallestDistance then
                    smallestDistance = distance
                    nearestEnemy = enemyUUID
                end
            end
        end
    end
    return nearestEnemy
end
local function FindLowestHPParty(actingEntity)
    local lowestHPParty = nil
    local lowestHP = math.huge
    if Enemies[actingEntity] then
        return nil
    else
        for partyUUID, _ in pairs(Party) do
            if partyUUID ~= actingEntity and IsDead(partyUUID) == 0 then
                local entity = Ext.Entity.Get(partyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPParty = partyUUID
                end
            end
        end
    end
    return lowestHPParty
end
local function FindLowestHPAlly(actingEntity)
    local lowestHPAlly = nil
    local lowestHP = math.huge
    if Enemies[actingEntity] then
        for enemyUUID, _ in pairs(Enemies) do
            if IsDead(enemyUUID) == 0 then
                local entity = Ext.Entity.Get(enemyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPAlly = enemyUUID
                end
            end
        end
    else
        for allyUUID, _ in pairs(Allies) do
            if IsDead(allyUUID) == 0 then
                local entity = Ext.Entity.Get(allyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPAlly = allyUUID
                end
            end
        end
        for partyUUID, _ in pairs(Party) do
            if IsDead(partyUUID) == 0 then
                local entity = Ext.Entity.Get(partyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPAlly = partyUUID
                end
            end
        end
    end
    return lowestHPAlly
end
local function FindLowestHPEnemy(actingEntity)
    local lowestHPEnemy = nil
    local lowestHP = math.huge
    if Enemies[actingEntity] then
        for allyUUID, _ in pairs(Allies) do
            if allyUUID ~= actingEntity and IsDead(allyUUID) == 0 then
                local entity = Ext.Entity.Get(allyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPEnemy = allyUUID
                end
            end
        end
        for partyUUID, _ in pairs(Party) do
            if IsDead(partyUUID) == 0 then
                local entity = Ext.Entity.Get(partyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPEnemy = partyUUID
                end
            end
        end
    else
        for enemyUUID, _ in pairs(Enemies) do
            if enemyUUID ~= actingEntity and IsDead(enemyUUID) == 0 then
                local entity = Ext.Entity.Get(enemyUUID)
                if entity and entity.Health and entity.Health.Hp < lowestHP then
                    lowestHP = entity.Health.Hp
                    lowestHPEnemy = enemyUUID
                end
            end
        end
    end
    return lowestHPEnemy
end
local function CountPartyMembersInRadius(entity, radius)
    local count = 0
    for partyUUID, _ in pairs(Party) do
        if IsDead(partyUUID) == 0 then
            local currentDistance = CalculateDistance(entity, partyUUID)
            if currentDistance <= radius then
                count = count + 1
            end
        end
    end
    return count
end
local function CountAlliesInRadius(entity, radius)
    local count = 0
    if Enemies[entity] then
        for enemyUUID, _ in pairs(Enemies) do
            if enemyUUID ~= entity and IsDead(enemyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, enemyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
    else
        for allyUUID, _ in pairs(Allies) do
            if allyUUID ~= entity and IsDead(allyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, allyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
        for partyUUID, _ in pairs(Party) do
            if partyUUID ~= entity and IsDead(partyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, partyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
    end
    return count
end
local function CountEnemiesInRadius(entity, radius)
    local count = 0
    if Enemies[entity] then
        for allyUUID, _ in pairs(Allies) do
            if IsDead(allyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, allyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
        for partyUUID, _ in pairs(Party) do
            if IsDead(partyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, partyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
    else
        for enemyUUID, _ in pairs(Enemies) do
            if IsDead(enemyUUID) == 0 then
                local currentDistance = CalculateDistance(entity, enemyUUID)
                if currentDistance <= radius then
                    count = count + 1
                end
            end
        end
    end
    return count
end
local function GetHighestAbilityScore(target)
    local abilities = {"Strength", "Dexterity", "Intelligence", "Wisdom", "Charisma", "Constitution"}
    local highestScore = 0
    local highestAbility = nil
    for _, ability in ipairs(abilities) do
        local score = Osi.GetAbility(target, ability)
        if score > highestScore then
            highestScore = score
            highestAbility = ability
        end
    end
    return highestAbility, highestScore
end
local function ApplyHexOnHighestAbility(target)
    local highestAbility, _ = GetHighestAbilityScore(target)
    local hexSpellMap = {
        Strength = "Target_Hex_Strength",
        Dexterity = "Target_Hex_Dexterity",
        Intelligence = "Target_Hex_Intelligence",
        Wisdom = "Target_Hex_Wisdom",
        Charisma = "Target_Hex_Charisma",
        Constitution = "Target_Hex_Constitution"
    }
    local hexSpell = hexSpellMap[highestAbility]
    if hexSpell then
        UseSpell(target, hexSpell, GetHostCharacter())
    end
end
local function CastHealingSpell(object, spell, target)
    local targetEntity = Ext.Entity.Get(target)
    if not targetEntity or not targetEntity.Health then return end
    local targetHP = targetEntity.Health.Hp
    local targetMaxHP = targetEntity.Health.MaxHp
    if targetHP < targetMaxHP then
        UseSpell(object, spell, target)
    end
end
local function DisengageTB()
    local allCharacters = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")
    for _, character in ipairs(allCharacters) do
        local uuid = character.Uuid.EntityUuid
        ApplyStatus(uuid, "DISENGAGE", -1)
    end
end

local function Engage()
    local allCharacters = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")
    for _, character in ipairs(allCharacters) do
        local uuid = character.Uuid.EntityUuid
        RemoveStatus(uuid, "DISENGAGE")
    end
end

local function GetAction(uuid, npcSpellCategories)
    local selectedSpells = {}
    local casterId = GetCharacterId(uuid)
    castSpellHistory[casterId] = castSpellHistory[casterId] or {}
    
    if not npcSpellCategories.originalSpells then
        npcSpellCategories.originalSpells = {}
        for spellID, spellDetails in pairs(npcSpellCategories.Spells) do
            npcSpellCategories.originalSpells[spellID] = spellDetails
        end
    end
    
    npcSpellCategories.excludedWildshapeSpells = npcSpellCategories.excludedWildshapeSpells or {}
    
    for spellID, spellDetails in pairs(npcSpellCategories.originalSpells) do
        local hasBeenCast = false
        for _, castedSpell in ipairs(castSpellHistory[casterId]) do
            if castedSpell == spellID then
                hasBeenCast = true
                break
            end
        end
        
        if GetCategoryName(spellID) == "wildshape" then
            if not hasBeenCast and not npcSpellCategories.excludedWildshapeSpells[spellID] then
                table.insert(selectedSpells, spellID)
            else
                npcSpellCategories.excludedWildshapeSpells[spellID] = true
                _D("Permanently excluding wildshape spell: " .. spellID .. " as it has already been cast.")
            end
        elseif not hasBeenCast then
            table.insert(selectedSpells, spellID)
        end
    end
    
    -- **Sort selectedSpells by targetRadius in descending order**
    table.sort(selectedSpells, function(a, b)
        local radiusA = tonumber(Ext.Stats.Get(a).TargetRadius) or 0
        local radiusB = tonumber(Ext.Stats.Get(b).TargetRadius) or 0
        
        -- Handle special cases for TargetRadius strings
        if Ext.Stats.Get(a).TargetRadius == "RangedMainWeaponRange" then
            radiusA = 9
        elseif Ext.Stats.Get(a).TargetRadius == "MeleeMainWeaponRange" then
            radiusA = 2
        end
        
        if Ext.Stats.Get(b).TargetRadius == "RangedMainWeaponRange" then
            radiusB = 9
        elseif Ext.Stats.Get(b).TargetRadius == "MeleeMainWeaponRange" then
            radiusB = 2
        end
        
        return radiusA > radiusB
    end)
    
    if #selectedSpells > 0 then
        return selectedSpells
    else
        _D("No spells left for NPC: " .. GetDisplayName(uuid) .. ". Clearing cast history and retrying.")
        castSpellHistory[casterId] = {}
        npcSpellCategories.Spells = {}
        for spellID, spellDetails in pairs(npcSpellCategories.originalSpells) do
            if not npcSpellCategories.excludedWildshapeSpells[spellID] then
                npcSpellCategories.Spells[spellID] = spellDetails
            end
        end
        return GetAction(uuid, npcSpellCategories)
    end
end

local function SelectTargetForSpell(caster, spellCategory)
    if spellCategory == "attack" or spellCategory == "debuff" or spellCategory == "offense_magic" then
        return FindNearestEnemy(caster)
    elseif spellCategory == "self_buff" or spellCategory == "physical_buff" or spellCategory == "summoning" or spellCategory == "wildshape" then
        return caster
    elseif spellCategory == "healing" then
        return FindLowestHPAlly(caster)
    else
        return FindNearestEnemy(caster)
    end
end

function differentialpath(entity, target, distance)
    if not distance then
        _D("differentialpath called with nil distance for entity: " .. GetDisplayName(entity))
        return nil
    end

    local moverX, moverY, moverZ = Osi.GetPosition(entity)
    local targetX, targetY, targetZ = Osi.GetPosition(target)

    if not (moverX and moverY and moverZ and targetX and targetY and targetZ) then
        _D("differentialpath received invalid positions. Entity: " .. GetDisplayName(entity) .. ", Target: " .. tostring(target))
        return nil
    end

    local dx = moverX - targetX
    local dy = moverY - targetY
    local dz = moverZ - targetZ
    local totalDistance = math.sqrt(dx*dx + dy*dy + dz*dz)

    if not totalDistance then
        _D("differentialpath calculated totalDistance as nil for entity: " .. GetDisplayName(entity) .. " and target: " .. GetDisplayName(target))
        return nil
    end

    if totalDistance <= distance then
        -- Already within desired distance, do not move
        return nil
    end
    if totalDistance == 0 then
        -- Entity is exactly on the target's position, do not move
        return nil
    end

    local fracDistance = distance / totalDistance
    local newX = targetX + dx * fracDistance
    local newY = targetY + dy * fracDistance
    local newZ = targetZ + dz * fracDistance
    return newX, newY, newZ
end


function partialmovement(entity, target, distance)
    if not target then
        _D("partialmovement called with nil target for entity: " .. GetDisplayName(entity))
        return
    end

    local x, y, z = differentialpath(entity, target, distance)
    
    if x and y and z then
        local validX, validY, validZ = Osi.FindValidPosition(x, y, z, 1, entity, 0)
        if validX and validY and validZ then
            Osi.CharacterMoveToPosition(entity, validX, validY, validZ, "Run", "")
        else
            _D("Valid position not found for entity: " .. GetDisplayName(entity) .. ". Moving directly to target.")
            Osi.CharacterMoveTo(entity, target, "Run", "")
        end
    else
        -- Do not move, already within desired distance or differentialpath failed
        _D("Entity " .. GetDisplayName(entity) .. " is already within desired distance to target or differentialpath failed.")
    end
end

function UseFallbackAttack(caster, target)
    local casterId = GetCharacterId(caster)
    local npcSpellCategories = NPCSpellTable[casterId]
    
    if not target then
        _D("UseFallbackAttack called with nil target for caster: " .. GetDisplayName(casterId))
        return
    end

    -- Determine which fallback attack to use
    local fallbackSpell = "Target_MainHandAttack" -- Default melee attack
    if npcSpellCategories and npcSpellCategories.Spells["Projectile_MainHandAttack"] then
        fallbackSpell = "Projectile_MainHandAttack"
    end

    -- Use the determined fallback spell
    UseSpell(caster, fallbackSpell, target)
end


local function PositionUpdater()
    if not PURunning then
        return
    end
    if IsTurnBased then
        Ext.Timer.WaitFor(2000, PositionUpdater)
        return
    end

    -- Combine Party, Allies, and Enemies into a single table
    local allCombatants = {}
    for uuid in pairs(Party) do
        allCombatants[uuid] = true
    end
    for uuid in pairs(Allies) do
        allCombatants[uuid] = true
    end
    for uuid in pairs(Enemies) do
        allCombatants[uuid] = true
    end

    -- Iterate through each NPC in combat
    for uuid in pairs(allCombatants) do
        if IsDead(uuid) == 0 and GetCharacterId(uuid) ~= GetCharacterId(GetHostCharacter()) then
            _D("Processing NPC: " .. GetDisplayName(uuid))

            -- Get NPC's spell categories and available actions
            local npcSpellCategories = NPCSpellTable[uuid] or GetNPCSpells(uuid)
            NPCSpellTable[uuid] = npcSpellCategories
            local availableSpells = GetAction(uuid, npcSpellCategories)

            -- If no spells are available, continue to the next NPC
            if #availableSpells == 0 then
                _D("No spells available for NPC: " .. GetDisplayName(uuid))
                goto continue
            end

            -- Initialize spell usage data for the NPC
            spellUsageCounter[uuid] = spellUsageCounter[uuid] or {}
            local charData = spellUsageCounter[uuid]
            _D("Spell Usage Counter for " .. GetDisplayName(uuid) .. ": " .. Ext.Json.Stringify(charData))

            -- Check if cooldown is nil or <= 0
            if not charData.cooldown or charData.cooldown <= 0 then
                _D("Cooldown expired or not set for " .. GetDisplayName(uuid) .. ". Selecting new spell and target.")
                -- Select a spell
                local selectedSpell = availableSpells[1] -- Select the first available spell
                charData.selectedSpell = selectedSpell
                -- Select target based on spell category
                local selectedTarget = SelectTargetForSpell(uuid, npcSpellCategories.Spells[selectedSpell].Category)
                charData.selectedTarget = selectedTarget

                -- Cast the spell if within range
                local spellData = Ext.Stats.Get(selectedSpell)
                local targetRadius = tonumber(spellData.TargetRadius) or 0
                if spellData.TargetRadius == "MeleeMainWeaponRange" then
                    targetRadius = 2
                elseif spellData.TargetRadius == "RangedMainWeaponRange" then
                    targetRadius = 9
                end
                local targetPos = { Osi.GetPosition(selectedTarget) }
                local npcPos = { Osi.GetPosition(uuid) }
                local distance = Ext.Math.Distance(npcPos, targetPos)
                _D("Distance from " .. GetDisplayName(uuid) .. " to target is: " .. tostring(distance))

                if distance <= targetRadius + 0.6 then
                    -- Within range, cast the spell
                    _D(GetDisplayName(uuid) .. " is casting spell: " .. selectedSpell)
                    Osi.PurgeOsirisQueue(uuid, 1)
                    Osi.FlushOsirisQueue(uuid)
                    UseSpell(uuid, selectedSpell, selectedTarget)
                    -- Set cooldown to 6 seconds
                    charData.cooldown = 6
                    -- Reset spellCasted flag
                    charData.spellCasted = false
                    -- Start a timer to check if spell was cast
                    Ext.Timer.WaitFor(3000, function()
                        if not charData.spellCasted then
                            _D(GetDisplayName(uuid) .. " failed to cast spell, using fallback attack.")
                            UseFallbackAttack(uuid, selectedTarget)
                        end
                    end)
                else
                    -- Not within range, reset cooldown to 2 seconds
                    charData.cooldown = 2
                end
            else
                -- Decrement cooldown
                charData.cooldown = charData.cooldown - 2
                if charData.cooldown < 0 then
                    charData.cooldown = 0
                end
                _D("Cooldown for " .. GetDisplayName(uuid) .. " is now: " .. tostring(charData.cooldown))

                -- Move towards target
                local currentTarget = charData.selectedTarget
                local selectedSpell = charData.selectedSpell

                if selectedSpell then
                    -- Find the closest target based on the spell category
                    local newTarget = SelectTargetForSpell(uuid, npcSpellCategories.Spells[selectedSpell].Category)
                    if newTarget and newTarget ~= currentTarget then
                        _D(GetDisplayName(uuid) .. " switching target to " .. GetDisplayName(newTarget))
                        charData.selectedTarget = newTarget
                        currentTarget = newTarget
                    end

                    -- Get positions and distance
                    local targetPos = { Osi.GetPosition(currentTarget) }
                    local npcPos = { Osi.GetPosition(uuid) }
                    local distance = Ext.Math.Distance(npcPos, targetPos)
                    _D("Distance from " .. GetDisplayName(uuid) .. " to target is: " .. tostring(distance))

                    -- Check if the character is moving closer to the target
                    if charData.lastDistance and distance >= charData.lastDistance then
                                                -- Not moving closer, use fallback attack with UseSpell
                        _D(GetDisplayName(uuid) .. " is not moving closer to target, using fallback attack.")
                        UseFallbackAttack(uuid, currentTarget)

                    else
                        -- Move towards target
                        partialmovement(uuid, currentTarget, targetRadius)
                    end
                    -- Update lastDistance
                    charData.lastDistance = distance
                else
                    _D("No selected spell for " .. GetDisplayName(uuid))
                end
            end
        end
        ::continue::
    end

    Ext.Timer.WaitFor(2000, PositionUpdater)
end


local function RegenerateMana()
    for charGuid, manaPool in pairs(characterManaPools) do
        if IsDead(charGuid) == 0 then
            if manaPool.currentMana <= manaPool.totalMana then
                local regenAmount
                if IsTurnBased and IsInCombat(GetHostCharacter()) == 1 then
                    regenAmount = math.ceil(manaPool.totalMana * 0.005)
                else
                    regenAmount = math.ceil(manaPool.totalMana * 0.025)
                end
                manaPool.currentMana = math.min(manaPool.currentMana + regenAmount, manaPool.totalMana)
                local character = Ext.Entity.Get(charGuid)
                if character then
                    SendManaPoolToClient(character)
                    if charGuid == Osi.GetHostCharacter() then
                        Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "UpdateManaPool", Ext.Json.Stringify({
                            Character = charGuid,
                            CurrentMana = manaPool.currentMana,
                            TotalMana = manaPool.totalMana
                        }))
                    end
                end
            end
        end
    end
    Ext.Timer.WaitFor(1000, RegenerateMana)
end
local function StartManaRegeneration()
    if not isRegeneratingMana then
        isRegeneratingMana = true
        RegenerateMana()
    end
end
Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(character)
    local charGuid = Ext.Entity.Get(character).Uuid.EntityUuid
    if not characterManaPools[charGuid] then
        local totalMana = CalculateMana(Ext.Entity.Get(character))
        characterManaPools[charGuid] = {
            totalMana = totalMana,
            currentMana = totalMana
        }
        SendManaPoolToClient(Ext.Entity.Get(character))
    end
    Party[charGuid] = true
end)


Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combatGuid)
    local hostCharacter = Osi.GetHostCharacter()

    -- Only set CanJoinCombat to 0 if it's not turn-based
    if not IsTurnBased then
        Ext.Timer.WaitFor(1000, function()
            Osi.SetCanJoinCombat(hostCharacter, 0)
        end)
        _D("Combat has started. Set CanJoinCombat to 0 for host character.")
    else
        _D("Combat started in turn-based mode, skipping CanJoinCombat adjustments.")
    end

    if not PURunning then
        PURunning = true
        Ext.Timer.WaitFor(1000, PositionUpdater)
    end
end)

Ext.Osiris.RegisterListener("GainedControl", 1, "after", function(newController)
    -- Only proceed if it's not turn-based and combat has started
    Osi.PurgeOsirisQueue(newController, 1)
    Osi.FlushOsirisQueue(newController)
    if not IsTurnBased and PURunning then
        -- Check if there's more than one alive party member
        if CountAlivePartyMembers() > 1 then
            -- Set CanJoinCombat = 1 for all other party members
            for partyUUID, _ in pairs(Party) do
                if partyUUID ~= newController then
                    Osi.SetCanJoinCombat(partyUUID, 1)
                end
            end

            -- Set CanJoinCombat = 0 for the new controller
            Osi.SetCanJoinCombat(newController, 0)

        else
            _D("Only one alive party member. Skipping CanJoinCombat adjustments.")
        end
    else
        _D("Skipped CanJoinCombat update as Turn-Based mode is active or Combat has not started.")
    end

    -- If the new controller has a mana pool, send it to the client
    if characterManaPools[newController] then
        local character = Ext.Entity.Get(newController)
        if character then
            SendManaPoolToClient(character)
        end
    end

    -- Notify the client about the gained control
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "GainedControl", Ext.Json.Stringify({ Character = newController }))
end)

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(levelName, isEditorMode)
    if levelName ~= "SYS_CC_I" then
        local partyMembers = Ext.Entity.GetAllEntitiesWithComponent("PartyMember")
        for _, character in ipairs(partyMembers) do
            local uuid = GetCharacterId(character.Uuid.EntityUuid)
            if not Party[uuid] then
                Party[uuid] = true
                _D("Added PartyMember to Party: " .. GetDisplayName(uuid) .. " (UUID: " .. uuid .. ")")
            else
                _D("PartyMember already in Party: " .. GetDisplayName(uuid) .. " (UUID: " .. uuid .. ")")
            end
            if not characterManaPools[uuid] then
                local totalMana = CalculateMana(character)
                characterManaPools[uuid] = {
                    totalMana = totalMana,
                    currentMana = totalMana
                }
                SendManaPoolToClient(character)
            end
        end
        StartManaRegeneration()
        Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "GainedControl", Ext.Json.Stringify({ Character = Osi.GetHostCharacter() }))
        Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "OpenWindow", "{}")
        Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "OpenManaUI", "{}")
        Ext.Utils.GetGlobalSwitches().GameCameraEnableAttackCameraOtherPlayers = false
        Ext.Utils.GetGlobalSwitches().GameCameraEnableAttackCamera = false
        DisengageTB()
        SetCanJoinCombatForAll(1)
    end
end)
Ext.Osiris.RegisterListener("CastedSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    local casterId = GetCharacterId(caster)
    castSpellHistory[casterId] = castSpellHistory[casterId] or {}
    table.insert(castSpellHistory[casterId], spell)
    if not IsTurnBased and characterManaPools[casterId] then
        local character = Ext.Entity.Get(casterId)
        if character then
            local manaCost = GetManaCost(character, spell)
            characterManaPools[casterId].currentMana = math.max(characterManaPools[casterId].currentMana - manaCost, 0)
            SendManaPoolToClient(character)
        end
    end
    -- Mark that the spell has been cast
    if spellUsageCounter[casterId] then
        spellUsageCounter[casterId].spellCasted = true
    end
    _D("CastedSpell event: " .. GetDisplayName(casterId) .. " casted " .. spell)
end)


Ext.Osiris.RegisterListener("Dying", 1, "after", function(character)
    local uuid = Ext.Entity.Get(character).Uuid.EntityUuid

    -- Remove the dead character from all relevant tables
    Enemies[uuid] = nil
    Allies[uuid] = nil
    Party[uuid]  = nil

    -- Check if there are no more enemies
    if next(Enemies) == nil then
        HandleCombatEnded()
    end

    if not IsTurnBased and CountAlivePartyMembers() == 1 then
        _D("Only one party member alive in real-time combat. Setting CanJoinCombat to 0 for all characters.")
        SetCanJoinCombatForAll(0)
    end

    -- Ensure the dead character lies on the ground after 3 seconds
    Ext.Timer.WaitFor(3000, function()
        Osi.LieOnGround(uuid)
    end)
end)


Ext.RegisterNetListener("RequestHostCharacter", function(channel, payload)
    local hostCharacterGuid = Osi.GetHostCharacter()
    if hostCharacterGuid then
        Ext.Net.PostMessageToClient(hostCharacterGuid, "SendHostCharacter", Ext.Json.Stringify({Character = hostCharacterGuid}))
    end
end)
Ext.RegisterNetListener("RequestSpellExecution", function(channel, payload)
    local data = Ext.Json.Parse(payload)
    local character = GetHostCharacter()
    if character then
        TryExecuteSpellAtPositionOrCharacter(character, data.spellID, data.position)
    end
end)
Ext.RegisterNetListener("PurgeOsirisQueue", function(channel,payload)
    Osi.PurgeOsirisQueue(Osi.GetHostCharacter(),1)
    Osi.FlushOsirisQueue(Osi.GetHostCharacter())
end)
Ext.RegisterNetListener("ToggleTurnBased", function(channel, payload)
    IsTurnBased = not IsTurnBased

    local hostCharacter = GetHostCharacter()
    if IsTurnBased then
        SetCanJoinCombatForAll(1)
        PURunning = false
        _D("Switched to Turn-Based Combat.")
        Ext.Net.PostMessageToClient(hostCharacter, "CloseManaUI", "{}")
        Ext.Net.PostMessageToClient(hostCharacter, "CloseWindow", "{}")
    else
        if CountAlivePartyMembers() == 1 then
            SetCanJoinCombatForAll(0)
        else
            Osi.SetCanJoinCombat(hostCharacter, 0)
        end
        if next(Enemies) ~= nil then
            PURunning = true
            Ext.Timer.WaitFor(1000, PositionUpdater)
            _D("Switched to Real-Time Combat.")
        else
            PURunning = false
            _D("Switched to Real-Time Combat. No Enemies so no updating positions.")
        end
        Ext.Net.PostMessageToClient(hostCharacter, "OpenManaUI", "{}")
        Ext.Net.PostMessageToClient(hostCharacter, "OpenWindow", "{}")
    end
end)

Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(object, status, causee, storyActionID)
    if status == "DASH" then
        local entity = Ext.Entity.Get(object)
        if entity and entity.ServerCharacter and entity.ServerCharacter.Template then
            entity.ServerCharacter.Template.MovementSpeedRun = 6
        end
    end
    local uuid = GetCharacterId(object)
    local knockOutStatuses = {
        "DOWNED",
        "KNOCKED_OUT",
        "KNOCKED_OUT_TEMPORARILY",
        "KNOCKED_OUT_PERMANENTLY"
    }
    for _, koStatus in ipairs(knockOutStatuses) do
        if status == koStatus then
            Enemies[uuid] = nil
            Allies[uuid] = nil
            Party[uuid] = nil
            if next(Enemies) == nil then
                HandleCombatEnded()
            end
            if not IsTurnBased and CountAlivePartyMembers() == 1 then
                _D("Only one party member alive in real-time combat. Setting CanJoinCombat to 0 for all characters.")
                SetCanJoinCombatForAll(0)
            end
        end
    end
end)
Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(object, status, causee, applyStoryActionID)
    if status == "DASH" then
        local entity = Ext.Entity.Get(object)
        if entity and entity.ServerCharacter and entity.ServerCharacter.Template then
            entity.ServerCharacter.Template.MovementSpeedRun = 3.75
        end
    end
end)

Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(character, combatGuid)
    if IsCharacter(character) == 1 and IsDead(character) == 0 and HasActiveStatus(character,"KNOCKED_OUT") == 0 then
        local uuid = GetCharacterId(character)
        local hostCharacter = GetHostCharacter()
        local hostUuid = GetCharacterId(hostCharacter)
        if not Party[hostUuid] then
            Party[hostUuid] = true
            _D("Manually added host character to Party: " .. GetDisplayName(hostCharacter))
        end
        if Party[uuid] and not NPCSpellTable[uuid] then
            local characterSpells = GetNPCSpells(character)
            NPCSpellTable[uuid] = characterSpells
        end
        if IsPartyMember(uuid, 1) == 1 then
            if not Party[uuid] then
                Party[uuid] = true
                _D("Added to Party: " .. GetDisplayName(uuid))
            end
        elseif IsEnemyWithParty(uuid) or HasActiveStatus(uuid,"TEMPORARILY_HOSTILE") == 1 then
            if not Enemies[uuid] then
                Enemies[uuid] = true
                _D("Added to Enemies: " .. GetDisplayName(uuid))
            end
        else
            if not Allies[uuid] then
                Allies[uuid] = true
                _D("Added to Allies: " .. GetDisplayName(uuid))
            end
        end
    end
end)

Ext.Osiris.RegisterListener("LevelUnloading", 1, "after", function(level)
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseWindow", "{}")
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseManaUI", "{}")
end)
Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(dialog, instanceID)
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseWindow", "{}")
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseManaUI", "{}")
end)
Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(dialog, instanceID)
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "OpenWindow", "{}")
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "OpenManaUI", "{}")
end)
Ext.Osiris.RegisterListener("LeftLevel", 2, "after", function(object, level)
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseWindow", "{}")
    Ext.Net.PostMessageToClient(Osi.GetHostCharacter(), "CloseManaUI", "{}")
end)
Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
    local charGuid = Ext.Entity.Get(character).Uuid.EntityUuid
    if characterManaPools[charGuid] then
        local totalMana = CalculateMana(Ext.Entity.Get(character))
        characterManaPools[charGuid].totalMana = totalMana
        characterManaPools[charGuid].currentMana = totalMana
        SendManaPoolToClient(Ext.Entity.Get(character))
    end
end)
Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(combatGuid)
    _D("Combat ended!")

    -- If the Enemies table is empty, handle combat end
    if next(Enemies) == nil then
        _D("Enemies table is empty. Handling combat end immediately.")
        HandleCombatEnded()
    else
        _D("Enemies remain. Combat will not end until all enemies are defeated.")
    end
end)
