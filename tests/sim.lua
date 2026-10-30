-- A tiny World of Warcraft simulator: just enough of the API to run several
-- TeamWOW clients in one Lua 5.1 process, each in its own environment, talking
-- over a fake network with a shared fake clock.

local Sim = {}

local ADDON_DIR = (arg and arg[0] and arg[0]:match("^(.*)/tests/") or ".") .. "/TeamWOW/"
local TOC_FILES = {}
for line in io.lines(ADDON_DIR .. "TeamWOW.toc") do
	if line:match("%.lua%s*$") then
		TOC_FILES[#TOC_FILES + 1] = line:gsub("\\", "/"):gsub("%s+$", "")
	end
end

Sim.now = 1000
Sim.epoch = 1800000000
Sim.timers = {}
Sim.clients = {}   -- name -> client (online only)
Sim.inbox = {}     -- pending network deliveries
Sim.guilds = {}    -- guild -> { [fullName] = client or false }
Sim.sent = 0

---------------------------------------------------------------------------
-- Clock
---------------------------------------------------------------------------

local function AddTimer(delay, fn, interval)
	local t = { at = Sim.now + delay, fn = fn, interval = interval }
	function t:Cancel() self.cancelled = true end
	function t:IsCancelled() return self.cancelled end
	Sim.timers[#Sim.timers + 1] = t
	return t
end

function Sim.Advance(seconds, step)
	step = step or 0.1
	local target = Sim.now + seconds
	while Sim.now < target do
		Sim.now = Sim.now + step
		-- timers
		local due = {}
		for i = #Sim.timers, 1, -1 do
			local t = Sim.timers[i]
			if t.cancelled then
				table.remove(Sim.timers, i)
			elseif t.at <= Sim.now then
				due[#due + 1] = t
				if t.interval then
					t.at = t.at + t.interval
				else
					table.remove(Sim.timers, i)
				end
			end
		end
		for _, t in ipairs(due) do
			if not t.cancelled then t.fn(t) end
		end
		-- network
		local inbox = Sim.inbox
		Sim.inbox = {}
		for _, d in ipairs(inbox) do d() end
		-- OnUpdate
		for _, client in pairs(Sim.clients) do
			for _, f in ipairs(client.frames) do
				local onUpdate = f.scripts.OnUpdate
				if f.shown and onUpdate then onUpdate(f, step) end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Frames (permissive: unknown methods are no-ops returning a dummy frame)
---------------------------------------------------------------------------

local function NewFrame(client)
	local f = { scripts = {}, events = {}, shown = true, client = client }
	local methods = {}
	function methods:SetScript(name, fn) self.scripts[name] = fn end
	function methods:GetScript(name) return self.scripts[name] end
	function methods:RegisterEvent(e) self.events[e] = true end
	function methods:UnregisterEvent(e) self.events[e] = nil end
	function methods:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
	function methods:Hide() self.shown = false end
	function methods:IsShown() return self.shown end
	function methods:SetShown(v) if v then self:Show() else self:Hide() end end
	function methods:GetWidth() return 140 end
	function methods:GetCenter() return 0, 0 end
	function methods:GetEffectiveScale() return 1 end
	function methods:CreateFontString() return NewFrame(client) end
	function methods:CreateTexture() return NewFrame(client) end
	function methods:SetText(t) self.text = t end
	function methods:GetText() return self.text end
	setmetatable(f, { __index = function(_, k)
		if k == "TitleText" then return nil end -- a field, not a method
		return methods[k] or function() return NewFrame(client) end
	end })
	client.frames[#client.frames + 1] = f
	return f
end

---------------------------------------------------------------------------
-- Clients
---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

function Client:FireEvent(event, ...)
	for _, f in ipairs(self.frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end

function Client:SystemMessage(msg)
	for _, filter in ipairs(self.filters) do
		if filter(nil, "CHAT_MSG_SYSTEM", msg) then return end
	end
	self.chat[#self.chat + 1] = msg
end

function Client:ChatContains(text)
	for _, line in ipairs(self.chat) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

function Client:Slash(input)
	self.env.SlashCmdList.TEAMWOW(input)
end

function Client:GroupMembers()
	return self.group and self.group.members or { self }
end

local function Deliver(to, text, channel, from)
	Sim.inbox[#Sim.inbox + 1] = function()
		if to.online then
			to:FireEvent("CHAT_MSG_ADDON", "TeamWOW", text, channel, from.fullName)
		end
	end
end

function Sim.NewClient(name, opts)
	opts = opts or {}
	local client = setmetatable({
		name = name,
		realm = opts.realm or "Forever",
		class = opts.class or "WARRIOR",
		level = opts.level or 1,
		guild = opts.guild,
		db = opts.db,
		frames = {},
		filters = {},
		chat = {},
	}, Client)
	client.fullName = name .. "-" .. client.realm
	if client.guild then
		Sim.guilds[client.guild] = Sim.guilds[client.guild] or {}
		Sim.guilds[client.guild][client.fullName] = false
	end
	return client
end

function Client:BuildEnv()
	local client = self
	local env = setmetatable({}, { __index = _G })
	env._G = env

	env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
	env.tostringall = function(...)
		local t = { ... }
		for i = 1, select("#", ...) do t[i] = tostring(t[i]) end
		return unpack(t, 1, select("#", ...))
	end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.tinsert = table.insert
	env.geterrorhandler = function() return function(e) error(e, 0) end end
	env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) client.chat[#client.chat + 1] = msg end }
	env.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
	local function timer(d, fn, interval)
		local t = AddTimer(d, fn, interval)
		t.client = client
		return t
	end
	env.C_Timer = {
		After = function(d, fn) timer(d, fn) end,
		NewTimer = function(d, fn) return timer(d, fn) end,
		NewTicker = function(d, fn) return timer(d, fn, d) end,
	}
	env.GetTime = function() return Sim.now end
	env.time = function() return math.floor(Sim.epoch + Sim.now) end
	env.GetServerTime = env.time
	env.CreateFrame = function() return NewFrame(client) end
	env.UIParent = NewFrame(client)
	env.Minimap = NewFrame(client)
	env.GameTooltip = NewFrame(client)
	env.UISpecialFrames = {}
	env.RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
	env.LOCALIZED_CLASS_NAMES_MALE = {}
	env.SlashCmdList = {}

	-- identity
	env.GetNormalizedRealmName = function() return client.realm end
	env.GetRealmName = function() return client.realm end
	env.UnitName = function(unit) if unit == "player" then return client.name end end
	env.UnitClass = function() return client.class, client.class end
	env.UnitRace = function() return "Human", "Human" end
	env.UnitFactionGroup = function() return "Alliance", "Alliance" end
	env.UnitLevel = function() return client.level end
	env.UnitIsPlayer = function() return false end
	env.GetUnitName = function() return nil end

	-- guild
	env.IsInGuild = function() return client.guild ~= nil end
	env.GetGuildInfo = function() return client.guild end
	local function roster()
		local list = {}
		for full, member in pairs(Sim.guilds[client.guild] or {}) do
			list[#list + 1] = { full, member and member.online }
		end
		table.sort(list, function(a, b) return a[1] < b[1] end)
		return list
	end
	env.GetNumGuildMembers = function() return #roster() end
	env.GetGuildRosterInfo = function(i)
		local m = roster()[i]
		return m[1], nil, nil, nil, nil, nil, nil, nil, m[2]
	end
	env.C_GuildInfo = { GuildRoster = function()
		Sim.inbox[#Sim.inbox + 1] = function() client:FireEvent("GUILD_ROSTER_UPDATE") end
	end }

	-- group
	local function inGroup(name)
		for _, m in ipairs(client:GroupMembers()) do
			if m ~= client and (m.name == name or m.fullName == name) then return m end
		end
	end
	env.LE_PARTY_CATEGORY_INSTANCE = 2
	env.IsInGroup = function(cat) return cat == nil and client.group ~= nil end
	env.IsInRaid = function() return false end
	env.GetNumGroupMembers = function() return client.group and #client.group.members or 0 end
	env.UnitInParty = function(name) return inGroup(name) ~= nil end
	env.UnitInRaid = function() return nil end
	env.UnitIsConnected = function(name) local m = inGroup(name) return m and m.online end
	env.Ambiguate = function(name)
		local char, realm = name:match("^([^%-]+)%-(.+)$")
		if char and realm == client.realm then return char end
		return name
	end

	-- chat
	env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
	env.ChatFrame_AddMessageEventFilter = function(_, fn) client.filters[#client.filters + 1] = fn end
	env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8 } }
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(p) assert(#p <= 16) return true end,
		SendAddonMessage = function(prefix, text, channel, target)
			assert(prefix == "TeamWOW")
			assert(#text <= 255, "addon message too long: " .. #text)
			Sim.sent = Sim.sent + 1
			if channel == "GUILD" then
				for full in pairs(Sim.guilds[client.guild] or {}) do
					local to = Sim.clients[full]
					if to then Deliver(to, text, channel, client) end -- includes echo to self
				end
			elseif channel == "PARTY" or channel == "RAID" then
				for _, to in ipairs(client:GroupMembers()) do Deliver(to, text, channel, client) end
			elseif channel == "WHISPER" then
				local to = Sim.clients[target]
				if to then
					Deliver(to, text, channel, client)
				else
					Sim.inbox[#Sim.inbox + 1] = function()
						client:SystemMessage(env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(target))
					end
				end
			else
				error("unexpected channel " .. tostring(channel))
			end
			return 0
		end,
	}

	return env
end

function Client:Login()
	self.frames = {}
	self.filters = {}
	self.env = self:BuildEnv()
	self.env.TeamWOWDB = self.db
	local ns = {}
	for _, file in ipairs(TOC_FILES) do
		local chunk = assert(loadfile(ADDON_DIR .. file))
		setfenv(chunk, self.env)
		chunk("TeamWOW", ns)
	end
	self.ns = ns
	self.addon = ns.TeamWOW
	self.online = true
	Sim.clients[self.fullName] = self
	if self.guild then Sim.guilds[self.guild][self.fullName] = self end
	self:FireEvent("ADDON_LOADED", "TeamWOW")
	self:FireEvent("PLAYER_LOGIN")
	return self
end

function Client:Logout()
	self.online = false
	Sim.clients[self.fullName] = nil
	if self.guild then Sim.guilds[self.guild][self.fullName] = false end
	-- the client stops running: unhook its frames and cancel its timers
	self.db = self.env.TeamWOWDB
	for _, f in ipairs(self.frames) do f.scripts = {} ; f.events = {} end
	for _, t in ipairs(Sim.timers) do
		if t.client == self then t.cancelled = true end
	end
end

-- Puts clients in a party together.
function Sim.Group(...)
	local group = { members = { ... } }
	for _, c in ipairs(group.members) do c.group = group end
	for _, c in ipairs(group.members) do
		if c.online then c:FireEvent("GROUP_ROSTER_UPDATE") end
	end
end

function Sim.Reset()
	Sim.now = 1000
	Sim.timers = {}
	Sim.clients = {}
	Sim.inbox = {}
	Sim.guilds = {}
	Sim.sent = 0
end

return Sim
