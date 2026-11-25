# 15. Feature by feature: Big Box, Batocera / RetroBat, CoinOPS, and how we beat each

> **Merged into [docs/19-rivals-master.md](19-rivals-master.md)** (2026-11-25): one numbered list (R1-R26) with owners and status. This file keeps its detail; plan and claim from docs/16.

Read from their own pages on 2026-11-25 (launchbox-app.com premium / windows pages; wiki.batocera.org: basic_commands,
configure_a_controller, emulators:wheel_games, emulators:lightgun_games, decoration, emulationstation_savestates,
retroachievements_settings, netplay, es-webserver, ledspicer; coinops.pages.dev, the whole page). docs/14 has the
summary table and the plan numbers (A1-A11); this is the detail to build from. "Ours" is what the cabinets do today.

## 1. Buttons while a game is running
| | |
|---|---|
| **Batocera** | HOTKEY (Select or Home) + START exit; + South emulator menu; + East Control Center; + West save state; + North load state; + D-pad up / down change slot; + left / right rewind / fast forward; + L1 screenshot; + R3 overlay. |
| **Big Box** | "Hold Select+Start" (controller automation, paid): exit; pause screen. |
| **CoinOPS** | Back + Start quit game; L + R thumb in-game options; MAME's own TAB menu. Quit the frontend can be locked to the keyboard so players can't leave the cabinet. |
| **Ours** | Exit combo in the boot launcher; JoyToKey. |
| **Plan (A3, pedestal)** | One map for every emulator: hold **PS 1 s** = pause menu; PS + Options = exit; PS + right / left paddle = save / load state; PS + D-pad up / down = slot. A wheel has no Select, so the PS button is our HOTKEY. **Beat them:** the same buttons work in TeknoParrot and PC games (send each game's own key), not only in RetroArch cores. |

## 2. Pause / in-game menu
| | |
|---|---|
| **Big Box** | "PAUSED": Resume, Save State, Load State, Exit Game (paid). |
| **Batocera** | Control Center + the emulator's own menu (RetroArch quick menu). |
| **Ours** | none. |
| **Plan (A3)** | Resume, Save / Load (with the slot's picture where the emulator gives one), **the controls card we already draw for the game**, force strength (100 / 70 / 50 / 30), shakers on / off, Exit. Opens in under 200 ms, no focus theft (games that crash on focus loss are listed and get an overlay window instead). |

## 3. Controllers set up by themselves
| | |
|---|---|
| **Batocera** | Built-in pad database; an unknown pad opens a setup screen on connect; neutral read at first sight; face buttons by position (North/East/South/West); arcade layouts: 4 diamond buttons, then L1 / R1. |
| **Big Box** | Emulator setup "maps controller" (RetroArch); no per-game wheel logic. |
| **CoinOPS** | Fixed maps for Xbox pads and encoders (iPac, Zero Delay, Xin-Mo, Pacto); "Controls Locked" stops players remapping MAME by accident. |
| **Ours** | WheelMap writes every emulator from one captured profile; at boot and on plug / unplug TeknoParrot, MAME, Model 2, Model 3, Cemu, Dolphin and the FFB plugin follow renumbered devices (PR 132). |
| **Plan** | A1 step 2 (RetroArch, PCSX2, Flycast, PC games), step 3 (check at game start). A2 (pedestal): on-screen setup for an unknown controller. **Beat them:** a lock like CoinOPS's (players can't break mappings) plus self-repair (if they do, the next boot puts it back). |

## 4. Wheels and pedals (our home ground)
| | |
|---|---|
| **Batocera** | Force feedback only in PCSX2 and Dolphin for sure; wheel settings: rotation angle (180°), midzone (5° centre deadzone), reverse deadzone (45°); pedals on the triggers. |
| **Big Box / CoinOPS** | nothing wheel-specific. |
| **Ours** | Per-game bindings for 313 controls (Test-WheelBindings), clutch / brake / gas fixed order, handbrake, H-shifter, FFB plugin on 34 configs, flight games on a wheel, shakers, steering from the wheel's rest point. |
| **Plan** | Per-game force strength (backlog 7); per-game rotation (900° for sims, 270° for arcade) set through G HUB profiles at launch; Batocera's three wheel settings as per-game options. |

## 5. Light guns
| | |
|---|---|
| **Batocera** | Crosshair on / off / auto, calibration per gun model, gun paired with a pad for Start / coin, Sinden white border auto, MAME off-screen reload. |
| **Ours** | lightgun WheelMap template (~20 TeknoParrot gun games), Lightgun menu. |
| **Plan** | Later (no gun on the racing cabinets): copy the calibration hints into the game screen per gun model. |

## 6. Save states and saves
| | |
|---|---|
| **Batocera** | Auto save on exit + load on start; incremental slots; a save-state list by time when you open a game (RetroArch full; Dolphin / PCSX2 partly). |
| **Big Box** | Save Vault: RetroArch, Dolphin, PCSX2 saves backed up by themselves; pick an older one to restore (current one backed up first). |
| **Plan (A10, RACE2)** | Vault to the NAS for RetroArch, Dolphin, PCSX2 **and TeknoParrot / PC games** (their save folders), 5 versions; restore from the Tools menu. **Beat them:** more emulators, off the cabinet's disk. |

## 7. Attract mode (idle showcase)
| | |
|---|---|
| **CoinOPS** | on / off, dim the screen, "joystick exits" or button only. |
| **Batocera** | screensaver (video / slideshow). |
| **Ours** | RetroFE attract mode **on**: after 90 s idle it moves to another game every 20 s (settings.conf attractModeTime / NextTime). Only real button presses reset it (checked in the source), so a twitching wheel can't block it. |
| **Plan (A8)** | Cycle the series playlists too (attractModeCyclePlaylist), dim after 10 min, any pedal or wheel turn exits; a Tools switch. |

## 8. Hi-scores
| | |
|---|---|
| **CoinOPS** | Local scores by hi2txt (~40 % of MAME games); online through iScored with a QR code and a screenshot per entry; top 10 posted to Discord; Hall of Fame; Game of the Month playlist. |
| **Big Box** | MAME high-score leaderboards (weekly to all-time). |
| **Ours** | the engine has iScored and QR tables (reloadableGlobalHiscores), not turned on. |
| **Plan (A9)** | Turn on local tables for racing games that keep times (lap records!), a "best laps" card on the launch screen. **Beat them:** racing games keep times, not scores; nobody shows those. |

## 9. Browsing: favourites, random, remember
| | |
|---|---|
| **CoinOPS** | Start = favourite; Y = random game; random start position; remember the last game; favourites filter. |
| **Big Box** | search, sort and filter by any field; group by platform; play time shown ("Play Time: 48h 26m"). |
| **Ours** | random on wheel button 6; remember menu on; 13 series playlists on P / O. **Favourites (2026-11-25):** Options marks / unmarks the selected game, Share jumps to Favourites, and Favourites is second in the P cycle. |
| **Plan** | Play time and most played (A10); search by letter on the shifter? (letterUp / letterDown exist on the paddles). |

## 10. Bezels and screen dressing
| | |
|---|---|
| **Batocera** | Bezel picked per game, then per system, then a default; .info file gives the game's area; stretch option. |
| **CoinOPS** | Bezels day / dusk / night, slim, off; reflective glass; scanlines (we don't: no retro look). |
| **Plan** | Clean frames only (no scanlines, by James's rule), chosen per game then per system, from art we already have. |

## 11. Panel lights
| | |
|---|---|
| **Batocera** | LEDSpicer: profile per game, then by player / button count, then per system, then default; events at game start / end; warns that per-scroll events spam the board. |
| **Big Box** | LEDBlinky (free). |
| **Ours** | AmPanel (pedestal) replaces LEDBlinky / Ultimarc; LED calls off the render thread and coalesced (patch 0014). |
| **Plan** | Use LEDSpicer's lookup order for games with no LED map (player / button count from the catalog). |

## 12. Settings without editing files
| | |
|---|---|
| **CoinOPS** | Customisation App (desktop .exe): themes, marquee, bezels, music, splash, performance (30 / 60 / 120 fps, hardware video, vsync, renderer), attract, favourites, monitors, quit lock. Option list not published. |
| **Batocera** | menus on the TV + a small web page (list games, Play, kill emulator, reload list). |
| **Ours** | Tools menu on the cabinet (Cabinet Settings, Bass Shakers, Themes, Rebuild Game Menus, Health). |
| **Plan (A7)** | A phone page on the cabinet network: health, settings, play a game, end a stuck game, board status. All settings listed in docs (CoinOPS hides theirs). |

## 13. Music
| | |
|---|---|
| **CoinOPS** | music player in the menu: full / low / off, random, volume bar, video preview sound on / off. |
| **Plan (A11)** | Menu music per collection, ducked under video, Tools switch. |

## 14. Speed (where Big Box loses)
Big Box is .NET / WPF; we could not find public numbers, so we publish ours instead: entering Racing 84 ms (from 92),
scrolling 0 stutters at 60 fps, boot prep 1.8 s. A4 makes these checks part of every self-test.
