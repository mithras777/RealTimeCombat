Ext.Require("RealTimeCombat/Server/Tables.lua")
local Settings = {
    ToggleKey = "NUM_0",
    TBToggleKey = "R",
    ManaToggleKey = "E"
}
local displayKeyMapping = {
    ["NUM_1"] = "1",
    ["NUM_2"] = "2",
    ["NUM_3"] = "3",
    ["NUM_4"] = "4",
    ["NUM_5"] = "5",
    ["NUM_6"] = "6",
    ["NUM_7"] = "7",
    ["NUM_8"] = "8",
    ["NUM_9"] = "9",
    ["NUM_0"] = "0",
}
local clientManaPools = {}
local characterHotkeyBindings = {}
local lastHostCharacter = nil
local hotkeyOptions = {
    " ",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
    "A", "S", "D", "F", "G", "H", "J", "K", "L",
    "Z", "X", "C", "V", "B", "N", "M",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
}
local function SaveHotkeyBindings()
    local dataToSave = {
        Hotkeys = characterHotkeyBindings,
        ToggleKey = Settings.ToggleKey,
        ManaToggleKey = Settings.ManaToggleKey,
        TBToggleKey = Settings.TBToggleKey
    }
    local bindingsJson = Ext.Json.Stringify(dataToSave)
    local success = Ext.IO.SaveFile("hotkeyBindings.json", bindingsJson)
end
local function LoadHotkeyBindings()
    local bindingsJson = Ext.IO.LoadFile("hotkeyBindings.json")
    if bindingsJson then
        local loadedData = Ext.Json.Parse(bindingsJson) or {}
        characterHotkeyBindings = loadedData.Hotkeys or {}
        Settings.ToggleKey = loadedData.ToggleKey or Settings.ToggleKey
        Settings.ManaToggleKey = loadedData.ManaToggleKey or "E"
        Settings.TBToggleKey = loadedData.TBToggleKey or "R"
        Ext.Utils.Print("Hotkey bindings and toggle keys loaded successfully.")
    else
        Ext.Utils.PrintWarning("Unable to load hotkey bindings and toggle keys, starting with default values.")
        characterHotkeyBindings = {}
        Settings.ManaToggleKey = "E"
        Settings.TBToggleKey = "R"
    end
end
LoadHotkeyBindings()
local function ClearWindow(window)
    for _, child in ipairs(window.Children) do
        if child ~= toggleKeyCombo then
            window:RemoveChild(child)
        end
    end
end
local toggleKeyCombo = nil
juice_window = Ext.IMGUI.NewWindow("Juice Window")
juice_window.NoTitleBar = true
juice_window.Closeable = false
juice_window.Open = false
juice_window.NoBackground = false
juice_window.NoResize = true
juice_window.NoMove = true
juice_window.NoScrollbar = true
juice_window:SetSize({230, 230})
juice_window:SetPos({1625, 850})
juice = juice_window:AddImage("Icon_Juice", {230, 230})
juice.Tint = {0.5, 0, 0.5, 1}
local grey_juice_window = Ext.IMGUI.NewWindow("Grey Juice Window")
grey_juice_window.NoTitleBar = true
grey_juice_window.Closeable = false
grey_juice_window.Open = false
grey_juice_window.NoBackground = true
grey_juice_window.NoResize = true
grey_juice_window.NoMove = true
grey_juice_window.NoScrollbar = true
grey_juice_window:SetSize({230, 230})
grey_juice_window:SetPos({1625, 850})
local grey_juice = grey_juice_window:AddImage("Icon_Juice", {230, 230})
grey_juice.Tint = {0, 0, 0, 1}
orb_window = Ext.IMGUI.NewWindow("Orb Window")
orb_window.NoTitleBar = true
orb_window.Closeable = false
orb_window.Open = false
orb_window.NoBackground = true
orb_window.NoResize = true
orb_window.NoMove = true
orb_window.NoScrollbar = true
orb_window:SetSize({240, 230})
orb_window:SetPos({1625, 850})
orb_window:AddImage("Icon_Orb", {230, 230})
text_window = Ext.IMGUI.NewWindow("Text Window")
text_window.NoTitleBar = true
text_window.Closeable = false
text_window.Open = false
text_window.NoBackground = true
text_window.NoResize = true
text_window.NoMove = true
text_window.NoScrollbar = true
text_window:SetSize({100, 30})
text_window:SetPos({1715, 960})
text_window:AddText("100/100")
local window = Ext.IMGUI.NewWindow("QuickCast")
window:SetSize({ 180, 484 })
window:SetPos({ 1740, 370 })
window.Closeable = false
window.NoFocusOnAppearing = true
window.Open = false
window.NoTitleBar = false
window.AlwaysVerticalScrollbar = true
local function open()
    window.Visible = true
    window.Open = true
