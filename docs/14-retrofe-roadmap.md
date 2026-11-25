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

### 1. Turn vsync on and let the screen set the pace (small, big win)
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
**Expect:** the cold-cache hitches below 33 ms (two frames). **Check:** the hitch log on the first scroll after a
reboot, before and after.

### 5. Loading a list on a thread, not the frame (medium)
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

## Order of work

1. Item 1 (vsync), measure: a settings change and a check of the pacer, one PR.
2. Item 3 (cache limit) and item 4b (preload neighbours): fork patches, one each.
3. Item 2 (zero-copy video): its own patch with a fallback, tested on RACE1 (NVIDIA) and the pedestal.
4. Items 4a/4c, 5, 6, 7 as the hitch log points at them.

Fork patches go in `retrofe\patches\` (next number after 0016). The pedestal owns 0014 onward and builds them; RACE1 and
RACE2 pick each build up by themselves (Update-Cabinet).
