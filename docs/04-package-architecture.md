# ArcadeMaster: single-package architecture

The goal is **one copy of every game and emulator, many frontends, many cabinet types, one installer.** Every path comes from configuration rendered at install time; nothing depends on links (see 02-plan, revised per owner feedback 2026-11-22).

## 1. On-disk layout (one root, any drive)

```
<ROOT>\ArcadeMaster\                      e.g. D:\ArcadeMaster   (the ONLY machine-specific value)
  manifest\
    games.json                            catalog: every game, once (schema below)
    cabinets\racing.json flight.json lightgun.json   which games/collections/inputs/settings per cabinet type
    inputs\<device>.json                  captured device profiles (tools/wheelmap)
  games\<system>\<GameId>\                canonical game files - ONE copy, never edited by hand
  emulators\<name>\                       one install each (TeknoParrot = newest; Dolphin, Supermodel, ...)
  media\<GameId>\logo.png fanart.jpg video.mp4 ...   one art store for all frontends
  frontend\retrofe\                       CoinOPS build + layouts\ArcadeMaster + GENERATED collections/launchers
  frontend\launchbox\                     optional, GENERATED platform XML only (no game copies)
  saves\<GameId>\                         per-cabinet writable state (nvram, TP saves) - excluded from packs
  tools\                                  this repo's tools
```

Rules:
- `games\` and `media\` are **read-only content**. Anything a game writes goes to `saves\`, by redirecting the save/config path, or the game runs from a differencing VHDX (section 3).
- Frontend configs, TeknoParrot UserProfiles and emulator input files are **outputs**. They are regenerated from `manifest\` + `inputs\` and never hand-edited (hand edits get lost; the tools write `.bak` first).

## 2. `games.json` (one entry per game)

```json
{
  "id": "srally3",
  "title": "Sega Rally 3",
  "year": 2008, "manufacturer": "Sega",
  "genres": ["racing"],
  "cabinets": ["racing"],
  "system": "Sega Europa-R",
  "path": "games/Sega Europa-R/srally3",
  "emulator": "teknoparrot",
  "launch": { "profile": "SR3", "exe": "Rally/Rally.exe" },
  "input": { "template": "racing-wheel-sequential" },
  "media": { "logo": "media/srally3/logo.png", "video": "media/srally3/video.mp4", "fanart": "media/srally3/fanart.jpg" },
  "sources": { "md5:Rally/Rally.exe": "...", "copies_merged": ["D:/Arcade PC/Sega Europa- R/Sega Rally 3", "E:/DRIVE Collection/collections/TeknoParrot/roms/SR3"] }
}
```

The installer renders this into the files each consumer actually reads:

| Consumer | Generated from games.json |
|---|---|
| TeknoParrot | `UserProfiles\<profile>.xml`: GameProfile template + `<GamePath>` + input bindings from `inputs\` |
| RetroFE | `collections\Racing|Flight|Lightgun\` (settings.conf, `include.txt`, per-item launchers, media paths), `launchers.windows\*.conf`, `Main\menu.txt` |
| LaunchBox (optional) | `Data\Platforms\Arcade Racing.xml` / `Arcade Flight.xml` |
| Dolphin / Supermodel / Model 2 / MAME / Cemu | ROM paths and input sections |

## 3. Package format: why images

The problem isn't total size, it's **1.33 M small files**. Copying them file-by-file is what makes deployment slow.

| Piece | Format | Why |
|---|---|---|
| Core (frontend, emulators, tools, manifests) | zip / installer, ~2-3 GB | small, changes often |
| Game library | **VHDX per system** (e.g. `TeknoParrot.vhdx`, `SegaEuropaR.vhdx`) mounted into `games\<system>\` with a folder mount point, no drive letter | deploying is copying a few large files sequentially at full disk speed. Mounting is instant. Paths are identical on every machine. |
| Per-cabinet changes | **differencing VHDX** (child of the read-only golden image) | game writes stay local; "factory reset" means deleting the child; the golden image is shared by all cabinets |
| Archive / transport | the same VHDX files (or WIM via wimlib, which also de-duplicates identical files across games) | replaces the 311 GB of multi-part RARs in `E:\Support` |

The mount runs as a boot-time scheduled task (SYSTEM) using `Mount-DiskImage` / `Add-PartitionAccessPath`. Mounting needs admin once at install; after that it's automatic.

## 4. Cabinet profiles (racing, flight, lightgun stand-ups)

`manifest\cabinets\<type>.json` selects:

| Setting | racing | flight | lightgun |
|---|---|---|---|
| Collections shown | Racing (+Favorites) | Flight | Lightgun |
| Layout theme | wheel + speedo/tacho | yoke + attitude/HUD | crosshair + targets, **Sinden border overlay** option |
| Input template family | wheel: steer/gas/brake/clutch/paddles | stick/yoke: pitch/roll/yaw/throttle | guns: trigger/reload/pedal, P1/P2 |
| Devices expected | G29 / G920 / Thrustmaster + button box | HOTAS / yoke | Sinden / Gun4IR / AimTrak |
| Extra emulators | none | none | Demul/Flycast (Naomi/Atomiswave guns), Model 2/3 guns, PS2/PS3 gun launchers |

One cabinet can enable several profiles (this machine: racing + flight).

## 5. Install flow (`Install-ArcadeMaster.ps1 -Root D:\ArcadeMaster -Cabinet racing,flight`)

1. **Prerequisites:** VC++ 2005–2022 redists, DirectX June 2010, .NET 8/Desktop 3.1 (TeknoParrot), wheel vendor software check.
2. **Lay down core:** frontend, emulators, tools, manifests.
3. **Mount or copy game packs** for the selected cabinets; verify hashes against `games.json`.
4. **Input:** run `tools\wheelmap\WheelMap.ps1 -Capture` (or reuse `inputs\<device>.json`), then `-Generate -Apply`.
5. **Render configs:** TeknoParrot profiles, RetroFE collections/launchers, LaunchBox XML, emulator paths. Then `Set-LayoutThemes.ps1`.
6. **Cabinet tuning (admin):** Defender exclusions for `<ROOT>`, High-performance power plan, USB selective suspend off, `fsutil behavior set disablelastaccess 1`, startup bloat removed (OneDrive/Teams/Edge), optional auto-logon + shell replacement.
7. **Boot launcher:** `ArcadeMaster.exe` replaces `DRIVE.exe`. It starts input helpers, starts RetroFE, restarts it if it crashes (crash dialogs are off in our build), and has a hidden exit combo.

## 6. Migration of this machine

1. `Find-Duplicates.ps1`: hash-level map of identical game folders (running).
2. `Build-Manifest.ps1` (next): drafts `games.json` from TeknoParrot UserProfiles, LaunchBox XML, RetroFE collections and the duplicate map. It picks the canonical copy (prefer complete, newest, SSD), and flags conflicts where copies differ (e.g. Mario Kart DX, 61% identical).
3. `Consolidate.ps1 -WhatIf` (next): shows moves, deletions and space reclaimed. **The owner approves before anything is deleted.** It moves canonical copies into `games\`, renders configs, and test-launches from each frontend.
4. Build the VHDX packs from `games\` and publish the core package.
