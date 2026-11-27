# 21. The ArcadeMaster frontend: our own, from RetroFE's code, with AmPanel inside

James, 2026-11-27: "I want to barrow retrofe code ... replicate and improve upon it adding no limitations and
navigational capabilities, rendering ... incredibly immersive easy to use frontend themes with unlimited
capabilities. The 2nd screen touch controls was awesome, need to think more along those lines." He also said "it will
be a common system that auto detects the cabinet" and "I want to use common code across all my cabinet types".

This plan takes over from [18-way-forward](18-way-forward.md), where RetroFE stays the screen and ArcadeMaster is
the host. Here the frontend itself becomes ours.

## Decisions

| | |
|---|---|
| **Base** | `jlvandusen/ZStudio-retrofe`: CoinOPS RetroFE at `caab32e6` plus all our patches 0001-0029 (synced 2026-11-27). From here on, frontend changes are commits in that repo, not new `retrofe/patches/*.patch` files. |
| **Licence** | GPL-3.0, inherited from RetroFE. James, 2026-11-27: "I hope to take donations for the effort but share with community". That fits the GPL. The frontend and AmPanel are public and open source, with a donation link, and RetroFE and CoinOPS are credited. A community release ships our code, tools, layouts and our own art only. ROMs, BIOS files, emulator builds and game artwork (logos, videos, box art) stay out: the installer points at the user's own files and fetches art from the user's own sources. |
| **AmPanel** | Merges into the frontend as modules: lights, sticks, ServoStik, Stream Deck, self-heal, search, the loading screen, focus and game hand-off, Recently Played. Until a module has moved, AmPanel keeps running beside the frontend. |
| **One codebase** | Every cabinet (pedestal 4P, RACE1 racing/flight, the 2P stand-up, anything new) runs the same build. The cabinet is found at start from its devices (`tools/Get-CabinetDevices.ps1` builds `manifest\cabinet.json` and `tools/lib/CabinetTypes.ps1` turns that into a type), and the type picks the controls, theme variant, touch surface and tools. No per-cabinet forks. |

## Phases

1. **Own the build (now).**
   - Sync the fork with every patch, then build the cabinets straight from it (`Build-RetroFE.ps1 -Source`).
   - `Update-Cabinet.ps1` follows the fork's `main` instead of the patch fingerprint.
   - Nothing visible changes.
2. **The game hand-off moves inside.**
   - Launching, then bringing the game forward and minimising the frontend (today `LoadingScreen.ShowGame` in AmPanel), the loading card and the return to the menu, all in the frontend.
   - Emulator consoles are hidden properly.
   - Self-heal runs after each game.
   - This removes the black-screen and behind-the-frontend class of bugs at the source.
   - **Started (RACE2, 2026-11-27):** ZStudio-retrofe PR 8, `Execute/GameHandOff.cpp`, is on with `gameHandOff = true`
     in settings.conf. It keeps the game on the main screen, brings it forward, and minimises the frontend with the
     touch-screen focus round trip (Supermodel). It also minimises emulator consoles in Windows Terminal and reads
     rectangles DPI aware. AmPanel steps aside when it's on, and the frontend comes back after the game. Tested on
     RACE2 with Arctic Thunder.
     - To test a build without the updater putting the official one back: `<retrofe>\am-test-build.txt` keeps a
       hand-copied exe for 4 h.
     - **Self-heal after each game moved (2026-11-27):** with `gameHandOff = true`, the frontend's own end hook
       (`Record-GamePlay.ps1`) starts `Repair-GameRoms.py`, detached and with the game's launcher as the emulator, and
       AmPanel leaves it alone.
     - Still to move in: the loading card, and consoles started hidden from the start.
3. **Cabinet profile at start.**
   - The frontend reads the detected cabinet type and capabilities.
   - Controls, the touch layout and the tools follow from it.
   - One settings tree with per-type overrides.
4. **Theme engine with no ceiling.**
   - Scenes made of any number of layers (video, image, text, list, shader, particles) with timelines and easing.
   - Data binding to any game or system field, and hot reload while designing.
   - Both screens designed in one theme.
   - Today's layouts keep working through a converter.
   - The menu stays ready in under 1 s (measured before and after, as the backlog asks).
5. **Navigation.**
   - Grid, carousel and wall views; jumping by letter, maker or system.
   - Search built into the frontend; "more like this".
   - Every view drivable by panel, pad, touch or keyboard.
6. **The touch surface** (built on the second screen James liked).
   - In the menus: a companion to the main screen with details, the controls card, a video scrubber, search, filters, favourites and settings.
   - In a game: coin, start, service, pause, save state and quit for that game.
   - In attract mode: the marquee, high scores and "now playing".
7. **AmPanel retires.** Its last modules (lights, sticks, ServoStik, Stream Deck) move in, and the LEDBlinky shim goes.

## Working rules

- **Branch and PR every change in ZStudio-retrofe.** Build on the pedestal with `Build-RetroFE.ps1 -Source <fork>
  -Work R:\ArcadeMaster\build\fork-work`, which needs `-Work` because the pedestal has no D: drive. Try it on the R:
  copy, never on the live `E:\CoinOPS LEGENDS 4 Max`.
- **RACE1 and the 2P cabinet build the same fork.** A change for one cabinet type sits behind that type, never in
  a separate branch.
