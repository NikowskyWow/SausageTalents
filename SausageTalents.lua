-- ============================================================================
-- SAUSAGE TALENTS (WotLK 3.3.5a) - v1.2.3 (FINAL EQUIPMENT FIX)
-- GitHub: github.com/NikowskyWow/SausageTalents
-- ============================================================================

local ADDON_NAME = "SausageTalents"
local SAUSAGE_VERSION = "1.2.3"
local GITHUB_URL = "github.com/NikowskyWow/SausageTalents"
local TICK_RATE = 0.15 

-- Fronty a stav
local talentQueue = {}
local currentProfileData = nil
local originalPreviewState = nil
local selectedRealm = GetRealmName()
local selectedChar = UnitName("player")
local activePresetName = "" 

-- Forward deklarácie
local UpdateList 
local ShowProgress
local UpdateProgress
local HideProgress
local ShowDeleteConfirm

-- ============================================================================
-- 1. DATABASE & HELPERS
-- ============================================================================

local function InitDB()
    if not SausageGlobalDB then SausageGlobalDB = {} end
    local r, c = GetRealmName(), UnitName("player")
    if not SausageGlobalDB[r] then SausageGlobalDB[r] = {} end
    if not SausageGlobalDB[r][c] then SausageGlobalDB[r][c] = {} end
    
    local _, englishClass = UnitClass("player")
    SausageGlobalDB[r][c].class = englishClass
    
    if not SausageGlobalDB.minimapPos then SausageGlobalDB.minimapPos = 45 end
end

local function PickupSpellByName(name)
    if not name then return false end
    PickupSpell(name)
    if CursorHasSpell() then return true end
    for tab = 1, GetNumSpellTabs() do
        local _, _, offset, num = GetSpellTabInfo(tab)
        for i = offset + 1, offset + num do
            local sName = GetSpellName(i, "spell")
            if sName == name then
                PickupSpellBookItem(i, "spell")
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- 2. PROGRESS FRAME
-- ============================================================================

local ProgressFrame = CreateFrame("Frame", "SausageProgressFrame", UIParent)
ProgressFrame:SetSize(300, 80)
ProgressFrame:SetPoint("CENTER")
ProgressFrame:SetFrameStrata("DIALOG")
ProgressFrame:Hide()

ProgressFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})

local progTitle = ProgressFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
progTitle:SetPoint("TOP", 0, -15)
progTitle:SetText("Applying Profile...")

local progBar = CreateFrame("StatusBar", nil, ProgressFrame)
progBar:SetSize(260, 20)
progBar:SetPoint("BOTTOM", 0, 20)
progBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
progBar:SetStatusBarColor(1, 0.82, 0)
progBar:SetMinMaxValues(0, 100)
progBar:SetValue(0)

local progText = progBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
progText:SetPoint("CENTER", 0, 0)
progText:SetText("0%")

local progBorder = CreateFrame("Frame", nil, progBar)
progBorder:SetPoint("TOPLEFT", -2, 2)
progBorder:SetPoint("BOTTOMRIGHT", 2, -2)
progBorder:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
})

ShowProgress = function(title)
    progTitle:SetText(title)
    progBar:SetValue(0)
    progText:SetText("0%")
    ProgressFrame:Show()
end

UpdateProgress = function(val, max, text)
    progBar:SetMinMaxValues(0, max)
    progBar:SetValue(val)
    local percent = math.floor((val / max) * 100)
    progText:SetText(text .. " (" .. percent .. "%)")
end

HideProgress = function()
    ProgressFrame:Hide()
end

-- ============================================================================
-- 3. SEQUENCER ENGINE
-- ============================================================================

