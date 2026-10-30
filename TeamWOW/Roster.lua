-- Roster: publishes who we are (class, level, guild...) in the "info" section.

local _, ns = ...
local TeamWOW = ns.TeamWOW

local Roster = TeamWOW:NewModule("Roster")

local function Set(info, key, value)
	if info[key] ~= value then
		info[key] = value
		return true
	end
	return false
end

function Roster:Update(level)
	local info = TeamWOW:GetMySection("info")
	local _, class = UnitClass("player")
	local _, race = UnitRace("player")
	local changed = false

	changed = Set(info, "class", class) or changed
	changed = Set(info, "race", race) or changed
	changed = Set(info, "faction", (UnitFactionGroup("player"))) or changed
	changed = Set(info, "level", level or UnitLevel("player")) or changed
	changed = Set(info, "version", TeamWOW.version) or changed

	-- GetGuildInfo can be nil for a moment after login even when in a guild.
	if not IsInGuild() then
		changed = Set(info, "guild", nil) or changed
	else
		local guild = GetGuildInfo("player")
		if guild then changed = Set(info, "guild", guild) or changed end
	end

	if changed then TeamWOW:TouchSection("info") end
end

function Roster:PLAYER_LEVEL_UP(_, level)
	self:Update(level)
end

function Roster:PLAYER_GUILD_UPDATE()
	self:Update()
end

function Roster:OnEnable()
	self:RegisterEvent("PLAYER_LEVEL_UP")
	self:RegisterEvent("PLAYER_GUILD_UPDATE")
	self:Update()
end

-- Everyone we know about: team members plus anyone with data, sorted with
-- online players first.
function Roster:GetMembers()
	local seen, list = {}, {}
	local function add(name)
		if not seen[name] and not TeamWOW.db.blocked[name] then
			seen[name] = true
			list[#list + 1] = {
				name = name,
				info = TeamWOW:GetSection(name, "info") or {},
				online = ns.Sync:IsOnline(name),
				peer = TeamWOW.db.peers[name],
			}
		end
	end
	add(TeamWOW.playerName)
	for name in pairs(TeamWOW.db.team) do add(name) end
	for name in pairs(TeamWOW.db.players) do
		if ns.Sync:IsTrusted(name) then add(name) end
	end
	table.sort(list, function(a, b)
		if (a.online == true) ~= (b.online == true) then return a.online == true end
		return a.name < b.name
	end)
	return list
end
