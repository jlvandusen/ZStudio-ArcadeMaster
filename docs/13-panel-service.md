# AmPanel: ArcadeMaster's panel service (LEDBlinky + Ultimarc tools, built in)

James, 2026-11-25: replicate and embed LEDBlinky's capabilities, run in the system tray as a service that talks
back to the frontend, and fold in the Ultimarc tools (light guns, 4/8-way restrictors, and the rest).

## North star (James, 2026-11-25)

"This master arcade will be the interface to end all other interfaces": complete, customizable and adaptive graphics
overlays, usable with legacy systems' layouts and art, on new technology that feels almost firmware-level fast.
AmPanel is the hardware half of that: lights, restrictors, sticks, guns and emulator outputs answer instantly, from one
service, with no third-party program in the path.

## Two faces: dummy-proof and pro (James, 2026-11-25)

- **Simple (default, for anyone at the cabinet):** everything automatic from what the cabinet learned (panel.json,
  controls.dat, Colors.ini, emulator outputs). A few big choices: lights on / off, colours per game on / off, stick
  auto / 8 / 4. Every change shows live on the panel and has an undo. Nothing here can break the cabinet.
- **Advanced (for developers):** every LED pin and raw output value, the full trigger -> activity rule editor
  (global / system / game), import / export of profiles, and the documented pipe API and command line, so anything on
  the cabinet can be scripted. Advanced changes are still saved as overrides on top of the learned defaults, never
  over the source files, so "back to automatic" always works.

## Validation: what is proven today, what is next

Proven on ARCADE-PEDESTAL (2026-11-25, step 1):

