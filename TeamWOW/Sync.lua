-- Gossip sync between teammates. See DESIGN.md "Sync protocol".
--
--   HELLO  { v, d = digest }   broadcast; receiver requests what it lacks and,
--                              if it holds newer data, replies with DIGEST
--   DIGEST { v, d = digest }   reply to HELLO; receiver only requests
--   REQ    { w = {{owner, section}, ...} }
--   DATA   { o = owner, s = section, r = rev, d = data }
--
-- digest = { [owner] = { [section] = rev } }

local _, ns = ...
local TeamWOW = ns.TeamWOW
local Comm = ns.Comm

local Sync = TeamWOW:NewModule("Sync")
ns.Sync = Sync

local BROADCAST_DEBOUNCE = 5
local PERIODIC_BROADCAST = 300
local LOGIN_DELAY = 5
local OFFLINE_BACKOFF = 600
local REQUEST_TIMEOUT = 60
local MAX_WANTS = 40
local ONLINE_WINDOW = PERIODIC_BROADCAST + 60

local pending = {}      -- owner .. "/" .. section -> { rev, expires }
local guildMembers = {} -- full name -> online (true/false); nil = not in guild
local strangers = {}    -- untrusted senders we've already told the user about
local lastGroupSize = 0

local function ValidSection(section)
	return type(section) == "string" and #section <= 24 and section:match("^%a%w*$") ~= nil
end

---------------------------------------------------------------------------
-- Trust and presence
---------------------------------------------------------------------------

function Sync:IsGuildMember(name)
	return guildMembers[name] ~= nil
end

function Sync:IsTrusted(name)
	if not name or TeamWOW.db.blocked[name] then return false end
	if TeamWOW:IsOnTeam(name) then return true end
	return TeamWOW.db.settings.trustGuild and guildMembers[name] ~= nil
end

local function GroupUnitName(name)
	return Ambiguate and Ambiguate(name, "none") or TeamWOW:ShortName(name)
end

local function InMyGroup(name)
	local unit = GroupUnitName(name)
	return (UnitInRaid(unit) or UnitInParty(unit)) and true or false
end

-- true = online, false = offline, nil = unknown
function Sync:IsOnline(name)
	if name == TeamWOW.playerName then return true end
	if InMyGroup(name) then
		return UnitIsConnected(GroupUnitName(name)) and true or false
	end
	if guildMembers[name] ~= nil then return guildMembers[name] end
	local peer = TeamWOW.db.peers[name]
	if peer and peer.offlineUntil and peer.offlineUntil > time() then return false end
	if peer and peer.lastSeen and time() - peer.lastSeen < ONLINE_WINDOW then return true end
	return nil
end

function Sync:OnWhisperFailed(name)
	local peer = TeamWOW.db.peers[name] or {}
	TeamWOW.db.peers[name] = peer
	if not (peer.offlineUntil and peer.offlineUntil > time()) then
		TeamWOW:Debug(name, "is offline")
	end
	peer.offlineUntil = time() + OFFLINE_BACKOFF
end

local function SeePeer(name, version)
	local peer = TeamWOW.db.peers[name] or {}
	TeamWOW.db.peers[name] = peer
	peer.lastSeen = time()
	peer.offlineUntil = nil
	if type(version) == "string" then peer.version = version end
	TeamWOW:Fire("PEER_SEEN", name)
end

---------------------------------------------------------------------------
-- Digests
---------------------------------------------------------------------------

function Sync:BuildDigest()
	local digest = {}
	for owner, player in pairs(TeamWOW.db.players) do
		if player.sections and self:IsTrusted(owner) then
			for section, rec in pairs(player.sections) do
				if rec.rev and rec.rev > 0 then
					digest[owner] = digest[owner] or {}
					digest[owner][section] = rec.rev
				end
			end
		end
	end
	return digest
end

-- Do we hold anything newer than (or missing from) this digest?
local function HasNewerThan(digest)
	for owner, player in pairs(TeamWOW.db.players) do
		if player.sections and Sync:IsTrusted(owner) then
			local theirs = type(digest[owner]) == "table" and digest[owner] or {}
			for section, rec in pairs(player.sections) do
				local rev = theirs[section]
				if rec.rev > 0 and (type(rev) ~= "number" or rev < rec.rev) then
					return true
				end
			end
		end
	end
	return false
end

