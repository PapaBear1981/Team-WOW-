-- /tw slash commands.

local _, ns = ...
local TeamWOW = ns.TeamWOW

local commands = {}
local help = {}

local function Command(name, usage, fn)
	commands[name] = fn
	help[#help + 1] = usage
end

Command("help", "/tw help - this list", function()
	TeamWOW:Print("version", TeamWOW.version, "- commands:")
	for _, line in ipairs(help) do
		DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
	end
end)

Command("show", "/tw - open or close the TeamWOW window", function()
	if ns.UI and ns.UI.Toggle then
		ns.UI:Toggle()
	end
end)

Command("add", "/tw add <name> - add a teammate (Name or Name-Realm)", function(arg)
	if arg == "" then
		local target = UnitIsPlayer("target") and GetUnitName("target", true)
		if not target then return TeamWOW:Print("Usage: /tw add <name>, or target the player.") end
		arg = target
	end
	local name, added = TeamWOW:AddTeamMember(arg, true)
	if not name then return TeamWOW:Print("Can't add that name.") end
	TeamWOW:Print(added and ("Added " .. name .. " to the team.") or (name .. " is already on the team."))
	ns.Sync:ScheduleBroadcast(1)
end)

Command("remove", "/tw remove <name> - remove a teammate and forget their data", function(arg)
	local name = TeamWOW:RemoveTeamMember(arg)
	if name then
		TeamWOW:Print("Removed", name .. ". Use /tw add to undo.")
	else
		TeamWOW:Print("Usage: /tw remove <name>")
	end
end)

Command("team", "/tw team - list teammates", function()
	local members = TeamWOW:GetModule("Roster"):GetMembers()
	TeamWOW:Print(#members, "player(s):")
	for _, m in ipairs(members) do
		local status = (m.online == true and "|cff00ff00online|r") or (m.online == false and "|cff888888offline|r") or "?"
		DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s  lvl %s %s  %s",
			m.name, tostring(m.info.level or "?"), m.info.class or "", status))
	end
end)

Command("sync", "/tw sync - sync with teammates now", function()
	ns.Sync:ForceSync()
	TeamWOW:Print("Syncing...")
end)

Command("status", "/tw status - sync diagnostics", function()
	local players = 0
	for _ in pairs(TeamWOW.db.players) do players = players + 1 end
	TeamWOW:Print(string.format("version %s, %d player record(s), %d message(s) queued, guild trust %s",
		TeamWOW.version, players, ns.Comm:GetQueueSize(), TeamWOW.db.settings.trustGuild and "on" or "off"))
end)

Command("guildtrust", "/tw guildtrust - toggle trusting all guildmates running TeamWOW", function()
	local s = TeamWOW.db.settings
	s.trustGuild = not s.trustGuild
	TeamWOW:Print("Trusting guildmates:", s.trustGuild and "on" or "off")
end)

Command("minimap", "/tw minimap - show or hide the minimap button", function()
	local s = TeamWOW.db.settings.minimap
	s.hide = not s.hide
	if ns.UI and ns.UI.UpdateMinimapButton then ns.UI:UpdateMinimapButton() end
end)

Command("debug", "/tw debug - toggle debug messages", function()
	local s = TeamWOW.db.settings
	s.debug = not s.debug
	TeamWOW:Print("Debug", s.debug and "on" or "off")
end)

SLASH_TEAMWOW1 = "/tw"
SLASH_TEAMWOW2 = "/teamwow"
SlashCmdList.TEAMWOW = function(input)
	local cmd, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" then cmd = "show" end
	local fn = commands[cmd]
	if fn then
		fn(arg or "")
	else
		commands.help("")
	end
end