local function RestoreBarsInstant(profile)
    if not profile or not profile.bars then HideProgress() return end
    
    ShowProgress("Restoring Action Bars")
    local oldSound = GetCVar("Sound_EnableSFX")
    SetCVar("Sound_EnableSFX", "0")
    
    local totalSlots = 120
    for slot = 1, totalSlots do
        PickupAction(slot) ClearCursor()
        local d = profile.bars[slot]
        if d then
            local success = false
            
            -- *** 1. SPELLS ***
            if d.type == "spell" then 
                success = PickupSpellByName(d.name)
            
            -- *** 2. ITEMS ***
            elseif d.type == "item" then 
                PickupItem(d.id) 
                if not CursorHasItem() and d.name then
                    PickupItem(d.name) 
                end
                success = true
            
            -- *** 3. MACROS ***
            elseif d.type == "macro" then 
                PickupMacro(d.id) 
                success = true
            
            -- *** 4. EQUIPMENT SETS (FIXED: 1-based index) ***
            elseif d.type == "equipmentset" then
                local numSets = GetNumEquipmentSets()
                if numSets > 0 then
                    -- Lua indexovanie začína od 1
                    for i = 1, numSets do 
                        local name = GetEquipmentSetInfo(i)
                        if name == d.id then
                            PickupEquipmentSet(i)
                            success = true
                            break
                        end
                    end
                end
                
            -- *** 5. COMPANIONS ***
            elseif d.type == "companion" then
                PickupCompanion(d.subType, d.id)
                success = true
            end
            
            -- Place Action
            if success and (CursorHasSpell() or CursorHasItem() or CursorHasMacro() or GetCursorInfo()) then 
                PlaceAction(slot) 
            end
            ClearCursor()
        end
        if slot % 10 == 0 then UpdateProgress(slot, totalSlots, "Restoring Bars") end
    end
    
    SetCVar("Sound_EnableSFX", oldSound)
    if originalPreviewState then SetCVar("installTalentPreview", originalPreviewState) originalPreviewState = nil end
    HideProgress()
    print("|cffffd100Sausage:|r Profile applied successfully!")
end

local scheduler = CreateFrame("Frame")
scheduler:Hide()
local timer = 0
local initialTalentCount = 0

scheduler:SetScript("OnUpdate", function(self, elapsed)
    timer = timer + elapsed
    if timer >= TICK_RATE then
        timer = 0
        if #talentQueue > 0 and UnitCharacterPoints("player") > 0 then
            local task = table.remove(talentQueue, 1)
            LearnTalent(task.tab, task.talent)
            
            local done = initialTalentCount - #talentQueue
            UpdateProgress(done, initialTalentCount, "Learning Talents")
        else
            self:Hide()
            RestoreBarsInstant(currentProfileData)
            currentProfileData = nil
        end
    end
end)

-- ============================================================================
-- 4. CORE LOGIC
-- ============================================================================

local function SaveProfile(name)
    if name == "" then return end
    InitDB()
    local r, c = GetRealmName(), UnitName("player")
    local _, class = UnitClass("player")
    local profile = { class = class, talents = {}, bars = {} }
    
    -- Save Talents
    for tab = 1, GetNumTalentTabs() do
        profile.talents[tab] = {}
        for talent = 1, GetNumTalents(tab) do
            local _, _, _, _, rank = GetTalentInfo(tab, talent)
            if rank > 0 then profile.talents[tab][talent] = rank end
        end
    end
    
    -- Save Bars
    for slot = 1, 120 do
        local t, id, st = GetActionInfo(slot)
        if t then
            local sName = nil
            if t == "spell" then
                sName = GetSpellName(id, "spell") or GetSpellInfo(id)
            elseif t == "item" then
                sName = GetItemInfo(id)
            elseif t == "equipmentset" then
                sName = id -- Ukladáme Meno setu
            end
            
            profile.bars[slot] = { type = t, id = id, subType = st, name = sName }
        end
    end
    
    SausageGlobalDB[r][c][name] = profile
    print("|cffffd100Sausage:|r Profile '"..name.."' saved.")
    UpdateList()
end

