# ArcadeMaster backlog

This list keeps the autonomous loop busy so it never waits on James. Each tick takes the top open item in the
highest section that has one, does it, and ticks it off here in the same PR. Anything new found while working
gets added. Items that need James move to **Needs James** and are skipped, not waited on.

The loop works like this (James, 2026-11-25):

- **Branch and PR every change.** Run `tools/Test-ArcadeMaster.ps1 -Cabinet` (on a machine with a test frontend),
  then merge your own PR (`gh pr merge --merge`).
- **Try it on the R: copy** (`R:\ArcadeMaster\frontend\LEGENDS-am`), never on the live `E:\CoinOPS LEGENDS 4 Max`.
- **Driver and display changes are approved.** Write down what changed and how to undo it.
- **Measure first.** A performance or visuals change states its before and after numbers, or before and after
  pictures, in the PR.
- **No retro look.** Backgrounds come from each game's own art.
- **Edit this file with the Edit tool, not PowerShell `Get-Content`/`Set-Content`.** PowerShell 5.1 reads UTF-8
  without a BOM as ANSI and mangles every arrow and dash.

## 1. Board and housekeeping (every tick, quick)
- Board: `beat`, `list`, then claim and do any job addressed to p1 or the pool.
- Open PRs: CI, review comments, conflicts.
- Delete merged branches and stale worktrees.

## 1a. James 2026-11-27: installer + demo for Daniel Spies (YouTube) - "when this is ready to rock"
James: "we need to also create a installer when this is ready to rock, we need to then consolidate as much as
possible into our ampanel so I can demo it and send to Daniel Spies as he will be a great influencer to get the word
out about my company". James sends it himself; no session contacts anyone outside.
- [ ] **AmPanel is the one ArcadeMaster app:** tray, settings, lights, Panel Test, menu music, updates, search and the
      touch surface. The ArcadeMaster.exe launcher folds into it. The frontend (our fork) is its screen.
- [ ] **Installer for a fresh PC.** It ships the frontend, AmPanel, the tools and our layouts / own art. It finds the
      user's RetroBat, emulators and game folders, detects the cabinet type, then builds the menus, hero art and
      controls cards from the user's own files. **Never** ROMs, BIOS files, emulator builds or game art (GPL / community
      release, docs/21). GPL-3.0 source link and credits (RetroFE, CoinOPS) in About.
- [ ] **Demo kit:** the installer, a one-page "what it does", and a showcase checklist: hero main menu, the touch
      screen (panels, search, list touch), the attract light show, the loading card, menu music, the cabinet link.
