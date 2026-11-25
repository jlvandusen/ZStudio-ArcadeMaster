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

## 1. Board and housekeeping (every tick, quick)
- Board: `beat`, `list`, then claim and do any job addressed to p1 or the pool.
- Open PRs: CI, review comments, conflicts.
- Delete merged branches and stale worktrees.

## 2. Game mechanics and controls
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
- [ ] Neo Geo and other games missing from controls.dat: add names for the most popular (Samurai Shodown, Fatal
      Fury, Garou, Blazing Star, Puzzle Bobble).
- [ ] Per-game "special controls" hints (trackball, spinner, dial, twin-stick): show them on more games, using
      MAME's `-listxml` control types.

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
- [ ] Boot time, next: Shuffle 1.7 s (now the largest), and Get-CabinetDevices on a cold start (1.3 s).
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
- [ ] Low-resolution backdrops: find them, then upscale them or pick a better still from the video.
- [ ] Attract mode: cycle game videos with the story line and controls card.
- [ ] Touch bar from `layout - 1` drawn on the main screen: find the root cause (displays are approved now).

## 5. Game stories
- [ ] Stories for the games that still lack one (2,474 written so far).
- [ ] Quality pass: no wrong years, makers or claims. Check against MAME's history and info data where it exists.
- [ ] Stories for merged-list (.sub) items and TeknoParrot and light-gun games.

## 6. Tooling
- [x] The E: refusal in the preview, marquee and theme tools comes from `tools/lib/am_guard.py`. It reads
      `AM_PROTECTED`, else `ProtectedPaths` in ArcadeMaster.config.json, else the whole E: drive. (2026-11-25)
- [ ] Self-test: add checks for the new tools (marquees, themes, library mover dry run).

## 7. Racing and flight cabinet (DESKTOP-RACE1 takes these first)
Mark an item `[RACE1]` or `[PEDESTAL]` when you start it, so the two cabinets never do the same one.
- [x] Performance: boot steps are timed in the launcher log; the title card is skipped when unchanged (PR 29).
      RACE1 boot prep 4.5 s, every step under 1 s.
- [ ] [RACE1] Performance: menu frame time with the live wheel, needles and moving backdrops on. Fix any drop below 60 fps.
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
