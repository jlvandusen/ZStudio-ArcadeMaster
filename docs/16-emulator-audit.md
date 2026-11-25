# 16. Emulator audit on ARCADE-PEDESTAL (2026-11-25)

James asked for a deep dive into every emulator on R:, the best choice for this hardware, a spot-check of each, and
updates where they are needed. This ties in with RACE2's GPU-driver work. The run was cut short for the night, and the
parts marked **not done** are still open.

## Hardware and driver

- Dell G5 5000: Intel i3-10100 (4 cores, 8 threads), **7.8 GB RAM**, GTX 1660 SUPER (6 GB), two 1920x1080 screens, Windows 11 26200.
- **NVIDIA driver 610.88** (Windows 32.0.16.1088, dated 2026-07-21).
- RAM limits this machine more than the GPU does. In a test, yuzu used 3.9 GB of RAM for one game, and RPCS3 used 1.4 GB.

**RACE2 coordination.** The board (`Board.ps1 list`, plus a search of every job and log.md for driver / NVIDIA / GPU)
had no job from RACE2 about a driver update at 16:30. The only GPU notes were about RACE2's own GTX 1060 (PR 131 and
PR 133). We installed and changed no driver. The re-test list is in the last section and was posted to the board.

## Inventory

### RetroBat at R:\CP78\RetroBat (the one the frontend launches)

This is RetroBat 7.3.0-stable, with emulatorLauncher dated 2025-07-27. It reports that 7.5.0 is available. The latest
release is **RetroBat 8.4.0**, from 2026-11-21: https://github.com/RetroBat-Official/retrobat/releases

| Emulator | Installed | Latest official (date) | Systems | Games here |
|---|---|---|---|---|
| RetroArch | 1.20.0 (Jan 2025), 149 cores | 1.22.2 (2025-11-19) github.com/libretro/RetroArch | NES, SNES, MD, SMS, PCE, PSX, N64, Saturn, DC, 2600, C64, Amiga, GBA... | NES 50, SNES 150, MD 151, SMS 25, PCE 11, PSX 110 files, N64 73, Saturn 63, DC 70, 2600 23, C64 30, A500 50, GBA 59 |
| Dolphin | 2409 | 2412 or newer (dolphin-emu.org blocks scripts; not confirmed) | GameCube, Wii | GC 109, Wii 7 |
| Cemu | 2.5 (2024-12-07) | 2.6 (2025-02-06) github.com/cemu-project/Cemu | Wii U | 27 |
| xemu | 0.8.1 (2024-12-31) | **0.8.139 (2026-10-21)** github.com/xemu-project/xemu | Xbox | 36 |
| PCSX2 | 2.3.83 (2024-12-29) | 2.8.2 (2026-09-04) github.com/PCSX2/pcsx2 | PS2 | 110 |
| RPCS3 | 0.0.34-17283 (2024-12) | build of 2026-11-25 github.com/RPCS3/rpcs3-binaries-win | PS3 | 4 folders |
| PPSSPP | 1.18.1 | 1.20.4 (2026-05-16) github.com/hrydgard/ppsspp | PSP | 56 |
| yuzu (EA build) | 2024-03 (project dead) | none; the successors are Eden and Citron (RetroBat 8 ships them) | Switch | 26 |
| Citra canary | 2798 (2024-10) | none; the successor is Azahar 2127.0.1 (2026-11-24) | 3DS | 0 |
| xenia canary | 5d3240d (2024-07) | 02d2cb5 (2026-03-24) | Xbox 360 | 0 |
| Project64 | 3.0.1-5664 | (no GitHub releases) | N64 (alternative) | 73 |
| BigPEmu | 1.18 | richwhitehouse.com/jaguar | Jaguar | 10 |
| Model 2 Emulator | 1.1a (2014; final) | final | Model 2 | 21 |
| Supermodel | 2024-03 build | v0.4-20261123-git-cd9c9d3 github.com/trzy/Supermodel | Model 3 | 10 |
| TeknoParrot | 1.0.0.1696 (2025-06) | TeknoParrot updates itself (teknoparrot.com) | PC arcade | profiles |