- [ ] A clean-PC dry run (a spare PC or VM) before anything is sent.
- [ ] **First run: AmPanel meets a new PC** (James 2026-11-27: "introduce the ampanel to a new environment and have it
      discover everything and emulators etc set it up and configure"). Discover (read-only), report and choose, set up
      (asked, logged, safe to re-run), prove it (one test launch per system, self-heal), then keep discovering at boot.
      Never deletes or moves the user's files without a yes; never downloads ROMs, BIOS files or art.
- Progress 2026-11-27 (ARCADE-PEDESTAL):
  - `tools/Invoke-FirstRun.ps1` chains discovery, lists, direct launchers and panel keys, links, content and lights,
    then the check. It is a dry run by default.
  - AmPanel tray > **Set up this PC...** runs it: a check first, then "Set it up" after a yes.
  - Every standalone emulator gets the panel's keys (`Set-EmulatorPanelKeys.py`): PCSX2, xemu, Xenia, Dolphin GC,
    PPSSPP, Citra, Yuzu and Cemu.
  - 34 RetroArch consoles have bezels. Xenia's first-run disclaimer is pre-acknowledged.
  - Done later the same day:
    - lists for PCs without RetroBat (`New-ListsFromDiscovery.py`);
    - Wii Remote + Nunchuk on the panel;
    - Model 3 card and lights;
    - folder import (AmPanel tray > Import a folder...);
    - the release build and updater (`Build-Release.ps1`, `Update-Release.ps1`). Publishing is on hold until James
      says so ("keep collecting the updates before packaging").
  - **Still open:**
    - the clean-PC dry run (a PC or VM that has never had ArcadeMaster);
    - a test launch per system after import;
    - generalising the links past RetroBat (LaunchBox and bare folders link through Import a folder today).
- [ ] **First run links, then offers to move** (James 2026-11-27: "when it does a discovery of a new system first run
      it can then find all the stuff and do the same thing to each thus not effecting another frontend etc.. or give the
      user option to move it all if wanted"). After discovery, `tools/Move-OffRetroBat.py` (link mode) puts a folder
      link in the ArcadeMaster tree for every emulator, BIOS, saves and game folder found, whatever frontend owns it
      (RetroBat, LaunchBox, a bare folder); the other frontend keeps working. Generalise it past RetroBat
      (discovery.json as the source). A choice in the wizard: keep links, or move everything in (`--mode move`).
      Done on ARCADE-PEDESTAL 2026-11-27 for RetroBat: 20 links + 176 TeknoParrot games; R:\ArcadeMaster\STORAGE.md.
- [x] **Import: point at a folder and take it in** (2026-11-27: tools/Import-Folder.py + tray; the test launch is still open) (James 2026-11-27: "add ability to perform import of a new game or
      system etc as needed and point to a folder and consume the rom or emulators etc"). In AmPanel: pick a folder; it
      tells what it found (an emulator by its exe from the catalog, a system's games by folder name and extensions, a
      single game), links it (or moves it, if asked) into the tree, makes / updates the list and its direct launcher,
      runs the art, cards, lights and search index for it, and test-launches one game.
- [ ] **Combine the cabinets' storage** when James says so: each cabinet's `<manifest>\storage-map.json` lists every
      link and its real folder; `--mode move` (same drive) or a copy to one drive turns links into real folders.
- [ ] **No RetroBat requirement** (James 2026-11-27: "not require retrobat and use their default emulators, retrobat is
      just a frontend not the emulator"). An emulator catalog of our own (tools/emulators/*.json: exe names, version,
      command line per system, config files to write). Direct launchers per system; we write each emulator's config
      (panel mapping, full screen, exits) so nothing rewrites it. RetroBat's emulators folder is just one place to find
      exes. Order: RetroArch + cores; MAME / Supermodel / TeknoParrot; Dolphin, PCSX2, PPSSPP, Cemu, Ryujinx, xemu,
      xenia, Flycast, DuckStation; the rest as needed (RetroBat's launcher only as a fallback until a system moves).
      Controls cards then use each emulator's exact button order. First step: the read-only discovery and its report.

## 1b. James 2026-11-27: "a good start shippable version" - next: more themes
Shippable baseline (2026-11-27): our own frontend build (fork, retrofe/fork.txt), touch buttons / list / panels /
breadcrumbs, SEARCH as a theme button with system badges, the main-menu hero show (New-MenuHeroArt.py: backdrops,
cycling consoles with captions, 24-character show, dropping facts, logo strip, timeline), menu music (Tools > Menu
Music), content refresh on every cabinet after boot.
- [ ] **More themes** (James: "we will need more themes"). Variations of the main-menu hero show: several rotating
      backdrops per entry, different character entrances (drop in, pop up, from the left), colour / font sets. Theme
      engine work is RACE1's phase 4 (docs/21): agree the split there before building.
- [ ] More rave / NCS tracks for Menu Music (only 22 on the drive today).
- [x] Main menu: no dial, hero art, facts, music (PRs 283-294).

## 2. James 2026-11-26: systems menus, controls per system, self-heal
- [ ] **Maker and system menus look mind-blowing and stay fast.** Each maker gets a high-resolution picture
      (Nintendo, Sega, Sony, Microsoft ...) with its consoles rotating, plus specs and a timeline (e.g. Xbox, then
      Xbox 360). Each system gets its console picture and history. Measure the frame time and memory before and
      after; no stutter.
- [ ] **Controller card per system:** the original controller art (RELOAD theme `art/controls/<sys>.png`) plus
      the panel mapping (es_input bottom-row layout), shown as each game's `am_controls`.
- [ ] **Supermodel (Model 3) on the panel:** the shared P1 bindings are moved to the panel keys (LCtrl, LAlt,
      Space, Shift; coin only on 5), and Star Wars has trigger B1 / event B2. The old file is kept as
      `Supermodel.ini.am-bak-panel`. Still to do: confirm RetroBat's automatic controller setup doesn't overwrite
      this; set up the P2 keys; map the yoke to the UltraStik analog axes; find out why James saw poor picture
      quality at 4K.
      **On hold (James 2026-11-27: "lets table model3 games for right now").** State when it was parked:
      - Supermodel shows black in full screen until its window loses focus and gets it back (Alt+Tab). AmPanel now
        does that switch 3 s after the game window is up (LoadingScreen.ShowGame), but this is untested: a manual
        focus switch made the picture appear once, but it may also have been a slow load.
      - Its console opens in Windows Terminal, which RetroBat cannot hide. AmPanel minimises it. The real fix,
        Settings > System > For developers > Terminal = Windows Console Host, needs James's OK.
      - RetroBat es_settings: model3.videomode 1920x1080x32x60, model3.forcefullscreen 1,
        model3.disableautocontrollers 1 (backup `es_settings.cfg.am-bak-model3`). 4K was black in every mode.
      - Star Wars starts with the EVENT button (panel B2), not Start.
      - Ideas: RetroFE `minimizeOnFocusLoss` / `unloadSDL`, `-ss=2` supersampling at 1080, borderless instead of
        exclusive full screen.
- [ ] **[PEDESTAL, docs/21 phase 7] Panel reference data is downloaded, not copied from LEDBlinky** (James
      2026-11-27: "It should download reference data etc?"). Today panel-data is a copy of the LEDBlinky install
      (PR 234), so a cabinet without LEDBlinky, or a community install, gets nothing. Setup fetches it and refreshes
      it, and falls back to the LEDBlinky copy when that exists:
      - Ultimarc PacDrive / UltraStik drivers: downloaded from Ultimarc, never bundled;
      - each game's controls: controls.dat, plus MAME -listxml for players and buttons;
      - colours: our New-LedColorsAuto.py;
      - stick maps: New-StickMaps.py;
      - animations: AmPanel's built-in ones, with `.lwax` files only when LEDBlinky is installed.
      Pedestal check done 2026-11-27: panel-data works (game lights, attract, 2 UltraStiks).
- [x] Self-heal for incomplete ROM sets (tools/Repair-GameRoms.py, run by AmPanel after every game) - PR #236.

## 2a. James 2026-11-25: full settings like the race cabinet, and our own LED engine
- [ ] **[PEDESTAL] CONTROLS settings group** (the pedestal's counterpart of the race cab's wheel / FFB / pedal
      settings), in Tools > Cabinet Settings and as Tools items:
      - [x] PANEL TEST (Tools > 1 Panel Test, control-panel cabinets): 30 s, and every control pressed shows with its
            panel name from panel.json ("P1 BUTTON 1 - key LCONTROL") or its joystick axis / button. Saved to
            manifest\input-capture.txt. (2026-11-25)
      - LEARN THE PANEL: Import-LEDBlinkyPanel, or button capture on marquee-only cabinets.
      - STICK RESTRICTOR: ServoStik (found: D209:1700) set to auto per game (joyways), always 8-way or always 4-way.
      - ROLLERBALL / DIAL: separate mice (multimouse) and sensitivity.
      - BUTTON LIGHTS: brightness, colours on or off, attract animation on or off (LED engine below).
- [ ] **[PEDESTAL] LED engine: ArcadeMaster drives the panel lights itself.** Built from Ultimarc's published PacDrive
      SDK (PacDrive32.dll, 32-bit: run through Windows' 32-bit PowerShell) and LEDBlinky's documented files: Colors.ini
      (per-game colours), Color-RGB.ini, LEDBlinkyInputMap.xml (which LED pin is which button). We do NOT
      disassemble LEDBlinky.exe; its own files and Ultimarc's SDK give everything needed.
      - [x] Step 1: `Get-UltimarcBoards.ps1` lists the boards through the SDK. Read-only, writes manifest\ultimarc.json.
            Pedestal: 2 × I-PAC Ultimate I/O (D209:0410 / 0411, 96 LEDs each) + 1 ServoStik (D209:1700).
            The two Ultimate I/O boards are also 2 of the 3 "Ultimarc mice" (their trackball/spinner inputs).
      - **Now AmPanel (docs/13-panel-service.md, James 2026-11-25):** a tray service that accepts LEDBlinky's documented
        command line, talks to the frontend over \\.\pipe\ArcadeMaster.Panel, and drives LEDs + ServoStik (PacDrive32)
        and UltraStik maps (UltraStik32). Steps 1–8 are in that doc; the old steps below fold into them.
      - [x] AmPanel steps 1, 2, 5, 6, 7, 9, 10, 11a/b and the Settings engine switch (#54–#73).
      - **Gaps to 100% LEDBlinky (James asked 2026-11-25; honest list):**
        - [x] Play LEDBlinky's `.lwax` files: the `<file>.lwax` command loops one until `11`. AmPanel.json
              AttractAnimation can name one. Newer (LedHwType) and older (PACLED64) files work. Tested live 2026-11-25.
        - [x] `random` / `random.lwax` and the `lwa\GameSpecific` GameStart / GamePlay / GamePause folders, with
              AmPanel.json GameStartAnimation / GamePauseAnimation defaults. Game stop ends any game animation.
              Tested live 2026-11-25.
        - [ ] Still open: the `Cab*` folders (cabinet LEDs: none on this cabinet), the S/N options, the `*Audio` variants.
        - [x] Audio-reactive animation: `audio` (AudioLevel.cs, the Windows peak meter) is a VU meter in the game's
              colours. Cabinet Settings > ATTRACT LIGHTS picks chase / breathe / to the music. Tested live 2026-11-25.
        - [x] Audio "via triggers": the rule action `audio` makes a button group (`P1B*`) follow the music while an output
              is on, and `level` turns an analog output into brightness (`max`). The pipe `simulate` feeds a fake output
              through the rules. Tested live 2026-11-25.
        - [x] Command `14` (set LED ports by label, colour, board:port or number). Tested live 2026-11-25.
        - [x] Command `13` + automatic UltraStik map per game (Sticks.cs, New-StickMaps.py). Tested live on both sticks.
        - [x] `16`/`17`: dim the panel to 25% on pause. Tested live.
        - [x] Command `12` is accepted and recorded (status `ctrlr`). LEDBlinky uses it to translate MAME input codes;
              AmPanel lights by Colors.ini labels, so there is nothing to translate.
        - [x] Graphical stick screen: tray > Sticks & Guns (StickStudio.cs). It draws the 9x9 map, tries a map on the
              sticks, keeps a pick per game (stick-maps-cabinet.json), has ServoStik 4/8 buttons and the gun list.
              Picture: docs/img/ampanel-sticks.png.
        - [ ] Draw your own map in that window (click cells), saved as a new .um.
        - [x] Speech: "Now playing <real title>" at game start (Speech.cs; game-titles.json from history.dat).
              Cabinet Settings > ANNOUNCE THE GAME, off by default. Verified: speaker peak 0.00 -> 0.97 while it spoke.
        - [x] Pixelcade / LED marquee output (the 2-player cabinet used LEDBlinky only for that): AmPanel.json
              `"Marquee": "pixelcade"`, docs/13 step 13. Left: high scores on the marquee (`~hiscoretop3~`).
        - [ ] Other LED boards: LED-Wiz (ledwiz.dll), Howler (HowlerDLL.dll), GPWiz.
        - [x] Buttons window (tray, or pipe `buttons`): it lights each RGB group in turn, you press the lit button, and
              it saves `<manifest>\LEDBlinkyInputMap-learned.xml` (LEDBlinky's format). AmPanel prefers that file, so
              LEDBlinky's input-map wizard is no longer needed. Tested with real key presses 2026-11-25.
        - [ ] Someone at the cabinet: walk all 64 groups once. This also settles the P1/P2 vs P3/P4 board order.
      - **"Which controller will you use?" at game start** (James 2026-11-25):
        - [x] The data: tools/New-ControllerChoices.py -> `<manifest>\controller-choices.json`. It runs in the hot-plug
              refresh and Rebuild Menus, so it follows what is plugged in. Pedestal: 311 games have a choice (222
              trackball/joystick, 53 analog/8-way stick, 36 gun games trackball/mouse).
        - [x] AmPanel's side: ControllerChooser.cs, the `choose` pipe command (on its own thread) and
              `AmPanel.exe choose <item> [collection]`, which waits and prints the pick. Picks go to controller-picks.json,
              and the picked stick map wins over the game's own at game start. Picture: docs/img/ampanel-choose.png.
              Tested: no answer -> best fit after 8 s; a game with no choice answers in 274 ms.
        - [x] Polished and themed (James: "pretty up that screen ... based on the theme"): ChooserScreen.cs.
              - The game's backdrop (softened) and logo, the active layout's font and accent colours.
              - Drawn controller pictures, a gliding, breathing highlight, a countdown bar, a fade-in, the theme's sounds.
        - [ ] The fork's Launcher.cpp calls `AmPanel.exe choose` before starting the emulator. The design:
              - The ZStudio-retrofe fork's Launcher.cpp makes a blocking pipe call to AmPanel (`choose <game>`, 15 s cap)
                before the emulator starts, and only for games in the file.
              - AmPanel shows a full-screen, top-most chooser driven by the panel: stick left/right, button 1 picks.
              - The last pick per game is highlighted, and that pick is used after 8 s of no input.
              - It replies with the stick map and any extra emulator arguments (e.g. a MAME `-ctrlr`), then sets the map.
              - No question when only one choice is plugged in.
        - [ ] Flight sticks are not detected (cabinet.json flightStick false): needs the Watch-Inputs capture at the cabinet.
      - [ ] Step 2: an LED test in Tools. Light each button in turn and in each player's colour. Only while LEDBlinky is
            not running (they would fight over the boards).
      - [ ] Step 3: per-game colours on game select (Colors.ini + InputMap), from the RetroFE launcher hook that now
            calls LEDBlinky.exe with "9 <game> mame".
      - [ ] Step 4: reactive lights: a held button glows brighter (LEDBlinky cannot do this).
      - [ ] Step 5: attract animations (chase, breathe in the game's colours) while idle. Then LEDBlinky becomes optional.

## 2. Game mechanics and controls
- [ ] **[PEDESTAL] Two-stick and special-control games, deep dive** (James 2026-11-25). For each game: the card says
      what each stick, dial and button really does, and MAME maps it to the right physical control. MAME 0.196 port
      tags and types were dumped with an autoboot Lua script (headless):
      - Tank treads, triggers fire. Assault (:MCUB/:MCUH/:MCUDI0), Battlezone (:IN3), Vindicators (:260000; left
        trigger B1, left thumb B2, right trigger B3, right thumb B4) go on the two upper flight sticks. Assault's
        current cfg is the old owner's one-gamepad mix: replace it.
      - Move + fire / aim / attack: Robotron, Smash TV, Total Carnage (move/fire), Black Widow (move/aim), Karate
        Champ (move/attack), Front Line (left aims, right moves). P1 stick left, P2 stick right: default.cfg already
        maps this. The cards need the real roles from controls.dat instead of "Move / Fire".
      - Crazy Climber: P1 stick = left arm, P2 stick = right arm (works by default; the card must say so).
      - Tutankham is one stick plus Fire Left / Fire Right / Flash: not a twin-stick game. Drop it from the filter.
      - Omega Race: the dial rotates, B1 fire, B2 thrust. NOT IN THIS BUILD (no romset, no menu entry). Add it from
        another build when the library move reaches MAME.
      - Discs of Tron: 8-way triggerstick (B1 throw, B2 deflect) plus a push/pull dial (B3 aim up, B4 aim down). The
        card is fixed (#41: stick + DIAL, no false trackball). In MAME, the dial's 2 panel buttons should be aim up/down.
      - [x] Cards: roles per stick (#40); Discs of Tron (#41).
      - [x] MAME: `tools/mame-controls.json` + `Set-MameControls.ps1` (backs up `.am-bak`, `-Restore` undoes).
            Assault, Battlezone and Vindicators: left tread = P1 stick OR joystick 1, right tread = P2 stick OR
            joystick 2, fire = either trigger (key or joystick button). Applied on the R: copy; MAME loads them.
      - Mice: 3 Ultimarc devices (D209:0410, 0411, 0511), and MAME runs with `multimouse 0`, so all are one mouse
        (rolling the rollerball also turns the dial in Tempest). Map them separately with `multimouse 1` (rollerball =
        MOUSECODE_n for TRACKBALL_X/Y, dial = MOUSECODE_m for DIAL) once the capture shows which is which.
      - [ ] With James at the panel: run `Watch-Inputs.ps1` to confirm the flight sticks are joystick 1/2 (or which
            keys), then trim the OR lists to the real controls. Add Discs of Tron (dial buttons = aim up/down).
      - First, find which device the flight sticks are (`tools/Watch-Inputs.ps1`: move each control, see what it
        sends). Then write each game's cfg on the R: copy, backing up the old one.
- [ ] Learn buttons on cabinets where LEDBlinky only drives the marquee. Read the I-PAC/Ultimarc config if there
      is one, otherwise add a "press each button" capture tool in Tools that writes `panel.json`.
- [x] The dial's 2 buttons: the importer now starts from `tools/panels/<host>.json`. A device LEDBlinky doesn't
      light (the dial, the twin-stick roles) is kept and no longer wiped. (2026-11-25)
- [ ] The dial's keys: find what the 2 dial buttons send (button capture), then add them to `panels/ARCADE-PEDESTAL.json`.
- [x] Key clashes found by the importer (LFLIPPER/P1B4 = LSHIFT, SETUP/TEST = TAB) show in System Health, with
      the fix. (2026-11-25)
- [x] TeknoParrot profiles: the health check repairs paths from where the catalog found the game, and a generic
      folder (`Game\RingGame.exe`) no longer counts as the same game. XML-escaped paths (`Let&apos;s`) no longer look
      broken. 2,563 → 2,580 of 2,601 games can start. (2026-11-25)
- [ ] The 16 games still "moved": profiles want a different release than the copy found (GGXrd Revelator vs SIGN).
      Look for the right copy in the other builds, or point the profile at the release we have when TeknoParrot has
      a profile for it.
- [x] Cards: checked 20 classics (no play history on the cabinet). Three changes (2026-11-25):
      - controls.dat's real cabinet now beats MAME's list of every input (Centipede: rollerball game, not a stick;
        2 players taking turns; MK: 5 buttons).
      - Neo Geo names (Metal Slug, KOF 94–2002) come from `*/item` overrides.
      - Long labels shrink, then hyphenate, then abbreviate, before being cut short.
- [x] [PEDESTAL] Neo Geo names for 17 more games missing from controls.dat: Fatal Fury 2/Special/3, Real Bout 1/Special/2,
      Garou, Samurai Shodown 1–5 + V Special, Last Blade 1–2, Windjammers. (2026-11-25)
- [ ] More Neo Geo names when the layout is certain (Art of Fighting, Blazing Star, Shock Troopers, Pulstar…).
- [ ] Live panel card on the pedestal: ZStudio-retrofe#1 (merged 2026-11-25) adds `liveButton` / `liveHat`, so the
      controls card's buttons can light up while held, as RACE1's G29 card does. Needs a RetroFE build with patch 0007
      on the R: copy first. Then map the panel's keys from panel.json onto the card.
- [ ] Per-game "special controls" hints (trackball, spinner, dial, twin-stick): show them on more games, using
      MAME's `-listxml` control types.

## 3a. RetroFE: the pedestal builds it now (ZStudio fork, R:\repos\personal\ZStudio-retrofe-git)
- [x] Build toolchain on the pedestal: VS 2022 Build Tools + GStreamer 1.24.13; `retrofe\Build-RetroFE.ps1 -Source`
      (#56). Installed on the R: copy as `core\` (CoinOPS kept in `core.am-coinops\`).
- [x] Fork #3: LEDBlinky calls off the render thread (coalesced); perfLog logs `hitch N ms: logic/draw/present | item`.
- [x] Fork #4: meta.db schema migration. Under the new build, no game had metadata (missing iscoredId/iscoredType).
- [ ] Scroll hitches on a cold cache (116–359 ms on the first run): read the new `hitch` lines to see which phase
      and item, then fix that (image / video first load off the main thread).
      - 2026-11-25 warm cache, build 0001-0016, 60 scripted Down presses: 0 scroll hitches (max frame 17 ms). One
        46 ms hitch on entering a list: `logic 44.1 draw 0.1 present 1.6 | state 66 | item 000 Bit Wars` (loading).
        Still to do: the first run after a reboot (cold file cache), read its `hitch` lines the same way.
- [ ] Settings errors under the new build: 5 menus have no collection settings.conf (All Trackball, All Twin Stick,
      All Vector, Console Arcade - Retro Arcade PC, Main); hi2txt defaults zip / scores folder missing. TOS GRS "not
      found" is expected (this cabinet has a ServoStik).
- [x] Upstream check (2026-11-25, RACE1): our base caab32e IS the tip of CoinOPS's working branch `current`; nothing
      to pull. The 1,443 commits are the old `master` line. The fork's history is still unrelated (fresh import), so a
      future upstream change needs a one-time --allow-unrelated-histories merge.
- [ ] RetroFE roadmap (docs/14-retrofe-roadmap.md), items in order; each with perfLog before/after:
  - [x] [RACE1] 1. vsync measured: no gain (off and on both p50 16.67 ms, max 17.6 ms, 0 hitches, 24-29 % of a core). Stays off.
  - [ ] 5. Entering a list costs one 100-136 ms frame on RACE1: menu read 29-49 ms (12 sub-collections), page 6-14,
        wait for all picture decodes 60-64. Keep built collections, decode the next menu's first screen while its tile is
        highlighted, wait only for first-screen pictures. Then a page-switch line in the perf log (A4).
      - [x] [RACE1] More picture threads: RETROFE_THREADPOOL_SIZE = half the cores (3-8) at start. Racing entry 92 -> 84 ms.
      - [x] [RACE1] Tried one preparation pass on entry: no gain (150 / 90 ms vs 83 / 95), not shipped (docs/14 item 5).
  - [x] [RACE1] 3. Picture cache measured: no growth (GPU 665 -> 670 MB, RAM 442 -> 449 MB over 380 scroll steps; the
        cache is only on Main). Not needed unless a list layout turns useTextureCache on.
  - [ ] 4b. Load the next / previous 3 items' art when the list moves (cold-cache hitches of 116-359 ms).
  - [ ] 2. Video frames stay on the graphics card (D3D11 memory into SDL), dropping two copies per frame.
  - [ ] 9. Crash dumps to the NAS from the health check; meta.db in WAL mode.
- [x] [RACE1] One menu layout on every cabinet type (James 2026-11-25): catalog/menu-controls.json + Set-MenuControls at
      boot. RACE1 applied (9 additions, nothing removed). Pedestal / RACE2: check the boot log line "menu controls: ...".
- [x] [RACE1] Emulator versions (James 2026-11-25): System Health line + Tools > Emulator Updates (docs/08). RACE1 today:
      Supermodel 0.3a -> 0.4, Dolphin 5.0-12188 -> 2609, Cemu 1.x -> 2.6 ready; MAME 0.244 (0.289 exists, shown only).
- [ ] James: choose the emulator updates in Tools > Emulator Updates (try Mario Kart 8 after Cemu; the backup folder undoes it).
- [x] [RACE1] Tools > Menu Buttons: the one layout with this cabinet's own button names (lib/AmMenuButtons.ps1).
- [x] [RACE1] Fix: letter shortcuts (R random, Q quit ...) only without a control panel; a keyboard-wired panel sends
      letters for player 2, so R / Q there jumped to a random game / closed the frontend. Taken off on panel cabinets.
- [x] [RACE1] Correction: favourites are Options (9) / Share (8) on the G29; 10 / 11 are R3 / L3 (both work).
- [x] [RACE1] Hold PS 5 s to leave any game (tools/Watch-GameExit.ps1; a pad: Back + Start). James was stuck in OutRunners.
- [x] [RACE1] Share = credit, Options = start on the wheel in every emulator (tools/Set-CoinStartButtons.ps1; 105 files).
- [x] [RACE1] Test = Plus, Service = Minus on the wheel in every emulator (same tool; 54 files; 3 Raw Thrills games keep
      theirs because Plus / Minus are their volume / test-menu buttons).
- [x] [RACE1] EXIT on the main menu only gave an error: the frontend had been started from a remote session whose
      environment stops cmd running a batch file by bare name. Start-ArcadeMaster now clears that setting (PR 190).
- [ ] RACE2: run tools\Set-CoinStartButtons.ps1 -Apply there too (same wheel), then New-GameControlsArt.
- [ ] Show "Share = coin, Options = start, hold PS = exit" on the game launch screen / controls card.
- [ ] Menu force feedback on RACE1 did not open at start-up ("Resetting device"): RetroFE patch 0022 (retry in the menu, plus the cabinet link back command)
      is built and applies, waiting for an idle frontend to test; then compare menu force strength with RACE2.
- [ ] **RACE1 has no force feedback and no Options / dial Enter / PS button** since Logitech G HUB was uninstalled
      (2026-11-26; docs/06). Needs Logitech software installed again (James to choose G HUB or Logitech Gaming Software).
      Then: Start back on Options (Set-CoinStartButtons -Start 9 -OldStart 10 -OldCoin 8 -Apply), check hold-PS exit.
- [ ] Cabinet link (James 2026-11-26, docs/16): similar cabinets browse in unison; "join? 5 s" then the same game starts.
  - [x] [RACE1] Part 1, RetroFE patch 0017: events out (hello / select / launch), commands in (goto / open), 127.0.0.1
        only, off by default (linkEvents). Tested with a stand-in helper.
  - [x] [RACE1] Fix found on the way (patch 0017): menus skipped their first games on a racing rig (up + down both held
        for 250 ms after entering; "down wins"). Opposite directions cancel; Racing opens on 1 / 91.
  - [x] [RACE1] Fix: the updater built 16 patches under the 17-patch key (it read the key, then listed the patches a moment
        later while a git stash had taken the new patch out). It now builds from a frozen copy checked against the key,
        counts new patch files as work in progress, and throws a build away when its log shows fewer patches than the key.
  - [x] [RACE1] Part 2-3: tools\AmLink.ps1 - cabinets hear each other through files on the NAS share, follow only while
        idle (30 s) and only the same cabinet type, "joining in 5" card, any menu button cancels. On for RACE1 + RACE2
        (catalog/cabinet-link.json), switch in Cabinet Settings. Tested on RACE1 against a stand-in second rig.
  - [ ] RACE2: restart the frontend after pulling, then try it with RACE1 for real (two cabinets, never tested together).
  - [ ] RetroFE patch 0022: `back` command, so a follower can leave the menu it is in (built, waiting for a test).
  - [ ] End a joined game when the leader's game ends and nobody touched this cabinet (needs the in-game exit, A3).
  - [ ] Part 4: the idle rig's wheel turns with the leader's steering (spring centre in Control/Haptics), gentle.
  - [ ] Part 5: linked games start their two-cabinet version on both rigs.
- [ ] Ahead of Big Box / Batocera / RetroBat / CoinOPS (docs/14, James 2026-11-25), after vsync and the cache:
  - [ ] A1. Controllers set up at every game start for each emulator from what is plugged in (150 ms budget).
    - [x] [RACE1] Step 1, survive reboots / USB renumbering: Repair-EmulatorDevices keeps MAME, Cemu, Supermodel and
          Model 2 on the right device (id and JOY number) at boot and on plug / unplug, as TeknoParrot already was.
    - [x] [RACE1] Step 2 on RACE1: every config searched for the G29 / handbrake GUIDs. New: Assetto Corsa Competizione
          (controls.json instanceGuid) via catalog/controller-files.json. DiRT 4 / GRID use the product GUID (safe).
          RetroArch, PCSX2, Flycast are not installed on RACE1.
    - [ ] Step 2 on the pedestal: RetroArch (RetroBat systems) stores players by index; pin them with
          input_playerN_reserved_device + device_reservation_type = preferred, and check PCSX2 / Flycast there.
    - [ ] Step 3: run the same checks at game start (launcher hook), so a controller plugged in mid-session is right.
  - [ ] A4. Speed promises as self-test checks: boot, 60 fps with video, video start 150 ms, launch 1 s.
  - [ ] A3. In-game menu on a hotkey combo: pause, save / load state, controls card, exit.
  - [ ] A2. On-screen controller setup for an unknown controller (RetroFE page + hot-plug listener).
  - [ ] A10. Play time per game (Most played / Recently played) and save backups to the NAS, 5 versions.
  - [ ] A9. Hi-score tables on (engine already has iScored / QR).
  - [ ] A8. Attract mode (watched on RACE1 2026-11-25, docs/15 section 7): boots with EXIT selected; on Main it never
        moves; in a list it moves once or twice; the series tour leaves the list on the old series. Root cause: the list
        stays "scrolling forward" after attract's scroll. Debug Page::isMenuIdle after attract, then patch 0017 (tour +
        "Tools,EXIT" skip list + controls card follows). Quick one first: boot onto Racing instead of EXIT.
  - [ ] A5. Missing art and info from an open game database. A6. RetroAchievements. A7. Settings from a phone. A11. Menu music.

## 3. Performance
- [x] Boot time: prep 6.9 s → 4.3 s (`-PrepOnly`, warm). The intro card is redrawn only when its key changes; it was
      ~2 s every boot for the same picture. (2026-11-25)
- [x] Background shuffle: 1.7–1.9 s → 1.6 s, while it now reads every game's backdrop too. It uses .NET folder
      listings, a partial shuffle and hard links (the helper DLL is compiled once, cached in %LOCALAPPDATA%). Boot prep
      4.2 s. (2026-11-25)
- [x] Health check at boot 2.0 s → 0.4 s. The touch-screen step (a PowerShell of its own, 1.65 s) runs only when the
      touch hardware or controls.conf changed (`touch-key.txt`). The games summary (10 MB games.json, 1.7 s) is kept in
      `games-summary.txt`. Boot prep 6.9 s → **2.7 s** today. Also fixed: since #27 a comment had swallowed the
      TeknoParrot path check, which then errored on every profile. (2026-11-25)
- [x] Get-CabinetDevices 1.3–1.5 s → 0.3 s at boot. The DirectInput scan (1.1 s) is kept in
      `manifest\directinput-scan.txt`, keyed on every present USB/HID device, so plugging anything in or out forces a
      new scan. The display helper now uses the type cache. (2026-11-25)
- [x] Shuffle 1.7 s → 0.7 s at boot. Plain loops replace the Where-Object/ForEach-Object pipelines, HashSet/List
      replace array += and Sort-Object -Unique, each folder's art is read once, and the slots are listed once per menu.
      Tool tiles no longer reach Main's backgrounds. **Boot prep 1.8 s** (6.9 s this morning). (2026-11-25)
- [ ] Boot time, next: Repair-ArcadeHealth 0.6 s and Get-CabinetDevices 0.3 s are left; most of the rest is
      PowerShell itself.
- [x] `Test-ArcadeMaster.ps1 -Cabinet` runs the health check (`-NoFix`) and the panel learn (`--dry-run`) against
      this cabinet's frontend, and fails on any error. It refuses a protected live frontend. A planted bug was caught
      (2026-11-25).
- [ ] Menu scrolling: turn on the perf log, measure frame time on Main and Arcades, and find the heavy layers.
- [ ] Backdrops and marquees: no texture bigger than it is drawn. Downscale anything over 1920x1080 and check memory
      before and after.
- [ ] Preview videos: check bitrate against quality, and make the remaining stand-ins into real clips.
- [ ] Library move: the rest of TeknoParrot, then the other systems one at a time (`Move-ToLibrary.py`, dry run
      first). Then build the move for emulators and BIOS (the CP78 TeknoParrot emulator and the AM_TP_CP78
      launcher repoint).

## 4. Graphics
- [x] No generated "retro" scenes as menu backgrounds (arcade_retro_grid, arcade_starfield…). 40 menus used them. A
      menu with no fanart now shows its games' own backdrops, then racing / flight / light-gun games for those menus,
      then game art from the whole library, with one picture per game. (2026-11-25)
- [x] Theme picker shows the label ("Tile Wall"), not the folder name. (2026-11-25)
- [ ] Polish the five AM themes: spacing, text fitting long names, and a check at 1080p and 4K.
- [ ] Marquees: replace placeholders with real art wherever any build has it, and improve the placeholder design.
- [x] Low-resolution backdrops: `Find-LowResArt.py` (at Rebuild Game Menus) lists art under 1024 px wide or in
      portrait shape: 72 of 2,055, mostly TeknoParrot flyers at 300×500. The shuffle leaves them out whenever a menu
      has enough other art. (2026-11-25)
- [ ] For the games whose only art is low-res: take a 1080p still from their video (New-PreviewMedia's backdrop) or
      find better fanart in the other builds.
- [ ] Attract mode: cycle game videos with the story line and controls card.
- [ ] Touch bar from `layout - 1` drawn on the main screen: find the root cause (displays are approved now).

## 5. Game stories
- [ ] Stories for the 5 games that still lack one (acedvrw, doom2, 3 Pinball FX3 tables).
- [x] Quality pass, wrong matches (2026-11-25). A history.dat entry found by title, or a non-MAME id taken as a rom
      name, must now agree with the catalog's year (within 2) and title. 9 games had another game's history:
      Batman 2013 had Data East's 1990 trivia, and GRID had Midway's The Grid. Garbled UTF-8 ("PokkÃ©n") is repaired.
- [x] 28 hand-written stories in `tools/game-stories.json`, which New-GameStories.py prefers over every other source:
      Battle Pod, Batman, Ikaruga, Initial D 6, OutRun 2 SP, Let's Go Jungle… (2026-11-25)
- [ ] The other ~30 TeknoParrot games with only a one-line "A 2010 racing game…" story. Add them to
      `tools/game-stories.json` only where the facts are certain. Spider-Man 2017, Rampage 2020 and K.O. Drive need a
      source first.

## 6. Tooling
- [x] The E: refusal in the preview, marquee and theme tools comes from `tools/lib/am_guard.py`. It reads
      `AM_PROTECTED`, else `ProtectedPaths` in ArcadeMaster.config.json, else the whole E: drive. (2026-11-25)
- [x] Self-test `-Cabinet` also runs New-Marquees, New-GameStories (both `--dry-run`) and Set-MameControls (dry run).
      11 s in all. (2026-11-25)
- [ ] Self-test: Move-ToLibrary dry run against a small plan.

## 7. Racing and flight cabinet (DESKTOP-RACE1 takes these first)
Mark an item `[RACE1]` or `[PEDESTAL]` when you start it, so the two cabinets never do the same one.
- [x] Performance: boot steps are timed in the launcher log; the title card is skipped when unchanged (PR 29).
      RACE1 boot prep 4.5 s, every step under 1 s.
- [x] [RACE1] Performance: menu frame time with the live wheel, needles and moving backdrops on. Fix any drop below 60 fps.
      Still menu: a steady 60 fps. Scrolling the main menu stuttered (4-9 frames over 33 ms every 5 s, worst 113 ms):
      7 full-screen pictures were uploaded to the graphics card on every move. Main menu now keeps them
      (useTextureCache): 1 stutter on the first visit, then a clean 60 fps. How to measure: settings.conf
      "perfLog = 5" and "log = ERROR,WARNING,INFO", then read the [Perf] lines in log.txt.
- [x] [RACE1] Performance: game lists reloaded the backdrop at about 6 ms of main-thread time per move. Patch 0012
      converts each picture on the loader thread, so the main thread only uploads it: 5.8 -> 2.4 ms (JPEG),
      6.4 -> 1.8 ms (PNG), and 0 frames over 33 ms while scrolling even with the cache off. A size limit on the
      cache was dropped: cached textures are shared without a use count, so trimming them could crash the menu.
- [x] [RACE1] Performance: warm the main menu's cache at start - not needed: since patch 0012 a picture upload is ~2 ms,
      and with the main menu's cache switched off scrolling had 0 frames over 33 ms (measured 2026-11-25).
- [x] [RACE1] Graphics: the main menu's Exit page had no backdrop (plain black). EXIT is a main-menu entry, not a
      collection, so the shuffle never dealt it backdrops; now it gets the main menu's game-art pool like the others.
- [x] [RACE1] Performance: Build-Manifest / Rebuild Game Menus. Timed: the folder listing behind 'games that can't
      start' was most of it (3 s warm, up to ~9 s cold). It is now saved (manifest\dir-index.json) and reused while the
      game folders' first two levels are unchanged (24 h at most): catalog 9.4-15 s -> 3.8 s, results identical.
- [x] [RACE1] Graphics: more racing and flight styles (night city, snow rally, desert, F1 pit, carrier deck, aerobatics).
      Six new skins (racing: Snow Rally, Desert Raid, Night City, F1 Pit Lane; flight: Carrier Deck, Display Team): 11 racing
      + 7 flight styles now. Same slots and sizes as the others, so just as fast; installed by each cabinet's layout update.
- [x] [RACE1] Graphics: wheel pictures for the 4 wheels with none (G25, Driving Force GT, Driving Force Pro, MOMO).
      G25, Driving Force GT and MOMO now have pictures (Newegg product photos, rim crop). 34 of 35 wheels have one.
- [ ] Graphics: Driving Force Pro picture: only small photos with the pedals in frame were found (wheel ~150 px).
      Look for a bigger front view. The MOMO cut-out keeps a light edge along its base (small source photo).
- [x] [RACE1] Graphics: game launch screen with the game's own art full screen and that game's wheel and pedal controls.
      The game's fanart (dimmed, slow push-in), its logo and its controls card (with the live G29) for ~2.5 s while it loads.
- [x] [RACE1] Controls: check the wheel, pedals and paddles in every TeknoParrot racing profile (clutch L, brake M, gas R).
      New read-only tools\Test-WheelBindings.ps1. RACE1: 303 of 313 ok -> 313 of 313. Fixed (backups *.wheelmap-*.bak):
      WMMT5, ID4Exp and FNFSB2 had no steering, gas or brake bound; OutRun 2 SP DX (E:) had its brake on the gas pedal.
- [x] [RACE1] Controls: run Test-WheelBindings in the health check ("Wheel bindings in TeknoParrot games": OK with the
      count, or WARN naming the games). Skipped while no profile changed: health 2.5 s after a change, 0.8 s otherwise.
- [x] [RACE1] Force feedback reached the wheel in only 18 of 31 games with the FFB Arcade Plugin: 12 named an SDL id
      their own SDL2.dll never produces (the newer checksum id with SDL 2.0.22), Initial D Zero named an Xbox pad.
      New tools\Repair-FFBPluginDevice.ps1 asks each folder's own SDL2.dll for the wheel's id: 31 of 31 now (backups
      *.am-ffbdevice-*.bak). RACE2 has the same E: games: run it there too.
- [x] [RACE1] WheelMap's FFBPlugin generator wrote one id into every config (it would have re-broken the 13 fixed
      games). It now picks the id per folder from that folder's SDL2.dll version (CRC-16 of the device name for SDL 2.26+).
      It also found MAME's plugin (E:\DRIVE Collection\emulators\MAME) with the same wrong id: fixed, 34 of 34 now.
- [ ] Controls: per-game wheel force settings (strength, spring) kept in the repo and applied when the game starts.
      Today: MinForce 0 everywhere, MaxForce 100 in most, 90 / 75 / 45 in a few.
- [x] [RACE1] Controls: flight games. Check the stick and throttle bindings and list any game that has none.
      All 3 (After Burner Climax, MachStorm, Star Wars Battle Pod) had NOTHING bound on RACE1 (no flight stick). Now flown
      with the G29 (tools\Set-FlightOnWheel.ps1: wheel, paddles = nose up / down, pedals = throttle / air brake).
- [x] [RACE1] Controls: set up the "ready to set up" games from games-cant-start.txt - none left (2026-11-25); the rest need their program files.
- [ ] Stories: every racing and flight game has a story line (year, maker, cabinet, what makes it special).
      [RACE1] 2026-11-25: 73 of 106 racing/flight games had a one-line or no story -> 31 (stories tool run for every
      list + 15 hand-written: Initial D 4/5/7/8/Zero, Wangan Midnight 5, Battle Gear 4, GTI Club 3, After Burner Climax,
      Wreckfest, Burnout Paradise, Project CARS, V-Rally 4, NASCAR Heat 5, American Truck Simulator). Left: MAME racers
      (art folder is a link onto E:, which the stories tool won't write into), Model 3 clones, GameCube, Sega Racing Classic.
      [RACE1] then 31 -> 19: an EMPTY menu.txt (CoinOPS leftover) made the stories and controls-card tools skip MAME and
      GameCube entirely; fixed, + 12 hand-written (Out Run, Virtua Racing, OutRunners, Cruis'n USA/World, Off Road
      Challenge, California Speed, Rush The Rock / 2049, F-Zero GX, Double Dash, Auto Modellista). Correction: the Model 3
      regional versions are hidden by Sega Model 3\exclude.txt and never shown, so the real count of visible racing/flight
      games with a one-line story is 7: Road Fighters 3D, Gaelco Championship Tuning Race, K.O. Drive, Sega Racing Classic,
      Valve Limit R, MachStorm, Cars. (A 'use the parent's story' rule was tried and dropped: by name prefix it pairs
      different TeknoParrot games, e.g. Dead Heat / Dead Heat Riders.)
- [x] [RACE1] Menus: group racing by series (Daytona, Sega Rally, Initial D, Wangan...), keeping every variant.
      catalog\series.json + tools\New-SeriesPlaylists.ps1: 13 series playlists in Racing; wheel button 3 / P next, 2 / O back.
- [x] [RACE1] Bass shakers: sound-driven shaker path for the games without telemetry, ready to switch on (docs/12).
      tools\tactile\Set-ShakerAudio.ps1 (check / -Apply / -Off, dry-run safe) through the VoiceMeeter already installed.
- [x] [RACE1] Bass shakers: a Tactile On-Off switch and strength setting in Tools, plus a health check line.
      Tools > 5a Bass Shakers On-Off (strength: -Choice strength:NN, kept in tactile.json); health 'Bass shakers' starts
      VoiceMeeter again when the shakers are on and it isn't running (otherwise no game sound), warns on an unplugged card.
- [x] [RACE1] Bass shakers: telemetry on in every PC racing game that has it, beyond the 6 Codemasters games.
      Checked 2026-11-25: every racer whose telemetry is a settings FILE has it on (the 6 Codemasters games). The rest are
      switched inside the game or by SimHub: DiRT 5 and Project CARS (in-game option), American Truck Simulator (SimHub's
      plugin). Wreckfest, Burnout Paradise, V-Rally 4, NASCAR Heat 5 have none - they use the sound-driven shakers.
- [x] [RACE1] Reliability: the health check notices a game whose last start crashed and says why in plain words.
      System Health 'Games that crashed': Windows' Application Error log, last 24 h (-CrashHours), games / emulators / RetroFE by title.

- [x] [RACE1] Daytona Championship USA single and linked versions: clear names, the full Daytona video and art, and
      stories saying which to pick; Crazy Taxi 3 plays the game's own Glitter Oasis movie (catalog/art-aliases.json).
- [x] [RACE1] Video: racing games without a preview 21 -> 11. tools\New-GameClips.ps1 makes menu videos from the games' own
      attract / intro movies (Bink, CRI USM, WMV, MP4; art-aliases.json 'clips'), e.g. Initial D 7/8/Zero/The Arcade from
      their ADVERTISE folders. Left: ATS, Burnout Paradise, Wreckfest, Battle Gear 4, Gaelco Tuning Race, GRID (TP), ID4, ID5,
      K.O. Drive, Sega Racing Classic, Valve Limit R (no movies in their folders).
- [x] [RACE1] Generated lists (AM_PC, AM_TP_*) lost their preview videos, backdrops and controls cards at every boot;
      every am_* art folder is now kept through the rebuild (was: stories only).
- [x] [RACE1] Stories: AM_PC and AM_TP_* lists are rebuilt at every boot, which emptied their am_story folders. The
      menu tool now sets the stories aside and puts them back: 26 of 26 kept over two rebuilds (before: 0 after one).
- [x] [RACE1] Wheel on the game list's controls card followed the handbrake, not the G29: 26 live elements had no
      liveDevice, so RetroFE used the first controller it opened (the handbrake on RACE1). All now say liveDevice="wheel".
- [x] [RACE1] Wheel pictures sat ~23 degrees left: held by the centring spring the G29 rests at raw -1658, not 0.
      RetroFE patch 0013 measures steering from where the wheel rests (steady 2 s, near the middle). James spotted it.
- [x] [RACE1] Board: two jobs with the same title posted in the same second got the same id and the second replaced
      the first (it happened with one job per cabinet). Board.ps1 post now adds -2, -3 and creates the file only if new.

- [x] [RACE1] Main's game-list layout installed on RACE1 (story panel, light preview videos). Portable ffmpeg 7.1 in
      D:\ArcadeMaster\_tools\ffmpeg (James ok); New-PreviewMedia made 110 previews (10.97 GB -> 1.69 GB) + 110 backdrops.

- [x] [RACE1] Self-healing: Update-Cabinet checks the installed retrofe.exe is the build am-build.txt names (hash) and puts
      the right one back when RetroFE is closed (the odd exe kept as retrofe.exe.am-stray-<time>). Tested with a planted exe.
- [x] [RACE1] Health: 'Game preview videos' - per menu, games with a preview (RACE1: Racing 92/103, Flight 1/3); WARN when a
      menu has none at all. It found Flight 0/3: After Burner Climax now plays its own attract movie (.sfd, silent - ffmpeg can't
      read its ADX audio; New-GameClips retries without sound). MachStorm and Star Wars Battle Pod pack their movies in archives.
- [x] [RACE1] Tools: bass-shaker strength in the menu - Cabinet Settings > MENUS: BASS SHAKERS (on / off) and BASS SHAKER
      STRENGTH (100 / 70 / 50 / 30 %, kept in tactile.json, applied at once when the shakers are on).
- [ ] Self-test: fails 8 of 9 now and then, only right after heavy work (video encoding, menu rebuilds; twice on 2026-11-25),
      never when idle (8 of 8 runs). Probably a timing-based watchdog check under load. Capture the FAIL lines next time
      (RACE1's merge step now stops and keeps them) and give that check more time.
- [ ] Self-healing: Update-Cabinet removes old RetroFE builds from its build folder (keeps the installed one and the one
      before); each is ~435 MB and every patch change adds one (RACE1: 3 builds, 1.3 GB on 2026-11-25).
- [x] [RACE1] Game feature: favourites, as CoinOPS does them. The wheel's Options button marks / unmarks the selected
      game, Share jumps to the Favourites list, and Favourites is second in the P cycle (skipped while empty). Set by
      New-SeriesPlaylists (Rebuild Game Menus). Tested live: marked Auto Modellista, unmarked it again (2026-11-25).
- [x] [RACE1] Fix: rebuilding the menus deleted Racing's whole folder, playlists included, so favourites, last played,
      the series and Most played were lost at every rebuild. New-RetroFECollections now keeps each generated menu's
      playlists\ and puts them back (a list the rebuild made wins). Tested live: 15 lists and a favourite kept.
      Start-ArcadeMaster makes the series playlists + favourite buttons again when the tool or series.json changed.
- Play Batman, Caladrius AC and Dead or Alive 5 from `R:\ArcadeMaster\library\roms\teknoparrot\`.
- Delete the empty `R:\_libtest` by hand (the tool refuses deletes at a drive root).
- Touch-screen patch 0006 test at the cabinet.
- Azure sign-in (device code) at a browser.
- GitHub builds of RetroFE: this PC's gh sign-in lacks the 'workflow' permission, so the workflow can't be pushed. On
  RACE1 run `gh auth refresh -h github.com -s workflow` (opens a browser / device code), then a session moves
  tools\ci\build-retrofe.yml to .github\workflows\ and merges it. Until then cabinets compile RetroFE themselves.
- RACE1: drive Daytona Championship USA (Linked Cabinets): its steering is bound "X -" where the single version has
  "X +"; check it does not steer backwards. Also try Wangan Midnight 5, Initial D 4 Export and OutRun 2 SP DX (bindings fixed).
- RACE1: drive a few force-feedback games (Batman, Daytona 3, Initial D Zero, Wangan Midnight 6R, OutRun 2 SP DX):
  the wheel should now push back. Before today 13 of them sent their force to nothing.
- RACE1: turn the G29 during a short menu test run, so the wheel picture problem can be measured.
- RACE1: try the flight games (After Burner Climax, MachStorm, Star Wars Battle Pod) with the wheel: do the paddles
  feel right for nose up / down?
- RACE1: in DiRT 5 and Project CARS, switch on the game's own telemetry option (UDP / shared memory) once SimHub is in.
- RACE1: install SimHub (D:\ArcadeMaster\installers\SimHubSetup_9.13.5.exe, accept the admin prompt).
- RACE1: plug in the USB sound card for the bass shakers, then run tools\tactile\Set-ShakerAudio.ps1 -Apply (or tell RACE1's session).
- RACE1: test the live wheel, needles, gear lights, moving backdrops and D-pad menu at the cabinet; merge PR #3.

## Done
- 2026-11-25: PRs #17–#23 merged (LEDBlinky panel, button names, marquees, five themes, all settings with a 15 s
  theme undo, no retro look, library mover). Launcher rebuilt and installed.