local function ApplyProfile(name)
    if name == "" then return end
    InitDB()
    local db = SausageGlobalDB[selectedRealm] and SausageGlobalDB[selectedRealm][selectedChar]
    local profile = db and db[name]
    
    if not profile or scheduler:IsShown() then return end

    local conflictFound = false
    for tab = 1, GetNumTalentTabs() do
        for talent = 1, GetNumTalents(tab) do
            local _, _, _, _, currentRank = GetTalentInfo(tab, talent)
            local savedRank = 0
            if profile.talents and profile.talents[tab] and profile.talents[tab][talent] then
                savedRank = profile.talents[tab][talent]
            end
            if currentRank > savedRank then
                conflictFound = true
                break 
            end
        end
        if conflictFound then break end
    end
    
    if conflictFound then
        print("|cffffd100Sausage:|r |cffff0000Cannot apply profile! You have conflicting talents.|r")
        print("|cffffd100Sausage:|r Please visit a trainer and reset your talents first.")
        return 
    end

    originalPreviewState = GetCVar("installTalentPreview")
    if originalPreviewState == "1" then SetCVar("installTalentPreview", "0") end
    currentProfileData = profile
    talentQueue = {}
    
    if profile.talents and UnitCharacterPoints("player") > 0 then
        for tab = 1, GetNumTalentTabs() do
            if profile.talents[tab] then
                for talent, savedRank in pairs(profile.talents[tab]) do
                    local _, _, _, _, currentRank = GetTalentInfo(tab, talent)
                    if currentRank < savedRank then
                        for i = 1, (savedRank - currentRank) do table.insert(talentQueue, {tab = tab, talent = talent}) end
                    end
                end
            end
        end
    end
    
    if #talentQueue > 0 then 
        initialTalentCount = #talentQueue
        ShowProgress("Initializing Talents")
        scheduler:Show() 
    else 
        RestoreBarsInstant(profile) 
    end
end

-- ============================================================================
-- 5. CONFIRM DELETE POPUP
-- ============================================================================

StaticPopupDialogs["SAUSAGE_CONFIRM_DELETE"] = {
    text = "Are you sure you want to delete profile:\n|cffffd100%s|r?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        local profileName = data
        if SausageGlobalDB[selectedRealm][selectedChar][profileName] then
            SausageGlobalDB[selectedRealm][selectedChar][profileName] = nil
            if activePresetName == profileName then activePresetName = "" end
            UpdateList()
            print("|cffffd100Sausage:|r Profile deleted.")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

ShowDeleteConfirm = function(name)
    local dialog = StaticPopup_Show("SAUSAGE_CONFIRM_DELETE", name)
    if dialog then dialog.data = name end
end

-- ============================================================================
-- 6. GITHUB POPUP
-- ============================================================================

local GitFrame = CreateFrame("Frame", "SausageGitFrame", UIParent)
GitFrame:SetSize(350, 120)
GitFrame:SetPoint("CENTER")
GitFrame:SetFrameStrata("DIALOG")
GitFrame:Hide()

GitFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})

local GitClose = CreateFrame("Button", nil, GitFrame, "UIPanelCloseButton")
GitClose:SetPoint("TOPRIGHT", -5, -5)

local GitHeader = GitFrame:CreateTexture(nil, "ARTWORK")
GitHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
GitHeader:SetWidth(200)
GitHeader:SetHeight(64)
GitHeader:SetPoint("TOP", 0, 12)

local GitTitle = GitFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
GitTitle:SetPoint("TOP", GitHeader, "TOP", 0, -14)
GitTitle:SetText("Update Link")

local GitBox = CreateFrame("EditBox", nil, GitFrame, "InputBoxTemplate")
GitBox:SetSize(280, 20)
GitBox:SetPoint("CENTER", 0, -10)
GitBox:SetAutoFocus(false)
GitBox:SetText(GITHUB_URL)
GitBox:SetCursorPosition(0)
GitBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
GitBox:SetScript("OnEscapePressed", function(self) GitFrame:Hide() end)
GitBox:SetScript("OnMouseUp", function(self) self:HighlightText() end)

local GitInst = GitFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
GitInst:SetPoint("BOTTOM", GitBox, "TOP", 0, 5)
GitInst:SetText("Press CTRL+C to copy:")

-- ============================================================================
-- 7. UI CONSTRUCTION
-- ============================================================================

