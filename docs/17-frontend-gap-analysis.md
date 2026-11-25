# 17. LaunchBox / Big Box, Batocera, RetroBat: what they do, and where ArcadeMaster matches or beats them

James, 2026-11-25: *"keep doing deep dive into the big 3 frontends and we need to mimic and exceed those functions"*. The big 3 are LaunchBox / Big Box, Batocera and RetroBat.

Versions read: LaunchBox 14.1 (2026-10-30), Batocera 44 "Malachite" (2026-11-17), RetroBat 8.4.0 (2026-11-21). Sources: feedback.launchbox-app.com/changelog, batocera.org/changelog, wiki.batocera.org, github.com/RetroBat-Official, wiki.retrobat.org, pluginapi.launchbox-app.com. The research brief and every source link are in the PR that added this file.

## Where ArcadeMaster already leads

| Area | The big 3 | ArcadeMaster |
|---|---|---|
| Game story / history.dat on screen | None of the three shows history.dat / command.dat | Story panel after 8 s on a game (New-GameStories: history.dat + 28 curated stories) |
| Button lights | LaunchBox: LEDBlinky (external); Batocera: LEDSpicer; RetroBat: undocumented | AmPanel: LEDBlinky's commands and files, plus reactive glow, audio-reactive and output-triggered lights, .lwax, a learn-the-buttons tool, per-game UltraStik maps and the ServoStik, all built in |
| Which controller for this game | Not asked anywhere | The themed "which controller will you use?" screen, from what is plugged in (hot-plug aware) |
| Hot-plug | Restart or rescan | Plug in a controller and the cabinet updates live, held during games |
| Racing / flight / gun cabinets | Generic | Wheel FFB, live wheel and pedal art, telemetry, bass shakers, cabinet modes that follow the hardware |
| Self-healing and updates | Manual | Health check and repair, 15-minute updates, RetroFE built and installed per cabinet, a job board between cabinets |
| Every RetroBat system and option | RetroBat only inside its own ES | The same emulatorLauncher (all per-game options, bezels, shaders, guns) behind our frontend: Classic Systems (docs/15) |
| Second screen / touch / Stream Deck | Big Box: premium marquee; Batocera: marquee + Pixelcade; RetroBat: none | Marquee + game header + touch buttons on screen 1, and the Stream Deck |
| Speed | LaunchBox: 30-40 s start and 2.3 GB RAM on big libraries | RetroFE at 60 fps (p99 17 ms, 0 scroll hitches measured), boot prep 1.8 s |

## Where we trail, ranked by what matters on a cabinet

| # | Feature | Who has it | ArcadeMaster today | Plan |
|---|---|---|---|---|
| 1 | Universal exit-to-frontend combo | Batocera / RetroBat: Hotkey + Start; LaunchBox: fragile | RetroFE's quitCombo; per-emulator keys | **AmPanel exit combo**: hold P1 Start + P1 Coin for 2 s and the running game closes cleanly (WM_CLOSE, then the process tree after 3 s), for every emulator. AmPanel already sees every key. |
| 2 | Pause menu over any game | Big Box (best): resume, manual, scores, achievements, save/load, disc swap | None | **AmPanel pause overlay**: a topmost screen on a hold combo showing resume, the controls card (move list), the story and the high score, plus save / load state by sending the emulator's own keys, and exit. |
| 3 | Kiosk lock with a button code | Batocera / RetroBat: UI modes + passkey; Big Box: PIN | Tools and Settings open to anyone | **Kiosk mode**: Tools / Settings hidden until a button code is entered on the panel; a kid mode with a whitelist. |
| 4 | High scores | LaunchBox 14.1 leaderboards; RetroAchievements in all three | hi2txt broken here (hi2txt_defaults.zip missing) | Fix hi2txt, then show the best scores on the game screen and in attract; RetroAchievements through RetroArch for Classic Systems. |
| 5 | Remote / web management | Batocera: web manager; others none | Pipe only, on the cabinet | **AmPanel web page** (HttpListener on the LAN): status, lights, sticks, settings, what is playing, from a phone. |
| 6 | Bezels per game | Batocera / RetroBat decorations | Arcade bezels exist; Classic Systems inherit RetroBat's | Turn on RetroBat's bezel option for Classic Systems; a bezel per arcade game where CoinOPS has one. |
| 7 | Light-gun auto-setup | Batocera deepest | Guns detected (AmPanel) | Classic Systems get RetroBat's gun support; TeknoParrot guns stay per profile. |
| 8 | Attract that plays demos | Nobody | RetroFE attract browses with videos | Later: let attract mode run a real game's demo for 60 s (MAME games only). |
| 9 | Netplay / achievements | Batocera / RetroBat | None | Through RetroArch settings in RetroBat (an account in es_settings); low priority on a cabinet. |
| 10 | CRT 15 kHz | Batocera | None | Not this cabinet (an LCD); note only. |

## Order of work

1. AmPanel universal exit combo (#1).
2. Kiosk lock with a panel button code (#3).
3. AmPanel pause overlay v1: resume, controls card, story, exit (#2). Save / load states come in v2, per emulator.
4. Fix hi2txt and show high scores (#4).
5. AmPanel web page (#5).
