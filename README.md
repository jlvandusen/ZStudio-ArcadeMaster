# ZStudio ArcadeMaster

A deployable arcade-cabinet system from **The Real Z Studios**. It covers racing, flight and lightgun stand-ups, runs on a patched, faster RetroFE build, and ships an original neon layout and a single install package.

## Status (2026-11-22)

| Area | State |
|---|---|
| Machine survey (racing/flight cabinet) | done, see `docs/01-machine-survey.md` |
| RetroFE: CoinOPS build, crash fixes, symbols | done. Menu is ready in **0.71 s**, down from 4–9 s on stock. See `retrofe/` |
| ArcadeMaster layout (boot banner, animated wheel/gauges/yoke/HUD, launch sequence) | working on the CoinOPS build, see `layouts/ArcadeMaster/` |
| Rotating horizon backdrops (5 racing, 6 flight, synthwave; random order every boot, Ken Burns drift) | working: `tools/New-Backgrounds.ps1`, `Set-LayoutThemes.ps1 -Shuffle` |
| Boot launcher (shuffle + crash-restart watchdog) | `tools/Start-ArcadeMaster.ps1` |
| Duplicate scan of all game trees | done: **155.5 GB reclaimable across 46 games**, see `reports/dupes/clusters.md` |
| Single package (one game store, all frontends) | design in `docs/04-package-architecture.md`; manifest builder + consolidation next |
| Wheel / lightgun master input mapping | built, see `tools/wheelmap/` and `docs/06-input-mapping.md`. The wizard needs one run on the real wheel. |

## Layout

```
docs/                       survey, plan, change log, input mapping
layouts/ArcadeMaster/       RetroFE layout: layout.xml (game list), collections/Main/layout/layout.xml (main menu),
                            splash.xml (Real Z Studios boot banner), images/ video/ sounds/ fonts/, themes.json
retrofe/                    Build-RetroFE.ps1 (pinned CoinOPS commit + patches/ -> runtime folder)
tools/
  New-LayoutArt.ps1         generates all layout art (System.Drawing, original artwork)
  New-LayoutSounds.ps1      synthesises the UI sounds
  Build-GridVideo.ps1       encodes the animated neon grid floor (GStreamer x264)
  Set-LayoutThemes.ps1      per-collection theme slots (racing / flight / lightgun) from themes.json
  Find-Duplicates.ps1       read-only duplicate finder (size -> prefix hash -> MD5)
  Repair-TPProfiles.ps1     fixes broken TeknoParrot <GamePath> entries (dry run by default)
  Resolve-CrashAddress.ps1  turns retrofe.exe+0xRVA from a crash log into function/file:line
  wheelmap/                 input capture + per-game best-practice mapping (in progress)
```

## Build RetroFE

```powershell
# GStreamer 1.24.x MSVC x86_64 runtime + devel MSIs, unpacked without installing:
msiexec /a gstreamer-1.0-msvc-x86_64-1.24.13.msi /qn TARGETDIR=D:\ArcadeMaster\_tools\gstreamer
msiexec /a gstreamer-1.0-devel-msvc-x86_64-1.24.13.msi /qn TARGETDIR=D:\ArcadeMaster\_tools\gstreamer
.\retrofe\Build-RetroFE.ps1 -GstRoot D:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64
```

The build needs VS 2022 Build Tools (MSVC x64), the CMake bundled with them, and Git.

## Layout art

```powershell
.\tools\New-LayoutArt.ps1; .\tools\New-LayoutSounds.ps1; .\tools\Build-GridVideo.ps1
.\tools\Set-LayoutThemes.ps1 -LayoutDir <retrofe>\layouts\ArcadeMaster -CollectionsDir <retrofe>\collections
```

The Real Z Studios logo (`layouts/ArcadeMaster/images/studio_realz.png`) is the studio's own mark. OpenSans is Apache-2.0.
