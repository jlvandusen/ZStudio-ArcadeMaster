# Dynamic catalog: one games.json drives the frontend

```
tools\Build-Manifest.ps1         -> D:\ArcadeMaster\manifest\games.json     (read-only scan)
tools\New-RetroFECollections.ps1 -> collections\Racing|Flight|Lightgun|Arcade, AM_TP_*, AM_PC, Main\menu.txt
tools\Set-LayoutThemes.ps1 -Shuffle -CollectionsDir ...   -> themes + random game-fanart backdrops (boot)
```

## Build-Manifest

Merges, by game:

| Source | Gives |
|---|---|
| every TeknoParrot install: `UserProfiles\*.xml` + `Metadata\<id>.json` | title, genre, platform, year, **wheel rotation**, game path. The same profile in several installs becomes **variants** (standalone / multicab / launchbox). Metadata is looked up across all installs, because the old D: install has none. |
| RetroFE collections + `meta\hyperlist\<collection>.xml` | file-based games (MAME, Model 2/3, Triforce, Dolphin, Cemu, PC), genre, launcher, media |
| LaunchBox `Data\Platforms\Arcade Racing/Flight.xml` | links titles to TeknoParrot profiles, flags flight games (the owner's classification wins), PC executables, art fallbacks (`Fanart - Background` → `Screenshot - Gameplay`, `Clear Logo`, videos) |

Category: TeknoParrot/hyperlist genre (Racing → racing, Flying → flight, Shooter → lightgun, else arcade). LaunchBox platform overrides; `-DefaultCategory racing` covers genre-less DRIVE items.

This machine (2026-11-22):

| Category | Games | Launchable | With fanart | Multi-variant |
|---|---:|---:|---:|---:|
| racing | 114 | 102 | 93 | 22 |
| flight | 6 | 3 | 4 | 0 |
| arcade | 4 | 2 | 0 | 0 |

## New-RetroFECollections

Generates, and never edits anything existing:

- **`Racing` / `Flight` / `Lightgun` / `Arcade`**: merged collections. There's one `<SourceCollection>.sub` per source, listing the games, so each game keeps its own launcher, art and emulator config.
- **`AM_TP_<install>`**: TeknoParrot games set up only in another install (e.g. LaunchBox's `D:\Emulators\TeknoParrot`). Includes `include.txt`, a launcher, and art copied in RetroFE naming.
- **`AM_PC`**: native Windows games, with one generated `.bat` per game (`cd` to the game folder, `start /wait` the exe) plus LaunchBox art.
- **`Main\menu.txt`**: categories plus Settings. A previous `menu.txt` is kept as `.am-backup`.

Everything generated carries `ARCADEMASTER-GENERATED.txt`. Re-running regenerates; `-Remove` restores the previous state.

Result on this machine: **Racing 103 entries** (12 sources incl. 7 PC games), **Flight 3** (Star Wars Battle Pod, After Burner Climax, MachStorm), **Arcade 2**. Verified on screen: main menu → Flight → After Burner with its own fanart and the flight instrument theme.

Not listed yet (17), and why:
- not installed: Blur, Juiced, NFS MW / MW 2012, Ridge Racer Unbounded, Split/Second, SnoCross, Blazing Angels, Heliborne
- profile/exe still needed: Under Defeat (only `game.bat`), FnF / Super Bikes 1+2, Valve Limit R, Road Fighters 3D (`spice.exe` missing), Chaos Code, Guitar Hero Arcade

## Order of operations on a cabinet

1. `Build-Manifest.ps1`
2. `New-RetroFECollections.ps1 -RetroFE <root>`
3. `Set-LayoutThemes.ps1 -LayoutDir <root>\layouts\ArcadeMaster -CollectionsDir <root>\collections -Shuffle` (also run at every boot by `Start-ArcadeMaster.ps1`)
