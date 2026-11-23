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

## TOOLS menu (maintenance from the cabinet controls, all visual)

`tools/New-CabinetToolsCollection.ps1 -RetroFE <root>` adds a **Tools** entry to the main menu. It has its own layout, `layouts/ArcadeMaster/collections/Tools/layout/layout.xml`: the list on the left, a large preview card on the right, and the tool's backdrop behind.

| Item | Runs | Tool page shows |
|---|---|---|
| Wheel Setup | `wheelmap\WheelMap.ps1 -Capture` | the prompt for each control, a movement meter, captured controls, and the LIVE wheel angle, pedal travel and button lights. Touch buttons: SKIP / REDO / BACK / ACCEPT / FINISH (FINISH saves). Esc cancels without saving. |
| Detect Controllers | `Get-CabinetDevices.ps1` plus a dry-run ID check | capability tiles (players, modes, displays, restrictor), a card per device (icon, role, FFB / axes / buttons), and profiles needing repair |
| Repair Controller IDs | `Update-ControllerIds.ps1 -Apply` | device cards and profiles repaired |
| Rebuild Game Menus | devices → catalog → controls → collections → backdrops | an animated checklist, then Racing / Flight / Arcade / Lightgun game counts |
| Force Feedback, Second Screen, Performance Log | toggle `ffb` / `numScreens` / `perfLog` | a large animated ON/OFF switch (Second Screen also draws the connected displays) |
| Shuffle Backgrounds | `Set-LayoutThemes.ps1 -Shuffle -BackgroundsOnly` | the new main-menu backdrops as thumbnails |

How it fits together:

- **List art:** `tools/New-ToolsArt.ps1` draws it from the cabinet's current state:
  - logos, with a live ON/OFF switch on the toggles
  - preview cards ("NOW": devices plugged in, game counts, current backdrops, switch state, whether the wheel profile was captured or only guessed)
  - backdrops

  It runs after every tool and at boot (`Start-ArcadeMaster.ps1`), so the menu never shows stale state.
- **Tool page:** `tools/Show-ToolScreen.ps1` is a borderless, topmost window on the display that `screenNum0` points at. Everything is scaled to that display's resolution. It runs `Invoke-CabinetTool.ps1` hidden and draws the `@AM {json}` events the tool emits (`AM_VISUAL=1`). WheelMap emits `wiz-*` events and reads the on-screen buttons from `AM_WIZ_KEYFILE`. Shared drawing (icons, cards, switches, checks, bars, live joystick reads through winmm) lives in `tools/lib/AmVisual.ps1`.
- **Returning:** once the tool is done, a key, tap or **short press-and-release** of any controller button returns to the arcade. Otherwise the page closes itself after 15 s. Held buttons never close it; an H-shifter sitting in gear reports one. Chattering buttons are ignored. The close reason is logged to `%TEMP%\am-toolscreen.log`, and paint errors to `%TEMP%\am-toolscreen-errors.txt`.
- **Launching:** the `AM_TOOLS` launcher runs `wscript RunHidden.vbs <item>.bat`, so no console window opens. It has `reboot = yes`, so RetroFE restarts and the new settings take effect.
- Generated items are marked `ARCADEMASTER-TOOLS.txt`, so `Build-Manifest` skips them. `-Remove` deletes the collection.

**Second-screen layouts:** `layout - 1.xml` (root and Main) must declare `<layout monitor="1" ...>`. Without it, RetroFE draws the pedestal layout (touch bar, title, PLAYERS/MAKER) over the main screen on a single-display cabinet. With it, RetroFE skips the layout when monitor 1 doesn't exist.
## Boot intro: cabinet type

The boot splash (`layouts/ArcadeMaster/splash.xml`) plays the Real Z Studios logo, fades to black, then shows a **cabinet title card**: icons rise, a neon title punches in, an accent line draws out and a tagline fades in. Total ≈ 6.8 s.

Set the type in RetroFE `settings.conf`:

```
cabinetType = auto        # auto | racing | flight | simulation | standup | lightgun | multicade | pedestal
                          # combine with +, e.g. racing+lightgun  (wheel + handbrake + gun shooters)
cabinetTitle = ...        # optional custom title
cabinetTagline = ...      # optional custom tagline
```

