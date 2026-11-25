# AmPanel: ArcadeMaster's panel service (LEDBlinky + Ultimarc tools, built in)

James, 2026-11-25: replicate and embed LEDBlinky's capabilities, run in the system tray as a service that talks
back to the frontend, and fold in the Ultimarc tools (light guns, 4/8-way restrictors, and the rest).

## How it is built: published interfaces only

| Source | What it gives us |
|---|---|
| LEDBlinky `Readme.txt` | its documented command line (below). RetroFE already calls it, so a drop-in replacement needs no frontend change |
| LEDBlinky config files | `LEDBlinkyInputMap.xml` (LED pin -> button label), `DefaultLayout.lay`, `Colors.ini` (per-game colours), `Color-RGB.ini`, `Controls.ini` (controls.dat) |
| Ultimarc `PacDrive32.dll` (SDK 2.3) | `PacInitialize`, `PacGetDeviceType/ProductName/...`, `Pac64SetLEDIntensity(ies)`, `Pac64SetLEDFadeTime`, `Pac64SetLEDFlashSpeed(s)`, `Pac64SetLEDStates`, `PacSetServoStik4Way` / `8Way` |
| Ultimarc `UltraStik32.dll` | `UltraStik_Initialize`, `UltraStik_LoadMap(File)`, `UltraStik_SetRestrictor`, `UltraStik_Shutdown` |
| Windows | PnP device list (AimTrak / Sinden / Gun4IR presence), low-level keyboard hook (reactive buttons) |

LEDBlinky.exe and the Ultimarc utilities are **not** disassembled. Their documented behaviour and the SDKs are enough,
and decompiling them is outside what we do (LEDBlinky's `License.txt` sits in its folder).

## LEDBlinky's documented command line (AmPanel accepts the same)

| Args | Event |
|---|---|
| (none) or `1` | frontend start |
| `2` | frontend quit |
| `<rom> [emulator]` | game start |
| `4` | game stop |
| `5` / `6` | screensaver start / stop |
| `8 [emulator]` | list change |
| `9 <rom> [emulator]` | game selected (RetroFE sends this on every scroll: `9 "bzone" "mame"`) |
| `<anim>.lwax [S] [N]`, `11 [N]` | animation start / stop |
| `12 <ctrlr file>` | load a MAME controller file |
| `13 [map]` | UltraStik map: joy2way, joy4way, joy8way, joydiag, vjoy2way, analog |
| `14 <port>,<intensity>\|...` | set LED ports |
| `15 [rom] [emulator]` | light a game's controls only |
| `16` / `17` | game pause / unpause |

## Architecture

```
RetroFE --(AmPanel.exe 9 bzone mame)--> AmPanel.exe (short-lived) --named pipe--> AmPanel (tray, single instance)
Tools screens / launcher <------------- \\.\pipe\ArcadeMaster.Panel (JSON lines: state, events, commands) -------->
AmPanel --PacDrive32.dll--> 2 x I-PAC Ultimate I/O (192 LEDs), ServoStik
        --UltraStik32.dll--> UltraStik 360s
        --> <manifest>\panel-state.json (what is lit, restrictor mode, devices) for the frontend / Tools
```

- **One process, x86.** PacDrive32 / UltraStik32 are 32-bit. AmPanel is a .NET Framework 4 WinForms tray app built
  with the framework's own `csc.exe` (like the launcher), so it needs no Visual Studio.
- **Single instance.** A second `AmPanel.exe <args>` forwards its arguments over the pipe and exits in milliseconds,
  the same pattern as LEDBlinky's "only one instance remains" and our launcher's mutex.
- **Tray icon:** status (boards found, current game, restrictor mode), test lights, pause / resume, quit.
- **Hand-over from LEDBlinky:** a setting picks which one RetroFE calls. Only one may own the boards at a time.

## What it does (each step a PR)

1. Boards, pipe, tray, LEDBlinky-compatible command line, `panel-state.json`.
2. Per-game lights: `9`/`15`/game start light the game's buttons in its Colors.ini colours; unused buttons dim.
3. ServoStik: 4-way games (controls.dat P1Controls `4-way`, MAME `ways=4`) get 4-way on select / start, else 8-way.
   A Cabinet Settings option: auto / always 8 / always 4.
4. UltraStik maps per game (`13 <map>` semantics, auto from controls.dat).
5. Reactive buttons: a held button glows brighter (keyboard hook, panel.json key -> LED pin).
6. Attract: breathe / chase in the selected game's colours while idle, screensaver on `5`.
7. Light guns: AimTrak / Sinden / Gun4IR presence and count in the tray and Detect Controllers. Calibration stays
   with each gun's own tool (no published AimTrak SDK).
8. Tools > Button Lights: test every LED, brightness, colours on / off; Cabinet Settings > CONTROLS uses the pipe.

## Safety

- Never runs alongside LEDBlinky on the same boards: it checks, and the tray tells you which one owns them.
- Writes LED / restrictor state only. No firmware calls (`Pac64UpdateFirmware`, `PacProgramUHid`, `Pac64SetDeviceId`,
  `Pac64ClearFlash` and `UltraStik_SetUltraStikId` / `SetFlash` are never called).