local MainFrame = CreateFrame("Frame", "SausageMainFrame", UIParent)
MainFrame:SetSize(430, 520)
MainFrame:SetPoint("CENTER")
MainFrame:SetMovable(true)
MainFrame:EnableMouse(true)
MainFrame:RegisterForDrag("LeftButton")
MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)
tinsert(UISpecialFrames, "SausageMainFrame")
MainFrame:Hide()

MainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})

local CloseBtn = CreateFrame("Button", nil, MainFrame, "UIPanelCloseButton")
CloseBtn:SetPoint("TOPRIGHT", -5, -5)

local header = MainFrame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(256, 64)
header:SetPoint("TOP", 0, 12)

local titleText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
titleText:SetPoint("TOP", header, "TOP", 0, -14)
titleText:SetText("|cffffd100Sausage Talents|r")

-- Dropdowns
local realmDrop = CreateFrame("Frame", "SausageRealmDrop", MainFrame, "UIDropDownMenuTemplate")
realmDrop:SetPoint("TOPLEFT", 20, -40)
UIDropDownMenu_SetWidth(realmDrop, 150)

local charDrop = CreateFrame("Frame", "SausageCharDrop", MainFrame, "UIDropDownMenuTemplate")
charDrop:SetPoint("TOPRIGHT", -20, -40)
UIDropDownMenu_SetWidth(charDrop, 150)

local function InitRealmMenu(self, level)
    local info = UIDropDownMenu_CreateInfo()
    for rName, data in pairs(SausageGlobalDB or {}) do
        if type(data) == "table" then
            info.text = rName
            info.func = function() selectedRealm = rName selectedChar = "None" UpdateList() end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end

local function InitCharMenu(self, level)
    if not SausageGlobalDB or not SausageGlobalDB[selectedRealm] then return end
    local _, playerClass = UnitClass("player")
    local info = UIDropDownMenu_CreateInfo()
    for cName, data in pairs(SausageGlobalDB[selectedRealm]) do
        local charClass = data.class or "Unknown"
        info.text = cName .. " |cffcccccc(" .. charClass .. ")|r"
        if charClass ~= playerClass and charClass ~= "Unknown" then
            info.disabled = true info.colorCode = "|cff666666"
        else
            info.disabled = false info.colorCode = nil
        end
        info.func = function() selectedChar = cName UpdateList() end
        UIDropDownMenu_AddButton(info, level)
    end
end

UIDropDownMenu_Initialize(realmDrop, InitRealmMenu)
UIDropDownMenu_Initialize(charDrop, InitCharMenu)

-- List Section
local listBg = CreateFrame("Frame", nil, MainFrame)
listBg:SetSize(370, 260)
listBg:SetPoint("TOP", 0, -80)
listBg:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
listBg:SetBackdropColor(0, 0, 0, 0.9)
listBg:SetBackdropBorderColor(0, 0.6, 1, 1)

local scrollFrame = CreateFrame("ScrollFrame", "SausageScroll", listBg, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 5, -5)
scrollFrame:SetPoint("BOTTOMRIGHT", -25, 5)
local scrollChild = CreateFrame("Frame")
scrollChild:SetSize(330, 1)
scrollFrame:SetScrollChild(scrollChild)

-- EditBox
local editBox = CreateFrame("EditBox", nil, MainFrame, "InputBoxTemplate")
editBox:SetSize(200, 30)
editBox:SetPoint("TOPLEFT", listBg, "BOTTOMLEFT", 10, -10)
editBox:SetAutoFocus(false)
editBox:SetText("NewProfile")

local btnSave = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
btnSave:SetSize(80, 25) btnSave:SetPoint("LEFT", editBox, "RIGHT", 10, 0)
btnSave:SetText("Save") btnSave:SetScript("OnClick", function() SaveProfile(editBox:GetText()) end)

local btnApply = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
btnApply:SetSize(160, 40) btnApply:SetPoint("BOTTOM", 0, 50)
btnApply:SetText("|cffffd100APPLY SELECTED|r") 
btnApply:SetScript("OnClick", function() ApplyProfile(activePresetName) end)

-- Footer Elements
local versionText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
versionText:SetPoint("BOTTOMLEFT", 20, 15)
versionText:SetText("v"..SAUSAGE_VERSION)