end
local function close()
    window.Visible = false
    window.Open = false
end
local function toggle()
    if window.Open and window.Visible then
        close()
    else
        open()
    end
end
function tableContains(tbl, element)
    for _, value in pairs(tbl) do
        if value == element then
            return true
        end
    end
    return false
end
local function OpenManaUI()
    juice_window.Open = true
    grey_juice_window.Open = true
    orb_window.Open = true
    text_window.Open = true
end
local function CloseManaUI()
    juice_window.Open = false
    grey_juice_window.Open = false
    orb_window.Open = false
    text_window.Open = false
end
local function GetHost()
    for _, entity in pairs(Ext.Entity.GetAllEntitiesWithComponent("ClientControl")) do
        if entity.UserReservedFor.UserID == 1 then
            return entity
        end
    end
    return nil
end
local function UpdateManaText(character)
    local charGuid = character.Uuid.EntityUuid
    local manaPool = clientManaPools[charGuid]
    if manaPool then
        local manaText = string.format("%d/%d", math.floor(manaPool.currentMana), math.floor(manaPool.totalMana))
        ClearWindow(text_window)
        text_window:AddText(manaText)
        local manaPercentage = manaPool.currentMana / manaPool.totalMana
        local greyJuiceHeight = 230 * (1 - manaPercentage)
        grey_juice.ImageData.Size = {230, greyJuiceHeight}
    end
end
Ext.RegisterNetListener("UpdateManaPool", function(channel, payload)
    local data = Ext.Json.Parse(payload)
    local charGuid = data.Character
    clientManaPools[charGuid] = {
        totalMana = data.TotalMana,
        currentMana = data.CurrentMana
    }
    local hostCharacter = GetHost()
    if hostCharacter and hostCharacter.Uuid.EntityUuid == charGuid then
        UpdateManaText(hostCharacter)
    end
end)
local function populateCombo(combobox, data)
    combobox.Options = {}
    for i, entry in ipairs(data) do
        combobox.Options[i] = displayKeyMapping[entry] or entry
    end
end
local function GetDisplayName(guid)
    local entity = Ext.Entity.Get(guid)
    if entity and entity.DisplayName and entity.DisplayName.NameKey and entity.DisplayName.NameKey.Handle then
        return Ext.Loca.GetTranslatedString(entity.DisplayName.NameKey.Handle.Handle)
    end
    return guid
end
local function GetCharacterSpells(character)
    local spells = {}
    local spellbook = character.SpellBook.Spells
    for _, spell in ipairs(spellbook) do
        local spellID = spell.Id.OriginatorPrototype
        local spellDisplayNameHandle = Ext.Stats.Get(spellID).DisplayName
        local spellDisplayName = Ext.Loca.GetTranslatedString(spellDisplayNameHandle)
        if not string.match(spellDisplayName, "^Disguise Self")
        and not string.match(spellDisplayName, "Astral Knowledge")
        and not string.match(spellDisplayName, "Improvised Melee Weapon")
        and not string.match(spellDisplayName, "Throw")
        and not string.match(spellDisplayName, "Disengage")
        and not string.match(spellDisplayName, "Hide")
        and not string.match(spellDisplayName, "Help") then
            table.insert(spells, spellID)
        end
    end
    return spells
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
local function BindHotkeyToSpell(character, hotkey, spellID)
    local charGuid = character.Uuid.EntityUuid
    if not characterHotkeyBindings[charGuid] then
        characterHotkeyBindings[charGuid] = {}
    end
    if hotkey and hotkey ~= " " then
        for key, existingSpellID in pairs(characterHotkeyBindings[charGuid]) do
            if key == hotkey then
                characterHotkeyBindings[charGuid][key] = nil
                break
            end
        end
        for key, existingSpellID in pairs(characterHotkeyBindings[charGuid]) do
            if existingSpellID == spellID then
                characterHotkeyBindings[charGuid][key] = nil
                break
            end
        end
        characterHotkeyBindings[charGuid][hotkey] = spellID
    end
    SaveHotkeyBindings()
