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

- Copy `layouts\ArcadeMaster` into `<root>\layouts\` and set `layout = ArcadeMaster` in settings.conf.
- Set `cabinetType = pedestal` in settings.conf, or `standup+lightgun` etc., or leave it on `auto`.
- Boot through `tools\Start-ArcadeMaster.ps1 -Root <root>`. It waits for the controllers, repairs IDs, matches Dolphin to the connected controllers, renders the intro and Tools art, shuffles backdrops, and runs RetroFE under the crash watchdog.
