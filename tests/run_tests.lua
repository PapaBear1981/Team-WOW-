-- Run from the repo root:  lua5.1 tests/run_tests.lua

package.path = (arg[0]:match("^(.*)/tests/") or ".") .. "/tests/?.lua;" .. package.path
local Sim = require("sim")

local passed, failed = 0, 0

local function test(name, fn)
	Sim.Reset()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("ok    " .. name)
	else
		failed = failed + 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function deepEq(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local function info(client, owner)
	return client.addon:GetSection(owner.fullName, "info")
end

---------------------------------------------------------------------------
-- Serializer
---------------------------------------------------------------------------

local function LoadSerializer()
	local ns = {}
	local chunk = assert(loadfile((arg[0]:match("^(.*)/tests/") or ".") .. "/TeamWOW/Serializer.lua"))
	chunk("TeamWOW", ns)
	return ns.Serializer
end

test("serializer round-trips nested tables", function()
	local S = LoadSerializer()
	local value = {
		"a", "b:c", 1, -2, 3.25, 1e15, 2 ^ 40, true, false,
		nested = { deep = { deeper = { "x" } }, ["key with spaces"] = "\t{}s5:" },
		[10] = "sparse", empty = "", unicode = "Ælfríc",
	}
	local ok, out = S.Deserialize(S.Serialize(value))
	assert(ok, out)
	assert(deepEq(value, out), "round trip mismatch")
end)

test("serializer rejects malformed input without erroring", function()
	local S = LoadSerializer()
	local good = S.Serialize({ a = { 1, 2, "three" }, b = true })
	for i = 0, #good - 1 do
		local ok = S.Deserialize(good:sub(1, i))
		eq(ok, false, "prefix of length " .. i)
	end
	for _, bad in ipairs({ "x", "s99:abc", "s-1:", "{s1:a", "{T T}", "i12", "nabc;", "{{}T}", "TT" }) do
		eq((S.Deserialize(bad)), false, "input " .. bad)
	end
	eq((S.Deserialize(string.rep("{", 100) .. string.rep("}", 100))), false, "deep nesting")
end)

test("serializer drops functions and NaN", function()
	local S = LoadSerializer()
	local ok, out = S.Deserialize(S.Serialize({ f = print, n = 0 / 0, x = 1 }))
	assert(ok)
	eq(out.f, nil, "function")
	eq(out.n, 0, "nan")
	eq(out.x, 1)
end)

---------------------------------------------------------------------------
-- Sync scenarios
---------------------------------------------------------------------------

test("guildmates sync automatically", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow", class = "MAGE", level = 10 }):Login()
	local bob = Sim.NewClient("Bob", { guild = "Wow", class = "ROGUE", level = 12 }):Login()
	Sim.Advance(20)
	eq(info(alice, bob).class, "ROGUE", "Alice sees Bob")
	eq(info(bob, alice).level, 10, "Bob sees Alice")
	eq(#bob.chat == 0 or not bob:ChatContains("wants to sync"), true, "no stranger prompt")
end)

test("level up propagates", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow" }):Login()
	local bob = Sim.NewClient("Bob", { guild = "Wow" }):Login()
	Sim.Advance(20)
	alice.level = 2
	alice:FireEvent("PLAYER_LEVEL_UP", 2)
	Sim.Advance(20)
	eq(info(bob, alice).level, 2)
end)

test("no guild: whisper sync between team members", function()
	local alice = Sim.NewClient("Alice"):Login()
	local bob = Sim.NewClient("Bob"):Login()
	alice:Slash("add Bob")
	bob:Slash("add alice")
	Sim.Advance(20)
	eq(info(alice, bob) ~= nil, true, "Alice has Bob")
	eq(info(bob, alice) ~= nil, true, "Bob has Alice")
end)

test("stranger is announced and ignored", function()
	local alice = Sim.NewClient("Alice"):Login()
	local eve = Sim.NewClient("Eve"):Login()
	eve:Slash("add Alice")
	Sim.Advance(20)
	eq(alice:ChatContains("Eve-Forever is running TeamWOW"), true, "prompt shown")
	eq(info(alice, eve), nil, "Eve's data not accepted")
end)

test("teammates spread by gossip", function()
	local alice = Sim.NewClient("Alice"):Login()
	local bob = Sim.NewClient("Bob"):Login()
	local carol = Sim.NewClient("Carol"):Login()
	alice:Slash("add Bob")
	bob:Slash("add Alice")
	bob:Slash("add Carol")
	carol:Slash("add Bob")
	Sim.Advance(30)
	alice:Slash("sync")
	carol:Slash("sync")
	Sim.Advance(30)
	eq(alice.addon:IsOnTeam(carol.fullName), true, "Alice learned Carol")
	eq(info(alice, carol) ~= nil, true, "Alice has Carol's data")
	eq(info(carol, alice) ~= nil, true, "Carol has Alice's data")
end)

test("data reaches someone who was never online at the same time", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow", level = 5 }):Login()
	local bob = Sim.NewClient("Bob", { guild = "Wow" }):Login()
	Sim.Advance(20)
	alice:Logout()
	local carol = Sim.NewClient("Carol", { guild = "Wow" }):Login()
	Sim.Advance(20)
	eq(info(carol, alice).level, 5, "Carol got Alice's data from Bob")
end)

test("offline teammate: no chat spam, backoff", function()
	local alice = Sim.NewClient("Alice"):Login()
	Sim.NewClient("Dave") -- never logs in
	alice:Slash("add Dave")
	Sim.Advance(20)
	eq(alice:ChatContains("No player named"), false, "system message filtered")
	local before = Sim.sent
	alice:Slash("sync") -- forced sync retries once
	Sim.Advance(1)
	alice.addon:GetModule("Sync"):Broadcast() -- normal broadcast respects backoff
	Sim.Advance(1)
	eq(Sim.sent - before, 1, "only the forced whisper was sent")
end)

test("large sections are chunked and reassembled", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow" }):Login()
	local bob = Sim.NewClient("Bob", { guild = "Wow" }):Login()
	Sim.Advance(20)
	local recipes = alice.addon:GetMySection("prof")
	for i = 1, 300 do recipes[i] = { item = 10000 + i, name = "Recipe number " .. i } end
	alice.addon:TouchSection("prof")
	Sim.Advance(120)
	local got = bob.addon:GetSection(alice.fullName, "prof")
	assert(got, "Bob has Alice's professions")
	assert(deepEq(got, recipes), "profession data intact")
end)

test("reinstall restores your own data from the team", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow" }):Login()
	local bob = Sim.NewClient("Bob", { guild = "Wow" }):Login()
	local pvp = alice.addon:GetMySection("pvp")
	pvp.killingBlows = 42
	alice.addon:TouchSection("pvp")
	Sim.Advance(30)
	alice:Logout()
	alice.db = nil -- wiped SavedVariables
	alice:Login()
	Sim.Advance(30)
	eq(alice.addon:GetMySection("pvp").killingBlows, 42, "restored")
	eq(alice:ChatContains("Restored your pvp data"), true, "told the player")
end)

test("removed players are not re-added by gossip", function()
	local alice = Sim.NewClient("Alice"):Login()
	local bob = Sim.NewClient("Bob"):Login()
	local carol = Sim.NewClient("Carol"):Login()
	for _, pair in ipairs({ { alice, "Bob" }, { bob, "Alice" }, { bob, "Carol" }, { carol, "Bob" } }) do
		pair[1]:Slash("add " .. pair[2])
	end
	Sim.Advance(30)
	alice:Slash("remove Carol")
	alice:Slash("sync")
	bob:Slash("sync")
	Sim.Advance(30)
	eq(alice.addon:IsOnTeam(carol.fullName), false, "still removed")
	eq(info(alice, carol), nil, "no data")
end)

test("party members sync over the group channel", function()
	local alice = Sim.NewClient("Alice"):Login()
	local bob = Sim.NewClient("Bob"):Login()
	alice:Slash("add Bob")
	bob:Slash("add Alice")
	Sim.Advance(1)
	Sim.Group(alice, bob)
	Sim.Advance(20)
	eq(info(bob, alice) ~= nil, true)
end)

test("UI builds and refreshes without errors", function()
	local alice = Sim.NewClient("Alice", { guild = "Wow" }):Login()
	Sim.NewClient("Bob", { guild = "Wow" }):Login()
	Sim.Advance(20)
	alice:Slash("")       -- open window
	alice:Slash("team")
	alice:Slash("status")
	alice:Slash("help")
	alice.ns.UI:Refresh()
	Sim.Advance(1)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
