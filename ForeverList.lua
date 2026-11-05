local ADDON_NAME = ...

------------------------------------------------------------
-- Settings
------------------------------------------------------------
local DEFAULTS = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    width = 380,
    height = 320,
}

-- Saved per character (ForeverListCharDB)
local CHAR_DEFAULTS = {
    text = "",             -- the list exactly as pasted; rows are parsed from it
    shown = false,         -- reopen the window after a reload or login if it was left open
}

local MIN_W, MIN_H, MAX_W, MAX_H = 260, 160, 800, 900
local ROW_HEIGHT = 18
local REFRESH_DELAY = 0.1  -- bag events can fire in bursts, so wait for them to settle
local NAME_RETRY_DELAY = 0.5 -- how often to recount while the game is still loading item names
local NAME_RETRIES = 20

local COLOR_DONE = "|cff40ff40"
local COLOR_MISSING = "|cffff6060"

local db, charDb
local frame, importButton, clearButton, saveButton, cancelButton
local listScroll, listChild, emptyText
local editScroll, editBox, editHint
local rows = {}
local refreshPending = false
local nameRetries = 0
local Refresh              -- forward declaration; defined in the Display section

------------------------------------------------------------
-- Parsing
------------------------------------------------------------
local function Trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- One line -> name, need. Accepts "20 Flask", "20x Flask", "20 x Flask", "x20 Flask",
-- "Flask x20", "Flask x 20", "Flask (20)", "Flask: 20", "Flask - 20", "Flask 20" and plain
-- "Flask" (need 1), with an optional leading bullet. [Brackets] and item links are unwrapped.
local function ParseLine(line)
    line = Trim(line):gsub("^\226\128\162%s*", ""):gsub("^[%-%*]+%s+", "")
    if line == "" then return nil end

    local count, name = line:match("^[xX]?(%d+)%s*[xX]?%s+(.+)$")
    if not count then name, count = line:match("^(.-)%s*%([xX]?(%d+)%)$") end
    if not count then name, count = line:match("^(.-)[%s:%-]+[xX]%s*(%d+)$") end
    if not count then name, count = line:match("^(.-)[%s:%-]+(%d+)$") end
    if not count or name == "" then name, count = line, 1 end

    name = Trim(name:match("%[(.+)%]") or name)
    if name == "" then return nil end
    return name, tonumber(count)
end

