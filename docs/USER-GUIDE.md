# ArcadeMaster User Guide

ArcadeMaster turns a Windows PC, arcade cabinet or game room into a single, polished arcade frontend. It finds the
emulators and games already on the PC and sets each system up to launch directly. It also maps your control panel
buttons in every emulator, lights the buttons each game uses, and draws menus, controls cards and art from your own
games.

> **ArcadeMaster never ships or downloads ROMs, BIOS files, emulators or game art.** It works with what is already on
> the PC.

Contents:
1. What you need
2. Install
3. Set up this PC
4. Using it
5. Configure it
6. Updates
7. Recovery and safety nets
8. Troubleshooting
9. Uninstall
10. Licence and credits

---

## 1. What you need

| | |
|---|---|
| **Windows** | Windows 10 or 11, 64-bit. .NET Framework 4.8 is already part of both. |
| **Emulators and games** | Any of these: RetroBat (ArcadeMaster uses its emulators and games and leaves RetroBat working), RetroArch, or standalone emulators (MAME, Dolphin, PCSX2, Cemu, xemu, Xenia, PPSSPP, Citra/Azahar, Yuzu-family, Supermodel, TeknoParrot, BigPEmu, Model 2) with your game folders. |
| **Controls** | An arcade encoder that sends keyboard keys (Ultimarc I-PAC and similar), a keyboard, or game pads (Xbox, PlayStation 3 or 4 through ScpToolkit or DS4Windows). |
| **Optional** | A second screen, which can be a touch screen; Ultimarc LED button boards (PacLED64, PacDrive, Ultimate I/O); ServoStik 4/8-way sticks; a Stream Deck; light guns; a racing wheel. |
| **Disk** | About 1 GB for ArcadeMaster itself. Your emulators and games stay where they are. |

## 2. Install

1. Download `ArcadeMaster-<version>-win64.zip` and its `.sha256` file from the project's GitHub **Releases** page.
2. Unzip it anywhere, for example `C:\ArcadeMaster`. Pick a folder you keep: ArcadeMaster lives there.
3. Right-click `Install.ps1` and choose **Run with PowerShell**. To start ArcadeMaster with Windows, run this instead:
   ```
   powershell -ExecutionPolicy Bypass -File C:\ArcadeMaster\Install.ps1 -Startup
   ```
   The installer:
   - points ArcadeMaster at this folder;
   - installs Python 3.12 (with Pillow) and ffmpeg if they are missing. The art tools need them; Windows may ask once
     for permission;
   - builds the **Tools** menu;
   - opens **Set up this PC**.

### Optional: let ArcadeMaster recover a stuck graphics driver (one admin click)

Some games can leave the graphics driver stuck when they quit (black screens, Alt+Tab does nothing). ArcadeMaster can
reset the driver by itself, but setting that up needs one Windows admin approval. Open PowerShell and run:
```
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\ArcadeMaster\repo\tools\Install-GpuReset.ps1'
```
Click **Yes**. This adds a scheduled task called "ArcadeMaster GPU Reset" (see section 7).

## 3. Set up this PC

**Set up this PC** opens at the end of the install. You can open it again at any time: right-click the ArcadeMaster
icon by the clock, then **Set up this PC...**.

1. **1. CHECK THIS PC** looks only. Nothing changes. Its report shows:
   - every emulator and RetroArch core on your local drives;
   - the game folders for each system, with how many games each holds;
   - your RetroBat, if you have one. With several, the one with the most games is used, and the report names the others;
   - the game lists, launchers and folder links it would make.
