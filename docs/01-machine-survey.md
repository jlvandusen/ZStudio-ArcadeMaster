# ArcadeMaster — Machine Survey (2026-11-22)

## Hardware / volumes

| Vol | Label  | Device                          | Type        | Used    | Free    | Role today |
|-----|--------|---------------------------------|-------------|---------|---------|------------|
| C:  | OS     | SSSTC CL1 128 GB NVMe           | SSD         | 87 GB   | **12 GB** | Windows |
| D:  | Flight | Crucial BX500 1 TB              | SATA SSD    | 805 GB  | 127 GB  | LaunchBox/BigBox, RocketLauncher, `Arcade PC` games, `Emulators` |
| E:  | Drive  | WD Blue WD10EZEX 1 TB 7200rpm   | **HDD**     | 680 GB  | 252 GB  | RetroFE "DRIVE Collection", Raw Thrills, Support archives |
| Z:  | (NAS)  | network                         | —           | 26.7 TB | 1.9 TB  | dev / storage |

All NTFS, 4 KB clusters. C: is nearly full.

## Frontends found

| Frontend | Location | Version | Health |
|---|---|---|---|
| RetroFE ("DRIVE Collection" by P1ch3) | `E:\DRIVE Collection` | RetroFE **0.10.33**, exe 2022-04, GStreamer DLL bundle 2020-03 | **31/31 TeknoParrot games resolve** |
| LaunchBox / BigBox | `D:\LaunchBox` | — | Platforms *Arcade Racing* (43) and *Arcade Flight* (6). **Flight: 6/6 broken. Racing: 14/43 point at missing exe/profile**, plus more via broken TP profiles below |
| RocketLauncher | `D:\RocketLauncher` | — | not wired to RetroFE; usage unclear |

`DRIVE.exe` is a 113 KB .NET wrapper ("CoreType_R") that sets JoyToKey registry keys and starts `core\retrofe.exe`. Boot shell is plain `explorer.exe`; nothing auto-starts the frontend.

## File counts (the core problem)

| Tree | Files | Size |
|---|---:|---:|
| `D:\Arcade PC` | 719,161 | 492 GB |
| `E:\DRIVE Collection` | 500,570 | 362 GB |
| ↳ `collections\TeknoParrot\roms` | 372,865 | 132 GB |
| ↳ `collections\PC Games` | 95,517 | 198 GB |
| `D:\LaunchBox` | 68,030 | 215 GB (MAME 88 GB, Videos 61 GB, Images 12 GB) |
| `D:\Emulators` | 31,548 | 61 GB |
| `E:\Support` | 1,128 | 311 GB (multi-part RARs of DRIVE Collection + updates 1.2) |
| **Total arcade data** | **~1.33 M** | **~1.5 TB** |

## Duplication

Name+size match between `D:\Arcade PC` and `E:\DRIVE Collection` / `E:\Raw Thrills` on 15 sampled racing titles: **55.6 GB identical** (most pairs 98–100%). Cars, Dirty Drivin', Chase HQ2, Sega Rally 3, Storm Racer G, SWDC, Daytona 3 (+Multi), ID6, Ford Racing, FnF SC/Drift, SSASR, Wacky Races, partial MKDX. Further suspected overlap not yet measured: MAME (`LaunchBox\Games\MAME` 88 GB vs DRIVE `emulators\MAME\roms`), Model 2/3, Triforce, Naomi.

**Four TeknoParrot installs**, each with its own profile set:

| Install | Version | Game profiles | User profiles | Broken game paths |
|---|---|---:|---:|---:|
| `E:\DRIVE Collection\emulators\TeknoParrot` | 1.0.0.1919 | 493 | 30 | 0 |
| `E:\DRIVE Collection\emulators\TeknoParrotMulti` | 1.0.0.1919 | 493 | 1 | 0 |
| `D:\Emulators\TeknoParrot` (used by LaunchBox) | 1.0.0.894 | 261 | 37 | **23** |
| `D:\Emulators\TeknoParrot - Copy` | 1.0.0.744 | 229 | 23 | 3 |

Root cause of the D: breakage: DRIVE's profiles were copied over with relative paths (`..\..\collections\TeknoParrot\roms\...`) that resolve to a non-existent `D:\collections`, plus references to a non-existent `E:\Arcade PC` and `E:\Emulators\TeknoParrot`.

## RetroFE performance evidence (from `log.txt`)

- Config parse + SDL init: < 1 s.
- **`layout.xml` load: 3 s** (16:00:46 → 16:00:49) — dominated by `layouts\DRIVE\video\particules.mp4`: **292 MB, 5-minute loop, ~8 Mbps**, decoded in software by 2020 GStreamer, read from the HDD.
- Collection scans: near-instant (small `roms` dirs / UserProfiles).
- Missing `sounds/select.wav`, `highlight.wav`, `load.wav` (errors every boot).
- Collection video snaps: 93 files, 7.8 GB.
