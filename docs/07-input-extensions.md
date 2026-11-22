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

## Next

1. **Tap-to-pick:** tap a visible game in the list to scroll to it, and tap it again to launch. This needs hit-testing in `ScrollingList`; the same code gives lightgun aim-to-select.
2. **On-screen touch buttons** in the layout (Back / Favourite / Random) for kiosks without any physical controls.
3. Optional haptic/FFB "tick" on scroll for wheels (outside RetroFE, via the wheel helper).
