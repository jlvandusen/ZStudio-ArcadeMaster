# 20. Deploying ArcadeMaster on a new cabinet: the 2-player stand-up (development)

For James and for the Claude session that sets up the cabinet. docs/09 is the general install. This file is the order of work for **this** cabinet and its hardware, with the traps the pedestal found, so a fresh machine doesn't repeat them.

## The cabinet

| Part | ArcadeMaster today | Work needed |
|---|---|---|
| 32" screen, single display | Supported (`numScreens = 1`; layouts are 1920x1080) | Check the panel's native resolution. |
| Two joysticks; **P1 has a physical 4/8-way switch** | Sticks: yes. The restrictor is driven only for a ServoStik (AmPanel) or a TOS GRS (RetroFE probes it) | A physical switch can't be driven. Instead, the 4-way reminder banner (Cabinet Settings > SPECIAL-CONTROL REMINDERS) and the controls card tell the player "set P1 to 4-way" for the 153 4-way games. Option: a line on the "which controller?" screen. |
| **GRS Tron 8-way stick** (trigger + top button) | Discs of Tron / Tron controls cards exist | Find out how it connects (USB HID, or wired into the encoder) and map it as the Tron stick: trigger B1, top button B2, 8-way. If it's the GRS optical/rotary type, it also feeds the spinner. |
| **2 Ultimarc light guns** (AimTrak) | Detected (AmPanel Guns: D209:16xx). TeknoParrot guns per profile | Calibrate each gun (Ultimarc's AimTrak tool), then map: MAME (raw input, `-mouse_index` per gun), TeknoParrot gun games, RetroBat / emulatorLauncher gun support for Classic Systems. Set `cabinetType = standup+lightgun`. |
| **USB foot switches** (Time Crisis "cover" pedal and others) | Not yet | Find what they send (keys or a HID gamepad: `tools\Watch-Inputs.ps1`), then map them as the cover / reload pedal in TeknoParrot (Time Crisis 4/5, Razing Storm...), MAME (`timecris`, `crisis2`) and Model 2/3 guns. Add a "pedal" control to the controls cards. |
| **Trackball** + **spinner dial** | Trackball and spinner games are tagged, cards are drawn, and MAME maps them | Several mice at once: MAME `-multimouse` so the trackball, spinner and two guns don't all move the same cursor (backlog: "rollerball / dial multimouse split"). The "which controller?" screen offers trackball or joystick for 222 games. |
| **Leap Motion hand sensor** (Ultraleap) | **Not supported, new** | A gesture module in AmPanel: swipe = menu left/right/up/down, pinch = select, open palm held = back / pause screen, and later the hand as a pointer for gun games without guns. Needs the Ultraleap Gemini runtime and its C API (LeapC), loaded the way AmPanel loads PacDrive. |
| **LEDBlinky drives the Pixelcade LED marquee** | **AmPanel drives it (2026-11-26):** AmPanel.json `"Marquee": "pixelcade"`, docs/13 step 13. Tested on the marquee itself (Pixelcade LED 128x32, listener 4.4.7) | When AmPanel is installed here: set `"Marquee": "pixelcade"`, then LEDBlinky and the "Pixelcade Listener" startup shortcut are no longer needed. |
| Button LEDs | Mini-PAC has no LED outputs | None on this cabinet. |

## Before the first command (lessons from the pedestal)

- **Drive letters:** many defaults say `D:\ArcadeMaster`. Pick `<drive>:\ArcadeMaster` (manifest, build, library) and pass `-ManifestDir`, `-Root` and `-BuildRoot` everywhere. Three tools broke on Windows PowerShell 5.1 because the pedestal has no D: (fixed in PRs 112, 135 and 162), so watch for more.
- **Install PowerShell 7 (pwsh)**, Git, Python 3.12 (`pip install pillow`) and the GitHub CLI. Everything also runs on Windows PowerShell 5.1 now, but pwsh 7 avoids its traps (native stderr, Join-Path on missing drives).
- **To build RetroFE locally (optional):** VS 2022 Build Tools (C++) and GStreamer 1.24.13 MSVC unpacked with `msiexec /a`. Otherwise Update-Cabinet takes the release from GitHub or a package from `Z:\ArcadeMaster\builds\retrofe-p0016-*`.
- **The live frontend is never edited.** Work on a copy (`<drive>:\ArcadeMaster\frontend\<build>-am`) and junction the big read-only parts back. MAME must be a real folder (docs/09).
- **controls.conf `quit`** must be a key on no panel button: RetroFE ends the running game on one press of any quit key. Use `quitCombo` (for example P1 Start + P1 Coin) and AmPanel's Esc exit guard (`tools\exit-rules.json`). The health check fixes this from panel.json.
- **Every lesson goes into ZStudio-DevBox** (`docs/07-windows-gotchas.md`) in the same session.

## Order of work

1. **Join the board.**
   - Run `tools\Board.ps1 beat -Doing "new 2P stand-up: setting up"`.
   - Post a note for DESKTOP-RACE1 (the coordinator) naming the machine, what it has (the table above, GPU, engines) and that it takes pool jobs. Ask it for its `coord` lane.
   - Read `Z:\ArcadeMaster\board` and docs/18 (the way forward).
2. **Clone and survey (read-only).**
   - `git clone https://github.com/jlvandusen/ZStudio-ArcadeMaster.git <drive>:\repos\personal\ZStudio-ArcadeMaster`
   - `tools\Survey-Frontends.ps1`: every RetroFE, CoinOPS, LaunchBox and RetroBat install, which become sources for the library (docs/18 end state).
   - `tools\Get-CabinetDevices.ps1 -Out <manifest>\cabinet.json -History <manifest>\device-history.json`: guns, trackball, spinner, encoders, displays.
   - `tools\Watch-Inputs.ps1 -Out <manifest>\input-capture.txt`, with James pressing every control: each button, both sticks, the Tron stick's trigger and top button, both foot switches, the spinner, the trackball, the guns (trigger + side buttons). That capture is the ground truth for everything below.
3. **Panel definition.**
   - `python tools\Import-LEDBlinkyPanel.py` (from LEDBlinky's input map) builds `<manifest>\panel.json`.
   - Add the Tron stick, the foot switches, the spinner and both guns, as the pedestal's panel.json has `spinner` / `twinStick` / `flightStick` / `trackball` entries.
   - The cards (`New-PanelControlsArt.py`), the Xbox map and the exit guard all read panel.json.
4. **Frontend copy and boot** (docs/09 section 6), then automatic updates:
   - Build-Manifest, Add-GameControls, New-RetroFECollections -RebuildDatabase, New-CabinetToolsCollection;
   - copy the ArcadeMaster layout and set `layout = ArcadeMaster`, `cabinetType = standup+lightgun`, `numScreens = 1`;
   - `Update-Cabinet.ps1 -Root <root> -ManifestDir <manifest> -BuildRoot <drive>:\ArcadeMaster\build`, then the same with `-Install` (the 15-minute task). Confirm that `Z:\ArcadeMaster\reports\state\<PC>.json` appears.
5. **AmPanel (lights, marquee, sticks, guns, exit guard).**
   - `tools\Build-AmPanel.ps1 -InstallTo <drive>:\ArcadeMaster` (or the NAS package), started at boot by Start-ArcadeMaster.
   - Start in shadow mode (LEDBlinky keeps the lights).
   - Then Cabinet Settings > BUTTON LIGHTS ENGINE = ArcadeMaster, and the Buttons window to learn every LED.
   - Then the marquee hardware (new work, see the table).
6. **Classic Systems / library** (docs/15, docs/18): `python tools\Import-RetroBatSystems.py ... --all` if this cabinet has RetroBat or a copy of the library. Then the library move (`tools\Invoke-LibraryMoves.ps1`) for its own packs, with James's go-ahead per install.
7. **Per-device mapping and tests:**
   - guns: calibrate, then test in MAME (Area 51, Lethal Enforcers), TeknoParrot (Time Crisis 5 with the pedal) and Model 2 (Virtua Cop);
   - trackball and spinner: Centipede, Marble Madness, Tempest, Arkanoid;
   - P1 4/8 switch: Pac-Man with the reminder showing;
   - Tron stick: Discs of Tron, Tron.
8. **New features this cabinet brings** (each a board item, claimed before starting):
   - AmPanel gesture module (Leap);
   - AmPanel marquee output (LEDBlinky replaced);
   - foot-switch "pedal" control in the catalog and cards;
   - MAME multimouse (trackball, spinner, two guns);
   - the physical-restrictor reminder on the controller screen.

## James's answers (2026-11-26), and what they change

- **Encoder: Ultimarc Mini-PAC.**
  - A keyboard encoder with no LED outputs, so there are no button lights to drive, and AmPanel's button-light features stay off on this cabinet.
  - Its keys come from the I-PAC tool (WinIPAC). Capture them with Watch-Inputs and write them into panel.json; LEDBlinky's input map has nothing to add for buttons here.
- **Marquee: a Pixelcade LED ("PixelLED Art Maker's Kit - Arcade", creativeartsandtechnology.com), driven by LEDBlinky today.**
  - Pixelcade is run by its own service (Pixelcade "pixelweb") with a local HTTP API on the cabinet (port 8080): show a game's marquee by system + game name, scrolling text, an idle / attract image.
  - **Takeover plan:** an AmPanel `Marquee` module calls that API from the events AmPanel already gets (game selected = that game's marquee; game start; frontend idle = attract; "Now playing" text). LEDBlinky is then no longer needed on this cabinet.
  - Verify the exact API paths on the cabinet first; Pixelcade's own docs and the running service are the source.
- **Foot switches: they can send keyboard keys or gamepad buttons.** Use **keyboard keys** on keys no other control sends, so they behave like the Mini-PAC (one place to map: panel.json "pedals"). Then map them as the cover / reload pedal per gun game.
- **Leap Motion: the original Leap Motion Controller, software 3.2.1 (Orion).**
  - The v3 service has a local WebSocket (JSON hand frames) and the LeapC C API.
  - The gesture module reads the WebSocket (the simplest route, no native DLL), turning swipe / pinch / palm-hold into menu keys and the pause screen.
  - Pin the 3.2.1 runtime: newer Ultraleap (Gemini) builds drop the original controller on some versions.
- **GRS Tron stick: wired as P1, with the trigger on P1 B1 and the top button on P1 B2.**
  - It shares P1's inputs with the regular P1 stick: no extra device, and the Tron / Discs of Tron cards use P1 B1 / B2.
  - Watch-Inputs confirms which of the two sticks is plugged into the Mini-PAC's P1 joystick inputs, or whether they are paralleled.
- **What the session found (2026-11-26):**
  - The PC is **DESKTOP-ARCADE**. Its drives are C:, E:, F:, G: and H:, with **no D:**. Pixelcade is in `E:\Pixelcade` and LEDBlinky in `E:\LEDBlinky`.
  - It booted into the CORE-TYPE R frontend (`E:\CORE-TYPE R\CORE.exe`) from the all-users Startup folder. That shortcut was moved to `C:\ProgramData\ArcadeMaster\disabled-startup` (James: no more auto-starting it). Nothing else was changed.
  - The Pixelcade listener is `pixelweb.exe`, a launcher that starts `E:\Pixelcade\jre\bin\java.exe`, which serves port 8080. pixelweb.log shows every request it gets, which is the easiest way to check the marquee.
  - On listener 4.4.7, `/attract` and `/info` don't exist (pixelweb answers with its web page). `/v2/info`, `/animations/stream/random?r` and `/localplayback` all work.
- **Install (2026-11-26):**
  - James added a 120 GB SSD as **D:**, so the tools' `D:\ArcadeMaster` defaults work here. The ROMs (1.5 TB) and the emulators stay on E:.
  - **Frontend:** a copy of CORE-TYPE R at `D:\ArcadeMaster\frontend\CORE-am`, 64 GB: frontend files plus every collection's artwork and videos.
    - Junctions back to E: for every `collections\*\roms` and every emulator except MAME.
    - MAME is a real folder; its `roms`, `hash`, `samples` and `artwork` are junctions.
  - **RetroFE build:** compiled here (VS 2022 Build Tools + GStreamer 1.24.13 unpacked in `D:\ArcadeMaster\_tools\gstreamer`). CORE has a file called `RetroFE` in its root, so `<root>\retrofe\` can't exist. The build goes over `core\`, and CORE's own files are kept in `retrofe.am-prev`.
    - Mirror the build into `core`. Laying it over CORE's old files made RetroFE quit at once.
  - **Quit key:** CORE's controls.conf has no `quit` line, and the patched RetroFE won't start without one ("Missing required property: controls.quit"; it closed 3 s after every start). The health check now adds the profile's quit key: F8 here, since Q is P2 button 3 on the Mini-PAC.
  - **Panel:** LEDBlinky's input map is empty here (there are no button LEDs). `panel.json` was written from the Mini-PAC's default keys:
    - P1: L-Ctrl, L-Alt, Space, L-Shift, Z, X, Start 1, Coin 5;
    - P2: A, S, Q, W, I, K, Start 2, Coin 6;
    - 6 buttons per player in 2 rows of 3, assumed; the input capture checks it.
  - **Lights and marquee:** `Set-ButtonLights -Engine ArcadeMaster` with `"Marquee": "pixelcade"`. LEDBlinky is no longer started.
  - **Boot:** `D:\ArcadeMaster\ArcadeMaster.exe` from the user's Startup folder, plus the "ArcadeMaster Update" task.
- **Devices found (Detect Controllers):**
  - 2 AimTrak guns (D209:1601 / 1602).
  - A **Mayflash DolphinBar** (057E:0306, 4 Wii Remote slots: James wants Wii Remotes connected as needed, a board job).
  - A **Xinmotek** encoder (16C0:05E1, most likely the Tron stick).
  - A "2 axis 8 button gamepad" (1A86:E026, possibly the foot switches).
  - A CH Flight Sim Yoke, plugged in only to test games (not part of the cabinet).
  - Players: 4. James: that's right, with Wii Remotes and other USB controllers.
- **Frontends on this PC (Survey-Frontends):** 11 installs, see `reports/frontends/DESKTOP-ARCADE.md`:
  - RetroFE: `E:\CORE-TYPE R`, `G:\CO LightGuns`, `G:\CORE Type R LightGuns`;
  - LaunchBox / BigBox: `F:\LaunchBox`, `F:\support\LaunchBox`, `G:\LaunchBox`;
  - RocketLauncher: `F:\RocketLauncher`, `G:\RocketLauncher`.
- **Drives:** C:, D: (added for ArcadeMaster), E:, F:, G:, H:. It has a D:, so the tools' defaults (`D:\ArcadeMaster\...`) can be used if D: is the data drive; still pass `-ManifestDir` / `-Root` / `-BuildRoot` explicitly. Pick the drive with room for the library, then fill in the PC name and GPU on the board when the session joins.
