-- Addon-message transport: serializes tables, splits them into 255-byte
-- chunks, throttles sending so Blizzard doesn't drop messages, and
-- reassembles chunks on the receiving side.
--
-- Wire format of one addon message:  <id>\t<index>\t<total>\t<payload bytes>

local _, ns = ...
local TeamWOW = ns.TeamWOW
local Serializer = ns.Serializer

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "TeamWOW"

local CHUNK_SIZE = 230       -- leaves room for the header within 255 bytes
local MAX_CHUNKS = 400
local BURST = 8              -- messages we may send back to back
local REFILL_SECONDS = 1     -- then one message per second
local PARTIAL_TIMEOUT = 60   -- drop half-received messages after this long
local WHISPER_FAIL_WINDOW = 10

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

---------------------------------------------------------------------------
-- Send queue
---------------------------------------------------------------------------

-- ALERT: small control messages (HELLO/REQ). BULK: section data.
local queues = { ALERT = {}, BULK = {} }
local tokens = BURST
local nextId = 0
local recentWhispers = {} -- target -> GetTime() of last whisper

local pump = CreateFrame("Frame")
pump:Hide()

local function QueueSize()
	return #queues.ALERT + #queues.BULK
end

local function IsThrottleResult(result)
	local R = Enum and Enum.SendAddonMessageResult
	if R then
		return result == R.AddonMessageThrottle or result == R.ChannelThrottle
	end
	return result == 3 or result == 8
end

-- Returns true if the item was sent or should be dropped, false to retry.
local function RawSend(item)
	if item.channel == "WHISPER" then
		recentWhispers[item.target] = GetTime()
	end
	local result = SendAddonMessage(Comm.PREFIX, item.text, item.channel, item.target)
	-- Older clients return nil/boolean, newer ones an enum where 0 is success.
	if result == nil or result == true or result == 0 then return true end
	if IsThrottleResult(result) then return false end
	TeamWOW:Debug("send failed", tostring(result), item.channel, item.target or "")
	return true
end

pump:SetScript("OnUpdate", function(self, elapsed)
	tokens = math.min(BURST, tokens + elapsed / REFILL_SECONDS)
	while tokens >= 1 do
		local queue = (#queues.ALERT > 0 and queues.ALERT) or (#queues.BULK > 0 and queues.BULK)
		if not queue then
			self:Hide()
			return
		end
		local item = queue[1]
		if RawSend(item) then
			table.remove(queue, 1)
			tokens = tokens - 1
		else
			tokens = 0 -- server says slow down; try again shortly
			return
		end
	end
end)

-- Sends a table. channel: GUILD, PARTY, RAID, INSTANCE_CHAT or WHISPER.
-- priority: "ALERT" (default) or "BULK".
function Comm:Send(msg, channel, target, priority)
	local ok, text = pcall(Serializer.Serialize, msg)
	if not ok then
		TeamWOW:Debug("serialize failed:", text)
		return false
	end
	if text:find("\0", 1, true) then
		TeamWOW:Debug("refusing to send message containing NUL")
		return false
	end
	local total = math.max(1, math.ceil(#text / CHUNK_SIZE))
	if total > MAX_CHUNKS then
		TeamWOW:Debug("message too large:", #text, "bytes")
		return false
	end
	nextId = (nextId + 1) % 0x100000
	local id = string.format("%x", nextId)
	local queue = queues[priority or "ALERT"] or queues.ALERT
	for i = 1, total do
		local piece = text:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
		queue[#queue + 1] = {
			channel = channel,
			target = target,
			text = id .. "\t" .. i .. "\t" .. total .. "\t" .. piece,
		}
	end
	pump:Show()
	return true
end

-- Drops everything queued for a whisper target (e.g. they went offline).
function Comm:DropTarget(target)
	for _, queue in pairs(queues) do
		for i = #queue, 1, -1 do
			if queue[i].channel == "WHISPER" and queue[i].target == target then
				table.remove(queue, i)
			end
		end
	end
end

function Comm:GetQueueSize()
	return QueueSize()
end

-- Group channel to use right now, or nil if not grouped.
function Comm:GetGroupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local partials = {} -- sender .. ":" .. id -> { total, count, parts, time }

local function Deliver(text, sender, channel)
	local ok, msg = Serializer.Deserialize(text)
	if not ok or type(msg) ~= "table" then
		TeamWOW:Debug("bad message from", sender, ok and "(not a table)" or msg)
		return
	end
	if Comm.handler then
		Comm.handler(msg, sender, channel)
	end
end

function Comm:CHAT_MSG_ADDON(_, prefix, text, channel, sender)
	if prefix ~= Comm.PREFIX or not TeamWOW.playerName then return end
	sender = TeamWOW:NormalizeName(sender)
	if not sender or sender == TeamWOW.playerName then return end

	local id, index, total, payload = text:match("^(%x+)\t(%d+)\t(%d+)\t(.*)$")
	index, total = tonumber(index), tonumber(total)
	if not id or not index or not total or index < 1 or index > total or total > MAX_CHUNKS then
		return
	end

	if total == 1 then
		Deliver(payload, sender, channel)
		return
	end

	local key = sender .. ":" .. id
	local partial = partials[key]
	if not partial or partial.total ~= total then
		partial = { total = total, count = 0, parts = {} }
		partials[key] = partial
	end
	partial.time = GetTime()
	if not partial.parts[index] then
		partial.parts[index] = payload
		partial.count = partial.count + 1
	end
	if partial.count == total then
		partials[key] = nil
		Deliver(table.concat(partial.parts), sender, channel)
	end
end

local function CleanupPartials()
	local now = GetTime()
	for key, partial in pairs(partials) do
		if now - partial.time > PARTIAL_TIMEOUT then
			partials[key] = nil
		end
	end
	for target, t in pairs(recentWhispers) do
		if now - t > WHISPER_FAIL_WINDOW then
			recentWhispers[target] = nil
		end
	end
end

---------------------------------------------------------------------------
-- "No player named X is currently playing" for teammates we whispered:
-- hide the spam and tell Sync they're offline.
---------------------------------------------------------------------------

local function FormatToPattern(fmt)
	local pattern = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
	pattern = pattern:gsub("%%s", "(.+)")
	return "^" .. pattern .. "$"
end

local notFoundPattern

local function SystemMessageFilter(_, _, msg, ...)
	if not notFoundPattern or type(msg) ~= "string" then return false end
	local name = msg:match(notFoundPattern)
	if not name then return false end
	name = TeamWOW:NormalizeName(name)
	-- Filters run once per chat frame, so this must stay idempotent.
	if name and recentWhispers[name] then
		Comm:DropTarget(name)
		if ns.Sync then ns.Sync:OnWhisperFailed(name) end
		return true
	end
	return false
end

---------------------------------------------------------------------------

function Comm:Init()
	if RegisterPrefix then RegisterPrefix(Comm.PREFIX) end
	TeamWOW.RegisterEvent(self, "CHAT_MSG_ADDON")
	if ERR_CHAT_PLAYER_NOT_FOUND_S then
		notFoundPattern = FormatToPattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
		local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
		if addFilter then addFilter("CHAT_MSG_SYSTEM", SystemMessageFilter) end
	end
	C_Timer.NewTicker(30, CleanupPartials)
end
