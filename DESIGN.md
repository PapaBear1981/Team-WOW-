# TeamWOW — Design

> **TeamWOW** is a placeholder name. Renaming is a find/replace of `TeamWOW`
> (folder, `.toc`, saved variable, addon-message prefix).

A private addon for a group of ~5 friends playing **WoW Forever** that tracks
and shares:

- PvP: honorable kills, killing blows, deaths, nemesis list
- Combat: DPS/HPS per boss and per dungeon run, personal bests, leaderboards
- Professions: skill levels, known recipes, "who can craft X", tooltip lines
- Team roster: class, level, guild, last seen, addon version
- Extras: leveling race, death log, gold, weekly awards

Details! is the group's live damage meter. TeamWOW does **not** replace it; it
records each player's own numbers so they can be compared across the team
over time.

## Target client

WoW Forever launches **2026-11-04** on the modern client (reported build
1.60.1, interface `16001`). We write against the modern API
(`C_ChatInfo`, `CombatLogGetCurrentEventInfo`, `ENCOUNTER_START/END`,
`BackdropTemplate`) and feature-detect anything that differs between
Classic-style and retail-style clients (notably the trade skill API).

**Launch-night checklist**

1. `/run print((select(4, GetBuildInfo())))` — confirm the interface number
   and update `## Interface:` in `TeamWOW.toc` if it differs.
2. Confirm the AddOns folder (reported as `_forever_/Interface/AddOns`).
3. `/tw debug` then `/tw sync` with two players online; check messages flow.

## Architecture

```
┌────────────┐  section updates  ┌──────────┐  digests / requests / data  ┌───────────┐
│  Modules   │ ────────────────► │   Sync   │ ◄─────────────────────────► │   Comm    │ ── addon messages ──► other players
│ PvP,Combat │                   │ (merge,  │                             │ (chunking,│
│ Prof,Roster│ ◄──── callbacks ─ │ versions)│                             │ throttle) │
└────────────┘                   └──────────┘                             └───────────┘
        ▲                              │
        │                              ▼
        └──────────── TeamWOWDB (SavedVariables, every client holds the whole team) ──┘
```

There is no server. Every client stores a full copy of the team's data and
they reconcile with each other whenever two of them can talk.

### Data model (`TeamWOWDB`, account-wide)

```lua
TeamWOWDB = {
  schema   = 1,
  settings = { debug = false, trustGuild = true, minimap = { angle = 200, hide = false } },
  team     = { ["Bob-Realm"] = true, ... },        -- whisper-sync list
  peers    = { ["Bob-Realm"] = { lastSeen = t, version = "0.1.0" } }, -- local only, never synced
  players  = {
    ["Alice-Realm"] = {
      sections = {
        info  = { rev = 1730000123, data = { class = "MAGE", level = 42, ... } },
        pvp   = { rev = ..., data = { ... } },
        prof  = { rev = ..., data = { ... } },
        combat= { rev = ..., data = { ... } },
        stats = { rev = ..., data = { ... } },
      },
    },
  },
}
```

A player's data is split into **sections**, each with its own revision, so a
new killing blow doesn't resend a 300-recipe profession list.

### Ownership and revisions

- **Each player is the only author of their own sections.** Nobody records
  anyone else's kills or damage, so nothing is double counted.
- A section's `rev` is `max(oldRev + 1, GetServerTime())`. Using server time
  means a player who deletes their SavedVariables (rev back to 0) is still
  "older" than the copies their friends hold, so…
- **Self-restore:** if a peer offers a newer copy of *your own* section, you
  accept it. Reinstalling the addon gets your lifetime stats back from the
  team.
- Merge rule for everyone else: higher `rev` wins, whole section replaced.

### Sync protocol

All messages use addon-message prefix `TeamWOW` and a serialized table
`{ t = <type>, ... }`.

| Type   | Sent when | Payload | Receiver does |
|--------|-----------|---------|---------------|
| `HELLO`| login, group/guild join, own data changed (debounced 5 s), every 5 min, `/tw sync` | `d` = digest `{ [owner] = { [section] = rev } }`, `v` = addon version | requests anything newer it lacks; if it holds newer data the sender lacks, replies with `DIGEST` (whisper) |
| `DIGEST`| reply to `HELLO` | same as `HELLO` | requests what it lacks (no further reply → no ping-pong) |
| `REQ`  | after comparing a digest | `w` = `{ {owner, section}, ... }` | sends one `DATA` per requested section (whisper) |
| `DATA` | reply to `REQ` | `o` owner, `s` section, `r` rev, `d` data | merges if newer |

Data spreads by gossip: if Alice syncs with Bob on Monday and Bob with Carol on
Tuesday, Carol gets Alice's data without ever seeing her online.

### Channels

The addon picks every channel that currently works:

1. **GUILD** — if in a guild. Keeps everyone synced while online.
2. **RAID / PARTY / INSTANCE_CHAT** — while grouped.
3. **WHISPER** to each name on the team list (`/tw add Name`) — works with no
   guild and no group. "Player not found" system spam for offline teammates
   is filtered out.

