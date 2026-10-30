# TeamWOW

A private WoW Forever addon for a small group of friends. It tracks who has
the most PvP kills, who does the most damage in dungeons and raids, who can
craft what, and more. It shares all of it automatically between teammates
running the addon.

> "TeamWOW" is a placeholder name.

Use [Details!](https://www.curseforge.com/wow/addons/details) as your live
damage meter. TeamWOW keeps the long-term records and leaderboards.

## Status

| Feature | State |
|---|---|
| Sync between teammates (guild, party, or whisper) | ✅ done |
| Team roster (class, level, guild, online, version) | ✅ done |
| Main window and minimap button | ✅ done (Team tab) |
| PvP kills / deaths / nemesis | ⏳ next |
| Professions and "who can craft X" | ⏳ planned |
| DPS/HPS per boss and dungeon run | ⏳ planned |
| Leveling race, death log, gold, weekly awards | ⏳ planned |

See [DESIGN.md](DESIGN.md) for how it all works.

## Install

1. Copy the `TeamWOW` folder into your WoW Forever AddOns folder (reported
   to be `World of Warcraft/_forever_/Interface/AddOns/`).
2. If it shows as "out of date" on the character screen, tick **Load out of
   date AddOns**, and let us know the number from
   `/run print((select(4, GetBuildInfo())))` so the `.toc` can be updated.

## Getting started

- **In a guild together:** nothing to do. Guildmates find each other automatically.
- **No guild:** one person types `/tw add Friendname` and that friend types
  `/tw add Yourname`. Anyone either of you has added is shared
  with the other automatically.

## Commands

| Command | What it does |
|---|---|
| `/tw` | Open or close the window |
| `/tw add <name>` | Add a teammate (or target them and type `/tw add`) |
| `/tw remove <name>` | Remove a teammate and forget their data |
| `/tw team` | List teammates in chat |
| `/tw sync` | Sync with everyone right now |
| `/tw status` | Sync diagnostics |
| `/tw guildtrust` | Toggle trusting all guildmates running TeamWOW |
| `/tw minimap` | Show or hide the minimap button |
| `/tw debug` | Toggle debug messages |

## Development

The sync logic is tested offline with a small WoW API simulator that runs
several clients in one Lua process:

```bash
lua5.1 tests/run_tests.lua
```
