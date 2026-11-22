# Changes log

## 2026-11-22

### (a) RetroFE on SSD
- Copied the frontend from `E:\DRIVE Collection` to `D:\ArcadeMaster\frontend\DRIVE` (8.7 GB, 1,290 files). `E:` was not modified, apart from `log.txt` being rewritten by one test run. The original log is saved in `reports/startup/`.
- Created 12 junctions back to `E:`: every `collections\*\roms` folder, plus `emulators`.
- Start the copy with `D:\ArcadeMaster\frontend\DRIVE\DRIVE.exe`.
- Measured time from process start to menu ready: E: (HDD) 9 s, D: (SSD) 3 s. Layout load: 6 s on E:, 1 s on D:. Logs are in `reports/startup/`.
- **To undo:** delete `D:\ArcadeMaster\frontend\DRIVE`. Use `rmdir` on the junctions first so nothing on E: is followed.

### (d) Path repairs
- `D:\Emulators\TeknoParrot\UserProfiles`: rewrote `<GamePath>` in 21 profiles. See `tools/Repair-TPProfiles.ps1`.
  - Backup: `D:\ArcadeMaster\_backup\TP-UserProfiles-TeknoParrot-20261122-061140`.
  - CC.xml and GHA.xml are still unresolved. They aren't racing or flight games, and the exe names differ from what the profiles expect.
- Created TP user profiles `StarWars.xml` and `WMMT5.xml` from GameProfiles, with GamePath set. **Controls are unbound; bind them in the TeknoParrot UI.**
- LaunchBox `Arcade Racing.xml`: Batman pointed at the non-existent `E:\Emulators` (emulator "TeknoParrotLegacy"). It now points at `..\Emulators\TeknoParrot` (emulator "TeknoParrot").
  - Backup: `D:\ArcadeMaster\_backup\LaunchBox-Data-20261122-061246`.
- Result:
  - LaunchBox Racing: 31/43 games now have paths that resolve.
  - LaunchBox Flight: 1/6.
- Still open:
  - These need the game exe chosen in the TeknoParrot UI: After Burner Climax, MachStorm, Under Defeat, Valve Limit R, FnF Super Bikes / Super Bikes 2, FnF.
  - These games aren't on the machine: Blur, Split/Second, Juiced 2, NFS MW, NFS MW 2012, Ridge Racer Unbounded, Heliborne, Blazing Angels, SnoCross.
  - Road Fighters 3D: its folder exists but `spice.exe` is missing.
  - The LaunchBox emulator "TeknoParrot Admin Mode" points at a `TeknoParrotUi - Admin.exe` that doesn't exist.

### (b) CoinOPS RetroFE build
- Installed Git (winget, machine scope, about 400 MB on C:).
- Cloned `CoinOPS-Official/RetroFE` branch `current` @ `caab32e` (2026-09-27) to `D:\ArcadeMaster\src\RetroFE`, including the `RetroFE-windows-deps` submodule (runtime DLLs).
- Toolchain present: MSVC 19.44 (VS 2022 BuildTools on D:), bundled CMake 3.31 and Ninja, Windows SDK 10.0.26100.
- Blocked on: GStreamer **1.24.11 MSVC x86_64 devel** package (CI uses `choco install gstreamer gstreamer-devel --version 1.24.11`). Also needs an include shim so `<SDL2/SDL.h>` resolves to `ThirdParty\SDL2-2.32.10\include`.

