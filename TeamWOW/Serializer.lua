-- Table <-> string serializer for addon messages and nothing else.
--
-- Format (no escaping needed because strings are length-prefixed):
--   T / F            true / false
--   i<int>;          integer
--   n<float>;        other number
--   s<len>:<bytes>   string
--   { k v k v ... }  table
-- Deserializing never runs code, and rejects anything malformed.

local _, ns = ...

local Serializer = {}
ns.Serializer = Serializer

local MAX_DEPTH = 32

local format, tostring, tonumber, type, pairs = string.format, tostring, tonumber, type, pairs
local floor, huge = math.floor, math.huge
local sub, find = string.sub, string.find
local concat = table.concat

local function write(value, out, depth)
	local t = type(value)
	if t == "string" then
		out[#out + 1] = "s" .. #value .. ":" .. value
	elseif t == "number" then
		if value ~= value or value == huge or value == -huge then
			value = 0
		end
		if value == floor(value) and value > -2^53 and value < 2^53 then
			-- %.0f rather than %d: %d is 32-bit on some clients.
			out[#out + 1] = format("i%.0f;", value)
		else
			out[#out + 1] = "n" .. format("%.17g", value) .. ";"
		end
	elseif t == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif t == "table" then
		if depth >= MAX_DEPTH then error("table nested too deeply", 0) end
		out[#out + 1] = "{"
		for k, v in pairs(value) do
			local kt, vt = type(k), type(v)
			if (kt == "string" or kt == "number") and vt ~= "function" and vt ~= "userdata" and vt ~= "thread" then
				write(k, out, depth + 1)
				write(v, out, depth + 1)
			end
		end
		out[#out + 1] = "}"
	else
		error("cannot serialize " .. t, 0)
	end
end

function Serializer.Serialize(value)
	local out = {}
	write(value, out, 0)
	return concat(out)
end

-- Returns value, nextPos  or  nil, errorMessage
local function read(str, pos, depth)
	local c = sub(str, pos, pos)
	if c == "T" then
		return true, pos + 1
	elseif c == "F" then
		return false, pos + 1
	elseif c == "i" or c == "n" then
		local stop = find(str, ";", pos + 1, true)
		if not stop then return nil, "unterminated number" end
		local num = tonumber(sub(str, pos + 1, stop - 1))
		if not num then return nil, "bad number" end
		return num, stop + 1
	elseif c == "s" then
		local colon = find(str, ":", pos + 1, true)
		if not colon then return nil, "bad string" end
		local len = tonumber(sub(str, pos + 1, colon - 1))
		if not len or len < 0 or len ~= floor(len) then return nil, "bad string length" end
		local last = colon + len
		if last > #str then return nil, "truncated string" end
		return sub(str, colon + 1, last), last + 1
	elseif c == "{" then
		if depth >= MAX_DEPTH then return nil, "nested too deeply" end
		local tbl = {}
		pos = pos + 1
		while true do
			if pos > #str then return nil, "unterminated table" end
			if sub(str, pos, pos) == "}" then return tbl, pos + 1 end
			local key, val
			key, pos = read(str, pos, depth + 1)
			if key == nil then return nil, pos end
			if type(key) == "table" or type(key) == "boolean" then return nil, "bad key" end
			val, pos = read(str, pos, depth + 1)
			if val == nil then return nil, pos end
			tbl[key] = val
		end
	end
	return nil, "unexpected '" .. c .. "' at " .. pos
end

-- Returns true, value  or  false, errorMessage
function Serializer.Deserialize(str)
	if type(str) ~= "string" or str == "" then return false, "empty" end
	local value, pos = read(str, 1, 0)
	if value == nil then return false, pos end
	if pos ~= #str + 1 then return false, "trailing data" end
	return true, value
end
