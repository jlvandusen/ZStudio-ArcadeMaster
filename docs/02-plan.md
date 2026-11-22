# ArcadeMaster — Plan (2026-11-22)

See `01-machine-survey.md` for the evidence behind each item.

## 1. One game store, many frontends

Goal: every game exists once on disk, and every frontend launches it through one shared TeknoParrot install.

```
<ROOT>\ArcadeMaster\
  frontend\retrofe\           RetroFE (CoinOPS build), layouts, meta.db   -> SSD
  frontend\launchbox\         (optional) BigBox data only, no game copies
  emulators\TeknoParrot\      ONE install (newest, 1919+), ONE UserProfiles set
  emulators\{Dolphin,Supermodel,m2emulator,MAME,Cemu}\
  games\<GameId>\             canonical game folders (HDD is fine)
  media\<collection>\         snaps/wheels, re-encoded                   -> SSD
  manifest.json               game id, title, genre (racing|flight), emulator,
                              profile, exe relpath, media, frontends
```

- TeknoParrot `GamePath` is generated from `manifest.json` (no hand-edited relative paths, which caused the 23 broken D: profiles).
- RetroFE collections `Racing` and `Flight` and LaunchBox platforms are **generated** from the same manifest.
- Old paths (`E:\DRIVE Collection\collections\TeknoParrot\roms\X`, `D:\Arcade PC\...`) are kept working during migration with **directory junctions** that point at `games\<GameId>`. Junctions work across local volumes. Hardlinks only work within one volume.
- Migration order: hash-verify each duplicate pair (55.6 GB found so far), keep one copy, add a junction where the other copy was, then test-launch from both frontends before deleting anything.

## 2. Deployable installer

Copying 1.3 M small files is what makes deployment slow. The fix is to stop deploying loose files:

- **Game library as images**: one **VHDX per collection** (or per large game). This means sequential copies of a few big files, mount at boot (`Mount-DiskImage`, or attach to a folder mount point so paths never change), and the volume can be read-only. An alternative is **WIM via wimlib**, which de-duplicates identical files automatically and applies quickly.
- **Bootstrapper** (Inno Setup or WiX + PowerShell). It:
  1. installs prerequisites (VC++ redists, .NET, DirectX June 2010, the TeknoParrot prerequisites),
  2. lays down `frontend\` and `emulators\`,
  3. attaches or applies the game images,
  4. renders `TeknoParrot UserProfiles`, RetroFE `launchers.windows`/collections and LaunchBox XML from `manifest.json` for the chosen `<ROOT>`,
  5. applies cabinet tuning (section 4),
  6. sets auto-logon and starts the frontend.
- Wheel GUIDs are regenerated per machine (the existing `UpdateGuid*.ps1` scripts in `E:\Support` do this).
- The 311 GB of RARs in `E:\Support` are replaced by the images.

## 3. RetroFE: rebuild from source

No decompiling is needed. RetroFE is GPLv3 and the source is public.

- **Base**: `CoinOPS-Official/RetroFE`, branch `current` (active through 2026-09, version line 2504.x).
  - Not `RetroFE-MF-Dev`: it was last updated 2024-08 and is a subset of `current`.
  - Not RetroFeVLC: it publishes no source.
  - Not `phulshof/RetroFE`: no commits since 2023-04.
- **Build**: VS2022, CMake, x64, GStreamer MSVC x86_64 1.22+ (runtime + devel), `cmake -A x64 -D GSTREAMER_ROOT=...`.
- **Features we get from CoinOPS**: file cache against drive thrashing, threaded media and video preroll, image and animation cache, `metaLock`, D3D11 renderer, and hardware decode (`HardwareVideoAccel`: D3D12 decode, or QSV on Intel).
- **Settings to port**: `metaLock=true`, `SDLRenderDriver=direct3d11`, `HardwareVideoAccel=true` (A/B test against `AvdecMaxThreads`), `highPriority`, `kiosk`. Note the renamed keys (`X_RES`/`Y_RES` became `H_RES`/`V_RES`, and others).
- **Our own patches, after measuring**:
  1. Instrumented startup timing.
  2. Async-first layout load, so the menu draws before the background video prerolls.
  3. Optional manifest-driven collections instead of directory scans.
  4. Launch via TeknoParrot with focus and exit handling, replacing the `DRIVE.exe` wrapper and `cmd.exe` stubs.
- Keep 0.10.33 as a fallback until the DRIVE layout is verified on the new build.

## 4. Quick wins (no rebuild needed)

| # | Change | Why |
|---|---|---|
| 1 | Re-encode `particules.mp4` (292 MB, 5 min, ~8 Mbps) to a 20–30 s H.264 1080p loop of about 10–20 MB | Accounts for most of the 3 s layout load |
| 2 | Re-encode the 93 collection snaps (7.8 GB) to H.264 at about 2–4 Mbps, 720p | Faster scrolling, less HDD seek |
| 3 | Move RetroFE (`core`, `layouts`, `meta.db`, media) to the SSD; leave game data on the HDD | Frontend I/O is small but latency-bound |
| 4 | Add the missing `sounds/select.wav`, `highlight.wav` and `load.wav` | Removes boot errors |
| 5 | Add Defender exclusions for game, emulator and frontend roots | Real-time scanning of game exes and DLLs at launch is a major cost with this many files |
| 6 | `fsutil behavior set disablelastaccess 1`; strip 8.3 names on D: and E:; exclude D: and E: from Windows Search indexing | Speeds enumeration of trees with 1.3 M files |
| 7 | Remove OneDrive, Teams and Edge from startup on the cabinet | Frees RAM and CPU and stops focus stealing |
| 8 | Free space on C: (12 GB left) | Windows updates and shader caches will fail |
