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

## Goal: our own, end to end (James 2026-11-25)

"I want to eventually run without either application, just our own which does the same thing." AmPanel replaces
LEDBlinky.exe and the Ultimarc utilities on every cabinet. Their DLL SDKs stay (they are the drivers' published API).
Until each feature is proven, a setting picks LEDBlinky or AmPanel per cabinet, so nothing is lost on the way.

## Emulator outputs: lamps, recoil, rumble, force feedback

Games tell the outside world what their cabinet lamps, recoil solenoids, coin counters and motors do. MAME publishes
this through its **Windows output protocol** (documented in MAME's source, `src/osd/windows/winoutput` / `output.h`).
A listener creates a window and receives the registered messages `MAMEOutputStart`, `MAMEOutputStop`,
`MAMEOutputUpdateState` (name id + value), `MAMEOutputRegister` / `Unregister`, and asks names with
`MAMEOutputGetIdString`. Supermodel (`-outputs=win`), Model 2 Emulator, Flycast and TeknoParrot's output plugins speak the
same protocol, so **one listener hears every emulator**. MAME itself is started with `-output windows`.

AmPanel keeps a **trigger -> activity** table: what each output does on this cabinet.

| Trigger (from the game) | Activity (on this cabinet) |
|---|---|
| `led0`, `lamp1`, `Start1_Lamp`... | light / flash a button LED in a colour |
| `recoil`, `P1_Gun_Recoil`, `Gun1Recoil` | fire the gun's recoil (Sinden / Gun4IR serial, AimTrak solenoid output) |
| `rumble`, `motor`, `Wheel_Motor`, `ffb_*` | rumble / force feedback on the wheel or a pad (DirectInput, through the device that owns FFB) |
| `coin_counter0`... | ignored, or counted for the cabinet stats |
| frontend events (`9 <rom>`, game start / stop, idle) | per-game colours, ServoStik 4/8, UltraStik map, attract animation |

- **Defaults are learned, not typed:** every output name a game sends is recorded per game the first time it runs
  (`manifest\outputs\<game>.json`). The assignment screen then lists the real names, not guesses.
- **Rules have three levels:** global (`*lamp*Start1*` -> P1 START button LED), per system (all of `naomi`), per game.
  The most specific wins.
- **FFB:** wheel FFB in games is the emulator's own (TeknoParrot, Supermodel, MAME drive DirectInput directly).
  AmPanel adds FFB effects only for outputs that have none (a MAME cabinet motor output -> a wheel rumble), and never
  holds the FFB device while a game owns it, the same rule as RetroFE's menu FFB (released before launch).

## Assignment UI: clear for a person at the cabinet

One "BUTTON LIGHTS & OUTPUTS" screen (Tools, and the tray window on a desktop), three tabs:
1. **Buttons.** The panel drawn as it really is (panel.json positions). Press a real button and it highlights on screen
   and on the panel. Choose its LED pin (or "learn": AmPanel blinks pins one by one, you press the button that lit up).
   This replaces LEDBlinky's InputMap wizard.
2. **Colours.** A game's buttons with its colours from Colors.ini. Pick a colour per button from a palette (or RGB),
   preview it live on the panel, and save as a per-game override (`manifest\led-colors.json`, never editing Colors.ini).
3. **Triggers.** Outputs the current or last game sent (learned list) -> activity, with a live value meter for
   each output so you can see which lamp is which while the game runs.

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
9. Output listener: MAME Windows output protocol (MAME `-output windows`, Supermodel `-outputs=win`, Model 2, Flycast,
   TeknoParrot output plugins). Learns each game's output names; live meters.
10. Trigger -> activity rules (global / system / game): lamps -> LEDs, recoil -> gun, motors -> rumble / FFB.
11. The assignment screen (Buttons / Colours / Triggers tabs above).
12. Cut-over: AmPanel is the default; LEDBlinky.exe and the Ultimarc utilities are no longer started.

## Safety

- Never runs alongside LEDBlinky on the same boards: it checks, and the tray tells you which one owns them.
- Writes LED / restrictor state only. No firmware calls (`Pac64UpdateFirmware`, `PacProgramUHid`, `Pac64SetDeviceId`,
  `Pac64ClearFlash` and `UltraStik_SetUltraStikId` / `SetFlash` are never called).