### (b) CoinOPS RetroFE: built and running (2026-11-22, second pass)
- GStreamer **1.24.13** MSVC x86_64 runtime and devel MSIs were downloaded from gstreamer.freedesktop.org (SHA-256 matches the published hashes). 1.24.11 is no longer hosted. Unpacked with `msiexec /a` (no system install) to `D:\ArcadeMaster\_tools\gstreamer`.
- An SDL2 include shim was needed because the source includes `<SDL2/SDL.h>` while the vendored headers are flat. It lives in `D:\ArcadeMaster\src\shim\include\SDL2`, built from the four `ThirdParty\SDL2*` include folders.
- Configure command:
  `cmake -A x64 -B RetroFE\Build -S RetroFE\Source -DGSTREAMER_ROOT=<gst> -DSDL2_INCLUDE_DIR=<shim> -DSDL2_IMAGE_INCLUDE_DIR=<shim> -DSDL2_MIXER_INCLUDE_DIR=<shim> -DSDL2_TTF_INCLUDE_DIR=<shim>`
- The Release build succeeded in under 1 minute. Output: `retrofe.exe` 2504.2.
- Test install: `D:\ArcadeMaster\frontend\DRIVE-coinops`. It has the same frontend files and junctions as the SSD copy. `retrofe\` holds the exe and runtime. `core` is a junction to `retrofe`, so `DRIVE.exe` works.
- Runtime problems found and fixed:
  1. The `RetroFE-windows-deps` submodule is **GStreamer 1.22.7**, not 1.24. It also lacks `libusb-1.0`, `libserialport`, `libcurl`, `zlib`/`zlib1` and `gst-plugin-scanner.exe`. With the 1.22.7 DLLs, warm starts crashed in USER32 before logging began. Cold starts survived one access violation during the plugin scan.
     **Fix:** a runtime folder built from the matching 1.24.13 `bin` and `lib\gstreamer-1.0` plugins, plus `gst-plugin-scanner.exe` and the ThirdParty DLLs. The old folder is kept as `retrofe-gst122`.
  2. `gstfrei0r.dll` is disabled (moved to `_disabled\`). RetroFE sets `FREI0R_PATH` to its own DLL folder, so frei0r tries to load every DLL there as an effect.
  3. `PacDrive64.dll` (Ultimarc LED SDK) is disabled. Nothing in the RetroFE source references it, but it sits in the GStreamer plugin folder, so the plugin scan loads it. It caused the access violation at `0x1800034e0`, logged as `PacDrive64.dll_unloaded` at 06:42:37.
  - All 6 RetroFE crash events today (06:41–06:45) came from testing this copy before fixes 1 and 3. Since then, cold and warm starts show 0 crash events.
- Settings appended to the test copy's `settings.conf`: `log = ERROR,WARNING`, `HardwareVideoAccel = true` (selects `d3d11h264dec` on the GTX 1650), `SDLRenderDriver = direct3d11`, `metaLock = true`.

| Build / location | launch → menu ready |
|---|---|
| stock 0.10.33, E: HDD | 4–9 s |
| stock 0.10.33, D: SSD | ~3 s |
| stock 0.10.33, D: SSD + re-encoded video | 1–2 s |
| **CoinOPS 2504.2, D: SSD, warm** | **0.71 s** |
| CoinOPS first boot (builds the GStreamer registry) | 5.8 s, one time only |

### (a) Background video re-encoded
- `particules.mp4`: 1080p25 H.264 at 8.1 Mbps and 292 MB became **960×540 H.264 High at 1 Mbps, 31.6 MB**. It keeps the full 5:00 length so the loop stays seamless. The layout draws it at `alpha=".1"`.
- It was encoded with GStreamer `x264enc` (running FFmpeg was blocked by the permission classifier).
- Installed in both D: copies. The original is still on E:.

### (c) Duplicate scan
- `tools/Find-Duplicates.ps1` is read-only and writes to `reports/dupes/`.
- The first run stalled after enumeration: PowerShell 5.1's `Group-Object` spent more than 45 minutes on 1.27 M items. I replaced it with Dictionary grouping and resumed with `-ReuseFileList`.

### Environment note
- C: dropped to 0 MB free during the session. My only writes there were Git and a failed WinGet download (deleted). The rest was Windows Update and Edge payloads, about 3.6 GB of zips in Downloads, and MSI installs from another process.
