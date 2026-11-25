# 14. RetroFE: deep dive and improvement list

Written 2026-11-25 on DESKTOP-RACE1 (GTX 1650, one 1920x1080 60 Hz screen), from the fork's own source
(`D:\ArcadeMaster\src\RetroFE`, CoinOPS base `caab32e` + our patches 0001-0016) and the numbers we measured today.

## Where it really stands

RetroFE is not as old as it looks. Our base **is** the newest upstream code: CoinOPS's working branch (`current`) has
not moved since `caab32e` (2026-09-27), so there is nothing to catch up on. (The "1,443 commits" in BACKLOG 3a is
the old `master` line's history, which the fresh import left out. It is not missing code.)

What it already has:

| Area | Today |
|---|---|
| Graphics | SDL 2.32, Direct3D 11 renderer |
| Video | GStreamer 1.24.13 with hardware decoding (NVIDIA nvcodec, D3D11, Intel QSV, AMD AMF all shipped; it picks by GPU) |
| Pictures | loaded and decoded on a thread pool; since patch 0012 the colour conversion is off the main thread too |
| Frame timing | its own sleep-then-spin pacer, plus our hitch log (patch 0014): `hitch N ms: logic/draw/present` |
| Controllers | SDL GameController with `gamecontrollerdb.txt`, plug and unplug handled |
| Crashes | writes a minidump on a crash |
| Data | SQLite meta.db (schema migration, patch 0015) |

So the job is not "replace an old engine". It is fixing five design choices that waste time on every frame or every
scroll.

## Measured so far (2026-11-25)

- Picture upload per scroll step: 6 ms → 2 ms (patch 0012).
- Scroll hitches on a warm cache: 4-9 per 5 s → 0 (60 presses, max frame 17 ms).
- Entering a list: one 46 ms hitch, all of it in `logic` (loading the first item).
- Cold cache (first run after a reboot): hitches of 116-359 ms.
- Live settings on RACE1: `vsync` not set (off), `fps` 60, `HardwareVideoAccel = true`, `direct3d11`.

## The list, best value first

Each item says what it fixes, what we expect, and how we'll know it worked (before/after with `perfLog = 5`).

### 1. Vsync: measured, no gain on RACE1 (2026-11-25)
**Measured:** 60 Down presses in Racing, `perfLog = 5`, vsync off vs on: both p50 16.67 ms, p99 16.7-17.3 ms, max
17.6 ms, 0 hitches; RetroFE used 24-29 % of one core either way. The sleep-then-spin pacer is better than it reads, so
vsync stays off (a tear line can't be seen in the log; switch it on only if James sees tearing). The original note:
**Was:** 1. Turn vsync on and let the screen set the pace
**Now:** vsync defaults off. A 60 fps timer sleeps and then spins the CPU (up to 1.5 ms a frame,
`sleepUntilTicks`) to hit the frame time on its own clock. That clock is not the screen's, so frames drift against the
refresh: a tear line or a doubled frame every few seconds, and a CPU core busy for nothing.
**Do:** `vsync = true` in our settings (the renderer already asks for `PRESENTVSYNC` when it's set), and skip the spin
when vsync is on (the code already does). Later: a waitable swap chain (DXGI flip model) for less lag.
**Expect:** no tearing, smooth scrolling at exactly the screen's rate, less CPU. **Check:** hitch log `late` values and
frame-time spread before and after; CPU % of retrofe.exe idle on Main.

### 2. Keep video frames on the graphics card (medium, big win for video menus)
**Now:** the card decodes the video (good), then each frame is copied back into main memory (`appsink`, NV12), and
uploaded to a texture again with `SDL_UpdateNVTexture`. At 720p30 that is ~40 MB/s each way per playing video, on the
main thread.
**Do:** ask GStreamer for `video/x-raw(memory:D3D11Memory)` and share that D3D11 texture with SDL's device (same
adapter; `SDL_RenderGetD3D11Device`). This drops both copies. Fall back to today's path on any error.
**Expect:** a much smaller `draw` share on video-heavy screens (the launch screen, the pedestal's grids), and room for two
videos at once. **Check:** hitch log `draw` ms with one and with two videos playing.

### 3. Picture cache with a size limit (small, stops slow growth)
**Now:** `Image::textureCache_` keeps every picture ever shown until the layout is torn down. There's no size limit and
no reference count (shared by raw pointer). Scroll through all 900 racing games and every backdrop and logo stays in
video memory; on the 4 GB GTX 1650 that ends in the driver paging, which shows up as random long hitches after an hour.
**Do:** count users per entry, and drop the least-recently-used unused pictures once the cache passes a limit
(setting `textureCacheMB`, default 1024).
**Expect:** flat video memory over a long session. **Check:** GPU memory (Task Manager / `nvidia-smi`) after a scripted
15-minute scroll, before and after.

### 4. Pictures at the size they are drawn, made ready ahead (medium, fixes cold-cache hitches)
**Now:** a 3840x2160 fanart is decoded at full size (33 MB) to show it in a 1920x1080 frame. The first time after a
reboot each new item costs a disk read plus a PNG/JPG decode, which is the 116-359 ms cold hitches. Nothing is loaded
before you reach it.
**Do:** (a) shrink on the loader thread to the size the layout draws it (or ship pre-shrunk copies: BACKLOG 3,
"no texture bigger than it is drawn"); (b) when the list moves, start loading the next 3 and previous 3 items' art;
(c) later, keep a compressed GPU-ready copy (BC7 / DDS) so a picture costs a read, not a decode.
**Tried 4b on the pedestal (2026-11-25), not shipped:**
- A background thread read the art of the selected item and 3 either side into the file cache (fork branch `perf/preload-neighbours`).
- A/B with 80 moves over never-visited items: preload off gave 0 and 0 hitches; preload on gave 2 hitches (worst 582 ms) and 0, while reading 1.4 GB.
- On this disk, unvisited art isn't what hitches; the reads only compete. The after-reboot hitches need their own `hitch` lines first, since they are probably first-use costs (decoder, driver), not file reads.
- 4a (shrink to drawn size) is still worth measuring separately.

**Expect:** the cold-cache hitches below 33 ms (two frames). **Check:** the hitch log on the first scroll after a
reboot, before and after.

### 5. Loading a list on a thread, not the frame (medium) - now the top speed item
**Measured on RACE1 (2026-11-25, timing build, not installed):** entering Racing is one 100-136 ms frame:
| step | ms |
|---|---|
| read the Racing menu from disk (`getCollection`): 12 sub-collections built + sorted 24, info files 4, rest 1 | 29-49 |
| build the page from its layout (`buildPage`) | 6-14 |
| pick playlist and item | 3-8 |
| wait for every background picture decode before the first frame (`preparePageForFirstRender` -> `ThreadPool::wait`) | 60-64 |
Fixes, in order: (a) keep a built collection between visits instead of reading it again each time, and build Main's
menus once in the background after boot; (b) start decoding a menu's first-screen art while its tile is highlighted on
the menu before, so the wait is already done; (c) wait only for the pictures on the first screen, not every job in the
pool. Only 9 of 431 racing pictures are bigger than 1920x1080 (worst: Burnout Paradise logo 4096x2048, 5 MB), so
shrinking art helps little here.
**Done (2026-11-25):** RetroFE decodes pictures on at most 3 threads (`ThreadPool.cpp`, `min(3, cores)`), and this PC
has 16. Start-ArcadeMaster now sets `RETROFE_THREADPOOL_SIZE` to half the cores (3 to 8; a value set by hand wins).
Two runs each on RACE1: 91.4 / 93.1 ms at 3 threads, 83.8 / 83.8 ms at 8. A 9 % cut, so most of the wait is not
the thread count: fixes (a)-(c) above are still the way to get under 33 ms.
**Inside the 60 ms (timing build, 2026-11-25):** two passes of wait-then-prepare: waiting for background decodes
7 + 16 = 24 ms, then making textures and starting videos on the main thread 28 + 12 = 40 ms (pass 1 starts new loads,
so a second pass is needed). The bigger share is main-thread texture / video setup, so fix (c) becomes: show the page
once the list and backdrop are ready and make the remaining textures over the next frames, behind the page's enter
animation. (Test builds must be swapped in between the 15-minute update runs: Update-Cabinet puts the installed
build back within 15 minutes, by design.)
**Now:** entering a list spends 44 ms in `logic` on the main thread building the first item. Startup also waits for
the thread pool to drain (`ThreadPool::wait()` in RetroFE.cpp) before the menu draws.
**Do:** draw the menu with placeholders and fill items as they finish; the pool already exists.
**Expect:** no hitch on entering a list; earlier first picture at boot. **Check:** the hitch log on list entry; time
from launch to the first frame in the log.

### 6. A video pool instead of a new player per video (medium)
**Now:** every video makes a new GStreamer `playbin` (demuxer, decoder, queues, converters and two app sinks)
and tears it down when you move on. Scrolling through videos builds and destroys these all the time.
**Do:** keep 2-3 players and swap only the file (`uri` change at READY state); start the next item's video paused
in the spare one.
**Expect:** video starts at once on scroll; fewer stalls in `logic`. **Check:** time from item change to the first
video frame.

### 7. Text drawn once, not every change (small)
**Now:** text goes through SDL_ttf to a surface, then a texture, every time it changes (scrolling titles, the clock).
**Do:** a glyph atlas per font and size, with text drawn from it in one batch.
**Expect:** a small `draw` cut on text-heavy screens (tools, scores).

### 8. Modern display support (larger; after 1-3)
- **High refresh / VRR:** follow the screen's rate instead of fixed `fps = 60` (with item 1 this mostly comes free;
  matters for the 144 Hz cabinet monitors on the wish list).
- **HDR:** not useful for the art we have. Leave it.
- **SDL3:** better D3D12 and GPU APIs, but a big port (every SDL call, SDL_image / ttf / mixer). Only worth it after
  1-7, and only if upstream moves first.

### 9. Health and repair (small, fits our self-healing work)
- Crash minidumps exist: copy new `.dmp` files to `Z:\ArcadeMaster\reports\crashes\<machine>\` from Repair-ArcadeHealth
  so they're seen.
- meta.db: open it in WAL mode with `synchronous=NORMAL` (the fork sets no journal mode now, so each write waits on the disk).
- Write the hitch log summary (count and worst per menu) to the health report each boot.

### 10. Builds (needs James)
GitHub builds wait on `gh auth refresh -h github.com -s workflow` on RACE1 (BACKLOG 7). With them every cabinet
downloads the same tested build instead of compiling 435 MB itself.

## Ahead of LaunchBox / Big Box, Batocera / RetroBat and CoinOPS

James, 2026-11-25: "we need to be 1 step ahead of them and not cave to performance issues like LaunchBox", and
"make our system superior" over CoinOPS. Read from their own sites on 2026-11-25: launchbox-app.com,
batocera.org (+ changelog and wiki), coinops.pages.dev. RetroBat is the Windows build of Batocera, so they share a
column. CoinOPS is the closest rival: our RetroFE **is** their engine, so everything they ship on top of it is the
floor, not the goal.

What each one is:
- **LaunchBox / Big Box:** Windows launcher for your own collection. Big Box (the full-screen cabinet mode) is paid.
  Strong on library import and metadata (Games DB, "180,000+ titles"); built on .NET / WPF.
- **Batocera 44** (17 Nov 2026) / **RetroBat:** a whole Linux system you boot from USB; hundreds of systems, ~300
  devices. Strong on "plug in and play" controllers.
- **CoinOPS ARISE** (latest listed: Easter 2026): curated RetroFE builds (160-1,252 games) with hand-made art, 20-70
  themes each, a Customisation App. No auto-update: fixes come as new 100 GB builds.

| Feature | Big Box | Batocera / RetroBat | CoinOPS | ArcadeMaster today | Plan |
|---|---|---|---|---|---|
| Controllers set up for each emulator automatically | Premium "controller automation" | **yes**, at each launch | pads + encoders "out of the box", fixed maps | boot and plug / unplug: TeknoParrot, Dolphin, MAME, Supermodel, Model 2, Cemu and the FFB plugin follow renumbered USB devices | **A1** (step 1 done) |
| New controller set up on screen | no | yes ("map a controller") | no (edit controls.conf) | no | **A2** |
| In-game menu | Premium pause screens | Control Center on hotkey + button; hotkey combos | MAME's TAB menu | exit combo only | **A3** |
| Wheels, pedals, force feedback | no | yes, growing (Logitech TrueForce, MOZA, FFB on several emulators) | no | **yes**: per-game wheel bindings, FFB device repair, clutch / handbrake, flight on a wheel | keep ahead: per-game force strength |
| Bass shakers / tactile | no | no | no | **yes** (VoiceMeeter routing, strength in the menu) | SimHub telemetry |
| Panel lights | LEDBlinky (free) | LEDSpicer | none | own LED engine (BACKLOG 2a) | keep ahead |
| 4-way / 8-way stick switching | no | no | **yes** (ServoStik, GRS by game) | pedestal ServoStik through RetroFE | match |
| Smoothness with video and big lists | weak (WPF; slows with videos) | good | good ("DX11, hardware video", "70% less RAM") | good, same engine + patches 0012-0016 | items 1-7, **A4** |
| Auto update | in-app updater | from the menu | **none** (re-download builds) | **every 15 min** from main, GitHub builds next | keep ahead |
| Repairs itself | no | partly (configs at launch) | "Restore Defaults.bat" | **yes**: health check, exe hash, FFB, wheel bindings, update task | keep ahead |
| Game art and info | **Games DB, automatic** | scraper | hand-made, no scraper | catalog, stories, clips, low-res finder | **A5** |
| Attract mode (idle showcase) | not on their site | screensaver | **yes**, themed | RetroFE's own attract mode | **A8** tune |
| Hi-scores | MAME leaderboards | no | local + online (iScored, QR, Discord) | engine has it (iScored, QR) | **A9** turn on |
| Achievements | RetroAchievements (free) | RetroAchievements | no | no | **A6** |
| Save backups | Vault for RetroArch, Dolphin, PCSX2 | saves folder | no | no | **A10** |
| Play time, most played | yes, synced between installs | yes | no | RetroFE last-played list | **A10** |
| Filter by controls / orientation | no | no | **yes** (8-way, 4-way, trackball, gun, twin stick, TATE) | menus by control type (All Trackball, All Twin Stick...) | match + filter in menu |
| Settings without editing files | Big Box options | menus + web server | Customisation App (desktop) | **Tools menu on the cabinet** | **A7** phone page |
| Music in the menu | yes | yes | yes (mixtapes) | layout sounds only | **A11** |
| Emulator set up for you | **yes** ("downloads it and sets it up") | built in | built in | built in (our layout) | n/a |
| Second screen / marquee | Premium marquee | no | thin / 9:16 marquee themes | pedestal touch screen, marquees | keep ahead |

Where we already win: real cabinet hardware (wheel, FFB, shakers, panel, lights), self-repair and updates, and
knowing each cabinet (cabinet.json) so menus show only what this cabinet can play. Where we lose today: controllers on
games other than TeknoParrot / Dolphin / MAME, an in-game menu, automatic art, achievements, save backups.

### A1. Controllers set up at every launch (the RetroBat / Batocera "configgen" idea, done our way)
At each game start (RetroFE's launcher hook, the same one AmPanel already answers with `choose <game>`), a fast
step (budget 150 ms) reads what is plugged in now and writes that game's emulator input settings: player order,
wheel vs pad vs stick, force feedback device. TeknoParrot, Dolphin and MAME reuse today's tools; then RetroArch,
PCSX2, Supermodel, Flycast, Model 2. Anything a person set by hand wins (same rule as Set-FlightOnWheel).
**Ahead of them:** we know the cabinet (cabinet.json: wheel, clutch, handbrake, shakers, panel) and the game's real
controls (catalog), so we map a wheel to a driving game and a stick to a fighter, not just "pad 1".

### A2. On-screen controller setup
New device with no known layout: RetroFE shows "New controller: press A", walks the buttons, saves an SDL mapping line
to `gamecontrollerdb.txt` and to `cabinet.json`, then A1 uses it everywhere. Needs a RetroFE patch (a setup page) and
our hot-plug listener to open it.

### A3. In-game menu
A light overlay process (not WPF) on a hotkey combo (e.g. Start + Select held 1 s, or a wheel button pair): pause,
save / load state where the emulator allows, show the controls card we already draw, exit to the menu. Must open in
under 200 ms and never steal focus from games that crash when they lose it (tested per emulator).

### A4. Speed promises, checked every build
Written as tests, not hopes, in Test-ArcadeMaster: boot to the first menu frame, 60 fps held while scrolling with
video (no hitch over 33 ms on a warm cache), video starts within 150 ms of landing on a game, game launch within 1 s
of pressing start (before the emulator's own load). The perf log already gives these numbers; the test reads them.

### A5. Art and info filled in by itself
For games without art or a story: look up an open database (ScreenScraper / TheGamesDB / IGDB, with James's own
account keys, nothing personal sent), download to the catalog's art folders, and mark it auto so owner text wins.

### A6. RetroAchievements
RetroArch has it built in; a Tools setting for the account and an achievements card on the game screen.

### A7. Settings from a phone
A small local web page (cabinet network only) showing health, cabinet settings and the board, using the same
Set-CabinetSettings / Invoke-CabinetTool steps the Tools menu runs.

### A8. Attract mode that sells the cabinet
After a few idle minutes: cycle racing / flight games' clips (ours, 720p) with the story text, never retro filters.
Any wheel turn or pedal press ends it.

### A9. Hi-scores on
The engine already has iScored and QR code tables (the reloadableGlobalHiscores tag). Turn them on in our layout for
games that have scores, and show the table on the launch screen.

### A10. Play time and save backups
Count play time per game from the launcher hook (start / exit), feed "Most played" and "Recently played" playlists,
and copy save folders (RetroArch, Dolphin, PCSX2, TeknoParrot) to the NAS after each game, keeping 5 versions.

### A11. Music in the menu
Optional menu music per collection (the cabinet's own tracks), quieter during video, off by a Tools switch.

### Order
Items 5 (list entry, measured 100-136 ms) and 3 (cache) first, because speed is the promise. Then A1 (the biggest gap), A4 (lock the speed in),
A3, A2, A10, then A5-A11. Each is its own PR with before/after numbers.

## Order of work

1. Item 1 (vsync), measure: a settings change and a check of the pacer, one PR.
2. Item 3 (cache limit) and item 4b (preload neighbours): fork patches, one each.
3. Item 2 (zero-copy video): its own patch with a fallback, tested on RACE1 (NVIDIA) and the pedestal.
4. Items 4a/4c, 5, 6, 7 as the hitch log points at them.

Fork patches go in `retrofe\patches\` (next number after 0016). The pedestal owns 0014 onward and builds them; RACE1 and
RACE2 pick each build up by themselves (Update-Cabinet).
