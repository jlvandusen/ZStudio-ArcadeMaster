# RetroFE input extensions: touch, wheel, trackball, spinner, lightgun

Patch: `retrofe/patches/0002-arcademaster-touch-pointer-input.patch` (on top of 0001; both applied by `retrofe/Build-RetroFE.ps1`).

## Why

The CoinOPS build had no working touch input: `TouchDragHandler` was compiled in but never created, and no `controls.conf` token mapped to it. Its `MouseAxisHandler` was an empty stub, so trackballs and spinners (which Windows sees as a mouse) could not scroll. Mouse wheel was not supported at all. Touches were also turned into fake mouse clicks by SDL, so a `mouseButtonLeft` binding would double-fire on a touchscreen.

## What was added

`Control/PointerInput.{h,cpp}` is one shared recogniser. `UserInput` feeds it every SDL event and ticks it once per frame. `Control/GestureHandler.h` binds one gesture to one RetroFE action. Gestures go in `controls.conf` next to keys and joystick inputs, comma-separated as usual:

| Token | Fires | Typical use |
|---|---|---|
| `touchTap` | short, still touch (≤ 300 ms) | select (kiosk) |
| `touchDoubleTap` | two taps ≤ 350 ms apart at the same spot (the first tap also fires `touchTap`) | select when single tap is used for something else |
| `touchLongPress` | one finger held still ≥ 650 ms (fires while held; no tap on release) | favourites / random / menu |
| `touchTwoFingerTap` | 2+ fingers down briefly; no single taps leak through | back |
| `touchSwipeUp/Down/Left/Right` | fast flick (≥ 12% of screen within 450 ms), fires on release | page / letter jumps, back |
| `touchDragUp/Down/Left/Right` | finger held ≥ 5% away from where it touched; acts like a **held key**, so RetroFE's scroll acceleration applies | scroll |
| `touchTapLeft/Right/Top/Bottom/Center` | tap in that third of the screen (fires together with `touchTap`) | kiosk zones: left = prev page, right = next page |
| `mouseWheelUp/Down/Left/Right` | each wheel notch | scroll |
| `mouseAxisX-/X+/Y-/Y+` (aliases `mouseX±`, `mouseY±`, `spinnerLeft/Right`, `trackballUp/Down/Left/Right`) | relative motion: each `mouseAxisStep` counts re-arms a short hold. A nudge moves one item; a spin is a held key | trackball / spinner scroll |
| `mouseButtonLeft/Right/Middle/X1/X2` (existing) | mouse or lightgun buttons; now ignores touch-synthesised clicks | lightgun trigger = select, offscreen = back |

Discrete gestures become a 90 ms "key tap" pulse, so a gesture made during an animation is never lost. Drag and axis gestures behave like held keys. One-shot actions still respect the existing 100 ms debounce.

### Tunables (`controls.conf`, all optional)

| Key | Default | Unit |
|---|---|---|
| `touchPulseMs` | 90 | ms |
| `touchTapMaxMs` | 300 | ms |
| `touchDoubleTapMs` | 350 | ms |
| `touchLongPressMs` | 650 | ms |
| `touchSwipeMaxMs` | 450 | ms |
| `touchMoveTolerance` | 0.03 | fraction of screen a "still" finger may wander |
| `touchSwipeMinDistance` | 0.12 | fraction of screen |
| `touchDragDeadzone` | 0.05 | fraction of screen before drag-scroll starts |
| `mouseAxisStep` | 30 | mouse counts per step (raise for high-DPI trackballs) |
| `mouseAxisHoldMs` | 120 | ms each step holds the key |

Set `log = ALL` to see `[Pointer] finger down/up`, `wheel` and `gesture ...` lines when tuning a new screen or controller.

## Ready-made profiles: `retrofe/controls/*.conf`

| File | Cabinet |
|---|---|
| `controls-racing-wheel.conf` | G29-style wheel + pedals + keyboard fallback (this machine) |
| `controls-touch-kiosk.conf` | touchscreen only |
| `controls-trackball-spinner.conf` | trackball / spinner panels |
| `controls-lightgun.conf` | Sinden / Gun4IR / AimTrak (guns are absolute mice: trigger = select, offscreen = back) |

They can be combined by copying lines: every action accepts any mix of inputs.

## Verified (2026-11-22, real Windows touch injection via `InjectTouchInput`, no touchscreen needed)

| Input | Recognised | RetroFE result |
|---|---|---|
| finger drag up 30% + hold | DragUp | list scrolled (ArcticThunder → DeadHeatRiders) |
| finger held 1 s | LongPress | random jump (→ H2Overdrive) |
| wheel down ×3 | WheelDown ×3 | scrolled (→ IDTA) |
| relative mouse motion (trackball) | AxisY+ | scrolled (→ SR3) |
| tap left third / double tap centre / fast flick / two-finger tap | Tap+TapLeft / DoubleTap / SwipeUp / TwoFingerTap | all recognised; no crashes |

Not verified: a physical touchscreen, a physical trackball/spinner, or lightguns.

## Second screen: pedestal / marquee touchscreen (patch 0003)

A second display, e.g. on a 4-player pedestal with a USB touch panel, becomes **RetroFE screen 1**. It's both an output (marquee banner, game header) and an input (touch buttons).

