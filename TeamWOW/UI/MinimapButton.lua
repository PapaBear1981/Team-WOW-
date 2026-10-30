-- Minimap button: left-click opens the window, drag to move around the edge.

local _, ns = ...
local TeamWOW = ns.TeamWOW
local UI = ns.UI

local ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"

local button

local function UpdatePosition()
	local angle = math.rad(TeamWOW.db.settings.minimap.angle or 200)
	local radius = (Minimap:GetWidth() / 2) + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local px, py = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	px, py = px / scale, py / scale
	TeamWOW.db.settings.minimap.angle = math.deg(math.atan2(py - my, px - mx)) % 360
	UpdatePosition()
end

local function CreateButton()
	button = CreateFrame("Button", "TeamWOWMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetTexture(ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("TOPLEFT", 7, -6)

	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			ns.Sync:ForceSync()
			TeamWOW:Print("Syncing...")
		else
			UI:Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("TeamWOW")
		GameTooltip:AddLine("Left-click: open", 1, 1, 1)
		GameTooltip:AddLine("Right-click: sync now", 1, 1, 1)
		GameTooltip:AddLine("Drag: move", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	UpdatePosition()
end

function UI:UpdateMinimapButton()
	if TeamWOW.db.settings.minimap.hide then
		if button then button:Hide() end
	else
		if not button then CreateButton() end
		button:Show()
	end
end

-- UI's OnEnable is defined in MainFrame.lua; hook ours onto it.
local baseOnEnable = UI.OnEnable
function UI:OnEnable()
	baseOnEnable(self)
	self:UpdateMinimapButton()
end
