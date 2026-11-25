# ArcadeMaster backlog

This list keeps the autonomous loop busy so it never waits on James. Each tick takes the top open item in the
highest section that has one, does it, and ticks it off here in the same PR. Anything new found while working
gets added. Items that need James move to **Needs James** and are skipped, not waited on.

The loop works like this (James, 2026-11-25):

- **Branch and PR every change.** Run `tools/Test-ArcadeMaster.ps1`, then merge your own PR (`gh pr merge --merge`).
- **Try it on the R: copy** (`R:\ArcadeMaster\frontend\LEGENDS-am`), never on the live `E:\CoinOPS LEGENDS 4 Max`.
- **Driver and display changes are approved.** Write down what changed and how to undo it.
- **Measure first.** A performance or visuals change states its before and after numbers, or before and after
  pictures, in the PR.
- **No retro look.** Backgrounds come from each game's own art.

## 1. Board and housekeeping (every tick, quick)
- Board: `beat`, `list`, then claim and do any job addressed to p1 or the pool.
- Open PRs: CI, review comments, conflicts.
- Delete merged branches and stale worktrees.

## 2. Game mechanics and controls
- [ ] Learn buttons on cabinets where LEDBlinky only drives the marquee. Read the I-PAC/Ultimarc config if there
      is one, otherwise add a "press each button" capture tool in Tools that writes `panel.json`.
- [ ] Map the dial's 2 buttons, which are missing from the LEDBlinky input map. Let `panel-controls-overrides.json`
      add devices.
- [ ] Key clashes found by the importer (LFLIPPER/P1B4 = LSHIFT, SETUP/TEST = TAB): report them in System Health
      and suggest a fix.
- [ ] Cards: check that the 20 most-played games show the right button names and LEDBlinky colours, and fix the
      overrides where they don't.
- [ ] Per-game "special controls" hints (trackball, spinner, dial, twin-stick): show them on more games, using
      MAME's `-listxml` control types.

## 3. Performance
- [ ] Boot time: time each step from launcher start to the first menu (boot log), and cut the slowest step.
- [ ] Menu scrolling: turn on the perf log, measure frame time on Main and Arcades, and find the heavy layers.
- [ ] Backdrops and marquees: no texture bigger than it is drawn. Downscale anything over 1920x1080 and check memory
      before and after.
- [ ] Preview videos: check bitrate against quality, and make the remaining stand-ins into real clips.
- [ ] Library move: the rest of TeknoParrot, then the other systems one at a time (`Move-ToLibrary.py`, dry run
      first). Then build the move for emulators and BIOS (the CP78 TeknoParrot emulator and the AM_TP_CP78
      launcher repoint).

## 4. Graphics
- [ ] Theme picker shows the label ("Tile Wall"), not the folder name.
- [ ] Polish the five AM themes: spacing, text fitting long names, and a check at 1080p and 4K.
- [ ] Marquees: replace placeholders with real art wherever any build has it, and improve the placeholder design.
- [ ] Low-resolution backdrops: find them, then upscale them or pick a better still from the video.
- [ ] Attract mode: cycle game videos with the story line and controls card.
- [ ] Touch bar from `layout - 1` drawn on the main screen: find the root cause (displays are approved now).

## 5. Game stories
- [ ] Stories for the games that still lack one (2,474 written so far).
- [ ] Quality pass: no wrong years, makers or claims. Check against MAME's history and info data where it exists.
- [ ] Stories for merged-list (.sub) items and TeknoParrot and light-gun games.

## 6. Tooling
- [ ] The E: refusal in the preview and marquee tools should come from the cabinet's live-frontend setting, not a
      hard-coded drive.
- [ ] Self-test: add checks for the new tools (marquees, themes, library mover dry run).

## 7. Racing and flight cabinet (DESKTOP-RACE1 takes these first)
Mark an item `[RACE1]` or `[PEDESTAL]` when you start it, so the two cabinets never do the same one.
- [ ] Performance: time each boot step on RACE1 into the launcher log, and cut the slowest step to under 1 s.
- [ ] Performance: menu frame time with the live wheel, needles and moving backdrops on. Fix any drop below 60 fps.
- [ ] Performance: Build-Manifest / Rebuild Game Menus. Time each part and remove the repeated scans.
- [ ] Graphics: more racing and flight styles (night city, snow rally, desert, F1 pit, carrier deck, aerobatics).
- [ ] Graphics: wheel pictures for the 4 wheels with none (G25, Driving Force GT, Driving Force Pro, MOMO).
- [ ] Graphics: game launch screen with the game's own art full screen and that game's wheel and pedal controls.
- [ ] Controls: check the wheel, pedals and paddles in every TeknoParrot racing profile (clutch L, brake M, gas R).
- [ ] Controls: per-game wheel force settings (strength, spring) kept in the repo and applied when the game starts.
- [ ] Controls: flight games. Check the stick and throttle bindings and list any game that has none.
- [ ] Controls: set up the "ready to set up" games from games-cant-start.txt with Add-TPGame (dry run first).
- [ ] Stories: every racing and flight game has a story line (year, maker, cabinet, what makes it special).
- [ ] Menus: group racing by series (Daytona, Sega Rally, Initial D, Wangan...), keeping every variant.
- [ ] Bass shakers: sound-driven shaker path for the games without telemetry, ready to switch on (docs/12).
- [ ] Bass shakers: a Tactile On-Off switch and strength setting in Tools, plus a health check line.
- [ ] Bass shakers: telemetry on in every PC racing game that has it, beyond the 6 Codemasters games.
- [ ] Reliability: the health check notices a game whose last start crashed and says why in plain words.

## Needs James (skip, never wait)
- Play Batman, Caladrius AC and Dead or Alive 5 from `R:\ArcadeMaster\library\roms\teknoparrot\`.
- Delete the empty `R:\_libtest` by hand (the tool refuses deletes at a drive root).
- Touch-screen patch 0006 test at the cabinet.
- Azure sign-in (device code) at a browser.
- RACE1: install SimHub (D:\ArcadeMaster\installers\SimHubSetup_9.13.5.exe, accept the admin prompt).
- RACE1: plug in the USB sound card for the bass shakers.
- RACE1: test the live wheel, needles, gear lights, moving backdrops and D-pad menu at the cabinet; merge PR #3.

## Done
- 2026-11-25: PRs #17–#23 merged (LEDBlinky panel, button names, marquees, five themes, all settings with a 15 s
  theme undo, no retro look, library mover). Launcher rebuilt and installed.