| Piece | What |
|---|---|
| `tools/Get-CabinetDevices.ps1` | records `displays` (resolution, primary) and `touchScreens` in `cabinet.json` |
| `tools/Set-RetroFEScreens.ps1` | `numScreens = 2`; screen 0 = primary display, screen 1 = the other display at its native resolution. Backs up `settings.conf`; `-Single` reverts. |
| `layouts/ArcadeMaster/layout - 1.xml` | game lists: the selected game's **logo as a marquee over its own fanart**, title, **PLAYERS / CONTROLS / YEAR / MAKER** header (from the catalog metadata), touch bar |
| `layouts/ArcadeMaster/collections/Main/layout/layout - 1.xml` | main menu: the highlighted collection's neon logo + emblem over its games' fanart, touch bar |
| `retrofe/controls/controls-pedestal-4p.conf` | I-PAC panel (P1 navigates, any Start selects) + the touch bar on screen 1 |

**Per-screen touch tokens:** `touch<N><gesture>` only reacts to touches on RetroFE screen N, e.g. `touch1Tap`, `touch1SwipeUp`, `touch1LongPress`. Plain `touchTap` reacts to any screen. RetroFE resolves the screen from the window under the finger, so Windows must map the USB digitizer to the right display **once**: *Control Panel → Tablet PC Settings → Setup*, or `MultiDigiMon.exe -touch`.

**Touch buttons (region taps):** `touch[N]Column<c>of<n>[Row<r>of<m>]` fires when a tap lands in that cell of a column/row grid. The second-screen layout's bar is the bottom third, split in five:

| Cell | Button | Action |
|---|---|---|
| `touch1Column1of5Row3of3` | BACK | back |
| `touch1Column2of5Row3of3` | PREV | up |
| `touch1Column3of5Row3of3` | START | select |
| `touch1Column4of5Row3of3` | NEXT | down |
| `touch1Column5of5Row3of3` | RANDOM | random |

Verified with injected touches (screen 0 standing in on this single-display machine):
- A screen-0 tap did **not** fire a `touch1Tap` binding.
- `touch0Column4of5Row3of3` scrolled.
- `touch0Column5of5Row3of3` did a random jump.

The second-screen layouts were previewed on screen 0 with real data, e.g. Ballistics: logo, fanart, *PLAYERS 1 · CONTROLS wheel · YEAR 2009 · MAKER TrioTech*.

**Not verified** (needs the pedestal hardware): a real second display, Windows digitizer-to-display mapping, and the layout at the pedestal screen's actual resolution. If that screen isn't 16:9, add a ratio-specific file such as `layout 16x10 - 1.xml`.

## Force feedback in the frontend (patch 0004)

The wheel is part of the UI. Opt in with `settings.conf`:

```
ffb = yes
ffbDevice = G29        # name substring; default = first wheel-like FFB device
ffbStrength = 75       # overall gain %
ffbCenter = 35         # centring spring while browsing (0 = off)
ffbDamper = 12         # light resistance (0 = off)
ffbTick = 45           # detent per item scrolled, pushed in the scroll direction
ffbTickMs = 35
ffbThunk = 60          # "gear change" when a collection opens
ffbSelect = 55         # rumble on select
ffbLaunch = 85         # rumble when a game starts
```

| Moment | Feel |
|---|---|
| browsing | centring spring + damper. If the device refuses a spring, its autocentre is used. |
| each item scrolled | short constant-force tick left/right (rate-limited to one per tick length on fast scrolls) |
| entering a collection | heavier thunk |
| select | short sine rumble |
| game launch | rumble, then the device is **released**. DirectInput FFB is exclusive, so the game (TeknoParrot FFB plugin, emulators) gets the wheel to itself. It's re-acquired when the game exits. |

Robustness:
- FFB is opened **from the joystick RetroFE already has open**. A second independent DirectInput open fails with "Resetting device".
- Only effects the device reports are created.
- All requests are flags executed on the main thread once per frame (scrolling can run on worker threads).
- Forces stop at exit.

Verified on this cabinet's **Logitech G29** (2026-11-22):
- opened via the shared joystick handle
- spring, damper, ticks and rumble created
- a test launch showed *released* before the program ran and *re-acquired* when it exited
- frame timing unchanged with FFB running

## Performance telemetry (patch 0004)

`perfLog = N` logs every N seconds: `frames | frame ms p50 / p95 / p99 / max | hitches (> 2x target)`.

This cabinet, CoinOPS build + ArcadeMaster layout, while scrolling and opening collections with FFB on:

`300 frames in 5.0s | p50 16.67 p95 16.67-16.80 p99 16.8-17.1 max ≤ 17.3 | hitches 0`

That's a locked 60 fps with no dropped frames.

## Next

1. **Tap-to-pick:** tap a visible game in the list to scroll to it, and tap it again to launch. This needs hit-testing in `ScrollingList`; the same code gives lightgun aim-to-select.
2. **On-screen touch buttons** in the layout (Back / Favourite / Random) for kiosks without any physical controls.
3. Optional haptic/FFB "tick" on scroll for wheels (outside RetroFE, via the wheel helper).