end
local function PopulateComboWithSpells(character)
    if lastHostCharacter ~= character then
        ClearWindow(window)
        if clientManaPools[charGuid] then
            UpdateManaText(character)
        end
        lastHostCharacter = character
        window:AddText("Menu Key")
        toggleKeyCombo = window:AddCombo("", Settings.ToggleKey)
        toggleKeyCombo.SameLine = true
        toggleKeyCombo.ItemWidth = 60
        populateCombo(toggleKeyCombo, hotkeyOptions)
        local selectedToggleKeyDisplay = displayKeyMapping[Settings.ToggleKey] or Settings.ToggleKey
        for i, key in ipairs(hotkeyOptions) do
            if key == selectedToggleKeyDisplay then
                toggleKeyCombo.SelectedIndex = i - 1
                break
            end
        end
        toggleKeyCombo.OnChange = function()
            local selectedToggleKeyIndex = toggleKeyCombo.SelectedIndex + 1
            if selectedToggleKeyIndex and selectedToggleKeyIndex > 0 and selectedToggleKeyIndex <= #toggleKeyCombo.Options then
                local selectedDisplayKey = toggleKeyCombo.Options[selectedToggleKeyIndex]
                local mappedKey = nil
                for key, displayKey in pairs(displayKeyMapping) do
                    if displayKey == selectedDisplayKey then
                        mappedKey = key
                        break
                    end
                end
                Settings.ToggleKey = mappedKey or selectedDisplayKey
                SaveHotkeyBindings()
            end
        end
        window:AddSeparator()
        window:AddText("Turn-Based")
        local tbToggleKeyCombo = window:AddCombo("", Settings.TBToggleKey)
        tbToggleKeyCombo.SameLine = true
        tbToggleKeyCombo.ItemWidth = 60
        populateCombo(tbToggleKeyCombo, hotkeyOptions)
        local tbToggleKey = Settings.TBToggleKey or "R"
        for i, key in ipairs(hotkeyOptions) do
            local displayKey = displayKeyMapping[key] or key
            if displayKey == tbToggleKey then
                tbToggleKeyCombo.SelectedIndex = i - 1
                break
            end
        end
        tbToggleKeyCombo.OnChange = function()
            local selectedHotkeyIndex = tbToggleKeyCombo.SelectedIndex + 1
            if selectedHotkeyIndex and selectedHotkeyIndex > 0 and selectedHotkeyIndex <= #tbToggleKeyCombo.Options then
                local selectedHotkey = tbToggleKeyCombo.Options[selectedHotkeyIndex]
                local mappedKey = nil
                for key, displayKey in pairs(displayKeyMapping) do
                    if displayKey == selectedHotkey then
                        mappedKey = key
                        break
                    end
                end
                Settings.TBToggleKey = mappedKey or selectedHotkey
                SaveHotkeyBindings()
            end
        end
        window:AddSeparator()
        window:AddText("Mana UI Toggle")
        local manaToggleKeyCombo = window:AddCombo("", Settings.ManaToggleKey)
        manaToggleKeyCombo.SameLine = true
        manaToggleKeyCombo.ItemWidth = 60
        populateCombo(manaToggleKeyCombo, hotkeyOptions)
        local manaToggleKey = Settings.ManaToggleKey or "E"
        for i, key in ipairs(hotkeyOptions) do
            local displayKey = displayKeyMapping[key] or key
            if displayKey == manaToggleKey then
                manaToggleKeyCombo.SelectedIndex = i - 1
                break
            end
        end
        manaToggleKeyCombo.OnChange = function()
            local selectedHotkeyIndex = manaToggleKeyCombo.SelectedIndex + 1
            if selectedHotkeyIndex and selectedHotkeyIndex > 0 and selectedHotkeyIndex <= #manaToggleKeyCombo.Options then
                local selectedHotkey = manaToggleKeyCombo.Options[selectedHotkeyIndex]
                local mappedKey = nil
                for key, displayKey in pairs(displayKeyMapping) do
                    if displayKey == selectedHotkey then
                        mappedKey = key
                        break
                    end
                end
                Settings.ManaToggleKey = mappedKey or selectedHotkey
                SaveHotkeyBindings()
            end
        end
        window:AddSeparator()
        local charGuid = character.Uuid.EntityUuid
        local savedBindings = characterHotkeyBindings[charGuid] or {}
        local spells = GetCharacterSpells(character)
        local spellOptions = {}
        for i, spellID in ipairs(spells) do
            local spellDisplayNameHandle = Ext.Stats.Get(spellID).DisplayName
            local spellDisplayName = Ext.Loca.GetTranslatedString(spellDisplayNameHandle)
            local spellIcon = Ext.Stats.Get(spellID).Icon
            local manaCost = GetManaCost(character, spellID)
            if spellDisplayName and spellDisplayName ~= "" then
                window:AddText(spellDisplayName)
                window:AddImage(spellIcon, {40, 40})
                local selectedHotkey = nil
                for hotkey, savedSpellID in pairs(savedBindings) do
                    if savedSpellID == spellID then
                        selectedHotkey = hotkey
                        break
                    end
                end
                if not selectedHotkey then
                    selectedHotkey = "None"
                end
                local hotkeyCombo = window:AddCombo("", 0, { Small = true })
                hotkeyCombo.ItemWidth = 60
                hotkeyCombo.SameLine = true
                populateCombo(hotkeyCombo, hotkeyOptions)
                for i, key in ipairs(hotkeyOptions) do
                    if key == selectedHotkey then
                        hotkeyCombo.SelectedIndex = i - 1
                        break
                    end
                end
                hotkeyCombo.OnChange = function()
                    local selectedHotkeyIndex = hotkeyCombo.SelectedIndex + 1
                    if selectedHotkeyIndex and selectedHotkeyIndex > 0 and selectedHotkeyIndex <= #hotkeyCombo.Options then
                        local selectedHotkey = hotkeyCombo.Options[selectedHotkeyIndex]
                        local selectedSpellID = spellID
                        if selectedHotkey == "None" then
                            for key, boundSpellID in pairs(characterHotkeyBindings[charGuid] or {}) do
                                if boundSpellID == selectedSpellID then
                                    characterHotkeyBindings[charGuid][key] = nil
                                    break
                                end
                            end
                            SaveHotkeyBindings()
                            PopulateComboWithSpells(character)
                        else
                            if savedBindings[selectedHotkey] and savedBindings[selectedHotkey] ~= selectedSpellID then
                                for key, boundSpellID in pairs(savedBindings) do
                                    if boundSpellID == selectedSpellID then
                                        characterHotkeyBindings[charGuid][key] = nil
                                        break
                                    end
                                end
                            end
                            BindHotkeyToSpell(character, selectedHotkey, selectedSpellID)
                        end
                    end
                end
                local manaCostText = string.format("%d", math.ceil(manaCost))
                local manaCostLabel = window:AddText(manaCostText)
                manaCostLabel.SameLine = true
                manaCostLabel.ItemWidth = 80
                local manaIcon = window:AddImage("Icon_Juice", {20, 20})
                manaIcon.SameLine = true
                window:AddSeparator()
                table.insert(spellOptions, spellDisplayName)
            end
        end
        local resetButton = window:AddButton("Reset Hotkeys")
        resetButton.MouseButtonLeft = true
        resetButton.MouseButtonMiddle = false
        resetButton.MouseButtonRight = false
        resetButton.Size = {100, 30}
        resetButton.SameLine = false
        resetButton.OnClick = function()
            if characterHotkeyBindings[charGuid] then
                characterHotkeyBindings[charGuid] = nil
                SaveHotkeyBindings()
                Ext.Utils.Print("Hotkeys reset for character: " .. GetDisplayName(charGuid))
                PopulateComboWithSpells(character)
            else
                Ext.Utils.Print("No hotkeys to reset for character: " .. GetDisplayName(charGuid))
            end
        end
    end
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
local function RequestSpellExecution(spellID)
    local picker = Ext.UI.GetPickingHelper(1)
    if picker.Inner ~= nil and picker.Inner.Position ~= nil then
        local targetPosition = picker.Inner.Position
        if IsValidPosition(targetPosition) then
            Ext.ClientNet.PostMessageToServer("RequestSpellExecution", Ext.Json.Stringify({ spellID = spellID, position = targetPosition }))
        end
    end