| type | title | icons | tagline |
|---|---|---|---|
| racing | RACING CABINET | wheel, pedals | START YOUR ENGINES |
| flight | FLIGHT CABINET | jet, flight stick | CLEARED FOR TAKEOFF |
| simulation | SIMULATION CABINET | wheel, shifter, pedals | FULL CONTROL |
| standup | STAND-UP ARCADE | cabinet, control panel | INSERT COIN |
| lightgun | LIGHT GUN ARCADE | gun, crosshair | LOCK AND LOAD |
| multicade | MULTICADE | control panel, trackball, gun | EVERY GAME - ONE CABINET |
| pedestal | 4-PLAYER PEDESTAL | pad, control panel | PLAYERS 1 TO 4 READY |
| hybrids (`a+b`) | "RACING + LIGHT GUN CABINET" | both sets, two-tone (racing hybrids show the handbrake if one is detected) | the types' verbs: DRIVE - AIM - FIRE |

**How it's set and drawn:**
- **`auto`** works the type out from `manifest\cabinet.json`:
  - wheel → racing; wheel + clutch/shifter + flight stick → simulation; flight stick → flight
  - a light gun is added to any of those
  - otherwise: 3+ players → pedestal, trackball → multicade, else stand-up
- **Rendering:** `tools/New-CabinetIntro.ps1` draws `images/intro/*.png`. Definitions live in `tools/lib/CabinetTypes.ps1`. `Start-ArcadeMaster.ps1` re-renders it every boot.
- **Tools → Cabinet Type** is a visual picker. Turn the wheel or a joystick (or use the hat or arrow keys) to move, press a button or Enter to confirm, or tap a card. It saves `cabinetType`, re-renders the intro and plays a preview of the new title card.
## System settings (Tools → System Settings)

`tools/Set-CabinetSystem.ps1` holds reversible cabinet switches. Previous Windows values are saved under `HKCU\Software\ArcadeMaster\Saved` and restored when a switch is turned off.

