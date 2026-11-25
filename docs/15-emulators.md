# 15. Emulators: what we run, and supporting every legacy system dynamically

James, 2026-11-25: *"Review all the emulators we use for WiiU, Wii, Genesis, SNES, NES etc... and important we document
and figure out how to support dynamically Amiga, C64 and other legacy systems... XEMU which runs legacy XBOX, that may
need a lot of work."* This review was made on ARCADE-PEDESTAL. Every launch below was tested there, not guessed.

## Where the emulators are

Two emulator stacks are on the pedestal:

| Stack | Where | What it is |
|---|---|---|
| CoinOPS LEGENDS | `R:\ArcadeMaster\frontend\LEGENDS-am\emulators` (live: `E:\CoinOPS LEGENDS 4 Max`) | What the frontend launches today: MAME 0.196 / 0.231 ("mameNEW"), three RetroArch builds (Plus / SEGA / Xiso), WinUAE (Pipmick Amiga pack), Supermodel, Daphne, TeknoParrot 1.0.0.886 / 737, Dolphin Triforce. Mostly arcade. |
| RetroBat | `R:\CP78\RetroBat` | A full console and computer library: **emulatorLauncher 1.0.0.2970** plus standalone emulators and large ROM sets. Today only its TeknoParrot (1.0.0.1696) is used by our catalog. |

Standalone emulators installed in RetroBat: Cemu (Wii U), Dolphin (GameCube / Wii), xemu 0.8.1 (Xbox), PCSX2 2.3.83 (PS2), RPCS3 (PS3), PPSSPP 1.18.1, Citra canary (3DS), Project64, BigPEmu (Jaguar), Model 2, Supermodel, TeknoParrot and RetroArch with a full core set.

Many other folders (winuae, hatari, mednafen, dosbox, ...) are empty placeholders that RetroBat fills on demand.

## System by system

| System | Today in ArcadeMaster | RetroBat games | Best emulator here | Notes |
|---|---|---|---|---|
| NES | MAME `nes` (collection near empty) | 150 | RetroArch Mesen / FCEUmm | MAME works but adds latency; libretro cores give run-ahead. |
| SNES | MAME `snes` (29 games) | 446 (+1028 MSU) | RetroArch Snes9x / bsnes | Same as NES. MSU-1 sets need their own system (`snes-msu`). |
| Genesis / Mega Drive | MAME `genesis` (16) | 443 (+260 MSU) | RetroArch Genesis Plus GX | Sega CD 74, 32X 30 too. |
| PC Engine, GBA, PS1 | MAME (`tg16`, `gba`, `psu`) | 32 / 175 / 255 | Mednafen PCE / mGBA / DuckStation or SwanStation | MAME's PS1 is weak; DuckStation is the one to use. |
| GameCube | RetroArch dolphin core (4) | 273 | Dolphin standalone | The core lags standalone Dolphin; RetroBat configures Dolphin per game. |
| Wii | none | 20 (.wbfs) | Dolphin standalone | Wii-mote games need a pointer: the light guns / trackball, mapped in Dolphin. |
| Wii U | launcher points at .bat files that aren't in this build | 70 (.wux / .wua) | Cemu | Needs title keys (keys.txt) and a GamePad mapping (second screen = the pedestal's touch screen?). |
| Xbox | none | 101 (XISO, checked) | **xemu 0.8.1** | Boots here (details below). |
| PS2 / PS3 | .bat launchers (missing here) | 329 / 18796 files | PCSX2 2.3 / RPCS3 | Heavy; RPCS3 on a GTX 1660 Super is per-game. |
| Amiga | WinUAE, Pipmick pack: 198 games as per-game `.uae` configs, plus CD32 (61) via PUAE | 140 Amiga 500 (.hdf WHDLoad) | WinUAE (pack) or PUAE through emulatorLauncher | Both work. The A1200 / CD32 folders in RetroBat are empty. |
| C64 | MAME `C64 -flop` (1 game) | 72 (.zip) | RetroArch VICE x64sc | MAME's C64 is slow to load disks. VICE autostarts, and joystick port 2 is the default most games use. |
| Others in RetroBat with games | none | 3DO 34, Atari 2600/5200/7800 69/63/33, Jaguar 29, Lynx 42, ColecoVision 30, Master System 72, Game Gear 64, GB/GBC 176/81, NDS 84, N64 218, Saturn 180, Dreamcast 195, Naomi 32, Atomiswave 51, Neo Geo 155, FBNeo 4020, Switch 48, ... | as RetroBat picks | All reachable the same way (next section). |

**Real game counts:** the "RetroBat games" column above counted every file under a system's folder, including its scraped images and videos. `Import-RetroBatSystems.py` counts only games in the system's extensions: Xbox 36, Wii 7, Wii U 27, GameCube 103, NES 50, SNES 150, Mega Drive 151, Master System 25, PC Engine 11, PS1 68, N64 73, Saturn 57, Dreamcast 54, Amiga 500 50, C64 30, Atari 2600 23. 47 of RetroBat's 237 systems have games, and all 47 have an installed emulator.

## How to support every system dynamically

RetroBat has already solved per-emulator setup. `emulatorLauncher.exe -system <s> -emulator <e> -core <c> -rom <file>` writes that emulator's config fresh for this PC at every launch: paths, BIOS, controllers, shaders, fullscreen. It then starts the emulator and waits. `es_systems.cfg` lists about 150 systems with their file extensions and emulator / core choices.

