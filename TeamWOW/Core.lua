-- TeamWOW core: namespace, modules, events, callbacks, SavedVariables and
-- the per-player "section" data store that every other module builds on.

local ADDON_NAME, ns = ...

local TeamWOW = {}
ns.TeamWOW = TeamWOW
_G.TeamWOW = TeamWOW

TeamWOW.name = ADDON_NAME
TeamWOW.SCHEMA = 1

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
TeamWOW.version = (GetMetadata and GetMetadata(ADDON_NAME, "Version")) or "dev"

local DEFAULTS = {
	settings = {
		debug = false,
		trustGuild = true,
		minimap = { angle = 200, hide = false },
	},
	team = {},
	blocked = {},
	peers = {},
	players = {},
}

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local CHAT_PREFIX = "|cff33ff99TeamWOW|r: "

function TeamWOW:Print(...)
	local msg = strjoin(" ", tostringall(...))
	DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. msg)
end

function TeamWOW:Debug(...)
	if self.db and self.db.settings.debug then
		self:Print("|cff999999[debug]|r", ...)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {} -- event -> { [owner] = method or function }

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local handlers = eventHandlers[event]
	if not handlers then return end
	for owner, handler in pairs(handlers) do
		if type(handler) == "function" then
			handler(owner, event, ...)
		else
			owner[handler](owner, event, ...)
		end
	end
end)

-- handler is a function(owner, event, ...) or a method name on owner;
-- defaults to the method named after the event.
function TeamWOW.RegisterEvent(owner, event, handler)
	if not eventHandlers[event] then
		eventHandlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	eventHandlers[event][owner] = handler or event
end

function TeamWOW.UnregisterEvent(owner, event)
	local handlers = eventHandlers[event]
	if not handlers then return end
	handlers[owner] = nil
	if next(handlers) == nil then
		eventHandlers[event] = nil
		eventFrame:UnregisterEvent(event)
	end
end

---------------------------------------------------------------------------
-- Callbacks (addon-internal messages, e.g. "SECTION_UPDATED")
---------------------------------------------------------------------------

local callbacks = {}

function TeamWOW.RegisterCallback(owner, name, handler)
	callbacks[name] = callbacks[name] or {}
	callbacks[name][owner] = handler or name
end

function TeamWOW.UnregisterCallback(owner, name)
	if callbacks[name] then callbacks[name][owner] = nil end
end

function TeamWOW:Fire(name, ...)
	local list = callbacks[name]
	if not list then return end
	for owner, handler in pairs(list) do
		local ok, err
		if type(handler) == "function" then
			ok, err = pcall(handler, owner, name, ...)
		else
			ok, err = pcall(owner[handler], owner, name, ...)
		end
		if not ok then geterrorhandler()(err) end
	end
end

---------------------------------------------------------------------------
-- Modules
---------------------------------------------------------------------------

local modules, moduleOrder = {}, {}

