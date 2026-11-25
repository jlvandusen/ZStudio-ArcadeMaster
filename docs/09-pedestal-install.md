# Installing ArcadeMaster on another cabinet (4-player pedestal)

These steps install ArcadeMaster on a second cabinet next to whatever frontends it already has. Everything here is read-only or keeps backups, so the existing CoinOPS builds keep working.

## 1. Get the repo

```powershell
git clone https://github.com/jlvandusen/ZStudio-ArcadeMaster.git D:\repos\ZStudio-ArcadeMaster
cd D:\repos\ZStudio-ArcadeMaster
```

## 2. Survey what is already there (read-only)

```powershell
powershell -ExecutionPolicy Bypass -File tools\Survey-Frontends.ps1
```

This finds every RetroFE/CoinOPS build (Core and the others), LaunchBox/BigBox, Attract-Mode, HyperSpin, ES-DE, Pegasus, RocketLauncher and Playnite. It writes three files to `reports\frontends\`:

| File | Contents |
|---|---|
| `<PC>.md` | for each RetroFE/CoinOPS layout: resolution, number of monitors, video use, the artwork types it reads, and per-collection layouts. Also the menu flow (Main → sub-menus → merged lists) and every collection's game count and artwork folders with file counts. |
| `<PC>.json` | the same data as JSON |
| `<PC>-layouts.png` | a contact sheet of every layout and theme |

Commit those three files so we can pick which artwork and flow to borrow.

## 3. Detect the controllers

```powershell
powershell -ExecutionPolicy Bypass -File tools\Get-CabinetDevices.ps1 -Out D:\ArcadeMaster\manifest\cabinet.json -History D:\ArcadeMaster\manifest\device-history.json
```

This detects wheels, pedals, handbrake, flight sticks and pads, plus:
- keyboard encoders (I-PAC) and restrictors
- light guns and trackballs
- touch screens and every display
- Nintendo controllers: Wii Remotes / "wands" (Bluetooth or DolphinBar), Wii U Pro, Balance Board, the GameCube adapter, Joy-Con and Switch Pro

The 4-player pedestal's second screen and touch panel show up under `displays` and `touchScreens`.

## 4. Point the tools at this machine's emulators

Copy `tools\wheelmap\targets\default.json` to `tools\wheelmap\targets\<COMPUTERNAME>.json` and fix the paths: TeknoParrot, Dolphin, Supermodel, MAME, Cemu and m2emulator. Missing entries are skipped.

## 5. Map the controls

- **Wheel cabinets:** `tools\wheelmap\WheelMap.ps1 -Capture -Name <wheel>`. It's also in the frontend as **Tools → Wheel Setup**. Pedals are always clutch LEFT, brake MIDDLE, gas RIGHT.
- **Keyboard-encoder panels (stand-up / pedestal):** Cemu gets `ArcadeMaster Panel P1` (Wii U GamePad) and `Panel P2` (Pro Controller) on I-PAC / MAME keys. MAME uses its own keyboard defaults. If the panel is wired differently, edit `templates\cemu.json → keyboardPanels`.
- **Generate:** `WheelMap.ps1 -Generate -Name <profile>`. Review `D:\ArcadeMaster\_staging\inputmap\<profile>\manifest.json`, then run `-Apply -Commit`, which backs up every file first.
- **Wii / GameCube:** `tools\Set-DolphinControllers.ps1` switches Wii Remote slots to real remotes while they are connected and back afterwards. It does the same for the Balance Board and GC adapter ports 2–4, and repairs stale device names. It runs at every boot.

## 6. Frontend, cabinet type and boot

```powershell
tools\Build-Manifest.ps1 -RetroFE <root> -Out D:\ArcadeMaster\manifest\games.json
tools\Add-GameControls.ps1 -Manifest D:\ArcadeMaster\manifest\games.json -Cabinet D:\ArcadeMaster\manifest\cabinet.json
tools\New-RetroFECollections.ps1 -Manifest D:\ArcadeMaster\manifest\games.json -RetroFE <root> -Cabinet D:\ArcadeMaster\manifest\cabinet.json -RebuildDatabase
tools\New-CabinetToolsCollection.ps1 -RetroFE <root>
```

- **Put the patched RetroFE in place: this step is required.** Copy a package's `retrofe\` folder from `Z:\ArcadeMaster\builds\retrofe-*` to `<root>\retrofe\`, with RetroFE closed; `Start-ArcadeMaster` prefers `<root>\retrofe\retrofe.exe` over a CoinOPS `core\retrofe.exe`. With only the stock exe, the layout still loads, but every button, gear and pedal glow is drawn all the time, the wheel and needles don't move, and the styles look broken. The health check reports this under `runtime`. To build one yourself: `retrofe\Build-RetroFE.ps1` under **pwsh 7** (Windows PowerShell 5.1 stops on git's stderr), with VS 2022 Build Tools and GStreamer 1.24.13 (see README).
- **Stay on the latest build: run this once per cabinet.** `pwsh tools\Update-Cabinet.ps1 -Root <root> -Install` registers the task "ArcadeMaster Update". It runs every 15 minutes and does the following:
  - pulls main (only when the clone is on main with no edits)
  - when the RetroFE patches or the build script changed, compiles RetroFE in its own folder (`D:\ArcadeMaster\build`) and installs it while RetroFE is closed
  - if RetroFE is open, leaves the new build for the next start; the boot installs a waiting build before RetroFE starts
  - keeps the previous files in `<root>\retrofe.am-prev\`
  - installs main's `layouts\ArcadeMaster` (layout files, images) while RetroFE is closed: per-collection art and the intro are left alone, replaced files go to `<manifest>\backup`, Cabinet Settings options are put back, and the game list waits until the cabinet has preview videos
  - logs to `<manifest>\update-cabinet.log`
  - on a cabinet without the build tools, logs which one is missing and keeps its exe (copy a package from Z: instead)
  To try it without changing Windows, set `$env:AM_SYSTEM_DRYRUN = 1` first.
- **Working on a copy of a protected frontend (E:, or `ProtectedPaths`):** junction the big read-only parts back, but give MAME a real folder. If `<copy>\emulators` is a single junction to E:, MAME's `cfg`, `nvram` and `diff` live on E:, and `Set-MameControls` (and the cabinet self-test) refuse to write there. Make `<copy>\emulators` a real folder holding one junction per emulator, except `MAME`. Copy `MAME` itself (about 500 MB) with `roms` and `hash` as junctions back to E:. RACE2 is set up this way.
- Copy `layouts\ArcadeMaster` into `<root>\layouts\` and set `layout = ArcadeMaster` in settings.conf.
- **Themes:** `tools\Import-RetroFETheme.ps1 -Source <root> -RetroFE <root> -All -NoPreview` registers the layouts already in the frontend (ArcadeMaster and the CoinOPS theme). Then run `python tools\New-ArcadeThemes.py --install <root> --manifest <manifest>`, which needs `pip install pillow`; don't run it with `python -I`, which hides user-installed packages. That adds the five AM-* layouts. Tools → Themes lists everything in `<manifest>\themes.json`.
- Set `cabinetType = pedestal` in settings.conf, or `standup+lightgun` etc., or leave it on `auto`.
- Boot through `tools\Start-ArcadeMaster.ps1 -Root <root>`. It waits for the controllers, repairs IDs, matches Dolphin to the connected controllers, renders the intro and Tools art, shuffles backdrops, and runs RetroFE under the crash watchdog.
  - takes RetroFE from GitHub first: every merged patch change is built once by `.github\workflows\build-retrofe.yml` and published as release `retrofe-<key>`; the cabinet downloads it (checksum checked) and only compiles itself when that build is not there yet
