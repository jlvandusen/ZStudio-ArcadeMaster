# Dynamic catalog: one games.json drives the frontend

```
tools\Build-Manifest.ps1         -> D:\ArcadeMaster\manifest\games.json     (read-only scan)
tools\New-RetroFECollections.ps1 -> collections\Racing|Flight|Lightgun|Arcade, AM_TP_*, AM_PC, Main\menu.txt
tools\Set-LayoutThemes.ps1 -Shuffle -CollectionsDir ...   -> themes + random game-fanart backdrops (boot)
```

## Build-Manifest

Merges, by game:

| Source | Gives |
|---|---|
| every TeknoParrot install: `UserProfiles\*.xml` + `Metadata\<id>.json` | title, genre, platform, year, **wheel rotation**, game path. The same profile in several installs becomes **variants** (standalone / multicab / launchbox). Metadata is looked up across all installs, because the old D: install has none. |
| RetroFE collections + `meta\hyperlist\<collection>.xml` | file-based games (MAME, Model 2/3, Triforce, Dolphin, Cemu, PC), genre, launcher, media |
| LaunchBox `Data\Platforms\Arcade Racing/Flight.xml` | links titles to TeknoParrot profiles, flags flight games (the owner's classification wins), PC executables, art fallbacks (`Fanart - Background` → `Screenshot - Gameplay`, `Clear Logo`, videos) |

Category: TeknoParrot/hyperlist genre (Racing → racing, Flying → flight, Shooter → lightgun, else arcade). LaunchBox platform overrides; `-DefaultCategory racing` covers genre-less DRIVE items.

This machine (2026-11-22):

| Category | Games | Launchable | With fanart | Multi-variant |
|---|---:|---:|---:|---:|
| racing | 114 | 102 | 93 | 22 |
| flight | 6 | 3 | 4 | 0 |
| arcade | 4 | 2 | 0 | 0 |

## New-RetroFECollections

Generates, and never edits anything existing:

- **`Racing` / `Flight` / `Lightgun` / `Arcade`**: merged collections. There's one `<SourceCollection>.sub` per source, listing the games, so each game keeps its own launcher, art and emulator config.
- **`AM_TP_<install>`**: TeknoParrot games set up only in another install (e.g. LaunchBox's `D:\Emulators\TeknoParrot`). Includes `include.txt`, a launcher, and art copied in RetroFE naming.
- **`AM_PC`**: native Windows games, with one generated `.bat` per game (`cd` to the game folder, `start /wait` the exe) plus LaunchBox art.
- **`Main\menu.txt`**: categories plus Settings. A previous `menu.txt` is kept as `.am-backup`.

Everything generated carries `ARCADEMASTER-GENERATED.txt`. Re-running regenerates; `-Remove` restores the previous state.

Result on this machine: **Racing 103 entries** (12 sources incl. 7 PC games), **Flight 3** (Star Wars Battle Pod, After Burner Climax, MachStorm), **Arcade 2**. Verified on screen: main menu → Flight → After Burner with its own fanart and the flight instrument theme.

Not listed yet (17), and why:
- not installed: Blur, Juiced, NFS MW / MW 2012, Ridge Racer Unbounded, Split/Second, SnoCross, Blazing Angels, Heliborne
- profile/exe still needed: Under Defeat (only `game.bat`), FnF / Super Bikes 1+2, Valve Limit R, Road Fighters 3D (`spice.exe` missing), Chaos Code, Guitar Hero Arcade

## Controls, preferred emulator, cabinet fit

`tools/Get-CabinetDevices.ps1` writes `manifest\cabinet.json`, what this cabinet can physically do (via `tools/wheelmap`):

- wheel, force feedback, pedals, clutch, handbrake, paddles
- H-shifter (needs a capture to confirm)
- flight stick / HOTAS, gamepads
- lightguns by vendor ID (Sinden, Gun4IR, AimTrak)
- trackball

DESKTOP-RACE1 has: G29 (wheel, FFB, pedals, clutch, paddles) + handbrake, no stick/gun/pad.

`tools/Add-GameControls.ps1` adds the following to every game in `games.json`:

| Field | From | Contents |
|---|---|---|
| `controls` | TeknoParrot GameProfiles (`ButtonName`/`AnalogType`/`InputMapping`), `mame -listxml` (MAME + Model 2/3 sets), defaults for console/PC | wheel, pedals, shifter `paddles`/`hpattern`, handbrake, flight stick, throttle, lightgun (+ gun players; a "gun trigger" on a flight stick is not a lightgun), trackball/spinner, analog stick, gamepad, buttons, players, extras (view/boost/weapons/...) |
| `preferred` | rules | variant + emulator + backend (TeknoParrot / OpenParrot / Lindbergh / ...) + reason. Rules: newest TeknoParrot install first, multicab only for linked cabinets, Model 2 → m2emulator (MAME `model2` is preliminary), Model 3 → Supermodel, Triforce → Dolphin Triforce, PC → native. The same MAME set in several collections keeps the preferred one; the others become `hidden`. |
| `fit` | `cabinet.json` | `native` / `mapped` / `unsupported` + notes, e.g. "flight stick mapped to wheel (roll) + pedals (throttle/brake)", "uses an H-pattern shifter", "set wheel rotation to 540 deg" |

`New-RetroFECollections.ps1` skips hidden duplicates and `unsupported` games (unless `-IncludeUnsupported`).
The human-readable table is in `reports/game-controls.md`.

This machine: 124 games, 118 native + 6 mapped (flight games on the wheel).

| Controls | Games |
|---|---:|
| wheel + pedals + paddles | 57 |
| wheel + pedals | 52 |
| wheel + pedals + **H-pattern** (Initial D, Daytona 3, …) | 11 |
| **handbrake** (D1GP, Sega Rally 3, …) | 3 |

Preferred emulators: TeknoParrot 47, Supermodel 22, PC native 15, MAME 9, m2emulator 6, Dolphin 4, Dolphin Triforce 3, Cemu 1.

## Tags and cabinet modes (racing cab / flight cab / stand-up / lightgun, or switching)

- **`catalog/tags.json`** (in this repo) is the owner's list and is **authoritative**. Per game: `"tags": ["racing"]` / `["flight"]` / `["standup"]` / `["lightgun"]`, plus any free tags (`linked`, `kids`, `favorite` ...).
  - Seeded with every game's auto-detected type and `"auto": true`. Edit an entry and delete `"auto"` to lock it.
  - New games are added automatically; locked entries are never overwritten.
- **Cabinet modes** (`cabinet.json → capabilities.modes`) are derived from hardware: wheel → racing (+ flight via wheel mapping), stick/HOTAS → flight, gun → lightgun, control panel (I-PAC) / sticks / pads → standup. They can be overridden with `Get-CabinetDevices.ps1 -Modes ...`.
- `New-RetroFECollections.ps1` only builds the collections for the cabinet's modes (or `-Modes racing,flight,standup`). One cabinet with several modes gets one main-menu entry per mode, which is the mode switch. Each gets its theme (wheel / yoke / crosshair / stick).
- Stand-up arcade is the `standup` type, shown as **Arcade**.

## Players, joystick ways, restrictors

- `controls.players` (TeknoParrot P1–P4 mappings, MAME `input players`), `controls.joystick` + `controls.ways` (MAME `ways` 2/4/8; digital TeknoParrot sticks = 8), `controls.ctrltype`.
- `cabinet.json → players` counts stations: sticks + pads, guns, or 2 for a control panel. Override with `-Players 4` for 4-player encoders. The fit notes flag games that support more players than the cabinet has.
- `New-RetroFECollections.ps1 -RebuildDatabase` writes `players`, `ctrltype`, `buttons`, `joyways` into RetroFE's metadata and rebuilds `meta.db`. **RetroFE then switches a ServoStik / TOS GRS restrictor to 4- or 8-way per game at launch** (CoinOPS `RestrictorGuard`) and restores 8-way after.
- `cabinet.json → restrictor` reports a ServoStik.

## Controller IDs that change

DirectInput instance GUIDs change when a device moves USB port or Windows re-enumerates, and every saved binding breaks.

- `Get-CabinetDevices.ps1` keeps **`device-history.json`**: every GUID each physical device (VID/PID + name + order) has ever had.
- `Update-ControllerIds.ps1` re-points every TeknoParrot binding using its own device-type label (`Driving…`, `Supplemental…`, `Keyboard…`):
  - Keyboard binds → the fixed SysKeyboard GUID.
  - Correct binds are left alone.
  - A GUID known from history → that device's current GUID.
  - Otherwise → the single connected device of that type.
  - Ambiguous or absent devices are reported and left alone.
  - Dry run by default; `-Apply` makes `.ids-<ts>.bak` backups. It's idempotent.
- First run on this machine (applied): 270 bindings in 39 files.
  - 244 → current G29, from 3 stale wheel IDs, mostly in the LaunchBox TeknoParrot.
  - 24 keyboard binds repaired (the old UpdateGuid script had pointed them at the wheel).
  - 2 handbrake binds → handbrake.
  - Left alone: an absent old joystick (4) and an unlabelled device (10).
- **`Start-ArcadeMaster.ps1`** does this at every boot:
  - waits up to 30 s for the wheel if it was there last boot, and logs a warning if it never appears
  - re-points IDs if they moved
  - regenerates the menus if the cabinet modes changed (e.g. a gamepad added → Arcade appears)
  - then shuffles the backdrops and starts RetroFE under the crash watchdog

## Order of operations on a cabinet

1. `Get-CabinetDevices.ps1`, `Build-Manifest.ps1`, `Add-GameControls.ps1`
2. `New-RetroFECollections.ps1 -RetroFE <root>`
3. `Set-LayoutThemes.ps1 -LayoutDir <root>\layouts\ArcadeMaster -CollectionsDir <root>\collections -Shuffle` (also run at every boot by `Start-ArcadeMaster.ps1`)

## TOOLS menu (maintenance from the cabinet controls)

`tools/New-CabinetToolsCollection.ps1 -RetroFE <root>` adds a **Tools** entry to the main menu. It has eight items, each a `.bat` with a neon logo:

| Item | Runs |
|---|---|
| Wheel Setup | `wheelmap\WheelMap.ps1 -Capture`, then device detection |
| Detect Controllers | `Get-CabinetDevices.ps1` + a dry-run ID check |
| Repair Controller IDs | `Update-ControllerIds.ps1 -Apply` |
| Rebuild Game Menus | devices → catalog → controls → collections → backdrops |
| Force Feedback On-Off | toggles `ffb` in `settings.conf` |
| Second Screen On-Off | `Set-RetroFEScreens.ps1` / `-Single` |
| Shuffle Backgrounds | `Set-LayoutThemes.ps1 -Shuffle -BackgroundsOnly` |
| Performance Log On-Off | toggles `perfLog` |

How a launch works:

- The `AM_TOOLS` launcher runs `wscript RunHidden.vbs <item>.bat`. No console window opens; from a GUI process, a console would open as a desktop-sized Windows Terminal with unreadable text.
- The `.bat` starts **`Show-ToolScreen.ps1`**. This is a borderless, topmost window covering the display that RetroFE's `screenNum0` points at, with text sized from the screen height. It streams the tool's output live: section titles in cyan, errors in red, warnings in amber.
- Once the tool is done, any key, tap, mouse click or joystick/wheel button returns to the arcade. Otherwise the window closes after 15 s. While the tool runs, these inputs are ignored, because Wheel Setup needs them.
- The launcher has `reboot = yes`, so RetroFE restarts and the new settings take effect.
- Generated items are marked `ARCADEMASTER-TOOLS.txt`, so `Build-Manifest` skips them. `-Remove` deletes the collection.