function TeamWOW:NewModule(name)
	assert(not modules[name], "module already exists: " .. name)
	local mod = {
		name = name,
		RegisterEvent = TeamWOW.RegisterEvent,
		UnregisterEvent = TeamWOW.UnregisterEvent,
		RegisterCallback = TeamWOW.RegisterCallback,
		UnregisterCallback = TeamWOW.UnregisterCallback,
	}
	modules[name] = mod
	moduleOrder[#moduleOrder + 1] = mod
	return mod
end

function TeamWOW:GetModule(name)
	return modules[name]
end

local function CallModules(method)
	for _, mod in ipairs(moduleOrder) do
		if mod[method] then
			local ok, err = pcall(mod[method], mod)
			if not ok then geterrorhandler()(err) end
		end
	end
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

-- Returns "Name-Realm" with the first letter capitalized.
function TeamWOW:NormalizeName(name)
	if type(name) ~= "string" then return nil end
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return nil end
	local char, realm = name:match("^([^%-]+)%-(.+)$")
	if not char then
		char, realm = name, self.realm
	end
	realm = realm and realm:gsub("%s", "")
	char = char:sub(1, 1):upper() .. char:sub(2):lower()
	if not realm or realm == "" then return char end
	return char .. "-" .. realm
end

-- "Bob" if Bob is on our realm, otherwise "Bob-OtherRealm".
function TeamWOW:ShortName(fullName)
	if not fullName then return "?" end
	local char, realm = fullName:match("^([^%-]+)%-(.+)$")
	if char and realm == self.realm then return char end
	return fullName
end

---------------------------------------------------------------------------
-- SavedVariables
---------------------------------------------------------------------------

local function ApplyDefaults(target, defaults)
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			if type(target[k]) ~= "table" then target[k] = {} end
			ApplyDefaults(target[k], v)
		elseif target[k] == nil then
			target[k] = v
		end
	end
end

function TeamWOW:InitDB()
	if type(TeamWOWDB) ~= "table" then TeamWOWDB = {} end
	local db = TeamWOWDB
	db.schema = db.schema or self.SCHEMA
	ApplyDefaults(db, DEFAULTS)
	self.db = db
end

---------------------------------------------------------------------------
-- Section store
--
-- players[owner].sections[name] = { rev = number, data = table }
-- Only the owner ever changes their own sections; everyone else just stores
-- the newest copy they have heard of.
---------------------------------------------------------------------------

function TeamWOW:GetSectionRecord(owner, section)
	local player = self.db.players[owner]
	return player and player.sections and player.sections[section]
end

function TeamWOW:GetSection(owner, section)
	local rec = self:GetSectionRecord(owner, section)
	return rec and rec.data
end

function TeamWOW:GetSectionRev(owner, section)
	local rec = self:GetSectionRecord(owner, section)
	return rec and rec.rev or 0
end

-- Stores a section as received from the network (or a restore).
function TeamWOW:SetSection(owner, section, rev, data)
	local players = self.db.players
	players[owner] = players[owner] or { sections = {} }
	players[owner].sections = players[owner].sections or {}
	players[owner].sections[section] = { rev = rev, data = data }
	self:Fire("SECTION_UPDATED", owner, section)
end

-- Returns our own (mutable) data table for a section, creating it if needed.
function TeamWOW:GetMySection(section)
	local rec = self:GetSectionRecord(self.playerName, section)
	if not rec then
		self:SetSection(self.playerName, section, 0, {})
		rec = self:GetSectionRecord(self.playerName, section)
	end
	return rec.data
end

local function ServerTime()
	return (GetServerTime and GetServerTime()) or time()
end

-- Call after changing data returned by GetMySection. Bumps the revision and
-- schedules a sync broadcast.
function TeamWOW:TouchSection(section)
	local rec = self:GetSectionRecord(self.playerName, section)
	if not rec then return end
	rec.rev = math.max(rec.rev + 1, ServerTime())
	self:Fire("SECTION_UPDATED", self.playerName, section)
	if ns.Sync then ns.Sync:ScheduleBroadcast() end
end

-- Iterates owner, data for every player that has the section.
function TeamWOW:IterateSection(section)
	local players = self.db.players
	local owner
	return function()
		while true do
			local player
			owner, player = next(players, owner)
			if not owner then return nil end
			local rec = player.sections and player.sections[section]
			if rec then return owner, rec.data end
		end
	end
end

function TeamWOW:ForgetPlayer(owner)
	self.db.players[owner] = nil
	self.db.peers[owner] = nil
	self:Fire("SECTION_UPDATED", owner, nil)
end

---------------------------------------------------------------------------
-- Team list
---------------------------------------------------------------------------

function TeamWOW:IsOnTeam(name)
	return name == self.playerName or self.db.team[name] == true
end

function TeamWOW:AddTeamMember(name, quiet)
	name = self:NormalizeName(name)
	if not name or name == self.playerName then return nil end
	self.db.blocked[name] = nil
	if self.db.team[name] then return name end
	self.db.team[name] = true
	if not quiet then self:Print("Added", name, "to the team.") end
	self:Fire("TEAM_CHANGED", name)
	return name, true
end

function TeamWOW:RemoveTeamMember(name)
	name = self:NormalizeName(name)
	if not name or name == self.playerName then return nil end
	self.db.team[name] = nil
	-- Blocked so gossip from other teammates doesn't re-add them.
	self.db.blocked[name] = true
	self:ForgetPlayer(name)
	self:Fire("TEAM_CHANGED", name)
	return name
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function TeamWOW:ADDON_LOADED(_, name)
	if name ~= ADDON_NAME then return end
	self:UnregisterEvent("ADDON_LOADED")
	self:InitDB()
	CallModules("OnInitialize")
end

function TeamWOW:PLAYER_LOGIN()
	self.realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not self.realm or self.realm == "" then
		self.realm = (GetRealmName() or ""):gsub("%s", "")
	end
	self.playerName = self:NormalizeName(UnitName("player"))
	self.db.players[self.playerName] = self.db.players[self.playerName] or { sections = {} }
	CallModules("OnEnable")
	self:Debug("loaded version", self.version, "as", self.playerName)
end

TeamWOW:RegisterEvent("ADDON_LOADED")
TeamWOW:RegisterEvent("PLAYER_LOGIN")