**Tested on the pedestal (2026-11-25):**
- xbox / xemu (Blackstone.iso): xemu ran (1.1 GB). emulatorLauncher rewrote `xemu.toml` from the copied machine's `G:\RetroBat\...` to this machine's `R:\CP78\RetroBat\bios\mcpx_1.0.bin`, `Complex_4627.bin` and `saves\xbox\xbox_hdd.qcow2`.
- amiga500 / PUAE ("Another World.hdf"): RetroArch with the puae core ran.
- c64 / VICE x64sc ("Airborne Ranger.zip"): RetroArch with the vice core ran.

So the plan is to **generate**, not hand-build:

1. **`tools/Import-RetroBatSystems.py`** (to write) reads `es_systems.cfg` and records, for each system: its name, full name, extensions, emulators and cores, which emulators are actually installed (exe present), and its ROM folder with the game count. Output: `<manifest>\systems.json`.
2. For every system with games **and** an installed emulator, it writes a RetroFE collection: `list.path` = the RetroBat ROM folder, `list.extensions` from es_systems, artwork from RetroBat's `gamelist.xml` / `downloaded_images`. The collection gets a launcher: `emulatorLauncher.exe -system <s> -emulator <e> -core <c> -rom "%ITEM_FILEPATH%"`.
3. The emulator / core choice is per cabinet in `<manifest>\systems-cabinet.json`, the same pattern as stick-maps-cabinet.json. A Tools screen picks it.
4. Systems feed the existing machinery:
   - `games.json` (controls per system: a C64 joystick on port 2, the Amiga mouse on the trackball);
   - controls cards;
   - the "which controller?" question (Xbox: panel or gamepad);
   - AmPanel lights per system.
5. Keep the LEGENDS launchers where they are better (the Pipmick Amiga pack with its tuned per-game configs, MAME for arcade). The cabinet's choice decides, and the importer never overwrites a hand-made collection.

Adding a system later is then only a matter of putting its ROMs in a RetroBat folder and rerunning the importer.

## Xbox (xemu): the work it needs

- **It boots** with the BIOS and hard-disk image already here, and the 101 games are already XISO (no conversion).
- **Input is the big item.**
  - Launched without a controller config, xemu falls back to `port1 = 'keyboard'`.
  - The pedestal has keyboard-encoder sticks and no gamepad, while Xbox games want a dual-analog pad with analog triggers.
  - Options: (a) xemu's keyboard bindings mapped to the panel; (b) a virtual XInput pad (ViGEmBus) fed from the panel and UltraStiks, which also helps PCSX2 / Cemu / Dolphin; (c) ask for a real pad with the controller question.
  - (b) is the robust one, and AmPanel already reads the panel.
  - **Done first, with no driver (2026-11-25, PR 138):** xemu 0.8 has `[input.keyboard_controller_scancode_map]`, and emulatorLauncher keeps that section when it rewrites xemu.toml (tested). `tools/Set-XemuPanelMap.py` writes it from panel.json, as a Rebuild Menus step:

    | Xbox pad | Panel |
    |---|---|
    | Left stick | P1 stick |
    | Right stick | P2 stick |
    | A / B / X / Y | P1 B1-B4 |
    | White / Black | P1 B5-B6 |
    | LT / RT | P1 B7-B8 |
    | L3 / R3 | P2 B1-B2 |
    | D-pad | P2 B5-B8 |
    | Start / Back | P1 start / coin |

    The sticks are digital: good for most games, weak for driving. Needs James at the panel to confirm each control in a game; the trigger names are the least certain.
- **emulatorLauncher's controller argument** (`%CONTROLLERSCONFIG%` in es_systems) has to be passed, or xemu gets keyboard only. Its format comes from EmulationStation and needs reading.
- **Performance:** Vulkan at `scale = 2` on a GTX 1660 Super. Measure per game; `scale = 1` where needed.
- **Exit:** RetroFE's quit combo or AmPanel has to close xemu cleanly (the hard-disk image is written).
- **Compatibility:** check each of the 101 games against xemu's compatibility list, and hide the ones that don't play (as games-cant-start does for TeknoParrot).

## Amiga and C64 specifics

- **Amiga:**
  - WHDLoad `.hdf` games run on PUAE with automatic models. AGA games need the A1200 model, which emulatorLauncher picks by system (`amiga1200`).
  - The mouse goes on the trackball, and multi-disk `.adf` sets go in `.m3u`.
  - The Pipmick pack's per-game `.uae` files are the best tuned; keep them as the default where they exist.
- **C64:**
  - VICE x64sc autostarts.
  - Most games read the joystick on **port 2**: map P1's stick there.
  - Some need the keyboard (space / F1 / RUN-STOP): put those on panel buttons, or use a virtual keyboard.
  - `.m3u` for multi-disk.

## Next steps (in order)

1. **Done (2026-11-25):** `tools/Import-RetroBatSystems.py`, a Rebuild Menus step that skips itself without RetroBat.
   - On the pedestal: 16 systems under a new **Classic Systems** main-menu entry, with 4,339 art links and launchers through emulatorLauncher.
   - The build's own GameCube / N64 / Dreamcast / C64 collections are untouched; ours are named "... (RetroBat)".
   - `--all` imports all 47 systems that have games.
   - `New-RetroFECollections.ps1` keeps `Main\am-extra-menu.txt` entries in the main menu.
   - Real titles, year, maker, genre and players come from RetroBat's `gamelist.xml` (`meta\hyperlist\<collection>.xml`), and meta.db is rebuilt. All 865 games in the 16 systems are titled.
2. Controller config pass-through to emulatorLauncher, and a panel-to-XInput bridge (ViGEm) for Xbox / PS2 / Wii U / GameCube.
3. Exit and the hot-plug / AmPanel game events for emulatorLauncher games (game start / stop, lights, stick maps).
4. xemu per-game compatibility and performance list on the pedestal and RACE1.