-- The whole pasted text -> { { name, need }, ... } in pasted order. A name listed twice
-- (in any case) becomes one row with the amounts added together.
local function ParseList(text)
    local items, byName = {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local name, need = ParseLine(line)
        if name then
            local key = name:lower()
            if byName[key] then
                byName[key].need = byName[key].need + need
            else
                byName[key] = { name = name, need = need }
                items[#items + 1] = byName[key]
            end
        end
    end
    return items
end

------------------------------------------------------------
-- Counting
------------------------------------------------------------
local requested = {} -- [itemID] = true once a name load has been asked for

-- A bag slot -> its item's name. Right after login the game may not have the name yet and gives
-- back a blank one, so ask it to load; Refresh keeps recounting until the name shows up.
local function ItemName(info)
    local name = info.itemName
    if not name or name == "" then
        -- retail links can carry a quality icon inside the [name]
        name = info.hyperlink and info.hyperlink:match("%[(.-)%]")
        name = name and Trim((name:gsub("|A.-|a", "")))
    end
    if (not name or name == "") and info.itemID then
        name = C_Item.GetItemNameByID(info.itemID)
    end
    if name and name ~= "" then return name end

    if info.itemID and not requested[info.itemID] then
        requested[info.itemID] = true
        C_Item.RequestLoadItemDataByID(info.itemID)
    end
end

-- This character's bags -> { [lowercase name] = total }, number of stacks with no name yet.
-- Only the equipped bags are walked, so nothing in the character, guild or Warband banks is
-- ever counted.
local function CountBags()
    local counts, unnamed = {}, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then
                local name = ItemName(info)
                if name then
                    local key = name:lower()
                    counts[key] = (counts[key] or 0) + (info.stackCount or 1)
                else
                    unnamed = unnamed + 1
                end
            end
        end
    end
    return counts, unnamed
end

------------------------------------------------------------
-- Display
------------------------------------------------------------
local function BumpFont(fontString, by)
    local path, size, flags = fontString:GetFont()
    fontString:SetFont(path, size + by, flags)
end

local function GetRow(index)
    local row = rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, listChild)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    BumpFont(row.text, 1)

    rows[index] = row
    return row
end

local function RequestRefresh(delay)
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(delay or REFRESH_DELAY, function()
        refreshPending = false
        Refresh()
    end)
end

function Refresh()
    if not frame or not frame:IsShown() or editScroll:IsShown() then return end

    local items = ParseList(charDb.text)
    local counts, unnamed = CountBags()
    for order, item in ipairs(items) do
        item.order = order
        item.have = counts[item.name:lower()] or 0
        item.done = item.have >= item.need
        item.progress = item.need > 0 and item.have / item.need or 1
    end
    -- closest to its goal first; finished items drop to the bottom; ties keep the pasted order
    table.sort(items, function(a, b)
        if a.done ~= b.done then return not a.done end
        if not a.done and a.progress ~= b.progress then return a.progress > b.progress end
        return a.order < b.order
    end)

    for index, item in ipairs(items) do
        local color = item.done and COLOR_DONE or COLOR_MISSING
        local row = GetRow(index)
        row.key = item.name:lower()
        row.text:SetText(color .. item.name .. " " .. item.have .. "/" .. item.need .. "|r")
        row:Show()
    end
    for index = #items + 1, #rows do
        rows[index]:Hide()
    end

    listChild:SetHeight(math.max(#items * ROW_HEIGHT, 1))
    emptyText:SetShown(#items == 0)

    -- some names are still loading: look again shortly, but don't poll forever
    if unnamed == 0 then
        nameRetries = 0
    elseif nameRetries < NAME_RETRIES then
        nameRetries = nameRetries + 1
        RequestRefresh(NAME_RETRY_DELAY)
    end
end

local function ShowListView()
    editBox:ClearFocus()
    editScroll:Hide()
    editHint:Hide()
    saveButton:Hide()
    cancelButton:Hide()
    listScroll:Show()
    importButton:Show()
    clearButton:Show()
    nameRetries = 0
    Refresh()
end

local function ShowEditView()
    listScroll:Hide()
    importButton:Hide()
    clearButton:Hide()
    editBox:SetText(charDb.text)
    editHint:Show()
    editScroll:Show()
    saveButton:Show()
    cancelButton:Show()
    editBox:SetFocus()
end

local function SaveLayout()
    local point, _, relativePoint, x, y = frame:GetPoint()
    db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
    db.width, db.height = frame:GetSize()
end

local function ApplyLayout()
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    frame:SetSize(db.width, db.height)
end

-- both scroll children have to follow the window's width (10 and 30 are the scroll frames' insets)
local function SyncWidths()
    local width = frame:GetWidth() - 40
    listChild:SetWidth(width)
    editBox:SetWidth(width)
end

local function CreateButton(label, width)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(label)
    return button
end

local function CreateDisplay()
    frame = CreateFrame("Frame", "ForeverListFrame", UIParent, "BackdropTemplate")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    frame:EnableMouse(true)
    frame:Hide()
    ApplyLayout()

    -- title bar: the only part of the window that moves it (stops short of the close button)
    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
    titleBar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -28, -26)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SaveLayout()
    end)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", frame, "TOP", 0, -15) -- centered on the window, not the shorter bar
    title:SetText("Forever List")
    BumpFont(title, 2)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    close:HookScript("OnClick", function() charDb.shown = false end)

    -- list view
    listScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
    listScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 38)
    listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(1, 1)
    listScroll:SetScrollChild(listChild)

    emptyText = listChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", listChild, "TOPLEFT", 2, -4)
    emptyText:SetText("Nothing listed yet. Click Import and paste your items.")

    -- edit view
    editHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editHint:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
    editHint:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    editHint:SetJustifyH("LEFT")
    editHint:SetWordWrap(false)
    editHint:SetText("One item per line, like: 20 Flask of Titans")
    editHint:Hide()

    editScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    editScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -46)
    editScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 38)
    editScroll:Hide()
    editBox = CreateFrame("EditBox", nil, editScroll)
    editBox:SetMultiLine(true)
    editBox:SetMaxLetters(0)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetSize(1, 1)
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    editScroll:SetScrollChild(editBox)
    -- the box is only as tall as its text, so clicking the empty space below has to focus it too
    editScroll:EnableMouse(true)
    editScroll:SetScript("OnMouseDown", function() editBox:SetFocus() end)

    -- buttons
    importButton = CreateButton("Import", 64)
    importButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
    importButton:SetScript("OnClick", ShowEditView)

    clearButton = CreateButton("Clear", 60)
    clearButton:SetPoint("LEFT", importButton, "RIGHT", 2, 0)
    clearButton:SetScript("OnClick", function()
        charDb.text = ""
        Refresh()
    end)

    saveButton = CreateButton("Save", 64)
    saveButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
    saveButton:SetScript("OnClick", function()
        charDb.text = editBox:GetText()
        ShowListView()
    end)
    saveButton:Hide()

    cancelButton = CreateButton("Cancel", 64)
    cancelButton:SetPoint("LEFT", saveButton, "RIGHT", 2, 0)
    cancelButton:SetScript("OnClick", ShowListView)
    cancelButton:Hide()

    -- resize grip
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        -- pin the top left corner, so a centered window grows only toward the cursor
        local left, top = frame:GetLeft(), frame:GetTop()
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SaveLayout()
    end)

    -- set last: these use the widgets created above
    frame:SetScript("OnShow", function()
        SyncWidths()
        nameRetries = 0
        Refresh()
    end)
    frame:SetScript("OnHide", ShowListView) -- closing while editing cancels the edit
    frame:SetScript("OnSizeChanged", SyncWidths)
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")

        ForeverListDB = ForeverListDB or {}
        db = ForeverListDB
        for key, value in pairs(DEFAULTS) do
            if db[key] == nil then db[key] = value end
        end

        ForeverListCharDB = ForeverListCharDB or {}
        charDb = ForeverListCharDB
        -- the list used to be account-wide; the first character to log in keeps it
        if charDb.text == nil and db.text ~= nil then
            charDb.text = db.text
        end
        db.text = nil
        for key, value in pairs(CHAR_DEFAULTS) do
            if charDb[key] == nil then charDb[key] = value end
        end

        CreateDisplay()
        frame:SetShown(charDb.shown)

        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD") -- bags may not be readable until now
    else -- bags changed, or the world finished loading
        RequestRefresh()
    end