end
local function ApplyNoCameraMove()
    for i,name in ipairs(Ext.Stats.GetStats("SpellData")) do
        local spell = Ext.Stats.Get(name)
        local flags = spell.SpellFlags
        table.insert(flags,"NoCameraMove")
        spell.SpellFlags = flags
    end
end
local function IncreaseJumpDistance()
    local jumpProjectile = Ext.Stats.Get("Projectile_Jump")
    if jumpProjectile then
        jumpProjectile.TargetRadius = "20.0"
        Ext.Utils.Print("RTS: Jump distance increased to 20.")
    end
end
local function ApplyNoConcentration()
    for i,name in ipairs(Ext.Stats.GetStats("SpellData")) do
        local spell = Ext.Stats.Get(name)
        local flags = spell.SpellFlags
         for j = #flags, 1, -1 do
            if flags[j] == "IsConcentration" then
                table.remove(flags, j)
            end
        end
        spell.SpellFlags = flags
    end
end
Ext.Events.StatsLoaded:Subscribe(function()
    IncreaseJumpDistance()
    ApplyNoCameraMove()
    ApplyNoConcentration()
end)
Ext.RegisterNetListener("SendHostCharacter", function(channel, payload)
    local data = Ext.Json.Parse(payload)
    local hostCharacter = Ext.Entity.Get(data.Character)
    if hostCharacter and hostCharacter.Level and hostCharacter.Level.LevelName ~= "SYS_CC_I" then
        PopulateComboWithSpells(hostCharacter)
        toggle()
    end
end)
Ext.RegisterNetListener("GainedControl", function(channel, payload)
    local data = Ext.Json.Parse(payload)
    local hostCharacter = Ext.Entity.Get(data.Character)
    if hostCharacter and hostCharacter.Level and hostCharacter.Level.LevelName ~= "SYS_CC_I" then
        PopulateComboWithSpells(hostCharacter)
        UpdateManaText(hostCharacter)
    end
end)
Ext.Events.KeyInput:Subscribe(function(e)
    if e.Event == "KeyDown" and e.Repeat == false then
        local character = GetHost()
        local charGuid = character and character.Uuid.EntityUuid
        if charGuid then
            local spellID = characterHotkeyBindings[charGuid] and characterHotkeyBindings[charGuid][displayKeyMapping[e.Key] or e.Key]
            if spellID then
                RequestSpellExecution(spellID)
            end
        end
        if e.Key == Settings.ToggleKey then
            Ext.ClientNet.PostMessageToServer("RequestHostCharacter", "{}")
        end
        if e.Key == Settings.TBToggleKey then
            Ext.ClientNet.PostMessageToServer("ToggleTurnBased", "{}")
        end
        if e.Key == Settings.ManaToggleKey then
            if juice_window.Open then
                CloseManaUI()
            else
                OpenManaUI()
            end
        end
    end
end)
Ext.RegisterNetListener("OpenWindow", function(channel, payload)
    window.Open = true
end)
Ext.RegisterNetListener("CloseWindow", function(channel, payload)
    window.Open = false
end)
Ext.Events.MouseButtonInput:Subscribe(function(e)
    if e.Button == 3 then
        Ext.ClientNet.PostMessageToServer("PurgeOsirisQueue", "{}")
    end
end)
Ext.RegisterNetListener("OpenManaUI", function(channel, payload)
    OpenManaUI()
end)
Ext.RegisterNetListener("CloseManaUI", function(channel, payload)
    CloseManaUI()
end)
Ext.RegisterNetListener("NotEnoughMana", function(channel, payload)
    juice.Tint = {1, 0, 0, 1}
    Ext.Timer.WaitFor(2000, function()
        juice.Tint = {0.5, 0, 0.5, 1}
        grey_juice.Tint = {0, 0, 0, 1}
    end)
    Ext.ClientNet.PostMessageToServer("PlayNoManaSound", "{}")
end)