| Claim | Evidence |
|---|---|
| We can talk to the panel hardware without LEDBlinky | AmPanel read all 3 boards through Ultimarc's PacDrive SDK: 2 × I-PAC Ultimate I/O (96 LEDs each), 1 ServoStik |
| RetroFE needs no change | AmPanel accepts LEDBlinky's documented command line. `9 bzone mame` -> game selected, `assault mame` -> game start, logged and in panel-state.json |
| One instance, talks back to the frontend | A second `AmPanel.exe ...` forwards over \\.\pipe\ArcadeMaster.Panel and exits. `{"cmd":"status"}` returns the full state as JSON |
| Faster than LEDBlinky on every scroll | `9 <rom> mame` round trip: **AmPanel 130–185 ms vs LEDBlinky.exe 590–880 ms** (Windows' own process start is 57–80 ms of that) |
| Nothing lost while it grows | Shadow mode: every command is also handed to LEDBlinky.exe, which still lights the panel |

Available in the SDKs, not yet used (the next steps):

| Feature | SDK function (exported by the DLLs on this cabinet) |
|---|---|
| per-game RGB colours, fades, flashing | PacDrive32 `Pac64SetLEDIntensities`, `Pac64SetLEDFadeTime`, `Pac64SetLEDFlashSpeeds`, `Pac64SetLEDStates` |
| ServoStik 4 / 8-way per game (replaces Ultimarc's ServoStik tool) | PacDrive32 `PacSetServoStik4Way`, `PacSetServoStik8Way` |
| UltraStik 360 maps / restrictor (replaces UltraMap) | UltraStik32 `UltraStik_LoadMap`, `UltraStik_LoadMapFile`, `UltraStik_SetRestrictor` |
| emulator lamps / recoil / motors | MAME's documented Windows output protocol (also Supermodel, Model 2, Flycast, TeknoParrot plugins) |

Not covered by any SDK on the cabinet (stays with the vendor's tool until a published interface exists): AimTrak
calibration, firmware updates (deliberately never called).

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
4. UltraStik maps per game (`13 <map>` semantics). **Done (2026-11-25):** `src/panel/Sticks.cs` loads
   `UltraStik_LoadMapFile(id, file)` (checked against the DLL: stdcall, two arguments) onto every stick. It loads the
   game's map at game start and Joy8Way on game stop / frontend start, and writes only when the map changes (9-13 ms
   for both sticks). `tools/New-StickMaps.py` writes `<manifest>\stick-maps.json` from MAME's controls (joy 4 -> Joy4Way,
   2 -> Joy2Way, vertical2 -> vJoy2Way, analog stick only -> Analog; 1917 games off the 8-way default) plus
   `tools/stick-maps-overrides.json` (Q*bert -> JoyDiag). It also writes ArcadeMaster's own `.um` set to
   `<manifest>\ultrastik`; all six match LEDBlinky's jdr maps line for line. AmPanel.json `"Sticks": "own" | "ledblinky"`
   (default: follows Lights). Pipe `{"cmd":"sticks"}` gives status and the map list; add `map` or `rom` to load one.
   The pedestal has 2 UltraStik 360s (D209:0511, both set to UltraStik ID 1).
   Also done: `14 port,intensity,...` (a label, a colour name, `board:port`, or a plain port number where 97+ continues
   on board 2), and `16`/`17` dim the game's colours to 25% while paused.
5. Reactive buttons: a held button glows brighter (keyboard hook, panel.json key -> LED pin).
6. Attract: breathe / chase in the selected game's colours while idle, screensaver on `5`.
7. Light guns: AimTrak / Sinden / Gun4IR presence and count in the tray and Detect Controllers. Calibration stays
   with each gun's own tool (no published AimTrak SDK).
8. Tools > Button Lights: test every LED, brightness, colours on / off; Cabinet Settings > CONTROLS uses the pipe.
9. Output listener: MAME Windows output protocol (MAME `-output windows`, Supermodel `-outputs=win`, Model 2, Flycast,
   TeknoParrot output plugins). Learns each game's output names; live meters.
10. Trigger -> activity rules (global / system / game): lamps -> LEDs, recoil -> gun, motors -> rumble / FFB.
11. The assignment screen (Buttons / Colours / Triggers tabs above).
**Keeping AmPanel current (2026-11-26):** each boot runs `tools\Update-AmPanel.ps1 -Boot` before AmPanel starts.
When `src\panel`, Build-AmPanel.ps1 or the rule files changed since the installed build (`<ArcadeMaster>\AmPanel.build.txt`),
it compiles AmPanel and installs it, together with the LEDBlinky.exe shim. A failed compile leaves the installed copy in place,
and a cabinet without AmPanel installed is left alone. Before this, fixes reached a cabinet only through a hand-run
`Build-AmPanel.ps1 -InstallTo`.

12. Cut-over: AmPanel is the default; LEDBlinky.exe and the Ultimarc utilities are no longer started.
    **First part done (2026-11-26):** AmPanel no longer needs the LEDBlinky install at run time. Set-ButtonLights copies
    the following into `<ArcadeMaster>\panel-data` and points AmPanel.json `LEDBlinkyDir` there:
    - Ultimarc's `PacDrive32.dll` and `UltraStik32.dll`
    - LEDBlinky's `Colors.ini`, `Color-RGB.ini`, `LEDBlinkyInputMap.xml` and `Settings.ini` (`[Pixelcade]`)
    - `lwa\` and `jdr\UltraStik\`

    It only copies (when a file is missing or newer at the source) and never deletes. `Set-ButtonLights -Refresh` runs at every
    boot, keeps the copy current while LEDBlinky is still installed, and moves cabinets that switched over earlier onto it.
    Switching back to LEDBlinky still uses the real folder (button-lights.json). Still open: ArcadeMaster as the default
    engine, and the encoder / AimTrak tools.
13. Pixelcade LED marquee. **Done (2026-11-26, the 2-player stand-up):** `src/panel/Marquee.cs`. AmPanel.json
    `"Marquee": "pixelcade"` turns it on; without it nothing changes (LEDBlinky keeps the marquee). AmPanel then
    sends the Pixelcade listener (pixelweb, port 8080) the same requests LEDBlinky sent on that cabinet:
    - frontend start: the welcome text once;
    - list change: the system's marquee;
    - game selected: the game's marquee;
    - game start: blank, "Now Playing <title>" once, then the game's marquee for the whole game;
    - game stop: the selected game's marquee again;
    - screensaver: a random animation from `<Pixelcade>\animations` (`"MarqueeScreensaver": "random" | "attract" | "none"`;
      `attract` needs a newer listener than 4.4.7);
    - frontend quit: "Thanks for Playing", then the marquee's own idle image.

    The texts, colour and speed are read from LEDBlinky's `[Pixelcade]` settings (Settings.ini), so it looks as before.
    `MarqueeStartText`, `MarqueeQuitText`, `MarqueeNowPlaying` (`~game~` = the title), `MarqueeColor` (a name, hex,
    or `random`), `MarqueeSpeed`, `PixelcadeUrl` and `PixelcadeDir` win over them. LEDBlinky stops getting commands
    when the marquee is on (unless `"PassThrough": true`, then set LEDBlinky's `UsePixelcade=0`).
    If the listener isn't answering, AmPanel starts `<Pixelcade>\pixelweb.exe` (at most once a minute), waits for the
    panel to connect and sends again, so the "Pixelcade Listener" startup shortcut isn't needed.
    The pipe takes `{"cmd":"marquee","text":"INSERT COIN","color":"yellow"}`, `{"cmd":"marquee","game":"pacman",
    "system":"mame"}` and `{"cmd":"marquee","path":"/v2/info"}`. The status shows sent / failed counts.
    Not yet: LEDBlinky's `~hiscoretop3~` (high scores on the marquee) is left out of the "Now Playing" text.
    **Turned on by itself (2026-11-26, `tools\Set-Marquee.ps1`):** the 2P stand-up's marquee went quiet after the
    cut-over. The shim takes LEDBlinky's place, so LEDBlinky's own Pixelcade link (`UsePixelcade=1`) never got an event, and
    nothing had written `"Marquee": "pixelcade"`. Now boot (Start-ArcadeMaster), the switch to the ArcadeMaster engine
    (Set-ButtonLights) and **Cabinet Settings > LED MARQUEE (PIXELCADE)** run Set-Marquee. It finds Pixelcade in this order:
    - AmPanel.json `PixelcadeDir`
    - LEDBlinky's `[Pixelcade] PixelcadeFolder`
    - a running listener
    - `<drive>:\Pixelcade` or `%USERPROFILE%\pixelcade`
    - anything answering on port 8080

    It then writes `Marquee` and `PixelcadeDir` (plus `LEDBlinkyDir` for the texts) and restarts AmPanel. It does nothing
    while LEDBlinky still gets the events, and it respects `"Marquee": "off"` (the settings switch).
    The health check no longer "repairs" a `LEDBlinkyDirectory` that points at the shim: that quietly gave the events back
    to LEDBlinky.

14. **Game Options. Done (2026-11-27, the 2-player stand-up):** `src/panel/GameOptions.cs`. **TAB** on the selected
    game, while the frontend is in front and no game runs, opens a menu for that game. It uses the "which controller?"
    screen, in menu mode: stick to move, button 1 to pick, button 2 / Esc / TAB to close, closes itself after 30 s.
    - **Emulator:** the launchers that can run this game, each named with its real version (`mame.exe -version`,
      cached in `<manifest>\emulator-versions.json`). A launcher counts when it is the same emulator family as the
      collection's own launcher, takes the same arguments, and its program exists (CORE's `MAME251` points at a
      missing folder, so it is left out). The choice is RetroFE's own per-game launcher file,
      `collections\<collection>\launchers\<item>.conf`.
    - **Map buttons:** MAME keeps a game's own buttons from its in-game menu (TAB > Input (this Machine), saved in
      `cfg\<game>.cfg`). The menu says so. TeknoParrot, Dolphin and Cemu: their own window opens, in front of the frontend.
    - **Back to default:** the launcher file as it was before Game Options changed it (CORE's own choices, e.g. mrdo ->
      MAME64196, come back). Every change is recorded in `<manifest>\game-options.json`.
    - The frontend names the item's launcher, not its collection ("arcade pc rh" for Friction). `games.json` ids
      (`<collection>:<item>`) give the real collection.
    - The screen takes the keyboard from the frontend by sharing its input queue for a moment. Without that, Windows
      kept the keys on the frontend, and the stick moved the list behind the menu.
    - AmPanel.json `"GameOptionsKey"`: `"Tab"` (default), any key name, or `"none"`. docs/21: a module that moves into the
      frontend later.
15. **Pixelcade listener window:** pixelweb opens a console window titled "Pixelcade Listener". AmPanel hides it
    whenever it shows up (its log stays in `<Pixelcade>\pixelweb.log`).
16. **AmPanel drives the Pixelcade board itself (2026-11-27, the 2-player stand-up):** `src/panel/PixelDirect.cs`.
    AmPanel.json `"PixelcadeDriver": "direct"` (with `"Marquee": "pixelcade"` and `PixelcadeDir`).
    - **Start:** AmPanel stops the Java listener (pixelweb.exe and its java.exe), then opens the board's serial port,
      the `port=` in `<Pixelcade>\settings.ini` (COM7 on the stand-up). If the board can't be opened, the listener is
      started again and everything goes through it, as before. Without the setting, nothing changes.
    - **Protocol,** from the open-source Pixelcade code (alinke/PIXEL, ioio-commons):
      - the board's hello is `0x00 'IOIO'` + hardware / bootloader / firmware ids (the stand-up: PIXL0025, IOIO0401,
        PIXL0010);
      - interface check: `0x02 "YTAI0002"`;
      - matrix on: `0x1E 0x14` (4 chained 32-wide panels, 16-row scan: ADAFRUIT_128x32, Pixelcade's "matrix type 15");
      - each frame: `0x1F` + 6144 bytes (3 bit-planes; `RgbLedMatrixImpl.convertAdafruit`).
    - **Art,** found like the listener finds it:
      - `<Pixelcade>\<folder>\<game>.gif` (or `<game>_NN.gif` at random), then `.png`. The folder comes from
        `console.csv` (e.g. `arcade` -> `mame`);
      - then `console\<folder>`, `console\default-<folder>`, `console\default-marquee`;
      - else the title scrolls as text.
      - GIFs play with their own frame timing.
    - **Events:** as with the listener (welcome, list change, selected game, Now Playing + the game held, game stop,
      a random animation for the screensaver, Thanks for Playing). A newer event replaces what is playing; a one-time
      text goes back to the last held picture.
    - **Only 128x32** (the Adafruit kind) so far. Other Pixelcade sizes keep the listener.

## Safety

- Never runs alongside LEDBlinky on the same boards: it checks, and the tray tells you which one owns them.
- Writes LED / restrictor state only. No firmware calls (`Pac64UpdateFirmware`, `PacProgramUHid`, `Pac64SetDeviceId`,
  `Pac64ClearFlash` and `UltraStik_SetUltraStikId` / `SetFlash` are never called).