About 100 other folders under `emulators\` are empty placeholders.

**R:\RetroBat** is a second, newer copy: RetroBat **7.5.0**, with emulatorLauncher dated 2025-11-01. Its emulators are
mostly the same builds, and it adds cxbx-reloaded. Nothing launches from it. If RetroBat is updated, pick one copy.

### CoinOPS LEGENDS test copy (R:\ArcadeMaster\frontend\LEGENDS-am\emulators)

| Emulator | Version | Used by |
|---|---|---|
| MAME | 0.196 (mame64), 0.231 (mameNEW264), 0.215 (mameNEW64) | Arcades / Fight (719 sets), plus the legacy NES / SNES / Genesis / PCE / GBA / PSX / C64 launchers |
| RetroArchPlus | 2020-08 | N64, Dolphin core, PSP, Atomiswave, Naomi |
| RetroArchSEGA | 2022-12 | Dreamcast (legacy) |
| RetroArchXiso | 2022-06 | Amiga CD32 (puae) |
| WinUAE (Pipmick) | 4.3.1 beta | Amiga (198 `.uae` configs) |
| Daphne | 1.0.10 (2010) | Laser Disc (.bat launchers) |
| Supermodel | 2018 / 2022 builds | Sega Model 3 (.bat) |
| TeknoParrot | 1.0.0.886 and 737 (2022) | TeknoParrot / TeknoParrotAlt |
| Dolphin Triforce | DolphinWX 2014 | Triforce (.bat) |

**Not updated, on purpose:** the MAME romsets match their exact MAME versions. A newer MAME would break sets unless the
romsets are rebuilt. The latest is mame0289 (2026-07-30).

**Other builds on R:** these sit beside the frontend and are not launched by it. Their emulator folders were not
audited (**not done**):
- CoinOPS LEGENDS 2 / 3 / 4
- ATARASHII
- Forgotten Worlds (four builds)
- CORE TYPE R
- Computer Classics

## Best emulator per system on this hardware

| System | Our launcher | Best here | Verdict |
|---|---|---|---|
| NES | AM_RB fceumm | Mesen (accuracy) or FCEUmm; both have run-ahead | OK. Mesen is slightly more accurate. |
| SNES | AM_RB snes9x (legacy: MAME 0.196) | Snes9x, with run-ahead 1. bsnes if accuracy matters. | OK. Drop the MAME `snes` launcher. |
| Mega Drive / SMS | AM_RB genesis_plus_gx (legacy: MAME) | Genesis Plus GX | OK. Drop MAME `genesis`. |
| PC Engine | AM_RB mednafen_pce (legacy: MAME tg16) | Beetle PCE | OK. |
| GBA | legacy MAME `gba` | mGBA core (installed) | **Mismatch.** Add AM_RB_gba with mgba. |
| PS1 | AM_RB mednafen_psx_hw (legacy: MAME `psu`) | Beetle PSX HW, or DuckStation standalone (not installed; latest v0.1-12640) | OK. MAME PSX is poor, so drop it. |
| N64 | AM_RB mupen64plus_next | Mupen64Plus-Next (ParaLLEl-RDP on Vulkan is fine on the 1660) | OK. Project64 also works. |
| Saturn | AM_RB kronos | Beetle Saturn (most accurate; the 4-core i3 is borderline) or Kronos (GPU upscaling) | OK. |
| Dreamcast / Naomi / Atomiswave | AM_RB flycast core | Flycast. Standalone 2.7 is newer. | OK. |
| GameCube / Wii | AM_RB Dolphin standalone (legacy: RetroArch dolphin core) | Dolphin standalone, Vulkan | OK. Drop the core launcher. |
| Wii U | AM_RB Cemu | Cemu | OK. |
| Xbox | AM_RB xemu | xemu, Vulkan | OK. **Update recommended** (below). |
| PS2 | legacy .bat (missing) | PCSX2 standalone (2.3 works here; 2.8 is better) | Not in the catalog yet. |
| PS3 | none | RPCS3. Limited by the 4-core i3 and 7.8 GB RAM; light games only. | Per game. |
| Switch | none | yuzu is dead. Eden or Citron, and 7.8 GB RAM is tight. | Not recommended on this machine. |
| 3DS | none | Azahar (Citra's successor) | No games. |
| Amiga | Pipmick WinUAE + AM_RB puae | WinUAE packs (tuned) and PUAE | OK. |
| C64 | AM_RB **vice_x64** (legacy: MAME C64) | VICE **x64sc** (cycle-exact) | **Mismatch.** Change `-core vice_x64` to `vice_x64sc`. |
| Atari 2600 | AM_RB stella | Stella | OK. |
| Arcade | MAME 0.196 / 0.231, FBNeo core available | MAME matched to its romsets; FBNeo for CPS / Neo Geo (run-ahead) | Keep. |
| Laserdisc | Daphne 2010 (.bat) | Hypseus Singe (Daphne's successor; RetroBat has a placeholder) | Recommended. |
| Model 2 | LEGENDS / RetroBat m2emulator 1.1a | Model 2 Emulator 1.1a (final) | OK. |
| Model 3 | Supermodel (.bat) | Supermodel git build | OK. Update is optional. |
| TeknoParrot | LEGENDS 886 and RetroBat 1696 | Current TeknoParrot (it updates itself) | Keep 1696. |

Sources: each project's GitHub release page in the table above, and the libretro core docs (docs.libretro.com). We did
no per-game benchmarking.

## Spot-checks (2026-11-25, 16:35-17:00, driver 610.88)

Each game was launched the way the frontend launches it, held for 15-30 s, then closed. "Ran" means:
- the emulator process stayed up;
- the GPU was busy (from about 2% idle up to 25-45%);
- the screenshot was checked where the emulator allows capture.

All processes were cleaned up. "Exit code 200" in emulatorLauncher.log comes from our forced close.

| Emulator / core | Game | Ran | s | Notes |
|---|---|---|---|---|
| RA fceumm | Super Mario Bros. | yes | 15 | screenshot black (too early) |
| RA snes9x | Bust-A-Move | yes | 15 | |
| RA genesis_plus_gx | Columns (MD), Alex Kidd (SMS) | yes | 15 | |
| RA mednafen_pce | Parasol Stars | yes | 15 | |
| RA mednafen_psx_hw | Crash Bash (.chd) | yes | 25 | |
| RA mednafen_psx_hw | Chrono Cross **.m3u folder** | **crash** | 10 | access violation in the core. The inner `.m3u` file runs fine (30 s). See finding 1. |
| RA swanstation | Chrono Cross .m3u folder | **no** | 3 | exits at once (same cause) |
| RA mupen64plus_next | SF Rush | yes | 20 | |
| RA kronos | Battle Monsters | yes | 20 | |
| RA stella | River Raid | yes | 15 | |
| RA vice_x64 | Boulder Dash | yes | 20 | |
| RA puae | Bomb Jack.hdf | yes | 20 | |
| RA flycast | Crazy Taxi | yes | 25 | |
| Dolphin 2409 | Crazy Taxi (GC), Super Mario Galaxy 2 (Wii) | yes | 25 / 30 | |
| Cemu 2.5 | Mario vs. DK: Tipping Stars | yes | 30 | |
| xemu 0.8.1 | Blackstone | yes | 30 | xemu.toml rewritten; the scancode map was not touched |
| PCSX2 2.3.83 | Crazy Taxi | yes | 30 | |
| PPSSPP 1.18.1 | Bust-A-Move Deluxe | yes | 20 | |
| BigPEmu 1.18 | Wolfenstein 3D | yes | 20 | |
| Model 2 Emulator | vf2 | yes | 25 | |
| Supermodel (RetroBat) | vs2 | yes | 25 | launched with **-res=3840,2160** on a 1080p screen (GPU 78%). See finding 3. |
| yuzu EA | Cadence of Hyrule | process up, screen black | 30 | game loaded (log); 3.9 GB RAM; unconfirmed |
| RPCS3 0.0.34 | Demon's Souls | yes (intro playing) | 30 | took about 2 min to close |
| Project64 | SF Rush | yes | 20 | |
| MAME 0.196 (LEGENDS) | sf2 | yes | 20 | |
| MAME 0.231 (LEGENDS) | outrun | yes | 20 | |
| WinUAE 4.3.1 (Pipmick) | AddamsFamily.uae | yes | 20 | |
| Daphne 1.0.10 | Dragon's Lair (exe run directly) | process up, screen black | 20 | GPU at 2%; unconfirmed |
| TeknoParrot 886 / 1696, Dolphin Triforce, LEGENDS RetroArch builds, Supermodel .bat, Naomi | - | **not done** | | the run was stopped for the night |

## Findings

1. **Multi-disc `.m3u` folders.** 25 games are stored as `<Game>.m3u` folders:
   - psx 12, dreamcast 6, gamecube 3, saturn 2, 3do 1, segacd 1.

   Launched as a folder, Beetle PSX crashes and SwanStation exits. Launched through the inner `<Game>.m3u` file, they
   run. `tools/Import-RetroBatSystems.py` (`games_in`) lists files only, so these games are missing from the catalog
   today. Fix: list the folder and launch `<folder>\<folder name>`.
2. **C64 core:** AM_RB_c64 uses `vice_x64`. `vice_x64sc` (installed) is the accurate one, and docs/15 says x64sc.
3. **Supermodel resolution:** RetroBat passes `-res=3840,2160` (4x supersampling). The GTX 1660 manages it, but the
   GPU load hits 78% for no visible gain on 1080p. Set it to 1920x1080 in RetroBat's model3 options.
4. **N64 video mode:** es_settings has `n64.videomode = 2560x1440x32x60`, but the screens are 1920x1080. Set it to
   auto or 1920x1080.
5. **The .bat launchers kill JoyToKey for the whole machine.** Daphne's .bat ends with `TASKKILL /F /IM JoyToKey.exe`.
   That also kills the frontend's own JoyToKey (`LEGENDS-am\JoyToKey`, running now). Other CoinOPS .bat launchers
   probably do the same. Check them before relying on JoyToKey after a laserdisc game.
6. **Legacy launchers in the LEGENDS copy are worse than the RetroBat ones:**
   - MAME for NES / SNES / Genesis / PCE / GBA / PSX / C64;
   - the RetroArch dolphin core for GameCube;
   - RetroArch 2020-2022 builds.

   Hide them where an AM_RB collection exists. GBA has no AM_RB launcher yet.
7. **RetroArch latency settings:**
   - run-ahead off;
   - vsync on;
   - 3 swapchain images;
   - audio latency 64 ms.

   For the 8/16-bit systems, try run-ahead 1 (second instance off) or preemptive frames, and set swapchain images to 2.
   This needs testing at the cabinet.

## Updates

**Done: none.** The run was stopped before the first update started. Every emulator is still at the version listed
above, and nothing was backed up, renamed or changed.

Recommended, in order:
1. **xemu 0.8.1 to 0.8.139.** Many NV2A and Vulkan fixes. Asset `xemu-win-x86_64-release.zip`, sha256
   `fbb14dd7ea08120ca9ec99c955758786645af16a5058250553b3b7d7592e8701`. Back up as `xemu.am-prev-<date>`. Keep
   `xemu.toml`, including its `[input.keyboard_controller_scancode_map]` section. Spot-check Blackstone.
2. **RetroBat 7.3 to 8.4 as a whole.** This is how RetroBat expects emulators to be updated: emulatorLauncher and its
   generators move in step with the emulators. It also brings Eden / Citron and Azahar for the dead yuzu and Citra, and
   newer PCSX2, Dolphin and RetroArch. It is a big change, so do it as its own job, on a copy first.
   - Re-run `Import-RetroBatSystems.py` afterwards.
   - Decide which of the two RetroBat copies stays.
3. **PCSX2 2.3 to 2.8.2**, when PS2 joins the catalog (or through item 2).
4. **Cemu 2.5 to 2.6** (minor) and **Dolphin 2409 to the current release.** Neither is needed today: both spot-checks
   pass.
5. **Hypseus Singe** in place of Daphne 2010, and **DuckStation** as an option for PS1.
6. **Not recommended:** MAME, because its romsets would break.

## For RACE2: re-test after a pedestal GPU driver update

No driver job was on the board, and the current driver is 610.88. None of the installed emulators needs a newer driver:
they all ran on 610.88. Do not use a driver older than the one each emulator needs for Vulkan 1.3 (any 5xx or newer is
fine).

After a driver change, re-run these, each 30 s through emulatorLauncher:
1. **xemu** (Vulkan): Blackstone.
2. **Cemu** (Vulkan; its shader cache rebuilds): Mario vs. DK.
3. **Dolphin** (Vulkan): Crazy Taxi (GC) and Mario Galaxy 2 (Wii).
4. **PCSX2** (Vulkan / D3D12): Crazy Taxi.
5. **RPCS3** (Vulkan): Demon's Souls.
6. **RetroArch** with the vulkan driver: SNES Snes9x, N64 mupen64plus_next, PSX Beetle HW, Saturn Kronos (GL), Dreamcast Flycast.
7. **yuzu** (Vulkan) and **PPSSPP**.
8. **Supermodel** and **Model 2** (OpenGL / D3D9).
9. **TeknoParrot** (D3D9-11) and **MAME** (D3D).

DuckStation is not installed. The spot-check script used for this audit was a scratch file and is not in the repo:
launch, sample the process tree and GPU load each second, take a screenshot, then kill the process tree.