Requests and data are always whispered to the one peer involved, so a request
in a 5-person group isn't answered five times.

### Trust

Messages are accepted only from **trusted** senders, and data only for trusted
owners:

- Team-list members are trusted. Anyone in your guild is trusted too while
  `trustGuild` is on (the default; `/tw guildtrust` toggles it).
- **A teammate vouches for their teammates.** Everyone in a trusted peer's
  digest is added to your team list, so with no guild only one pair of people
  has to `/tw add` each other to get started and the rest spreads by gossip.
- If someone who isn't trusted sends a `HELLO`, you get a single chat line
  telling you to `/tw add` them. Until then, their messages are ignored.
- `/tw remove Name` deletes their data and blocks them, so gossip doesn't add
  them back. `/tw add` lifts the block.

This is a friends-only addon: there is no cryptographic protection against a teammate
editing their own SavedVariables, and that is fine.

### Transport (Comm)

- Addon messages are limited to 255 bytes. Payloads are serialized
  (custom length-prefixed format, no `loadstring`) and split into chunks:
  `<id>\t<index>\t<total>\t<bytes>`. The receiver reassembles per sender + id
  and drops partial messages after 60 s.
- Blizzard throttles addon messages per prefix. Comm uses a token bucket
  (burst 8, refill 1 message/second) with a FIFO queue, so a big profession
  list trickles out in the background instead of being dropped.

## Modules

Modules register with `TeamWOW:NewModule(name)` and get `OnInitialize`,
`OnEnable`, `RegisterEvent`, and helpers for their own section:

```lua
local data = TeamWOW:GetMySection("pvp")   -- mutable table
data.killingBlows = data.killingBlows + 1
TeamWOW:TouchSection("pvp")                  -- bump rev, schedule broadcast
```

Other players' data: `TeamWOW:IterateSection("pvp")` → `owner, data`.
UI listens for `TeamWOW:RegisterCallback("SECTION_UPDATED", fn)`.

### Roster (`info`)  — *built*
Class, race, level, faction, guild, addon version. Updated on login and level
up. Online/last-seen is derived locally from received messages.

### PvP (`pvp`) — *next*
- Honorable kills from `GetPVPLifetimeStats()` (server-tracked).
- Killing blows: combat log `PARTY_KILL` where source is the player and the
  destination GUID is a player.
- Deaths to players: `UNIT_DIED` for the player, attribute to the last enemy
  player that damaged us within a few seconds.
- Breakdowns: by victim class, zone, battleground vs world; current and best
  kill streak; nemesis (who killed us most) and favorite victim.
- Weekly counters reset on the weekly reset.

### Professions (`prof`)
- Skill lines/levels from the skill API.
- On `TRADE_SKILL_SHOW` / `CRAFT_SHOW` (enchanting in Classic-style clients),
  scan recipes: result item ID + recipe/spell ID only. Feature-detect
  `GetTradeSkillInfo` (Classic-style) vs `C_TradeSkillUI` (retail-style).
- Each player has to open each profession window once; new recipes are picked
  up automatically after that.
- `/tw craft <item>` search, and tooltip lines on items: "Craftable by: Bob
  (Tailoring 225)". On recipe items: who knows it / who could learn it.

### Combat (`combat`)
- Record only the player's own damage/healing plus their pets/guardians
  (owner map built from `SPELL_SUMMON` and pet GUIDs).
- Segments: boss = `ENCOUNTER_START/END` (with encounter ID/name and
  success); dungeon run = enter/leave instance (`GetInstanceInfo`).
- DPS = damage / encounter duration (same denominator for everyone in the
  fight, so it is fair).
- Store per boss: best DPS, best HPS, kill count, last kill; per run: totals.
  Leaderboards per boss and an "MVP of the run" summary posted optionally.

### Extras (`stats`)
- Leveling race: level, XP, `/played` (`TIME_PLAYED_MSG`).
- Death log: what killed you, where (PvE and PvP).
- Gold: current, looted lifetime.
- Weekly awards on reset (most KBs, most deaths, best DPS…), announced in
  guild/party chat.

## UI

- Minimap button (drag to move, click to open, right-click for menu).
- `/tw` slash commands.
- Main window with tabs: **Team | PvP | Combat | Professions | Awards**
  (tabs are added as modules land).

## Files

```
TeamWOW/
  TeamWOW.toc
  Core.lua          namespace, modules, events, callbacks, timers, SavedVariables
  Serializer.lua    table <-> string, no loadstring
  Comm.lua          chunking, reassembly, throttled queue, channel selection
  Sync.lua          HELLO/DIGEST/REQ/DATA protocol, revisions, trust, merge
  Roster.lua        info section, team list
  Commands.lua      /tw
  UI/MinimapButton.lua
  UI/MainFrame.lua
tests/              plain Lua 5.1 tests with a stubbed WoW API
```

No external libraries for now (Ace3 etc.) — the transport and serializer are
small and this keeps the addon self-contained for a brand-new client.
Compression (LibDeflate) can be added later if profession sync is slow.
