# Tactile feedback: bass shakers for every game

**Goal:** you feel the game through the seat and platform in every game type, not only the sims that have native support: rumble strips, engine and exhaust, acceleration, gear changes, landings and impacts.

**Hardware:**
- one or more tactile transducers (bass shakers) on the seat or platform
- an amplifier
- one PC sound output that carries only the shaker signal: a cheap USB sound card is best, because the cabinet's speakers keep their own output

## Two sources, so that every game is covered

| Games | Source | What you feel |
|---|---|---|
| PC racing with telemetry: DiRT 3/4/5/Showdown, GRID / 2 / Autosport / 2019, F1, Wreckfest, Project CARS, American & Euro Truck Simulator | **Telemetry** through SimHub "ShakeIt Bass Shakers" | Each effect on its own: rumble strips per wheel, engine RPM, gear-shift kick, road texture, wheel slip, ABS, impacts, landing after a jump |
| Everything else: TeknoParrot arcade PC games, MAME, Sega Model 2/3, Triforce, GameCube/Wii (Dolphin), and PC games without telemetry (Burnout, Crazy Taxi 3, NASCAR Heat 5, V-Rally 4, Road Fighters 3D), plus flight and light-gun games | **Game sound**: the low end (about 20-80 Hz) of the game's own audio, mirrored to the shaker output | Engine rumble, crashes, explosions and gunfire, rumble strips that have a sound |

On this cabinet that's 16 PC racing games, and the other 87 racing games run on sound.

## What is done

- `tools\tactile\Set-GameTelemetry.ps1` turns on the telemetry output of the Codemasters games (DiRT, GRID, F1). The older ones were pointed at a D-BOX seat (`ip="dbox"`) and are now pointed at this PC with the full packet (`extradata="3"`). Backups are kept as `*.am-telemetry.bak`. On DESKTOP-RACE1 that covers DiRT 3, DiRT 4, GRID 2, GRID Autosport, GRID 2019 and F1 22 (2026-11-24).

## Still to do (needs the hardware or an OK)

1. **Shaker output:** decide which sound output feeds the amplifier. The health check will then confirm the output is present.
2. **SimHub:** install it (free; winget `SHWotever.SimHub`). Enable ShakeIt Bass Shakers on the shaker output, using one shared profile kept in the repo for every cabinet. The launcher starts SimHub hidden at boot, the same way as the Stream Deck helper.
3. **Sound-driven games:** mirror the game audio to the shaker output through a low-pass filter. VoiceMeeter is already installed, and Equalizer APO on the shaker output is the alternative. While SimHub is driving a telemetry game, the sound path is turned down so the two don't double up.
4. **Tools menu:** add a "Tactile On-Off" switch and a strength setting, plus a health-check line for the shaker output.
