# ArcadeMaster.exe: launcher, installer / setup, updater

`dist\ArcadeMaster.exe` is a single 114 KB program. It needs only the .NET Framework 4.x that every Windows 10 / 11 has. Build it with `tools\Build-Launcher.ps1`, which uses the Roslyn compiler from VS Build Tools and makes the icon from the Real Z Studios logo.

**Install it outside the repo**, e.g. `D:\ArcadeMaster\ArcadeMaster.exe` (`Build-Launcher.ps1 -InstallTo D:\ArcadeMaster`). That way `git pull` never has to overwrite a running exe. A newer build from the repo is staged as `.new` and swapped in on the next start. Settings live in `ArcadeMaster.config.json` next to the exe.

| Run | What it does |
|---|---|
| `ArcadeMaster.exe` | **launch**: optional GitHub update, then the full boot (`Start-ArcadeMaster.ps1`, hidden). This is what the cabinet autostarts. The first run without a config opens setup. |
| `--setup` | **installer / configuration window** |
| `--update` | shows local vs GitHub, the list of new commits, and **Update now** |
| `--dry-run` | logs what launch would do (`manifest\launcher.log`) |
| `--no-update` | launch without checking GitHub |

## Setup tabs
- **Locations**
  - repository folder; cloned from GitHub when empty
  - RetroFE / CoinOPS root, with **Find frontends** to search the drives
  - **Work on a COPY of this frontend**: robocopy to `<root>-am`, recommended on a cabinet already in use
  - manifest folder
  - **Install the programs ArcadeMaster needs** (on by default): see "Prerequisites" below

## Prerequisites: every cabinet builds its own RetroFE
James's decision (2026-11-26): no ready-made RetroFE packages from the NAS. A package goes stale: the 2P stand-up got a 16-patch build while main had 20, and the layout needed the newer patches. Every cabinet installs the build tools instead, and `Update-Cabinet.ps1` (every 15 minutes) compiles main's patches itself.

`tools\Install-Prerequisites.ps1` installs only what is missing, and leaves alone what is there:

| Program | How | What for |
|---|---|---|
| Git | winget `Git.Git` (Setup installs it first, before cloning) | the repository, updates |
| GitHub CLI | winget `GitHub.cli` | pull requests from the cabinet's own session |
| PowerShell 7 | winget `Microsoft.PowerShell` | the RetroFE build and several tools |
| Python 3.12 + Pillow | winget `Python.Python.3.12` (machine-wide), then `pip install pillow` | controls cards, art, preview clips |
| VS 2022 Build Tools (C++) | winget `Microsoft.VisualStudio.2022.BuildTools` with the C++ workload. Windows asks once for permission: answer **Yes** (10-20 minutes) | compiles RetroFE |
| GStreamer 1.24.13 | the MSVC runtime + devel MSIs from gstreamer.freedesktop.org, **unpacked** (`msiexec /a`, nothing installed into Windows) into `<ArcadeMaster>\_tools\gstreamer`; the downloads are deleted after | compiles and runs RetroFE's video |
| ffmpeg | winget `Gyan.FFmpeg` | the menu preview clips |

- `-Check` only reports, and so does `AM_SYSTEM_DRYRUN=1`.
- Each line starts with `ok`, `installed`, `would install` or `FAILED`.
- A refused Windows permission prompt (exit 1602) says so, and setup can simply be run again.
- **Frontend**: install / refresh the ArcadeMaster layout, make it the active theme, add the Tools menu, detect controllers and rebuild the game menus.
- **Cabinet**: type (auto / racing / flight / simulation / standup / lightgun / multicade / pedestal / hybrids), follow the hardware, show all modes, second screen, custom intro title and tagline.
- **System**: start at logon (a Startup shortcut to this exe), quiet startup, no Windows pop-ups, MAME bezels, screen always on. Auto login opens the Windows dialog. **Only the switches you change are applied**: the current state is read first, and Windows is left alone otherwise.
- **Updates**: update on every start (fast-forward only, never over local changes or local commits), log-only mode, branch, and a **Check GitHub now** button.

**Before Install / Apply changes a frontend in place** (the COPY box is not ticked), Setup checks whether that frontend is in use and asks first:
- **Started at logon by something else**: a Startup shortcut or script, a Run key, or the Windows shell names that folder. This is how the pedestal's CoinOPS LEGENDS 4 Max starts. ArcadeMaster's own logon entry doesn't count.
- **ArcadeMaster was never installed there**: no `layouts\ArcadeMaster`. Copies named `<root>-am` are exempt.

The question has three answers: **Yes** works on a copy (recommended), **No** changes the frontend anyway, **Cancel** does nothing. This was added after Install changed the pedestal's live E: frontend.

**Install / Apply** runs the selected steps with a live log:
1. Git, only if it is missing and "Install the programs" is ticked
2. repository
3. prerequisites (`Install-Prerequisites.ps1`), if ticked
4. copy of the frontend (if ticked)
5. settings.conf, backed up to `settings.conf.setup-bak`
6. layout
7. controllers and menus
8. Tools menu
9. cabinet mode and intro
10. system switches
11. health check, which also saves a last-known-good snapshot

## Tested on DESKTOP-RACE1 (2026-11-22)
- `--dry-run` checked GitHub (up to date).
- `--update` showed "up to date"; setup read the live system state.
- **A complete theme change:**
  - Tools → Themes picked the imported DRIVE theme.
  - Booting with `ArcadeMaster.exe` brought RetroFE up in 9 s, with the "RACING CABINET" intro rendered into DRIVE.
  - The DRIVE main menu showed only the plugged-in modes.
  - The DRIVE game list showed each game's logo on the theme's own frames. The importer now makes this per-game art for themes that draw lists from a common art folder.