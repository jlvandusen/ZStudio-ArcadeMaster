# 18. The way forward: ArcadeMaster becomes the host, RetroFE becomes the screen

James, 2026-11-25: *"are we at a point where we consume retrofe and become something more since we consumed ledblinky and ultimarc tools?"* Then: *"write that as the way forward and send to all 3 systems to build it out as a todo"*.

## The end state (James, 2026-11-25: "our stuff is here to replace all retrobat, batocera, launchbox and retrofe installs on that machine")

ArcadeMaster is the only frontend on a cabinet. Every other install is a source: we import its games, emulators, BIOS, media and good settings into ArcadeMaster's own tree, prove the games run from there, then retire the install.

- **On the pedestal (survey 2026-11-25):**
  - RetroBat twice (`R:\CP78\RetroBat` 7.3, `R:\RetroBat` 7.5);
  - CoinOPS LEGENDS 2 Bit Wars / 3 Vertical / 4 Collector, plus the TeknoParrot Collection;
  - CORE TYPE R;
  - Forgotten Worlds Legends MAX / REBORN PINBALL / ATARASHII Forgotten Universe / Gems / Max / Mini (some with 32-bit RetroFE);
  - Computer Classics Reloaded;
  - the live `E:\CoinOPS LEGENDS 4 Max` (stays untouched until James says so).
- **What changes in today's work:** Classic Systems currently call RetroBat's `emulatorLauncher.exe` in place. That's a bridge, not the target. The target is the emulators, BIOS and ROMs in ArcadeMaster's library, launched by the ArcadeMaster Host:
  - First, the Host calls emulatorLauncher from our own tree as an engine, like RetroArch.
  - Then our own per-emulator config writers replace it, one system at a time, using emulatorLauncher (open source) as the reference.
- **The existing library move does the importing.** `library-plan.json`, `Move-ToLibrary`, `Find-Duplicates` and games.json dedupe what is in all these packs, keeping the best copy of each game, emulator and media file.
- **Retiring an install needs James's go-ahead each time.** Delete only after its games launch from ArcadeMaster and the health check is clean, through nasctl when it is on the NAS.

## Where we stand

- **LEDBlinky and the Ultimarc tools are absorbed.** AmPanel does the lights, UltraStik maps, ServoStik, guns, animations, speech, triggers and button learning (docs/13).
- **RetroFE is already ours.** The ZStudio-retrofe fork plus `retrofe/patches` 0001-0016 are built on every cabinet by Update-Cabinet.
- **Logic has moved out of RetroFE.** The controller question, hot-plug, Esc-ends-any-game (ExitGuard), lights, sticks, Classic Systems through emulatorLauncher and auto-updates all live outside it.

## The plan (in order)

1. **The fork is "ArcadeMaster Frontend".** Give it a name and a version in the about screen, the log and the exe properties; keep it built from the patch set. This is cosmetic; no rewrite.
2. **RetroFE becomes the screen only.** It's very good at menus at 60 fps and the theme work rides on it, so rewriting it buys nothing now. Performance work stays in patches (docs/14).
3. **AmPanel grows into the ArcadeMaster Host.** It starts, tracks, pauses and ends every game:
   - **launch service:** RetroFE asks the host to launch (as it already asks "which controller?"), and the host owns the process tree;
   - **pause screen over any emulator:** resume, controls card, story, high score, save/load state through each emulator's own keys, exit (Big Box's best feature, docs/17 #2);
   - **kiosk lock with a panel button code**, and a kid mode (docs/17 #3);
   - **web page on the LAN** (status, lights, sticks, settings, what is playing) from a phone (docs/17 #5);
   - **high scores** (hi2txt fixed) on the game screen and in attract (docs/17 #4).
4. **Only then consider our own renderer.** Once the host does nearly everything, swapping the screen is a contained job, not a rewrite.

## Todo, by machine

Claim on the board before starting (`tools\Board.ps1 claim`); one PR per item; self-test before merge.

**ALL THREE: replace every other frontend install (the end state above)**
- [ ] Survey your cabinet's frontend installs (`tools\Survey-Frontends.ps1`) and post them on the board.
- [ ] Per install: what it has that ArcadeMaster lacks (games, emulators, BIOS, media, tuned configs), then import it into the library (library-plan / Move-ToLibrary), prove it launches from ArcadeMaster, and ask James to retire it.
- [ ] Classic Systems: move the RetroBat emulators, BIOS and ROMs into ArcadeMaster's library and point the launchers there; then own config writers per system, replacing emulatorLauncher.

**ARCADE-PEDESTAL (AmPanel, panel, classic systems)**
- [ ] Host step 1: the launch service. RetroFE's launcher runs `AmPanel.exe launch <collection> <item>`, and the host starts the game, keeps its process tree, runs ExitGuard and reports start / stop (replaces the LEDBlinky-hook guesswork).
- [ ] Pause screen v1: hold Esc 1 s (or a combo) to pause the emulator (suspend or its own pause key), then a themed overlay (ChooserScreen style) with resume, controls card, story and exit.
- [ ] Pause screen v2: save / load state per emulator (rules in exit-rules.json style: the key each emulator uses).
- [ ] Kiosk lock: Tools / Settings hidden until a panel button code; kid mode whitelist.
- [ ] Hands-on with James: the Buttons walk (64 LEDs), the Xbox panel map, the "which controller?" screen, Esc on RPCS3 / PCSX2 / Dolphin.
- [ ] Merge the emulator audit (docs/16) and act on its update list.

**DESKTOP-RACE1 (coordinator: RetroFE, catalog, themes)**
- [ ] Name and version "ArcadeMaster Frontend" in the fork, the patches and the build (step 1).
- [ ] Roadmap docs/14: vsync (item 1), picture cache limit (3), zero-copy video (2); a hitch log right after a reboot.
- [ ] Fix hi2txt (the defaults zip and scores folder are missing on the copies) and show high scores in the layouts.
- [ ] Bezels per game where CoinOPS has them; RetroBat's bezel option for Classic Systems.
- [ ] The web page's backend contract with the pedestal (one JSON API over AmPanel's pipe).

**DESKTOP-RACE2 (GPU, emulators, racing)**
- [ ] The GPU driver update, then re-test the emulators listed in docs/16 (Vulkan ones first: xemu, Cemu, Dolphin, PCSX2, RPCS3).
- [ ] exit-rules.json for the racing cabinet's emulators (TeknoParrot games, Model 2 / 3, Supermodel): press Esc in each and add a rule where it doesn't end cleanly.
- [ ] Classic Systems on RACE2 if it has RetroBat (`Import-RetroBatSystems.py` skips itself otherwise).
- [ ] The pause screen on a wheel cabinet: which wheel buttons open it, and the FFB release on pause.
