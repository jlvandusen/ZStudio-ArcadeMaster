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
| **LEDBlinky drives the marquee** | AmPanel shadow mode passes LEDBlinky's commands through | **The cabinet to take it over on.** Find the marquee hardware (LED-Wiz, PacLED, Pixelcade, a DMD, a second display?). AmPanel then lights it per game, removing LEDBlinky's last job (backlog: "Pixelcade / LED marquee output"; "Other LED boards: LED-Wiz, Howler, GPWiz"). |
| Buttons with LEDs (if any) | AmPanel, LEDBlinky-compatible | Run the Buttons window once (lights each RGB group, you press it) to make the input map. |

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

## Questions for James before the session starts

- **Encoder:** which board (I-PAC 2, Ultimate I/O, other) and are the LEDs on it? Is LEDBlinky's `LEDBlinkyInputMap.xml` up to date?
- **Marquee:** what LEDBlinky drives (LED-Wiz, PacLED64, Pixelcade, DMD, an LCD marquee).
- **Foot switches:** what they appear as (keyboard keys or a USB gamepad) and the model.
- **Leap Motion:** the model (the original Leap or Ultraleap 3Di / Stereo IR 170) and whether it faces up from the panel.
- **GRS Tron stick:** how it's wired (its own USB board or the encoder) and whether its trigger and top button are separate inputs.
- **Drive letters, PC name, GPU,** and whether RetroBat or other packs come with it, so its board entry and lane can be set up.