end)

------------------------------------------------------------
-- Slash commands
--   /fl, /flist or /foreverlist : show/hide the window
--   /flist edit            : open the window on the paste box
--   /flist reset           : restore the default position and size (keeps the list)
--   /flist debug           : print what the addon reads from the bags, to diagnose wrong counts
------------------------------------------------------------
SLASH_FOREVERLIST1 = "/flist"
SLASH_FOREVERLIST2 = "/foreverlist"
SLASH_FOREVERLIST3 = "/fl"
SlashCmdList.FOREVERLIST = function(input)
    local cmd = Trim(input or ""):lower()

    -- /flist : toggle the window
    if cmd == "" then
        frame:SetShown(not frame:IsShown())
        charDb.shown = frame:IsShown()
    -- /flist edit : jump straight to pasting
    elseif cmd == "edit" then
        frame:Show()
        charDb.shown = true
        ShowEditView()
    -- /flist reset : position and size only, never the list
    elseif cmd == "reset" then
        db.point, db.relativePoint, db.x, db.y = DEFAULTS.point, DEFAULTS.relativePoint, DEFAULTS.x, DEFAULTS.y
        db.width, db.height = DEFAULTS.width, DEFAULTS.height
        ApplyLayout()
        print("|cffffd700Forever List:|r position and size reset.")
    -- /flist debug : every name read from the bags, then how each listed item matched
    elseif cmd == "debug" then
        local counts, unnamed = CountBags()
        local names = {}
        for key, total in pairs(counts) do names[#names + 1] = key .. " = " .. total end
        table.sort(names)
        print("|cffffd700Forever List:|r in bags (" .. unnamed .. " stacks with no name yet):")
        for _, line in ipairs(names) do print("  " .. line) end
        print("|cffffd700Forever List:|r your list:")
        for _, item in ipairs(ParseList(charDb.text)) do
            local shown
            for _, row in ipairs(rows) do
                if row:IsShown() and row.key == item.name:lower() then shown = row.text:GetText() end
            end
            print("  [" .. item.name .. "] have " .. (counts[item.name:lower()] or 0) .. ", need " .. item.need
                .. ", box shows: " .. (shown or "nothing"))
        end
    -- anything else: show the list of commands
    else
        print("|cffffd700Forever List:|r commands: /fl (show/hide), edit, reset, debug")
    end
end
