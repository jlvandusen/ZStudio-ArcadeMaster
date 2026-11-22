# Stream Deck

ArcadeMaster drives an Elgato Stream Deck directly over USB with `tools\streamdeck\amdeck.py`. Elgato's own app is not used and must not be running: it takes over the device.

## What the deck does

**Menu page** (while the frontend is up):

| | | | | |
|---|---|---|---|---|
| studio logo + current theme | THEMES > | 2ND SCREEN | SHUFFLE ART | RESTART MENU |
| VOL - | VOL + | MUTE | DECK LIGHT | IN-GAME KEYS > |
| DETECT PADS | REBUILD MENUS | SYSTEM HEALTH | PERF LOG | |

- **THEMES** opens the theme picker. Each key shows a theme's preview and name, and the theme in use has a green frame. Pressing one applies it the same way Tools → Themes does (`Invoke-CabinetTool -Tool Themes -Choice <layout>`): it sets `layout`, keeps it for the current cabinet mode (`cabinetTheme.<mode>`), renders the intro, then restarts the frontend.
- The switches run the matching Tools command (`Invoke-CabinetTool -Tool <name>`). The ones that need it then restart the frontend.
- A key shows `... WAIT` while its job runs. Other presses are ignored until it finishes.

**In-game page:** this appears by itself while any emulator in `gameProcesses` runs, and the menu page comes back when the game ends.
- Keys: COIN 1P–4P, 1P–4P START, PAUSE, the running game's logo, EXIT, SAVE / LOAD state, SERVICE, MENU <.
- They are sent as keyboard **scancodes**, so DirectInput and raw-input games see them.
- They use MAME's default keys (coin 5–8, start 1–4, P, Esc, 9, F2, Shift+F7/F7). If the panel is wired differently, change them in `deck.json`.
- A tool change that needs a restart while a game is running waits until the game ends.

## Automatic behaviour

- **The running game's logo.** When a game starts, `amdeck.py` reads RetroFE's last launch from `log.txt`. CoinOPS launches LEDBlinky with `"<rom>" "<collection>"`, TeknoParrot uses `--profile=<game>.xml`, and other launches fall back to the last argument. The deck then shows `collections\<collection>\medium_artwork\logo\<rom>.png` on the in-game page with a light sweep. Without a logo, the key shows the rom name.
- **Live ON/OFF.** Keys with a `"state"` rule (2ND SCREEN: `numScreens` 2 or more; PERF: `perfLog` > 0) redraw whenever `settings.conf` changes, whatever changed it.
- **`deck.json` reloads itself** within a second of being saved.
- **Idle dimming.** The deck dims to `idleBrightness` after `idleDimMinutes` without a press (never during a game). The first press only wakes it.
- **Elgato's app.** If its app is running, `amdeck.py` waits and takes the deck over as soon as the app closes.
- **First boot.** `Start-ArcadeMaster.ps1` installs the Python packages if they're missing (it skips the Microsoft Store `python` placeholder).

## Performance

- **Rendering.** Every key's frames are drawn and converted to the deck's format once, then cached. The other pages are pre-rendered in the background at start, so a page switch is a lookup. Only keys whose frame changed are written to the deck.
- **Game check.** Once a second, using the Windows process snapshot (about 7 ms), not `tasklist`.
- **`settings.conf`** is re-read only when its modification time changes.

## Key art

`tools\streamdeck\New-DeckArt.py` draws the whole set in code (Pillow only) into `tools\streamdeck\art\`: animated PNGs, 72 px, neon on black, in player colours (P1 red, P2 blue, P3 green, P4 yellow). Re-run it after changing the style. `--preview <png>` writes a contact sheet. A key whose art file is missing shows its text label.

## Animated keys

The deck has no animation of its own, so `amdeck.py` streams the frames itself at `fps` (12 by default). It only rewrites keys whose frame changed.

| Animation | When |
|---|---|
| **Press flash** | Every key, on every press. It fills with the key's colour and fades back in about 0.25 s. It shows before the action runs, so a press is always visibly answered. |
| **Spinner** | While the key's job runs (a tool, a theme change, a restart). |
| **Pulse** | The frame breathes. Shown on the logo key, the theme in use, keys with `"anim": "pulse"`, and RESTART MENU while a restart is waiting for a game to end. |
| **Animated PNG / GIF** | `"image": "art/<file>.png"` (relative to `tools\streamdeck\`, or absolute) replaces the label. The file's own frame timing is used. Still images work too. |

## Restarting the frontend without counting a crash

`Start-ArcadeMaster.ps1` treats a non-zero RetroFE exit as a crash, and three crashes in a row restore the last-known-good configs. A deliberate restart therefore writes `<manifest>\restart.request` (holding the reason) before it closes RetroFE. The watchdog sees the file, logs `restart requested (...)` and starts RetroFE again. Any other tool can use the same file.

## Setup on a cabinet

```powershell
winget install Python.Python.3.12 --scope user          # if Python is missing
python -m pip install --user -r tools\streamdeck\requirements.txt
python tools\streamdeck\amdeck.py --retrofe <RetroFE root> --manifest <manifest dir> --once   # draws the menu page
```

- Quit Elgato's Stream Deck app and take it out of startup.
- `Start-ArcadeMaster.ps1` starts `amdeck.py` hidden with `pythonw` at every boot. A named mutex keeps it to one copy.
- `amdeck.py` waits for the deck when it is unplugged, and reconnects when it comes back.
- Log: `<manifest>\amdeck.log`.
- `tools\streamdeck\bin\hidapi.dll` is libusb/hidapi 0.16.0 (x64), used under its BSD licence.

## Changing the layout

Edit `tools\streamdeck\deck.json`. Keys are numbered 0–14, row by row, on the 15-key deck.

| Action | What it does |
|---|---|
| `page:<name>` | show another page |
| `themes` | open the theme picker |
| `theme:<layout>` | apply one theme |
| `tool:<Invoke-CabinetTool name>` | run a Tools command; add `"restart": true` if the change needs a frontend restart |
| `restart` | restart the frontend |
| `keys:SHIFT+F7` | send keys to the game |
| `volume:up\|down\|mute` | system volume |
| `brightness` | cycle the deck's brightness |

## Tested on ARCADE-PEDESTAL (2026-11-22)

- Stream Deck MK.2 (USB `0FD9:0080`, 15 keys, 72 px). The library reports it as "Stream Deck Original".
- The menu and in-game pages rendered on the deck.
- The theme picker is waiting for the LEGENDS theme import (`themes.json`).