local authorText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
authorText:SetPoint("BOTTOM", 0, 15)
authorText:SetText("by Sausage Party")

local btnGit = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
btnGit:SetSize(110, 25) 
btnGit:SetPoint("BOTTOMRIGHT", -15, 12)
btnGit:SetText("Check Updates")
btnGit:SetScript("OnClick", function() 
    GitFrame:Show() 
    GitBox:SetFocus() 
    GitBox:HighlightText() 
end)

-- Update List Logic
local rowPool = {}
UpdateList = function()
    InitDB()
    UIDropDownMenu_SetText(realmDrop, selectedRealm)
    UIDropDownMenu_SetText(charDrop, selectedChar)
    for _, r in pairs(rowPool) do r:Hide() r.hl:Hide() end
    local db = SausageGlobalDB[selectedRealm] and SausageGlobalDB[selectedRealm][selectedChar]
    if not db then return end
    local i = 0
    for name, data in pairs(db) do
        if type(data) == "table" then
            i = i + 1
            local r = rowPool[i]
            if not r then
                r = CreateFrame("Button", nil, scrollChild)
                r:SetSize(330, 20)
                local hl = r:CreateTexture(nil, "BACKGROUND")
                hl:SetAllPoints() hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hl:SetBlendMode("ADD") hl:Hide() r.hl = hl
                local nb = CreateFrame("Button", nil, r)
                nb:SetPoint("TOPLEFT", 5, 0) nb:SetPoint("BOTTOMRIGHT", -25, 0)
                nb:SetNormalFontObject("GameFontHighlightLeft")
                nb:SetScript("OnClick", function() activePresetName = r.pName UpdateList() end)
                r.nb = nb
                local dbb = CreateFrame("Button", nil, r)
                dbb:SetSize(16, 16) dbb:SetPoint("RIGHT", -2, 0)
                dbb:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
                dbb:SetScript("OnClick", function() ShowDeleteConfirm(r.pName) end)
                rowPool[i] = r
            end
            r.pName = name r.nb:SetText(name)
            if activePresetName == name then r.hl:Show() else r.hl:Hide() end
            r:SetPoint("TOPLEFT", 0, -(i-1)*20) r:Show()
        end
    end
end

-- =========================================================================
-- 🌭 MINIMAP BUTTON
-- =========================================================================

local MinimapBtn = CreateFrame("Button", "SausageMinimapButton", Minimap)
MinimapBtn:SetSize(32, 32)
MinimapBtn:SetFrameLevel(8)
MinimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local icon = MinimapBtn:CreateTexture(nil, "BACKGROUND")
icon:SetTexture("Interface\\Icons\\Inv_Misc_Food_54")
icon:SetSize(20, 20)
icon:SetPoint("CENTER")

local border = MinimapBtn:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(52, 52)
border:SetPoint("TOPLEFT")

local function UpdateMinimapButton()
    local angle = math.rad(SausageGlobalDB.minimapPos or 45)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    MinimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

MinimapBtn:RegisterForDrag("RightButton")
MinimapBtn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function(self)
        local xpos, ypos = GetCursorPosition()
        local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
        xpos = xpos / Minimap:GetEffectiveScale() - xmin - 70
        ypos = ypos / Minimap:GetEffectiveScale() - ymin - 70
        local angle = math.deg(math.atan2(ypos, xpos))
        SausageGlobalDB.minimapPos = angle
        UpdateMinimapButton()
    end)
end)

MinimapBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

MinimapBtn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        if MainFrame:IsShown() then MainFrame:Hide() else MainFrame:Show() end
    end
end)

MinimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Sausage Talents")
    GameTooltip:AddLine("Left-Click: Open Menu", 1, 1, 1)
    GameTooltip:AddLine("Right-Click: Move Icon", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
MinimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- =========================================================================
-- INITIALIZATION
-- =========================================================================

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, e, a1) 
    if a1 == ADDON_NAME then 
        InitDB()
        UpdateMinimapButton()
        UpdateList() 
    end 
end)

SLASH_ST1 = "/st"
SlashCmdList["ST"] = function() MainFrame:Show() UpdateList() end