2. Read the report, then press **2. SET IT UP** and answer **Yes**. It takes a few minutes. It:
   - **makes a game list for each system** that has games and an emulator, grouped under the makers (Nintendo,
     Sega, Sony, Microsoft, Atari, NEC, SNK, Computers, Arcade Boards, Other Systems);
   - **makes each list launch its emulator directly**, with no other frontend in between. RetroArch consoles get a
     bezel round the picture;
   - **sets your panel's keys in every emulator**, in the button layout the on-screen controls card shows;
   - **links your other frontend's folders** (emulators, BIOS, saves, game folders) into the ArcadeMaster folder.
     Nothing is moved, so the other frontend keeps working. The tick box **move folders in instead of linking**
     moves them instead (see 5.12);
   - **draws the art from your games**: system controls cards, backdrops, the hero main menu, game tiles and the
     search index;
   - **sets the button lights** for every game and system;
   - **finishes with a health check.**

It is safe to run again whenever you add emulators or games.

## 4. Using it

Start ArcadeMaster with `ArcadeMaster.exe`, or let it start with Windows. Close it with **F8**.

### Moving around

| Do this | Panel (player 1) | Keyboard | Pad |
|---|---|---|---|
| Move | stick | arrow keys | d-pad / stick |
| Choose | button 1 or START | Enter, Left Ctrl | A / Cross |
| Back | button 2 | Esc, Backspace, Left Alt | B / Circle |
| Switch filter (All games, Favourites, Last played, genres ...) | stick left / right | Left / Right | d-pad left / right |
| Jump a letter | button 5 / button 6 | Z / X | shoulders |
| Random game | COIN | 5 | Back |
| Add to Favourites | | F or V | |
| Game options (that game's emulator version, map its buttons) | | TAB | |
| Search | the touch screen's SEARCH button | the TAB menu, or F3 | |

The menus go **main menu (makers) > system > game list**. Breadcrumbs at the top show where you are
(MAIN > NINTENDO > SUPER NINTENDO > ALL GAMES). The BACK and FILTERS hints and buttons sit next to the filter bar.

### What you see

- **Main menu:** each maker gets a full-screen backdrop, its consoles in turn, characters that walk on and wave, facts
  that drop in one at a time, and a strip of its games. Menu music plays if you turn it on (5.8).
- **System menus:** each system shows a **how-to-play card**: the original controller, and which panel button is which
  of its buttons.
- **Game lists:** the game's preview video, its art, its story after a few seconds' rest, and its controls card.
- **While a list or game loads:** **LOADING - PLEASE WAIT** stays up. Presses made while loading are ignored, so a game
  is never started by accident.
- **Attract mode:** after a while with no input, it browses games by itself and the button lights run a light show.

### The touch screen (second screen)

Tap a game to jump to it, and tap it again to start it. The touch screen also has:
- **INFO** and **BOX ART** tabs for the selected game;
- **BACK** and arrow buttons;
- the breadcrumbs;
- **SEARCH**: type a few letters. Results show their system (arcade originals first) and can be started from there.

### Playing and leaving a game

The panel works in every system ArcadeMaster set up. Its buttons light in the colours the controls card shows.

**To leave a game, hold Esc** (or your panel's exit button). Computers such as the C64 and Amiga use Esc in their games,
so for them you hold it a little longer. You return to the same game in the list.

## 5. Configure it

Most settings are in the **Tools** menu (the last entry on the main menu) and in the tray menu (right-click the
ArcadeMaster icon by the clock).

### 5.1 Tools menu

| Entry | What it does |
|---|---|
| Cabinet Settings | Cabinet name and tagline, intro, which modes show, lists and views |
| System Health | Checks the frontend, panel, art and emulators, and repairs what it can |
| Menu Buttons | Which keys / buttons move through the menus |
| Panel Test | Press each button: it shows which key it sends and lights it |
| Detect Controllers | Finds pads, wheels, flight sticks and light guns that were plugged in |
| Repair Controller IDs | Fixes controllers whose Windows IDs changed (a different USB port) |
| Rebuild Game Menus | Rebuilds the lists from the game folders |
| Second Screen On-Off | Turns the second (touch) screen on or off |
| Shuffle Backgrounds | Picks new backdrops |
| Menu Music | Off, rave, synthwave, 80s, computer, mix, or next track (music from your local drives) |
| Performance Log On-Off | Frame-time logging, for slow PCs |
| Cabinet Type | Auto, or arcade / pedestal / stand-up / racing / flight / light gun / simulation / multicade |
| Themes / Reset Theme | Pick a theme (5.5); go back to the default |
| Graphics Driver | Checks and updates the graphics driver |
| Emulator Updates | Looks for newer emulator versions |
| Restart PC / Shut Down PC | |

### 5.2 Your control panel (which key each button sends)

The panel layout is stored in `manifest\panel.json`. A PC whose panel ArcadeMaster has not learned gets the standard
**Ultimarc I-PAC / MAME** layout, which most arcade encoders send out of the box:

| | B1 | B2 | B3 | B4 | B5 | B6 | B7 | B8 | START | COIN | stick |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Player 1 | L-Ctrl | L-Alt | Space | L-Shift | Z | X | C | V | 1 | 5 | arrow keys |
| Player 2 | A | S | Q | W | I | K | J | L | 2 | 6 | R F D G |

If your encoder is set up differently, there are two ways to tell ArcadeMaster:
- **Import it from LEDBlinky**, if you use it: **Tools > System Health** reads LEDBlinky's input map; or
- **edit `manifest\panel.json`**, then run **Set up this PC** again, which rewrites every emulator's keys.

### 5.3 Pads and controllers

- **Xbox pads, and PlayStation 3/4 pads through ScpToolkit or DS4Windows:** these work next to the panel in RetroArch,
  PCSX2, Cemu, xemu (where the pad is player 1 and the panel player 2) and Xenia.
- **Wii:** without a real Wii Remote paired, the panel is an emulated Wii Remote + Nunchuk (A, B, 1, 2 on B1-B4, C / Z on B5 / B6, shake B7, Home B8) and the trackball or mouse is the pointer. Pair a real Wii Remote and it is used instead.
- After plugging a new controller in, run **Tools > Detect Controllers**.
- **To map one game's buttons:** press **TAB** on it, then **MAP BUTTONS**.

### 5.4 Button lights

Ultimarc LED boards are driven directly by AmPanel. LEDBlinky is not needed.
- **Arcade games** light the buttons they use (from MAME's controls, or LEDBlinky's Colors.ini if you have it).
- **Consoles** light the buttons their emulator uses, in the colours of the system's controls card.
- **To change a game's colours:** use **Lights & Colours...** in the tray menu.
- **Menus and attract mode** run a changing light show (waves, rainbows, ripples, sparkles ...).
- **To see which light is which:** use **Buttons...** in the tray menu.

### 5.5 Themes and game list views

**Themes** (Tools > Themes). Every theme has the touch screen, SEARCH, breadcrumbs, the loading card and the hero main
menu:

| Theme | Look |
|---|---|
| ArcadeMaster (default) | Logo wheel left, big preview, controls card, story |
| Tile Wall | A wall of logo tiles left, the chosen game large on the right |
| Cabinet | A whole cabinet: lit marquee, the preview in its screen, the controls card on the deck |
| Spin Wheel | A curved logo wheel on the right, big preview left, story ticker at the bottom |
| Showcase | A stage: light beams sweep over the game's drifting art, its video glows in a double neon frame with a passing glint, the logo drops in, box art fans out on a lit floor |
| Arcade Hall | A games room: the chosen game is a lit arcade cabinet (its marquee flickering on top, its video on the screen, its controls on the deck), the list a stack of glowing marquees |

A theme you pick has to be **kept**. If you don't confirm it, ArcadeMaster goes back to the last one that worked.

**Game list views** (Tools > Cabinet Settings) change only how the game lists look:

| View | Look |
|---|---|
| Wall of Games | 15 picture tiles, the chosen game playing in the middle |
| Pit Wall | The preview full screen, the list as a timing tower down the left |
| Split Screen | The game left, the list as a strip down the middle, what it is and how often it was played right |
| Cockpit | The preview in a windscreen, the games as a row of logos, a dash with gauges (racing cabinets) |

### 5.6 Screens

- **The second screen** shows the touch surface (or a marquee). Turn it on or off with Tools > Second Screen On-Off.
- **To change which screen is which:** `repo\tools\Set-RetroFEScreens.ps1`.
- Screens at 4K with Windows scaling are handled.

### 5.7 Cabinet type

**Auto** detects the cabinet from its hardware: wheel and pedals mean racing, flight sticks mean flight, guns mean
light gun, four panels mean pedestal. The type sets the boot intro, the instrument cluster in the game list and which
modes show. You can fix the type in Tools > Cabinet Type.

### 5.8 Menu music

Tools > Menu Music offers off, rave, synthwave, 80s, computer, mix, or "next" to skip a track. Music comes from your
own local drives; ArcadeMaster ships none. The playlists are in `manifest\music\`.

### 5.9 Bezels

RetroArch consoles get a bezel round the picture, from RetroBat's decoration sets when RetroBat is present.
- **To use another set:** run `repo\tools\New-DirectLaunchers.py --retrofe <frontend> --manifest <manifest> --bezels <set>`.
- **To turn bezels off:** `--bezels none`.

### 5.10 Emulators

Every list launches its emulator directly. The launchers are in `frontend\ArcadeMaster\launchers.windows\AM_DL_*.conf`.
- **A system ArcadeMaster has no launcher for yet:** it is reported as "left on RetroBat" or "no emulator".
- **To pick another emulator version for one game:** TAB > EMULATOR.
- **New emulator versions:** Tools > Emulator Updates.
- **All emulator settings in one go** (after an emulator update, or on another cabinet): `repo\tools\Configure-Emulators.ps1 -RetroFE <frontend> -ManifestDir <manifest> -Apply`. It runs the launchers, the panel keys in every emulator, real Wii Remotes / GameCube adapters, controller ids, the controls cards and the lights; a dry run without -Apply.

### 5.11 Adding games or a whole new system

**Easiest: tray > Import a folder...** Pick the folder: an emulator, one system's games, or a folder of system folders. Press 1 to see what it found, then 2 to import it. It is linked into ArcadeMaster (or moved, if you tick that), then its lists, launchers, keys, art and lights are made. If the folder's name does not say the system, type it in the system box (snes, psx, megadrive ...).

Or by hand:

1. Put the games in the system's folder. For a new system, use a folder named after it (snes, megadrive, psx ...).
2. Run **Set up this PC** again. New lists, launchers, art and lights are made; your existing settings stay.

### 5.12 Where things are kept

| Folder | What |
|---|---|
| `C:\ArcadeMaster\frontend\ArcadeMaster` | the frontend: lists (`collections`), launchers, themes (`layouts`), settings.conf |
| `C:\ArcadeMaster\manifest` | ArcadeMaster's data and logs: panel.json, discovery.json, lights, search index, *.log |
| `C:\ArcadeMaster\emulators`, `bios`, `saves`, `library\roms`, `decorations` | folder links to your other frontend's folders |
| `C:\ArcadeMaster\STORAGE.md` | every folder link, and where it really points |
| `C:\ArcadeMaster\repo` | ArcadeMaster's tools |

**To move the linked folders into ArcadeMaster for real** (so you can delete the other frontend), run Set up this PC
with **move folders in instead of linking** ticked. A move on the same drive is instant. To undo the links or moves:
```
python C:\ArcadeMaster\repo\tools\Move-OffRetroBat.py --retrobat <RetroBat folder> --dest C:\ArcadeMaster --retrofe C:\ArcadeMaster\frontend\ArcadeMaster --manifest C:\ArcadeMaster\manifest --undo
```

## 6. Updates

- **Automatic:** every time ArcadeMaster starts, it checks GitHub for a newer release, before the frontend opens. If
  there is one, it:
  - downloads it and checks its SHA-256 checksum;
  - replaces the engine, the tools, the themes and AmPanel;
  - keeps your game lists, settings, panel layout and themes you added.

  The art drawn from your games is then redrawn by the new tools. The log is `manifest\release-update.log`.
- **On demand:** use **Check for updates...** in the tray menu.
- **A PC without internet:** copy the release zip and its `.sha256` to it, then run:
  ```
  powershell -ExecutionPolicy Bypass -File C:\ArcadeMaster\repo\tools\Update-Release.ps1 -Root C:\ArcadeMaster -Zip D:\ArcadeMaster-<version>-win64.zip
  ```
- **To turn automatic updates off:** set `"ReleaseUpdate": false` in `C:\ArcadeMaster\ArcadeMaster.config.json`.

## 7. Recovery and safety nets

- **Frontend watchdog:** AmPanel watches the frontend in the menus. If it stops answering for 25 seconds, AmPanel:
  1. stops it;
  2. resets the graphics driver, if you approved the GPU reset task (section 2);
  3. starts it again.

  It does this at most twice in 10 minutes, then leaves it and logs "restart the PC".
- **Theme safety:** a new theme that isn't confirmed goes back to the last one that worked.
- **Self-heal:** a game that fails because of incomplete ROM files is repaired from a complete copy elsewhere on your
  drives, where one exists. The log is `manifest\rom-repairs.log`.
- **Backups:** every settings file ArcadeMaster changes is kept once as `<file>.am-bak`.

## 8. Troubleshooting

| Problem | What to do |
|---|---|
| Black screen after a game, Alt+Tab does nothing | The graphics driver is stuck. Press **Win+Ctrl+Shift+B** on the keyboard, or restart the PC. With the GPU reset task installed, the watchdog does this for you. |
| A button does nothing in one system | Tools > Panel Test (does it send the key you expect?), then Set up this PC again. TAB > MAP BUTTONS for one game. |
| A game does not start | Its log: `manifest\ampanel.log` and `frontend\ArcadeMaster\log.txt`. Check the BIOS for that system in `bios`. |
| The frontend closed by itself | F8 quits. Check the log for "Exiting". |
| Lights wrong or off | Tray > Buttons... to check the wiring; Tray > Status shows whether the LED boards were found. |
| A system is missing | Set up this PC > CHECK THIS PC: is its emulator found? Are its games found? |
| Update did not happen | `manifest\release-update.log`. The frontend must be closed for an update; it installs at the next start. |

Logs are all in `C:\ArcadeMaster\manifest\`:
- `ampanel.log`: lights, games, focus, watchdog;
- `launcher.log`: start-up and updates;
- `first-run.log`: Set up this PC;
- `release-update.log`: updates;
- `content-refresh.log`: art.

## 9. Uninstall

1. Close ArcadeMaster (F8) and AmPanel (tray > Quit).
2. Run `C:\ArcadeMaster\repo\tools\Move-OffRetroBat.py ... --undo` (section 5.12) to remove the folder links. This
   leaves your other frontend's files exactly where they were.
3. Delete `C:\ArcadeMaster`, and `ArcadeMaster.lnk` from your Startup folder.
4. If you installed it, remove the "ArcadeMaster GPU Reset" task in Task Scheduler.

> **Do step 2 before step 3.** Deleting the folder while the folder links are still there could delete the real
> emulators, BIOS files and saves they point to.

## 10. Licence and credits

ArcadeMaster is free software under the **GNU General Public License v3.0** (LICENSE).
- **Source:** https://github.com/jlvandusen/ZStudio-ArcadeMaster
- **The frontend:** our fork of RetroFE, https://github.com/jlvandusen/ZStudio-retrofe.

Thanks to the RetroFE and CoinOPS teams, whose work it builds on, and to the authors of every emulator it runs. Made
by The Real Z Studios.