| Switch | Effect |
|---|---|
| Auto login | Status comes from Winlogon. ON opens Sysinternals Autologon if present, otherwise netplwiz; the password is typed into Windows and never stored by us. OFF clears `AutoAdminLogon`, which needs admin. |
| Start arcade at logon | Startup shortcut to `Start-ArcadeMaster.ps1` (hidden console) |
| Quiet startup | OneDrive / Teams / Edge etc. stop auto-launching; G HUB, JoyToKey and gun / DolphinBar tools stay |
| No Windows pop-ups | Xbox Game Bar overlay and notification toasts off |
| Game bezels / overlays | MAME `use_bezels/overlays/backdrops/cpanels/marquees` (MAME's default is on) |
| Screen always on | display and sleep timeouts off on AC power |

**Using it:**
- The page is a list of switches: turn the wheel or stick, use the arrows, or tap to pick a row. **Every switch needs a confirming second press**, and the row turns red with "PRESS AGAIN…". A Windows dialog (auto login) pushes the page out of the way until the dialog is closed.
- `AM_SYSTEM_DRYRUN=1` runs everything against a temp file; use it to test the UI without touching Windows.

**Lessons recorded from building it:**
- `New-Item -Force` on an existing registry key recreates it and wipes all its values. Use `Confirm-Key`.
- A controller without a hat reports POV 0 ("up"), so check `JOYCAPS_HASPOV`.
- A failed joystick read must keep the last state, or held buttons look like fresh presses.
## Cabinet mode follows the hardware (2026-11-22)

`tools/Set-CabinetMode.ps1` runs at every boot, before the intro.

| Situation | Result |
|---|---|
| `cabinetType = auto` (default) | the mode is what's plugged in: wheel → racing, flight stick → flight, both → racing+flight, gun → light gun |
| `cabinetType = racing` + `cabinetFollowHardware = yes` | stays racing while a wheel is connected; wheel gone and flight stick connected → flight cab |
| a configured hybrid loses one part | drops that part, e.g. racing+lightgun with no gun → racing |

**What the boot does with the mode:**
- The **main menu shows only the plugged-in modes' collections** (Racing / Flight / Lightgun / Arcade). Settings, Tools, GAMES and the rest always stay. Hidden entries are kept in `manifest\main-menu-full.txt` and come back with their controller. `cabinetShowAllModes = yes` shows everything.
- The mode's collection moves to the top of the menu, and `cabinetTheme.<mode> = <layout>` switches the theme per mode.
- The boot intro shows the effective type. A custom `cabinetTitle` is only used while the configured type is active.
- The decision is recorded in `manifest\cabinet-mode.json`.

**Main menu:** choices run along the bottom in a carousel that the wheel steers, under a dashboard (speedometer / steering wheel / tachometer). `enterOnCollection = no`: scrolling only highlights, and SELECT opens. This RetroFE build defaults to entering a collection as soon as it is highlighted.

## Themes: CoinOPS / Core import (first part of docs/10)

`tools/Import-RetroFETheme.ps1 -Source <coinops root> -Layout <name> | -All`:
- Copies the layout to `CO-<name>`; the source is never touched.
- Fixes `monitor=` on second-screen layouts.
- Carries in our boot intro and Tools screen; the theme's own splash is kept as `splash.original.xml`.
- **Makes main-menu art for our items** by compositing our neon logo onto the theme's own frame.
- Scores the artwork coverage on this cabinet and takes a real RetroFE preview screenshot.
- Registers the theme in `manifest\themes.json`. Layouts already inside the install are registered in place, unchanged.

Tested with DRIVE from E: → `CO-DRIVE`, 51% coverage (gaps: bezel, gallery, option art). ArcadeMaster is 74%.
## Self-healing (Repair-ArcadeHealth.ps1)

At every boot, before RetroFE starts, and from **Tools → System Health** (a visual checklist), nine checks report OK, FIXED or WARN:

| Check | What it covers |
|---|---|
| runtime | retrofe.exe and core DLLs present, else restored from the last-known-good copy |
| settings | layout installed, start collection exists, `numScreens` ≤ connected displays, `enterOnCollection = no` |
| controls | controls.conf present |
| screens | second-screen layouts declare `monitor=`; `mouseTouchScreens` follows whether a mouse-type touch board is plugged in (docs/07, patch 0006) |
| menu | main-menu entries point at real collections; the menu's Exit leaves a note so the launcher stops instead of restarting (2026-11-22) |
| launchers | report only; emulators are never touched |
| games | TeknoParrot profiles inside this frontend whose game path is gone are repaired by `Repair-TPProfiles.ps1`, which backs up first and only writes when it found the game. The path comes from the same profile in another TeknoParrot install, or by file name. Profiles that can't be fixed are remembered, so the disks aren't searched on every boot. The check also says how many catalog games can start and why the others can't (2026-11-23). |
| logs | log rotation above 20 MB, crash folders capped at 10 |
| disk | free space |
| art | intro and Tools art (regenerated when missing) |

Fixes are conservative and backed up. Results go to `manifest\health.json`; `-NoFix` reports without changing anything.

**Watchdog:**
- After RetroFE has run 3 minutes without a crash, the configs are saved as last-known-good in `manifest\lkg\`, keeping 3 copies plus the core runtime files.
- **3 crashes within 2 minutes:** the last-known-good configs are restored once (the current files are kept as `*.before-lkg`) and RetroFE is retried. It gives up only after that.

Tested by breaking settings.conf (missing theme, 2 screens on a 1-display cabinet); both were repaired.

## Games that can't start (2026-11-23)

Every catalog build (`Build-Manifest`, Tools → Rebuild Game Menus) runs `tools\lib\AmGameDoctor.ps1` over each game copy that can't start. It gives each one a reason, in `games.json` (`problem`, `why`) and in plain words in `manifest\games-cant-start.txt`:

| Reason | Meaning | What happens |
|---|---|---|
| moved | the program file is in another folder on this PC, with the same file name and the same folder name | PC games: the catalog points there and the game is back in the menu. TeknoParrot: the health check repairs the profile. |
| incomplete | the game's folder is here but its program file isn't (a partial copy) | listed: copy the game in again |
| not installed | neither the file nor its folder is on this PC | listed |
| not set up | TeknoParrot has never been set up for the game (no profile) | looks for a folder named after the game (its TeknoParrot name, its title, or the usual short names of arcade dumps such as `FFSB` and `SNOTP`). It reports either **ready to set up**, with the `Add-TPGame.ps1` line to run, or **data only** (program files missing). |

**Program files are not always `.exe`.** Linux-based boards (Sega Lindbergh / Nu, Taito Type X3, some Raw Thrills) start from a Linux program file: `.elf` or no extension at all (`abc`, `Jennifer`, `car`). 16 working TeknoParrot profiles here point at one. The doctor searches by the exact file name, whatever the extension, and tells a program from data by its header (`.exe`, or a Linux file starting with `ELF`).

**Setting a game up:** `tools\Add-TPGame.ps1 -Id <TeknoParrot name> -GamePath <program file> [-Apply]` does what TeknoParrotUI's "add game" does, with this cabinet's controls already bound by the wheel tool (pedals clutch LEFT, brake MIDDLE, gas RIGHT). It does a dry run by default, never replaces an existing profile, and accepts `.exe` or Linux program files. Then run Tools → Rebuild Game Menus.

Games that can't start are never shown in the menus. First run on DESKTOP-RACE1:
- Road Fighters 3D moved (`D:\Arcade PC\PC\...` → `D:\Arcade PC\Konami\...`) and is back.
- Nicktoons Nitro, Fast & Furious Drift and Fast & Furious SuperCars had broken relative paths in the frontend's own TeknoParrot copy, left over from copying the frontend from E: to D:. They were repaired.
- Valve Limit R (`VirtuaRLimit`, Taito Type X) was installed at `D:\Arcade PC\Taito Type X\Valve Limit R` but never set up. It was set up with `Add-TPGame.ps1` and is in the Racing menu.
- These have their data but none of their program files (no `.exe` and no Linux program), although each was set up and run once (a `teknoparrot.ini` is there):
  - Chaos Code, Guitar Hero Arcade, Under Defeat (Windows boards)
  - Fast & Furious, Super Bikes 1 and 2, SnoCross (`Raw Thrills\FF`, `FFSB`, `FFSB2`, `SNOTP`; the working Raw Thrills games keep `sdaemon.exe` in `rawart\`)
  - Missing program files with the data left behind usually means an antivirus removed them.
- 7 PC games are not installed, and Blazing Angels is not on this cabinet.

## Boot speed (2026-11-22)

`Start-ArcadeMaster` logs one line per boot with the time of every step, e.g.
`boot prep 5.5s: Get-CabinetDevices 1.9s, Set-DolphinControllers 0.4s, Update-ControllerIds 0.6s, Shuffle 0.7s, Set-CabinetMode 0.4s, New-CabinetIntro+New-ToolsArt(bg) 0.8s, Repair-ArcadeHealth 0.6s`.
`-PrepOnly` runs every step and prints the timings without starting RetroFE, so you can measure without disturbing the cabinet.

On DESKTOP-RACE1, boot prep went from **9.6 s to 5.5 s**:

| Change | Saved |
|---|---|
| `Get-CabinetDevices` lists PnP devices once instead of 7 times (about 0.4 s each) | ~1.7 s |
| Inline C# (`WheelMapInput.cs`, AmVisual, the Tool screen) compiles once to `%LOCALAPPDATA%\ArcadeMaster\typecache\<type>-<hash>.dll` and is loaded from there after that (`tools\lib\AmTypeCache.ps1`). An edited source gets a new hash, so it never loads a stale build. If the cache fails, it compiles in memory as before. | ~0.25 s per tool start, at boot and on every Tools page |
| The intro and the Tools art render side by side | ~0.8 s |
| The Tools art finishes in the background at low priority while RetroFE starts. It only shows inside Tools, never during the intro. Its images are swapped in atomically (temp file, then replace). | ~1.1 s |
| The health check only starts the touch re-check when there is a touch board or a touch setting | ~0.4 s |
| Boot tools run inside the launcher's own PowerShell instead of one new `powershell.exe` each. Each still gets its own script scope, and `exit` in a tool ends only that tool. `Get-CabinetDevices` also runs the controller scan in-process. Set `AM_BOOT_SEPARATE=1` to go back to separate processes when a tool misbehaves. | 6.1 s -> 4.6 s here; about 1.2 s per tool on the pedestal's i3 |
