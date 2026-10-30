-- Main window with tabs. Modules add tabs with ns.UI:RegisterTab().

local _, ns = ...
local TeamWOW = ns.TeamWOW

local UI = TeamWOW:NewModule("UI")
ns.UI = UI

local WIDTH, HEIGHT = 640, 420
local TAB_WIDTH, TAB_HEIGHT = 100, 22

local tabs = {}  -- { key, label, build(container), refresh(container), container, button }
local frame, activeTab

---------------------------------------------------------------------------
-- Helpers shared by tabs
---------------------------------------------------------------------------

function UI.ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not c then return "|cffffffff" end
	return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

function UI.ClassName(class)
	return (class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class or ""
end

function UI.TimeAgo(t)
	if not t then return "never" end
	local d = time() - t
	if d < 120 then return "just now" end
	if d < 7200 then return math.floor(d / 60) .. "m ago" end
	if d < 172800 then return math.floor(d / 3600) .. "h ago" end
	return math.floor(d / 86400) .. "d ago"
end

-- A scrollable list of rows with fixed columns.
-- columns = { { title, width, justify }, ... }
function UI.CreateTable(parent, columns)
	local tbl = { columns = columns, rows = {} }

	local x = 4
	for _, col in ipairs(columns) do
		local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		header:SetPoint("TOPLEFT", x, -4)
		header:SetWidth(col[2])
		header:SetJustifyH(col[3] or "LEFT")
		header:SetText(col[1])
		x = x + col[2]
	end

	local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -20)
	scroll:SetPoint("BOTTOMRIGHT", -26, 0)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(x, 1)
	scroll:SetScrollChild(content)
	tbl.content = content

	function tbl:SetData(data)
		for i, values in ipairs(data) do
			local row = self.rows[i]
			if not row then
				row = CreateFrame("Frame", nil, content)
				row:SetSize(x, 18)
				row:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
				row.cells = {}
				local cx = 4
				for c, col in ipairs(columns) do
					local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					fs:SetPoint("LEFT", cx, 0)
					fs:SetWidth(col[2])
					fs:SetJustifyH(col[3] or "LEFT")
					fs:SetWordWrap(false)
					row.cells[c] = fs
					cx = cx + col[2]
				end
				if i % 2 == 0 then
					local bg = row:CreateTexture(nil, "BACKGROUND")
					bg:SetAllPoints()
					bg:SetColorTexture(1, 1, 1, 0.04)
				end
				self.rows[i] = row
			end
			for c = 1, #columns do
				row.cells[c]:SetText(values[c] or "")
			end
			row:Show()
		end
		for i = #data + 1, #self.rows do
			self.rows[i]:Hide()
		end
		content:SetHeight(math.max(1, #data * 18))
	end

	return tbl
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function SelectTab(key)
	for _, tab in ipairs(tabs) do
		local selected = tab.key == key
		if tab.container then tab.container:SetShown(selected) end
		if tab.button then
			if selected then tab.button:LockHighlight() else tab.button:UnlockHighlight() end
		end
		if selected then
			activeTab = tab
			if not tab.container then
				tab.container = CreateFrame("Frame", nil, frame)
				tab.container:SetPoint("TOPLEFT", 14, -60)
				tab.container:SetPoint("BOTTOMRIGHT", -12, 12)
				tab.build(tab.container)
			end
			tab.container:Show()
			if tab.refresh then tab.refresh(tab.container) end
		end
	end
end

local function CreateTabButton(tab, index)
	local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	button:SetSize(TAB_WIDTH, TAB_HEIGHT)
	button:SetPoint("TOPLEFT", 12 + (index - 1) * (TAB_WIDTH + 4), -30)
	button:SetText(tab.label)
	button:SetScript("OnClick", function() SelectTab(tab.key) end)
	tab.button = button
end

local function CreateMainFrame()
	frame = CreateFrame("Frame", "TeamWOWMainFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
	title:SetText("TeamWOW")

	tinsert(UISpecialFrames, "TeamWOWMainFrame") -- close with Escape

	for i, tab in ipairs(tabs) do CreateTabButton(tab, i) end

	frame:SetScript("OnShow", function()
		SelectTab(activeTab and activeTab.key or tabs[1].key)
	end)
end

-- build(container) runs once, the first time the tab is shown.
-- refresh(container) runs whenever the tab is shown or UI:Refresh() is called.
function UI:RegisterTab(key, label, build, refresh)
	local tab = { key = key, label = label, build = build, refresh = refresh }
	tabs[#tabs + 1] = tab
	if frame then CreateTabButton(tab, #tabs) end
end

function UI:Toggle()
	if not frame then CreateMainFrame() end
	frame:SetShown(not frame:IsShown())
end

-- Re-render the visible tab, at most a few times per second.
function UI:Refresh()
	if not frame or not frame:IsShown() or self.refreshPending then return end
	self.refreshPending = true
	C_Timer.After(0.2, function()
		self.refreshPending = false
		if frame:IsShown() and activeTab and activeTab.refresh and activeTab.container then
			activeTab.refresh(activeTab.container)
		end
	end)
end

function UI:OnEnable()
	self:RegisterCallback("SECTION_UPDATED", "Refresh")
	self:RegisterCallback("TEAM_CHANGED", "Refresh")
	self:RegisterCallback("PEER_SEEN", "Refresh")
	self:RegisterCallback("PRESENCE_CHANGED", "Refresh")
end

---------------------------------------------------------------------------
-- Team tab
---------------------------------------------------------------------------

UI:RegisterTab("team", "Team",
	function(container)
		container.table = UI.CreateTable(container, {
			{ "Name", 150 }, { "Level", 45, "CENTER" }, { "Class", 90 },
			{ "Guild", 140 }, { "Status", 90 }, { "Version", 60 },
		})
	end,
	function(container)
		local rows = {}
		for _, m in ipairs(TeamWOW:GetModule("Roster"):GetMembers()) do
			local status
			if m.name == TeamWOW.playerName then
				status = "|cff00ff00you|r"
			elseif m.online == true then
				status = "|cff00ff00online|r"
			else
				status = "|cff888888" .. UI.TimeAgo(m.peer and m.peer.lastSeen) .. "|r"
			end
			rows[#rows + 1] = {
				UI.ClassColor(m.info.class) .. TeamWOW:ShortName(m.name) .. "|r",
				m.info.level and tostring(m.info.level) or "?",
				UI.ClassName(m.info.class),
				m.info.guild or "",
				status,
				m.info.version or "",
			}
		end
		container.table:SetData(rows)
	end)
