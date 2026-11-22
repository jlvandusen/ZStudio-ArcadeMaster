# Interface and performance

## Done and measured (2026-11-22)

| Change | Effect |
|---|---|
| CoinOPS RetroFE 2504.2 build (threaded media, file cache, D3D11, metaLock) | launch → menu **0.71 s**, from 4–9 s on stock 0.10.33 on HDD |
| Matching GStreamer 1.24.13 + out-of-process plugin scanner; frei0r and PacDrive excluded | no more crashes on startup |
| Hardware video decode (`HardwareVideoAccel=true`) | `d3d11h264dec` on the GTX 1650 instead of CPU `avdec_h264` |
| Frontend on SSD, games stay on HDD | layout load 6 s → 1 s (stock build) |
| Background video re-encoded (292 MB 1080p 8 Mbps → 31.6 MB 540p 1 Mbps; shown at 10% alpha) | stock build: menu 3 s → 1–2 s |
| Null guards in RetroFE (empty collection scroll/select), crash log symbolised, no modal crash dialog | cabinet never sits on a "click OK" box |

## Interface: ArcadeMaster layout

Built so far:
- **The Real Z Studios boot banner**: `splash.xml`, held 3.5 s (`minShowTime`), with zoom-in, neon flicker and glow bloom.
- **Synthwave stage**: gradient sky, striped sun with a pulsing glow, mountain ridges, stars, and an **animated neon grid floor** (seamless 1.6 MB video loop that rushes toward the player).
- **Per-collection instrument cluster** (theme slots, `themes.json`):
  - Racing: steering wheel with a *driving line* idle (varied angles, easing and pauses, not a left/right metronome). Snap-turn on scroll; 720° spin on launch. The speedo floors it on scroll and settles into an idle flutter; the tacho bangs the limiter and drops like an upshift.
  - Flight: yoke, plus an attitude indicator whose horizon rolls and pitches behind a fixed bezel, a HUD reticle and drifting clouds.
  - Lightgun: crosshair, targets, muzzle-flash burst.
- Speed-line burst on every scroll, pulsing selection frame, video preview in a neon frame with fanart cross-fade, live title/manufacturer/year, scanlines and vignette.
- **Launch sequence**: blackout, game logo punch-in, wheel spin and speed-line warp.
- Main menu: big neon collection logos in a carousel; the cluster switches to the highlighted collection's theme.

Next ideas, in rough order of value:
1. **"How to play" control card per game**: generated from the wheelmap templates (which pedal is boost, which paddle is view, and so on). Shown on highlight after 2 s idle and on the launch screen.
2. **Attract mode**: after idle, full-screen video tour of random games with the logo overlay, with a "PRESS START" pulse. Any input returns to the menu.
3. **Playlists**: Favorites, Most Played (CoinOPS playCount), "Quick Race" (games that start straight into a race), and 2-player linked games (Daytona 3 Multi and others).
4. **Marquee / second monitor** support via `layout - 1.xml`, with the same theme on the cabinet marquee.
5. **Wheel-native navigation**: steer to scroll (with acceleration), paddles to page, gas to select, brake to go back. Configured in `controls.conf` from the captured device profile.
6. **Force-feedback "rumble" on scroll** using the G29 (small centring pulse). Needs a helper; nice-to-have.
7. **Hi-scores / best laps** panel where games expose them (CoinOPS hi2txt for MAME titles).
8. **Lightgun cabinets**: Sinden white-border overlay toggled per game, a gun-calibration screen in Settings, and trigger-to-select navigation.

## Performance: further work

| Item | Why | Effort |
|---|---|---|
| Re-encode all preview videos to H.264 720p ~2.5 Mbps faststart (LaunchBox 61 GB, DRIVE 7.8 GB) | faster preroll, hardware-decodable, about 80% smaller | script exists (GStreamer); batch it |
| Downscale artwork to display size (logos ≤ 600 px wide, fanart 1920×1080 JPEG q85) | less decode work, lower VRAM; LaunchBox images are 12 GB | batch script |
| Defender exclusions for `<ROOT>` (games, emulators, frontend) | real-time scanning of game executables and thousands of DLLs at launch is the biggest launch-time cost | installer step (admin) |
| `disablelastaccess`, 8.3 names off, Search indexing off on game volumes | faster enumeration of 1.3 M files | installer step (admin) |
| Power plan High performance; USB selective suspend off | consistent clocks; wheel never sleeps | installer step |
| Startup bloat off on cabinets (OneDrive, Teams, Edge auto-launch, G HUB only if required) | RAM/CPU free, no focus stealing | installer step |
| Free C: (0.6–3.5 GB free during today's session) | Windows updates and shader caches fail when C: is full | owner action |
| VHDX game packs (see 04) | deploy at sequential speed instead of 1.3 M small files | packaging step |
| Keep RetroFE resident during gameplay but release video/VRAM (CoinOPS `unloadSDL`/launch options) | instant return to menu | test per emulator |