local function CompareDigest(digest, sender, reply)
	if type(digest) ~= "table" then return end
	local wants = {}
	local now = GetTime()
	for owner, sections in pairs(digest) do
		owner = TeamWOW:NormalizeName(owner)
		if owner and type(sections) == "table" then
			-- A trusted teammate vouches for everyone in their digest.
			if not Sync:IsTrusted(owner) and not TeamWOW.db.blocked[owner] then
				if TeamWOW:AddTeamMember(owner, true) then
					TeamWOW:Print("Added", owner, "to the team (shared by " .. TeamWOW:ShortName(sender) .. ").")
				end
			end
			if Sync:IsTrusted(owner) then
				for section, rev in pairs(sections) do
					if #wants >= MAX_WANTS then break end
					if ValidSection(section) and type(rev) == "number" and rev > TeamWOW:GetSectionRev(owner, section) then
						local key = owner .. "/" .. section
						local p = pending[key]
						if not p or p.expires < now or p.rev < rev then
							pending[key] = { rev = rev, expires = now + REQUEST_TIMEOUT }
							wants[#wants + 1] = { owner, section }
						end
					end
				end
			end
		end
	end
	if #wants > 0 then
		TeamWOW:Debug("requesting", #wants, "section(s) from", sender)
		Comm:Send({ t = "REQ", w = wants }, "WHISPER", sender)
	end
	if reply and HasNewerThan(digest) then
		Comm:Send({ t = "DIGEST", v = TeamWOW.version, d = Sync:BuildDigest() }, "WHISPER", sender)
	end
end

---------------------------------------------------------------------------
-- Message handlers
---------------------------------------------------------------------------

local handlers = {}

function handlers.HELLO(msg, sender)
	CompareDigest(msg.d, sender, true)
end

function handlers.DIGEST(msg, sender)
	CompareDigest(msg.d, sender, false)
end

function handlers.REQ(msg, sender)
	if type(msg.w) ~= "table" then return end
	local sent = 0
	for _, want in ipairs(msg.w) do
		if sent >= MAX_WANTS then break end
		if type(want) == "table" then
			local owner, section = TeamWOW:NormalizeName(want[1]), want[2]
			local rec = owner and ValidSection(section) and Sync:IsTrusted(owner)
				and TeamWOW:GetSectionRecord(owner, section)
			if rec and rec.rev > 0 then
				Comm:Send({ t = "DATA", o = owner, s = section, r = rec.rev, d = rec.data }, "WHISPER", sender, "BULK")
				sent = sent + 1
			end
		end
	end
end

function handlers.DATA(msg, sender)
	local owner, section, rev, data = TeamWOW:NormalizeName(msg.o), msg.s, msg.r, msg.d
	if not owner or not ValidSection(section) or type(rev) ~= "number" or type(data) ~= "table" then return end
	if not Sync:IsTrusted(owner) then return end
	pending[owner .. "/" .. section] = nil
	if rev <= TeamWOW:GetSectionRev(owner, section) then return end
	TeamWOW:Debug("got", owner, section, "rev", rev, "from", sender)
	TeamWOW:SetSection(owner, section, rev, data)
	if owner == TeamWOW.playerName then
		TeamWOW:Print("Restored your", section, "data from", TeamWOW:ShortName(sender) .. ".")
	end
end

local function OnMessage(msg, sender, channel)
	local handler = type(msg.t) == "string" and handlers[msg.t]
	if not handler then return end
	-- The guild roster loads late; anyone talking on GUILD is a guildmate.
	if channel == "GUILD" and guildMembers[sender] == nil then
		guildMembers[sender] = true
	end
	if not Sync:IsTrusted(sender) then
		if msg.t == "HELLO" and not strangers[sender] then
			strangers[sender] = true
			TeamWOW:Print(sender, "is running TeamWOW and wants to sync. Type |cffffff00/tw add",
				sender .. "|r to add them to your team.")
		end
		return
	end
	SeePeer(sender, msg.v)
	handler(msg, sender, channel)
end

---------------------------------------------------------------------------
-- Broadcasting
---------------------------------------------------------------------------

function Sync:Broadcast()
	if not TeamWOW.playerName then return end
	if self.broadcastTimer then
		self.broadcastTimer:Cancel()
		self.broadcastTimer = nil
	end
	local msg = { t = "HELLO", v = TeamWOW.version, d = self:BuildDigest() }
	if IsInGuild() then Comm:Send(msg, "GUILD") end
	local groupChannel = Comm:GetGroupChannel()
	if groupChannel then Comm:Send(msg, groupChannel) end
	for name in pairs(TeamWOW.db.team) do
		local reached = guildMembers[name] ~= nil or (groupChannel and InMyGroup(name))
		if not reached and self:IsOnline(name) ~= false then
			Comm:Send(msg, "WHISPER", name)
		end
	end
	TeamWOW:Debug("broadcast HELLO")
end

-- Debounced broadcast, used after our own data changes.
function Sync:ScheduleBroadcast(delay)
	if self.broadcastTimer or not TeamWOW.playerName then return end
	self.broadcastTimer = C_Timer.NewTimer(delay or BROADCAST_DEBOUNCE, function()
		self.broadcastTimer = nil
		self:Broadcast()
	end)
end

-- Forget about offline backoff and sync with everyone now.
function Sync:ForceSync()
	for _, peer in pairs(TeamWOW.db.peers) do peer.offlineUntil = nil end
	wipe(pending)
	self:Broadcast()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function RequestGuildRoster()
	if not IsInGuild() then return end
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

function Sync:GUILD_ROSTER_UPDATE()
	wipe(guildMembers)
	if not IsInGuild() then return end
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		name = TeamWOW:NormalizeName(name)
		if name then guildMembers[name] = online and true or false end
	end
	TeamWOW:Fire("PRESENCE_CHANGED")
end

function Sync:PLAYER_GUILD_UPDATE()
	if IsInGuild() then
		RequestGuildRoster()
	else
		wipe(guildMembers)
	end
end

function Sync:GROUP_ROSTER_UPDATE()
	local size = GetNumGroupMembers()
	if size > lastGroupSize then
		self:ScheduleBroadcast(2)
	end
	lastGroupSize = size
	TeamWOW:Fire("PRESENCE_CHANGED")
end

function Sync:OnInitialize()
	Comm.handler = OnMessage
	Comm:Init()
end

function Sync:OnEnable()
	self:RegisterEvent("GUILD_ROSTER_UPDATE")
	self:RegisterEvent("PLAYER_GUILD_UPDATE")
	self:RegisterEvent("GROUP_ROSTER_UPDATE")
	lastGroupSize = GetNumGroupMembers()
	RequestGuildRoster()
	C_Timer.After(LOGIN_DELAY, function() self:Broadcast() end)
	C_Timer.NewTicker(PERIODIC_BROADCAST, function() self:Broadcast() end)
end
