# 16. Beating the rivals: the one list

James, 2026-11-25: *"lets have all 3 merge and compare updates/enhancements for the system"*.

Three cabinets researched the same rivals on the same day:
- `docs/14` items A1-A20 (RACE1 and RACE2)
- `docs/15-rival-features.md`, the feature-by-feature detail (RACE1)
- `docs/17-frontend-gap-analysis.md`, the ranked gaps (pedestal)

This file merges them into **one numbered list**. Every row says where its old numbers came from, who owns it and where it stands. Claim a row on the board before starting it, and change its status in this file in the same PR that does the work.

Rivals: **LaunchBox / Big Box** 14.1, **Batocera** 44 / **RetroBat** 8.4, **CoinOPS** ARISE / LEGENDS / DRIVE.

House rules that apply to every row:
- No scanlines or CRT look (James). Clean bezels only.
- Pedals are always clutch LEFT, brake MIDDLE, gas RIGHT.
- Anything that changes Windows is tested with `AM_SYSTEM_DRYRUN=1`.

## Done

| # | Feature | Was | Where | Notes |
|---|---|---|---|---|
| R1 | Play time, Most played, save backups to the NAS (5 rotating slots, TeknoParrot / PC saves learned) | A10, 15 §6 | RACE2, PR 136 | Restore from Tools is still open: **R1b** |
| R2 | Game of the Month + random game + reachable playlist bar | A18, 15 §9 | RACE2, PR 144 | Random: RetroFE's own key (R / wheel button 6) |
| R3 | Favourites on the wheel | 15 §9 | RACE1, PR 143 | |
| R4 | Controllers survive reboots in MAME, Model 2, Model 3, Cemu | A1 step 1, 15 §3 | RACE1, PR 132 | |
| R5 | Graphics driver updates from NVIDIA / AMD, legacy cards included | (new) | RACE2, PR 140 | Not in any rival |
| R6 | Flight only with real flight controls, HOTAS detection, Flight Stick Setup | (new) | RACE2, PR 126 | |
| R7 | Light AmPanel: LEDBlinky / Ultimarc replacement | 15 §11, 17 lead | pedestal | Hands-on LED walk still open |

## Open, best value first

| # | Feature | Was | Rivals | Value on a cabinet | Size | Owner |
|---|---|---|---|---|---|---|
| R8 | **Universal exit combo**: hold Start + Coin (wheel: PS + Options) 2 s; the game closes cleanly in every emulator | 17 #1, 15 §1, A3 | Batocera / RetroBat hotkey + Start | high: a guest can always get back | S | pedestal (AmPanel) |
| R9 | **Kiosk / guest lock**: Tools, settings and exit-to-Windows hidden; a button code on the panel or wheel unlocks; kid list = a playlist | A12, 17 #3, 15 §3 (lock) | Batocera UI modes + passkey, Big Box PIN, CoinOPS ARISE Micro | high: guests can't break it | S-M | **RACE2** |
| R10 | **Pause menu over any game**: resume, controls card, story, hi-score, force strength, shakers, save / load, exit | A3, 15 §2, 17 #2 | Big Box (paid), Batocera Control Center | high | M-L | pedestal (AmPanel overlay) |
| R11 | **Hi-scores + lap records**: fix hi2txt, show best scores / best laps on the game screen and in attract; Hall of Fame on the NAS / touch screen | A9, A19, 15 §8, 17 #4 | CoinOPS (iScored, Discord), LaunchBox 14.1 leaderboards | high, and racing **lap records nobody shows** | M | open |
| R12 | **Phone page**: health, settings, play a game, end a stuck one, now playing, board status | A7, A17, 15 §12, 17 #5 | Batocera web manager / ES web server | medium-high | M | open (pedestal sketched it on AmPanel) |
| R13 | **Light guns end to end**: Sinden border, per-emulator gun setup at launch, crosshair off, calibration in Tools | A13, 15 §5, 17 #7 | Batocera (deepest) | high on the pedestal | M-L | pedestal |
| R14 | **Insert Coin / free play** start screen | A14 | CoinOPS kiosk config | high: arcade feel | S | open |
| R15 | **Clean bezels for 4:3 games**, per game then per system | A15, 15 §10, 17 #6 | Batocera decorations, CoinOPS, Big Box | medium-high (pedestal) | M | open |
| R16 | **Per-game wheel profiles**: force strength, rotation (900° sim / 270° arcade), deadzones from the catalog | 15 §4, backlog 7 | **none of them** | high on the race cabs | M | RACE1 (posted) |
| R17 | **Linked cabinets**: RACE1 + RACE2 head to head on the LAN, "Join RACE2?" in the menu | (A12-A20 "exceed") | **none of them** | very high for the race pair | L | RACE2 study |
| R18 | **Attract mode that sells**: cycles series / Game of the Month, dims after 10 min, any pedal / wheel exits; later real MAME demos | A8, 15 §7, 17 #8 | CoinOPS themed attract | medium | S-M | open |
| R19 | **Run-ahead per game** (2D cores) + a lag figure in the speed checks | A16, A4 | Batocera (RetroArch) | medium (pedestal) | S-M | open |
| R20 | **Music in the menu**, ducked under video, Tools switch | A11, 15 §13 | CoinOPS mixtapes, Big Box | medium | S | open |
| R21 | **Branded start + clean shutdown** (no Windows at boot; VoiceMeeter / SimHub closed) | A20 | Big Box Premium | medium | S | RACE1 (posted) |
| R22 | **On-screen controller setup** for an unknown pad | A2, 15 §3 | Batocera | medium | M | pedestal |
| R23 | **Automatic art and info** | A5 | Big Box (Games DB), Batocera scraper | medium | M | open |
| R24 | **Achievements / netplay** (RetroArch, through Classic Systems) | A6, 17 #9 | Batocera / RetroBat, LaunchBox | low on a cabinet | S | open |
| R25 | **Fleet page**: every cabinet's state, health, play time and saves on one page | (exceed) | **none of them** | high for running 3+ cabinets | S on top of R26 | RACE2 |
| R26 | **Cabinets side by side** (what each actually runs): `Write-CabinetState` at boot and every update, `Compare-Cabinets` | (new) | **none** | the base of R25 | S | **RACE2, this PR** |
| R1b | Restore a save from the NAS in Tools (pick a slot) | 15 §6 | Big Box Vault | medium | S | RACE2 |

Not planned: CRT 15 kHz (LCD cabinets), manuals reader, Steam store import, 3D boxes.

## Where we already lead
This is the docs/17 list, kept.
- **Game story on screen**
- **Lights:** AmPanel
- **"Which controller?" screen and live hot-plug**
- **Cabinet hardware:** wheel FFB, live wheel art, bass shakers, cabinet modes that follow the hardware
- **Self-repair and updates:** health check, 15-minute updates, per-cabinet RetroFE builds, the board
- **Second screen and Stream Deck**
- **Speed:** 60 fps, entering Racing in 84 ms
- **Since today:**
  - play time and NAS saves for TeknoParrot and PC games
  - driver updates for legacy cards
  - flight detection
  - comparing cabinets
