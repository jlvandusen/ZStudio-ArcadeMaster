# 06 - Master input mapping (WheelMap)

`tools\wheelmap\WheelMap.ps1` is one tool for every cabinet. It:

1. **Detects** the attached controllers.
2. Runs a **capture wizard**: "turn the wheel fully left", "press gas", and so on.
3. Saves what it saw as a **device profile** (`profiles\<Name>.json`).
4. **Generates** emulator configs from that profile using per-game best-practice **templates** (`templates\*.json`).

Generated files go to a staging folder: `D:\ArcadeMaster\_staging\inputmap\<Name>\` by default. That folder mirrors the live paths, so you can diff staged against live. Nothing live changes until you run `-Apply -Commit`, and that backs up every file before overwriting it.

No downloads and no third-party executables. It uses PowerShell 5.1 plus a C# file compiled at runtime with `Add-Type`.

## Quick start

```powershell
cd D:\repos\personal\ZStudio-ArcadeMaster\tools\wheelmap
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Detect                  # what is attached, GUIDs, axes
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Monitor -Seconds 30      # live values, any key stops
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Capture -Name G29        # wizard -> profiles\G29.json
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Generate -Name G29       # -> D:\ArcadeMaster\_staging\inputmap\G29
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Apply -Name G29          # DRY RUN: lists what would change
powershell -ExecutionPolicy Bypass -File .\WheelMap.ps1 -Apply -Name G29 -Commit  # back up + write live configs
```

Other switches:

| Switch | What it does |
|---|---|
| `-Capture -Only Clutch,Handbrake` | Redoes just those steps and keeps the rest of the existing profile. |
| `-Capture -Devices "G29","handbrake"` | Limits capture to some devices: name substring, instance GUID or `VID:PID`. |
| `-Capture -Keyboard` | Also accepts keyboard keys, for I-PAC encoders or light-gun buttons in key mode. |
| `-Generate -Emulators teknoparrot,mame` | Generates only those emulators. |
| `-Generate -Games ID6,SR3` | Generates only those TeknoParrot games. |
| `-Generate -NoRematch` | Doesn't re-match profile devices against what is attached now. |
| `-Seed` | Writes a non-interactive starter profile. See "This machine (RACE1)" below. |
| `-ResolveTable` | Prints every TeknoParrot ButtonName and the logical control it resolves to, for reviewing templates. |
| `-Targets <file>` | Uses a different target list. Default is `targets\<COMPUTERNAME>.json`, then `targets\default.json`. |
| `-StageDir <dir>` | Uses a different staging root. |
| `-Apply -Force` | Writes even if a live file changed after `-Generate`. By default those files are skipped. |

## Files

```
tools\wheelmap\
  WheelMap.ps1                 entry point (Detect / Monitor / Capture / Seed / Generate / Apply / ResolveTable)
  lib\WheelMapInput.cs         DirectInput8 (COM vtable interop), XInput, RawInput list, GetAsyncKeyState
  lib\Common.ps1               JSON helpers, device enumeration + registry cross-check, staging/manifest
  lib\Capture.ps1              wizard + live monitor
  lib\Gen-TeknoParrot.ps1      TeknoParrot UserProfile generator, template resolver, -Seed
  lib\Gen-Others.ps1           Dolphin, Dolphin Triforce, Supermodel, MAME, Cemu, m2emulator, FFBPlugin
  templates\controls.json      logical control catalog + wizard steps (racing / flight / lightgun)
  templates\teknoparrot.json   ButtonName -> logical rules + per-game overrides/notes (52 games)
  templates\dolphin.json       GCPad/Wiimote/Triforce slot -> logical, per game
  templates\supermodel.json    Supermodel [ Global ] Input* keys -> logical
  templates\mame.json          reference-layout translation + per-game port overrides (23 games)
  templates\cemu.json          reference button translation
  templates\m2emulator.json    EMULATOR.INI [Input] keys; .input files are passed through
  templates\lightgun.json      light-gun rules/games for TeknoParrot (+ planned MAME/Supermodel keys)
  targets\DESKTOP-RACE1.json   where the live configs are on this cabinet
  targets\default.json         template for a new cabinet (copy to targets\<COMPUTERNAME>.json)
  profiles\G29.json            example profile for this machine (UNCONFIRMED seed, see below)
  dev\Test-CaptureLogic.ps1    offline tests of the capture detection with scripted fake devices
```

## How it works

### Device access

`lib\WheelMapInput.cs` calls `DirectInput8Create` from `dinput8.dll`. It drives `IDirectInputDevice8W` through `[ComImport]` interfaces. The enumeration callbacks need `[MarshalAs(UnmanagedType.FunctionPtr)]`; without it the call crashes.

- **Instance GUIDs.** DirectInput gives the exact instance GUIDs that TeknoParrot stores in `<JoystickGuid>` and Cemu stores in `<uuid>`. They are cross-checked against `HKCU\System\CurrentControlSet\Control\MediaProperties\PrivateProperties\DirectInput\VID_xxxx&PID_xxxx\Calibration\N\GUID`.
- **Data format.** The tool registers its own data format that is byte-identical to the first 176 bytes of `DIJOYSTATE2`. Offsets are therefore SharpDX `JoystickOffset` values, which is what TeknoParrot writes in `<Button>`:

  | Input | Offset |
  |---|---|
  | X | 0 |
  | Y | 4 |
  | Z | 8 |
  | RotationX | 12 |
  | RotationY | 16 |
  | RotationZ | 20 |
  | Sliders0 | 24 |
  | Sliders1 | 28 |
  | POV 0-3 | 32-44 |
  | Buttons0-127 | 48-175 |

- **Object offsets.** `EnumObjects` reports native offsets. They are translated to the format slot by `guidType`, so the axis names in `-Detect` match what TeknoParrot shows. For example: `X 'Wheel axis'`, `Y 'Accelerator'`, `RotationZ 'Brake'`, `Sliders0 'Y Axis'`.
- **Axis range.** Axes are set to 0..65535 with `DIPROP_RANGE`. This applies only to our own device instance and does not change calibration.
- **Background reading.** Devices are opened `NONEXCLUSIVE|BACKGROUND`, so the wizard reads the wheel while the console has focus and does not block games or G HUB.
- **Other inputs.** XInput slots come from `XInputGetState`. RawInput mice come from `GetRawInputDeviceList`, which is where mouse-mode light guns appear. Keyboard keys come from `GetAsyncKeyState`.

### Capture wizard rules

These rules are in `lib\Capture.ps1` and covered by `dev\Test-CaptureLogic.ps1`.

- **Baseline.** Each step starts with a 250 ms baseline. Buttons already held, such as a stuck switch, are ignored.
- **Axes.** The largest deviation across all open devices wins, so a wheel, a separate pedal box and a handbrake can all be captured in one run.
  - **Pedals** need about 40% of travel. The rest value is read after release, because G29 pedals report 32768 until they first move. Press direction (`+`/`-`), rest, pressed value and full-or-half travel are all recorded.
  - **Steering and sticks** need about 30% each way. "Left first" tells the tool whether the axis is inverted. The observed min/max is stored, with a warning if you didn't reach full lock.
- **Buttons.** A press must be seen twice at least 25 ms apart, which filters out a 1-poll glitch. The wizard then waits for release, so a press can't trigger the next step.
- **Hats.** Only exact cardinal directions are accepted; diagonals are ignored.
- **Handbrake.** It accepts either an axis or a button.
- **H-shifter.** Pressing `S` on the first H-shifter step skips the whole shifter group.
- **Wizard keys.** `S` skip, `R` redo, `B` back, `Q` quit and save, `Enter` accept the axis now, `M` (light gun) record this gun as mouse-mode.
- **Duplicates.** A duplicate binding (same input on two controls) only warns. Start and MenuSelect sharing a button is fine.
- **Resume.** With `-Only`, an existing profile is loaded and only the listed steps are redone. The old file is kept as `.bak`.

### Device profile (`profiles\<Name>.json`)

```json
{ "schema": "wheelmap.profile/1", "name": "G29", "cabinetType": "racing", "confirmed": true,
  "devices": [ { "id": "wheel", "productName": "Logitech G HUB G29 Driving Force Racing Wheel USB",
                 "instanceGuid": "32304790-...", "vid": "046D", "pid": "C24F", "diType": "Driving",
                 "enumIndex": 1, "forceFeedback": true, "sdlGuid": "0300..." },
               { "id": "handbrake", ... } ],
  "controls": {
    "Steering": { "device": "wheel", "type": "axis", "axis": "X", "offset": 0, "invert": false, "min": 0, "max": 65535 },
    "Gas":      { "device": "wheel", "type": "axis", "axis": "Y", "offset": 4, "direction": "-", "rest": 65535, "pressed": 0, "full": true },
    "GearUp":   { "device": "wheel", "type": "button", "button": 4 },
    "MenuUp":   { "device": "wheel", "type": "pov", "pov": 0, "dir": "Up" },
    "Start":    { "device": "keyboard", "type": "key", "vk": 49, "name": "D1" },
    "Clutch":   { "type": "none" } } }
```

- **Control types:** `axis`, `button`, `pov`, `key`, `mouse` (light guns) and `none` (skipped).
- **Device matching on generate.** When you generate on another cabinet, devices are re-matched by instance GUID, then VID/PID, then product name. This lets a profile move between cabinets with the same hardware.
- **Logical names** are defined in `templates\controls.json`:

  | Group | Controls |
  |---|---|
  | Racing | Steering, Gas, Brake, Clutch, Handbrake, GearUp, GearDown, Gear1-6, GearReverse, ViewChange, View2-4, Nitro |
  | Extras | Action1-3 |
  | Cabinet / menu | Start, Coin, Coin2, Test, Service, MenuUp/Down/Left/Right, MenuSelect, Exit |
  | Flight | Pitch, Roll, Yaw, Throttle, Fire, Missile, Special |
  | Light gun | AimX, AimY, Trigger, Reload, GunAction, Grenade, Pedal |

  The gun-2 copies of the light-gun controls are prefixed `P2.`.

### Templates

- **`A|B` fallback.** Any template value `A|B` means "A if the profile has it, otherwise B". BattleGear4's `Gear 3 / Shift Down` becomes `Gear3|GearDown`, so a paddle-only cabinet still shifts.
- **TeknoParrot** (`teknoparrot.json`):
  - Ordered regex rules on `<ButtonName>`, optionally limited by `<AnalogType>`, plus per-game `map` overrides.
  - `null` means "leave this binding untouched".
  - The generator starts from the live `UserProfiles\<id>.xml`, or from `GameProfiles\<id>.xml` for games that only LaunchBox lists. It rewrites `<DirectInputButton>`, `<BindNameDi>` and `<BindName>` for every mapped control and sets `Input API = DirectInput`. It keeps everything else: config values, XInput binds and unmapped buttons.
  - If the profile lacks a control, the existing bind is left as it is, not cleared.
  - Keyboard binds (`BindNameDi` "Keyboard ...") that point at a non-keyboard GUID are re-pointed to the SysKeyboard GUID `6f1d2b61-d5a0-11cf-bfc7-444553540000`.
  - Pedal binding:

    | Pedal travel | TeknoParrot fields |
    |---|---|
    | Rests at the centre | `IsAxisMinus` = press direction (the existing profiles' convention, e.g. `Driving Y -`) |
    | Rests at one end | `IsFullAxis=true`, and `IsReverseAxis` if pressing lowers the value |

- **Dolphin** (`dolphin.json`):
  - Each slot lists logical controls that are OR-ed together. Steering halves are written `Steering-`/`Steering+`.
  - Pedal forms depend on the build and travel:

    | Build / travel | Pedal expression |
    |---|---|
    | Current Dolphin, full travel | `` `Full Axis Y-` `` |
    | Older Triforce builds, full travel | `` `Axis Y+-` `` |
    | Half travel | `` `Axis Y-` `` |

  - A control on a second device is written device-qualified, e.g. `` `DInput/0/handbrake:Slider 0+` ``.
  - Profiles go to `User\Config\Profiles\GCPad|Wiimote\<KEY> <Name>.ini`. Only `PadProfile1`/`WiimoteProfile1` is set in `GameSettings\<ID>.ini`; existing `PadType` lines are kept.
  - Triforce `GCPadNew.ini` gets a new `[GCPad1]`; the other pads are kept.
- **Supermodel** (`supermodel.json`): Input keys are rewritten in `[ Global ]`, which is the only place Supermodel reads inputs. `JOYn` is the DirectInput enumeration order (`-Detect` shows `JOYn`). With `pedalStyle: auto`, half-travel pedals use `_NEG`/`_POS` and full-travel pedals use `_INV`. Also sets `InputSystem=dinput` and `ForceFeedback=1`.
- **MAME** (`mame.json`):
  - MAME needs the exact port tag/type/mask/defvalue. The base file is the live `cfg\<game>.cfg`, or else the previous owner's `controllers\MAME\G29\<game>.cfg`.
  - Ports whose type has a known meaning are replaced outright. These are START1, COIN1, PADDLE, PEDAL and PEDAL2/3, plus per-game ports such as gears.
  - Other JOYCODE tokens are translated through the reference G29 layout.
  - Unknown buttons stay on the same physical button, and the manifest lists them as `rawButtonsKept`.
  - `ctrlr\wheelmap.cfg` pins `JOYCODE_1..n` to the profile devices with `<mapdevice device="<instance GUID>">`. `mame.ini ctrlr` is set to `wheelmap`.
- **Cemu** (`cemu.json`): The previous owner's `G29.xml` is copied with `<uuid>`/`<display_name>` set to the captured wheel. Button ids below 32 are translated; axis ids are kept, with a warning if the axis layout isn't wheel X / gas Y / brake Rz. `gameProfiles\*.ini` gets `controller1 = <Name>`.
- **m2emulator**: Sets `EMULATOR.INI [Input] XInput=0 EnableFF=1 HoldGears=1`. Per-game `.input` files use an undocumented binary format and are passed through unchanged. It warns if the wheel is not DirectInput device #1.
- **FFBPlugin** (Boomslangnz): `DeviceGUID=` is set in every `FFBPlugin.ini` under the configured roots. That covers 22 TeknoParrot rom folders plus the MAME, Supermodel and m2emulator folders. The value is the SDL2 GUID of the wheel (bus/CRC/VID/PID); the name-CRC already used by the existing files is reused.

### Staging and apply

- **Output layout.** `-Generate` wipes and rebuilds `<StageDir>\<Name>\`. Each file sits at its live path with the drive letter as the first folder, for example `D:\ArcadeMaster\_staging\inputmap\G29\E\DRIVE Collection\emulators\TeknoParrot\UserProfiles\ID6.xml`.
- **Manifest.** `manifest.json` lists every file with its live path, generator, whether it differs from live, whether it is new, the live SHA1 at generate time, and a note. The note includes the controls bound and any controls not in the profile. The manifest also holds per-emulator reports and warnings.
- **Apply.** `-Apply` alone is a dry run.
- **Apply -Commit:**
  - Copies each changed file over the live one.
  - First makes `<live>.wheelmap-<timestamp>.bak`.
  - Skips any live file whose hash changed after `-Generate`, for example because it was edited in the emulator UI. `-Force` overrides this.

## Running it on a new cabinet

1. Copy `tools\wheelmap` to the cabinet. Copy `targets\default.json` to `targets\<COMPUTERNAME>.json` and fix the paths. Missing paths are skipped with a warning.
2. Start the vendor software first: G HUB, the Sinden software, and so on. Set the wheel to its PC/DirectInput mode with separate pedal axes; "combined pedals" off. Then run `-Detect`. Check that every device shows, that the registry line says `(matches)`, and note the `JOYn` order.
3. Run `-Monitor -Seconds 30` and move everything once. This confirms the axes move and nothing is stuck.
4. Run the capture for the cabinet type. Keep the console focused for the wizard keys; the controls are read in the background.

**Racing**

```powershell
.\WheelMap.ps1 -Capture -Name G29
```

Recommended physical layout. The wizard prints these as suggestions; whatever you press is what gets recorded.

| Logical | G29 suggestion | Notes |
|---|---|---|
| Steering | wheel (X) | Turn to full lock both ways; set 900° in G HUB first. |
| Gas / Brake / Clutch | pedals (Y / RotationZ / Sliders0 "Y Axis") | Must be separate axes. |
| GearUp / GearDown | right / left paddle (buttons 4 / 5) | Sequential games also use these for Hi/Lo. |
| Gear1-6, Reverse | Driving Force shifter (buttons 12-18) | Skip with `S` if there is no H-shifter. |
| ViewChange | Cross | |
| Nitro | Circle | |
| Action1 / Action2 | Square / Triangle | Item / jump / reset. |
| View2 / View3 | R2 / L2 | Sega VR2/VR3. |
| Start / Coin | Options / Share, or a button box | |
| Test / Service | R3 / L3 | Operator menus. |
| Menu Up/Down/Left/Right | D-pad (hat) | |
| MenuSelect | red-dial Return | |
| Exit | PS button | Front-end hotkey only. |
| Handbrake | separate analog handbrake | e.g. the MMJoy2 "handbrake" here. |

**Flight**

```powershell
.\WheelMap.ps1 -Capture -Name HOTAS -CabinetType flight
```

The steps are stick Roll/Pitch, optional Yaw, Throttle, Fire, Missile, Special, then cabinet buttons and the hat. The TeknoParrot flight games already have templates: After Burner Climax, Star Wars Battle Pod, MachStorm, Blazing Angels and Under Defeat.

**Light gun**

```powershell
.\WheelMap.ps1 -Capture -Name Sinden2P -CabinetType lightgun -Guns 2 -Keyboard
```

- **Gun steps.** Each gun is asked for aim X/Y, Trigger, Reload, Action and Grenade, then the cabinet buttons and pedal. Gun-2 controls are stored as `P2.<control>`.
- **Aiming by gun mode.** Joystick-mode guns (Gun4IR, or AimTrak in joystick mode) are captured as axes. For mouse-mode guns (Sinden default, AimTrak mouse mode), press `M` on the aim steps; the gun is recorded as `mouse`. `-Detect` lists RawInput mice and flags likely guns.
- **Gun buttons in key mode** need `-Keyboard`.
- **Generation.** `-Generate` switches to `templates\lightgun.json`: gun rules plus about 20 TeknoParrot gun games. Mouse-type aim is reported as not generated; see the limitations section.

5. Run `-Generate -Name <Name>` and review `manifest.json`. Diff a few staged files against live with WinMerge or `fc`.
6. Run `-Apply -Name <Name>` (dry run), then `-Apply -Name <Name> -Commit`. Test one game per emulator.

## This machine (RACE1)

### Detected

Validated non-interactively with `-Detect`, `-Monitor` and DirectInput state reads:

| JOYn | Device | Details |
|---|---|---|
| JOY1 | Logitech G HUB G29 Driving Force Racing Wheel USB | VID_046D&PID_C24F, type Driving, FFB yes, 25 buttons, 1 hat. Instance GUID `32304790-2e7c-11ec-8001-444553540000`; matches the registry key `VID_046D&PID_C24F\Calibration\0` and the GUID in the TeknoParrot profiles and `E:\Support\RACE1 Wheel GUID.txt`. Axes: X 'Wheel axis', Y 'Accelerator', RotationZ 'Brake', Sliders0 'Y Axis' (clutch). |
| JOY2 | "handbrake" | The unidentified VID_8888&PID_8888 device. It is an MMJoy2 board (USB serial `MMJOY2-20150706`) named "handbrake", type Supplemental, 1 axis (Sliders0), no buttons. Instance GUID `6a358b90-2e78-11ec-8001-444553540000`. This is the "Supplemental Sliders0" seen in TeknoParrot profiles. |
| (none) | XBOX Synthetic Gamepad Bus | No XInput pad is connected at the moment. The G HUB virtual pad is not active. |

At idle every G29 axis reads exactly 32768, including the pedals. Either the pedals rest mid-range in this G HUB mode, or the wheel hasn't sent a report since it was last touched. Only a capture can settle this. Pedal half or full travel changes how every emulator binding is written.

### `profiles\G29.json`

This is a **seed, `confirmed=false`**. Nobody touched the controls when it was made.

- **Axes** come from the DirectInput object names; rest values are idle readings.
- **Buttons and hat** come from the most common existing bindings across the 30 E: TeknoParrot UserProfiles plus START1/COIN1 in the owner's 23 MAME cfgs. Coin = button 11, Start = 10, paddles 4/5, shifter 12-17, Test/Service = 19/20, D-pad = hat.
- **Action1/Action2/MenuSelect** were left out because the existing profiles disagree. The disagreements are listed in the profile `notes`.

Replace it with a real capture: `.\WheelMap.ps1 -Capture -Name G29`. Answer `y` to overwrite; the seed is kept as `.bak`.

### Staged output

`D:\ArcadeMaster\_staging\inputmap\G29\` (generated from the seed). The `files` column is files staged; most differ from live because they were generated from the seed.

| Emulator | Files staged | What |
|---|---|---|
| TeknoParrot E: v1919 | 50 | 30 existing UserProfiles + 20 new ones for LaunchBox-listed games that have a GameProfile but no UserProfile here. New ones need the game exe set in TeknoParrotUI. |
| TeknoParrot E: Multi | 1 | Daytona3 |
| TeknoParrot D: v894 | 35 | Existing UserProfiles only; this is the install LaunchBox launches. |
| Dolphin | 8 | 4 profiles (MKDD, FZERO, AM, MKW) + 4 GameSettings |
| Dolphin Triforce | 3 | F-Zero AX, MKGP, MKGP2 `GCPadNew.ini` |
| Supermodel | 1 | `Config\Supermodel.ini` |
| MAME | 25 | 23 game cfgs + `ctrlr\wheelmap.cfg` + `mame.ini` |
| Cemu | 2 | `controllerProfiles\G29.xml` + MK8 gameProfile |
| m2emulator | 7 | `EMULATOR.INI` + 6 `.input` (all identical to live) |
| FFBPlugin | 1 | `WackyRaces\FFBPlugin.ini`; the other 27 already carry the right GUID |

### Problems found in the existing configs

Nothing live was changed. The staged output fixes items 1-3 and 5-7.

1. **The old GUID script broke keyboard and handbrake binds.** `E:\Support\UpdateGuid*.ps1` replaced every `<JoystickGuid>` in the racing UserProfiles with the wheel GUID, including keyboard and handbrake binds.
   - 22 keyboard binds in E: TeknoParrot point at the wheel, for example Start=Return and Test=F1 in Cars, ChaseHQ2 and D1GP. These cannot work.
   - The D1GP "Side Brake" and DirtyDrivin "Crank The Yank!" handbrake binds (`Supplemental Sliders0`) carry the wheel GUID, so the handbrake is dead in those games. D: BattleGear4Tuned has the correct handbrake GUID.
2. **D: TeknoParrot has bindings for devices that aren't here.** The D: install (v894) is the one LaunchBox uses. 203 bindings point at `abe2a820-426d-11ed-8005-...` and about 57 more at four other GUIDs; none of these devices is present. ID6, D1GP, DirtyDrivin and other games launched from LaunchBox therefore probably have no working wheel input.
3. **Bindings are inconsistent between games.** Coin is on button 6, 11 or 0. View Change is on 0, 1, 11 or hat-left. Test/Service sit on hat up/down in two games, which clashes with menu navigation. ID6 uses the `+` half for both pedals while 27 other games use `-`.
4. **The owner's controller sets have errors.**
   - `E:\DRIVE Collection\controllers\Supermodel\G29\Supermodel.ini` uses JOY2 for the wheel. The live file uses JOY1, which is correct for the current enumeration. Running `collections\Controller\roms\G29.bat` would revert it.
   - The owner's MAME cfgs contain French-locale hat tokens (`JOYCODE_1_COMMANDEDEPOUCEU/D`, French Windows "commande de pouce") in START1 and VOLUME ports of calspeed, crusnusa, crusnwld, offroadc, sf2049, sf2049se and sfrush. They don't resolve on this English Windows; the staged MAME cfgs translate them.
   - polepos2a has ACCEL/BRAKE swapped.
5. **Cemu `G29.xml` uses the wrong `<uuid>`.** It uses the SysKeyboard GUID and works only through the display-name fallback.
6. **WackyRaces has a different FFB GUID.** Its `FFBPlugin.ini` has `DeviceGUID=030000006d04...` (CRC 0000); the other 22 files use `03004ed76d04...`.
7. **Two TeknoParrot versions name the same BattleGear4 buttons the other way round.** v1919 has `Gear 3 / Shift Down`, `Gear 4 / Shift Up`; v894 has `Gear 3 / Shift Up`, `Gear 4 / Shift Down` and adds `Shift Left/Right`. The rules handle both.

## Per-game best-practice table (TeknoParrot)

Generated from `-ResolveTable` against the E: v1919 GameProfiles. Input names come from the GameProfile XMLs; none are guessed.

- **Source:** TP-E = has a UserProfile in E: TeknoParrot; LB = in the LaunchBox Arcade Racing/Flight lists.
- **FFB:** an `FFBPlugin.ini` exists in the game's rom folder, so force feedback depends on the plugin `DeviceGUID`.
- **Shifter:** when it says "H", an H-shifter makes the gear buttons matter. Otherwise the paddles are used.
- **"A or B"** means A if captured, else B.
- **Left untouched:** existing binds that are not overwritten, such as card readers, volume and cheats.

| Id | Title | Genre | Source | Shifter | FFB | Mapped (ButtonName = logical) | Left untouched |
|---|---|---|---|---|---|---|---|
| ArcticThunder | Arctic Thunder | Racing (snowmobile) | TP-E | paddles | FFBPlugin | Coin=Coin, Start=Start, Attack=Action1, View Change=ViewChange, Wheel Axis=Steering, Gas=Gas | Volume Up, Volume Down |
| Ballistics | Ballistics | Racing (sci-fi) | TP-E | paddles |  | Start/Booster=Start, Flip=Action1, Cooler=Action2, View=ViewChange, Wheel Axis=Steering, Throttle=Gas |  |
| Batman | Batman | Racing (combat) | TP-E+LB | paddles | FFBPlugin | Test=Test, Service=Service, Coin=Coin, Start=Start, Brake Button=Brake, Fire=Action1, Wheel Axis=Steering, Gas Axis=Gas | Volume Up, Volume Down |
| BattleGear4Tuned | Battle Gear 4 | Racing (H-shifter) | LB | H-pattern + clutch |  | Test=Test, Service=Service, Coin=Coin, Start=Start, View Change=ViewChange, Sidebrake=Handbrake, Gear 1=Gear1, Gear 2=Gear2, Gear 3 / Shift Down=Gear3 or GearDown, Gear 4 / Shift Up=Gear4 or GearUp, Gear 5=Gear5, Gear 6 / Reverse=Gear6 or GearReverse, Wheel Axis=Steering, Gas=Gas, Brake=Brake, Clutch=Clutch | Hazard, Overtake, Timer Start, Seat Switch 1, Seat Switch 2, Key |
| BlazingAngels | Blazing Angels: Squadrons of WWII | Flight | LB | - |  | Test=Test, Service=Service, Coin 1=Coin, Trigger (Primary Fire) / Start=Fire, Throttle Button (Closest Threat / Next Target)=Special, Missiles (Secondary Fire)=Missile, Hat Up/Down/Left/Right=Menu*, Joystick Analog X=Roll, Joystick Analog Y=Pitch, Throttle Axis=Throttle | Volume Up, Volume Down, Coin 2, Landing Gear, Throttle Brake Axis |
| Cars | Cars | Racing (kids) | TP-E | paddles |  | Test=Test, Service=Service, Coin=Coin, Boost / Start=Start, Flip=Action2, Jump=Action1, Wheel Axis=Steering, Gas=Gas, Brake Button/Pedal=Brake | Chatter, Volume Up, Volume Down |
| ChaseHQ2 | Chase H.Q. 2 | Racing | TP-E+LB | Hi/Lo | FFBPlugin | Test=Test, Service=Service, Coin=Coin, Start=Start, Wheel Axis=Steering, Gas=Gas, Brake=Brake, Shift Low=GearDown, Shift-Nitro=Nitro, Pato-Nitro=Action1 |  |
| CrazyRide | Crazy Ride | Racing | TP-E | paddles |  | Start=Start, Emergency Stop=Action1, Test / Test Menu Up=Test, Service / Test Menu Down=Service, Enter=MenuSelect, Wheel Axis=Steering, Gas=Gas, Brake=Brake |  |
| D1GP | D1GP Arcade | Racing (drift) | TP-E | paddles | FFBPlugin | Test / Service=Test, Start=Start, Coin=Coin, View Change=ViewChange, Side Brake=Handbrake, Shift Down / Test Menu Down=GearDown, Shift Up / Test Menu Up=GearUp, Wheel Axis=Steering, Gas=Gas, Brake=Brake | Save Card Insert/Remove |
| Daytona3 | Daytona Championship USA | Racing | TP-E | 4-speed H | FFBPlugin | Coin=Coin, Start=Start, Shift Up=GearUp, Shift Down=GearDown, Gear 1-4=Gear1-4, View Change 1=ViewChange, View Change 2=View2, View Change 3=View3, View Change 4=View4, Wheel Axis=Steering, Gas=Gas, Brake=Brake |  |
| Daytona3Single / Daytona3Multi | Daytona Championship USA Single / Multi | Racing | LB (D: UserProfile only) | 4-speed H |  | as Daytona3 (no GameProfile in either install; generated from the D: UserProfile) |  |
| DeadHeat | Dead Heat | Racing | TP-E | 4-speed H | FFBPlugin | Test, Service, Coin, Enter=MenuSelect, Menu Up/Down, View=ViewChange, Nitrous=Nitro, Shift Up/Down=GearUp/Down, Shift 1-4=Gear1-4, Wheel/Gas/Brake |  |
| DeadHeatRiders | Dead Heat Riders | Racing (bike) | TP-E | paddles | FFBPlugin | Test, Service, Coin, Enter=MenuSelect, Menu Up/Down, View Change=ViewChange, Nitrous=Nitro, Wheel/Gas, Brake (button input: pedal bound as digital) |  |
| DirtyDrivin | Dirty Drivin' | Racing (combat) | TP-E+LB | paddles | FFBPlugin | Test, Service, Start, Credit=Coin, Crank The Yank!=Handbrake or Action1, View=ViewChange, Wheel/Gas/Brake Axis | Volume Down, Volume Up |
| FNF | The Fast and the Furious | Racing | LB | 4-speed H |  | Start/Nitro=Start, Gear Shift 1-4=Gear1-4, Shift Up/Down, View1-3=ViewChange/View2/View3, Test, Service, Wheel/Gas/Brake | Tunes, Volume Up, Volume Down |
| FNFDrift | The Fast and the Furious Drift | Racing (drift) | TP-E+LB | paddles |  | Start, Shift Up/Down, Nitro, View1-3, Test, Left/Right=MenuLeft/Right, Wheel/Gas/Brake |  |
| FNFSB | The Fast and the Furious: Super Bikes | Racing (bike) | LB | paddles |  | Start / Nitro=Start, Shift Up=GearUp, View1=ViewChange, Test, Service, Wheel/Gas, Brake / Shift Down=Brake | Tunes, Volume Up, Volume Down |
| FNFSB2 | Super Bikes 2 | Racing (bike) | LB | paddles |  | Start / Accept PIN=Start, Nitro / Cancel PIN / Neon Color=Nitro, View / Bike Change=ViewChange, Shift / Bike Color=GearUp, Test, Left/Right, Wheel/Gas/Brake | Music / Change Biker, Menu Toggle Manual-Auto, Enter PIN |
| FNFSC | The Fast and the Furious SuperCars | Racing | TP-E+LB | 4-speed H |  | Test, Service, Coin, Start, View1-3, Gear Shift 1-4=Gear1-4, Shift Up/Down, Wheel/Gas/Brake | Music, Volume Up, Volume Down |
| FR | Ford Racing: Full Blown | Racing | TP-E+LB | paddles | FFBPlugin | Coin, Start, Wheel/Gas/Brake, Shift up/Down, View Change |  |
| GaelcoChampionshipTuningRace | Gaelco Championship Tuning Race | Racing | LB | paddles |  | Test, Service, Coin Chute 1=Coin, Coin Chute 2=Coin2, Shift Up / Menu Up=GearUp, Shift Down / Menu Down=GearDown, View Button=ViewChange, Start Button=Start, Wheel/Gas/Brake | Volume Up, Volume Down |
| GRID | GRID | Racing | LB | 6-speed H + R |  | Start, View Change, Reset Button=Action2, Shift Up/Down, Gear 1-6=Gear1-6, Gear Reverse=GearReverse, Wheel/Gas/Brake | Replay / Look Behind hacks |
| GtiClub3 | GTI Club | Racing | LB | paddles |  | Test, Service, Coin, Start, Shift Up/Down, Action Button=Action1, Select Button Up/Down/Left/Right=Menu*, Wheel/Gas/Brake |  |
| H2Overdrive | H2Overdrive | Racing (boat) | TP-E | paddles | FFBPlugin | Test, Service / Coin=Coin, Start, Boost=Nitro, View, Vol / Menu Up/Down=MenuUp/Down, Throttle Up Axis=Gas, Throttle Down Axis=Brake, Wheel |  |
| ID4Exp / ID5 / ID8 | Initial D Arcade Stage 4 / 5 / 8 | Racing (Initial D) | LB | 6-speed H (optional) |  | Test, Service, Coin, Start, Wheel/Gas/Brake, Shift up/Down, View Change, Menu Up/Down/Left/Right, Gear 1-6 |  |
| ID6 | Initial D Arcade Stage 6 AA | Racing (Initial D) | TP-E+LB | 6-speed H (optional; RealGearshift=1 in config) | FFBPlugin | as ID5 |  |
| IDTA | Initial D The Arcade (S3) | Racing (Initial D) | TP-E | 6-speed H (optional) | FFBPlugin | as ID5, gears named 1st..6th Gear; Wheel/Gas/Brake are Analog1/3/5 | Insert AIME Card, Force Retire |
| KODrive | K.O. Drive | Racing | LB | paddles |  | Test, Service, Coin, Wheel/Gas/Brake, Start / Item=Start |  |
| MKDX | Mario Kart Arcade GP DX | Racing (kart) | TP-E+LB | paddles | FFBPlugin | Test, Service, Coin, Start, Wheel/Gas/Brake, Item=Action1, Menu Up/Down, Enter Switch=MenuSelect, Mario Button=Action2 | Banapass Card Entry |
| NicktoonsNitro | Nicktoons Nitro Racing | Racing (kart) | TP-E | paddles |  | Test, Start, Fire / Start=Action1, View, Menu Up/Down/Left/Right, Wheel/Gas/Brake |  |
| NitroplusBlasterz | Nitro+ Blasterz | Fighting (not a wheel game) | TP-E | - |  | Test, Service 1, Coin 1/2, Player 1 Start, Player 1 directions=Menu* | all attack buttons, Player 2, card |
| or2spdlx | OutRun 2 SP SDX | Racing | TP-E+LB | paddles (Hi/Lo) |  | Test, Service, Coin 1/2, Start, Wheel/Gas/Brake, View Change, Gear Shift Up/Down |  |
| R-Tuned | R-Tuned: Ultimate Street Racing | Racing | TP-E | paddles | FFBPlugin | Test, Service, Coin, Start, Wheel/Gas/Brake, Shift Up/Down, View Change, Boost Button Left/Right=Nitro | Player Enter Card |
| segartv | SEGA Race TV | Racing | TP-E+LB | paddles | FFBPlugin | Test, Service, Coin 1/2, Start, Wheel/Gas/Brake, View Change, Gear Shift Up/Down, Boost=Nitro |  |
| SnoCross | Winter X Games SnoCross | Racing (snowmobile) | LB | paddles |  | Start / Accept PIN=Start, Nitro / Cancel PIN=Nitro, Snowballs=Action1, View, Credits=Coin, Test, Left/Right, Wheel/Gas/Brake | Enter PIN |
| SR3 | SEGA Rally 3 | Racing (rally) | TP-E+LB | paddles | FFBPlugin | Coin, Start, Wheel/Gas/Brake, Shift up/Down, View Change, Handbrake=Handbrake |  |
| SRC | Sega Racing Classic | Racing | LB | 4-speed H |  | Test, Service, Coin, Start, Wheel/Gas/Brake, View Change Red/Blue/Yellow/Green=ViewChange/View2/View3/View4, Gear 1-4, Gear Shift Up/Down |  |
| SRG | Storm Racer G | Racing | TP-E | paddles | FFBPlugin | Start, Boost=Nitro, View (Reverse on Track Select)=ViewChange, Test Menu (on Title Screen)=Test, Coin, Menu Up/Down/Left/Right, Wheel/Gas/Brake | Debug Menu |
| SSASR | Sonic & SEGA All-Stars Racing | Racing (kart) | TP-E+LB | paddles | FFBPlugin | Test, Service, Coin, Start, Wheel/Gas/Brake, Item=Action1 |  |
| StarWars | Star Wars: Battle Pod | Flight | LB | - |  | Test, Service, Start, Throttle=Throttle, Analog X=Roll, Analog Y=Pitch, View Change, Menu Up/Down, Enter Switch=MenuSelect, Weapon Trigger=Fire, Weapon Button=Missile | Throttle Brake |
| MS | MachStorm | Flight | LB | - |  | Test, Service/Coin=Coin, Throttle, Analog X=Roll, Analog Y=Pitch, Menu Up/Down, Enter Switch=MenuSelect, Machine Gun=Fire, Missile=Missile | Throttle Brake |
| abc | After Burner: Climax | Flight | LB | - |  | Test, Service, Coin 1/2, Start, Joystick Analog X=Roll, Joystick Analog Y=Pitch, Throttle Lever=Throttle, Gun Trigger=Fire, Missile Trigger=Missile, Climax Switch=Special | Throttle Brake |
| UDX | Under Defeat HD+ | Shmup (flight list) | LB | - |  | Test, Service 1, Coin 1/2, Player 1 Start, Player 1 directions=Menu*, Button 1=Fire, Button 2=Missile, Button 3=Special | Player 2 |
| SWDC | Sega World Drivers Championship | Racing (drift) | TP-E | paddles | FFBPlugin | Test, Service, Coin, Start, Wheel/Gas/Brake (Analog1/3/5), View Change Button, Menu * Button, Shift Up (P2ButtonStart)/Down | Insert AIME Card, coloured buttons |
| VirtuaRLimit | Valve Limit R | Racing | LB | paddles |  | Test, Service, Coin, Start, Wheel/Gas/Brake, Nitro, View Change, Side Brake=Handbrake, Shift Up/Down |  |
| WackyRaces | Wacky Races | Racing (kart) | TP-E | paddles | FFBPlugin | Test, Service, Coin, Start, Wheel/Gas/Brake (Analog4/6/8), View Change, Lever=Action1 |  |
| WastelandRacers | Wasteland Racers 2071 | Racing | TP-E | paddles (Hi/Lo) | FFBPlugin | Test, Coin, Start, Boost=Nitro, Gear=GearUp, View, Wheel/Gas/Brake | Cheat1-4 |
| WMMT5 / WMMT6R | Wangan Midnight Maximum Tune 5 / 6R | Racing (Wangan) | LB / TP-E | 6-speed H (optional) | WMMT6R: FFBPlugin | Test, Service, Coin, Wheel/Gas/Brake, Test Menu Up/Down=MenuUp/Down, Enter Switch=MenuSelect, Gear Shift 1-6, Gear Shift Up/Down, Perspective Switch Button=ViewChange | Interuption Switch Button |

Light-gun TeknoParrot games covered by `templates\lightgun.json` (untested): HOTD4, HOTD4SP, HOTDEX, HOTDSD, LGJ, LGJS, LGI, LGI3D, Gunslinger, GSEVO, AliensExtermination, 2Spicy, DarkEscape4D, JurassicPark, MIB, LostLand, BugBusters, HauntedMuseum and HauntedMuseumII.

### Other emulators: per-game notes

| Emulator | Game | Mapping |
|---|---|---|
| Dolphin GC | Mario Kart: Double Dash (GM4E01) | A = Gas (or MenuSelect), B = Brake, L/R = paddles (drift/hop), X/Y = Action1/Action2 (item), Z = Nitro (swap), Start, wheel on main stick X, menus on hat + main stick Y. PadType 8 (steering wheel) is kept. |
| Dolphin GC | F-Zero GX (GFZE01) | A = Gas, B = Brake, Y = Nitro (boost), X = Action1, Z = Action2, L/R = paddles. |
| Dolphin GC | Auto Modellista (GAUE08) | Gas/Brake on main stick up/down, as in the owner's working file; paddles on L/R. |
| Dolphin Wii | Mario Kart Wii (RMCE01, Classic) | A = Gas, B = Brake, R = right paddle (drift), L = Action1 (item) or left paddle, + = Start, - = Coin or Action3. Sideways Wiimote and Classic extension. |
| Dolphin Triforce | F-Zero AX | Pedals on A/B, boost on Y, paddles on L/R-Analog. |
| Dolphin Triforce | Mario Kart Arcade GP 1/2 | Gas on R-Analog, brake on L-Analog, item on A, Mario/cancel on B. |
| Supermodel | Daytona 2 / PE, Scud Race, Le Mans 24 | 4-speed `InputGearShift1-4` from the H-shifter (paddles always on ShiftUp/Down), VR1-4. |
| Supermodel | Sega Rally 2, Dirt Devils | ViewChange and HandBrake (the analog handbrake as `JOY2_SLIDER1_POS`). Force feedback via `ForceFeedback=1` + DirectInput. |
| MAME | 23 racing cfgs | See `templates\mame.json`: Out Run family Hi/Lo on the right paddle, Turbo on Nitro, Ace Driver lever on the paddles, Cruis'n / Rush / Cal Speed / Off Road Challenge 4-speed on Gear1-4, Rush clutch pedal on Clutch. |
| m2emulator | Daytona, Sega Rally, Indy 500, Over Rev, Super GT, STCC | Reference bindings unchanged. Re-bind in the emulator if the wheel is not DirectInput #1. FFB via `EnableFF=1` / FFBPlugin. |

## Known limitations / untested

- **The interactive wizard hasn't been run on real hardware.** Nobody was at the cabinet. The detection logic is covered by `dev\Test-CaptureLogic.ps1` with scripted fake devices:
  - pedal with the G29 "32768 until first report" quirk
  - normal and inverted steering
  - button debounce and a held-button filter
  - hat diagonals
  - handbrake on a second device

  Console key handling (`[Console]::KeyAvailable`) is untested in Windows Terminal and the VS Code terminal. Use a plain PowerShell console if keys don't register.
- **G29 pedal rest values are unknown** (see "Detected"). The seed assumes rest at 32768 (half travel), which reproduces the existing TeknoParrot `Driving Y -` convention. If a capture shows rest at 65535, generation switches to full-axis forms everywhere: TeknoParrot `IsFullAxis` + `IsReverseAxis`, Dolphin `Full Axis Y-`, Supermodel `_INV`. The TeknoParrot full-axis semantics are inferred from the schema, not from TeknoParrot source.
- **No game or emulator was launched**, so no generated config has been confirmed in-game.
- **TeknoParrot:**
  - Only `<DirectInputButton>` is written. XInput and RawInput bindings are left as they are.
  - Mouse-mode light guns need TeknoParrot's RawInput API and are not generated.
  - The 20 new E: UserProfiles have an empty GamePath. Applying them makes those games appear in TeknoParrotUI's list without an exe set.
- **MAME:**
  - `<mapdevice device="<instance GUID>">` relies on MAME 0.244 DirectInput device ids containing the instance GUID; MAME matches by substring. Check `mame -v` once. If it isn't pinned, MAME falls back to enumeration order, which is also correct here: wheel JOYCODE_1, handbrake JOYCODE_2, no XInput pads.
  - Pedal `_POS`/`_NEG` forms follow the owner's reference files. They are only flipped when the captured direction differs from the reference.
- **Supermodel:** `JOYn` is DirectInput enumeration order, which can change when USB ports change. Re-run `-Detect` + `-Generate` after hardware changes.
- **Cemu / m2emulator:** these rely on the previous owner's reference files. Cemu axis ids and m2 `.input` binary are not decoded. Different hardware needs in-emulator rebinding, and the generator warns about it.
- **FFBPlugin GUID:** the SDL2 GUID name-CRC is copied from existing files. For a wheel that has never had an `FFBPlugin.ini`, CRC `0000` is written and flagged; confirm with `FFBPluginGUI.exe`.
- **Light guns:** the template and profile schema exist, but nothing has been tested. Mouse-mode aim (Sinden, AimTrak mouse) is recorded but not written to any emulator yet. Next steps:
  - TeknoParrot RawInput `<RawInputButton>` writer
  - MAME `multimouse` + `GUNCODE` `mapdevice`
  - Supermodel `InputGunX/Y`
- **G HUB profiles:** if G HUB has a per-game profile with remapped buttons or a different rotation, captured numbers apply only while that G HUB profile is active. Capture with the G HUB profile you'll actually play with.

## Brake on the clutch pedal (fixed 2026-11-22): `tools\Repair-TPPedals.ps1`

The G29 reports gas on the Y axis, brake on RotationZ and clutch on Slider 0. Nine TeknoParrot profiles in `D:\Emulators\TeknoParrot` had Brake on Slider 0, so the clutch (left pedal) braked and the brake did nothing. BattleGear4Tuned also had the clutch on the brake. The nine were BattleGear4Tuned, GaelcoChampionshipTuningRace, GRID, GtiClub3, ID5, ID7, ID8, IDZ and KODrive.

`Repair-TPPedals.ps1` fixes only those two entries:
- it touches only profiles whose Gas is on the same wheel's Y axis (the Logitech pedal layout)
- it does a dry run unless you give `-Apply`
- with `-Apply`, it first backs up `UserProfiles` to `D:\ArcadeMaster\_backup\TP-UserProfiles-<install>-pedals-<time>`

Re-generating the whole profile (`WheelMap.ps1 -Generate`) would also fix it, but it changes more, such as the steering direction label, so it needs a test drive first.

```powershell
tools\Repair-TPPedals.ps1                                         # list wrong pedals
tools\Repair-TPPedals.ps1 -TpDir D:\Emulators\TeknoParrot -Apply  # back up + fix
```

## Legacy emulators (2026-11-22): generated from the profile, not copied

The previous owner's per-wheel sets were copied unchanged. They encode that machine's driver layout, and on this cabinet (G29 on G HUB) they were wrong:

| Emulator | Was | Now |
|---|---|---|
| **Model 2** (`CFG\<rom>.input`) | copied; Accelerate on axis #1 = the **clutch** under G HUB | generated. The format is decoded (see `templates/m2emulator.json`). Per-game slot lists come from EMULATOR.EXE's control tables (Daytona 24, Sega Rally 21, STCC / Indy / Over Rev / Super GT 18, bikes, Wing War flight, Desert Tank). Axes use the device's live DirectInput **object order**. Buttons, hats and keys are encoded per slot. Files are written only for installed ROMs (read from `[RomDirs]`). |
| **Cemu** (`controllerProfiles\G29.xml`) | copied; gas on **Y+**, active with the pedal released under G HUB | generated. Wii U Pro slot → Cemu DirectInput code (buttons 0–31, hat 34–37, axis halves 38–49). The pedal half follows its pressed direction. |
| **MAME** | 23 per-game cfgs only; hats named `COMMANDEDEPOUCE*` (French Windows), so the D-pad was dead | per-game cfgs regenerated, plus `ctrlr\wheelmap.cfg` defaults for **every** game: paddle / dial / positional = wheel, pedal 1–3, AD stick X/Y/Z for flight, buttons, start / coin, and device pinning |
| Supermodel, Dolphin / Triforce | already generated from the profile (DIJOYSTATE axis names) | unchanged |

**Pedal convention (always):** clutch = LEFT pedal, brake = MIDDLE (LEFT on a 2-pedal set), gas = RIGHT. The Wheel Setup prompts name the position. `Test-WMPedalLayout` checks the profile against the axis names the driver reports and warns on swapped or shared pedal axes, both in `-Generate` and after a capture.
## Per-game controls cards (game list)

`tools/New-GameControlsArt.ps1` draws a card for each game showing the cabinet controller: wheel face, paddles, pedals (clutch left / brake middle / gas right), handbrake and shifter. Every control the game uses is lit and numbered, with a legend of what it does **in that game**. The data comes from the live configuration:

| Emulator | Source |
|---|---|
| TeknoParrot | UserProfiles: ButtonName + BindNameDi |
| Model 2 | decoded `.input` codes + slot names |
| Supermodel | its INI |
| MAME | per-game cfg + `ctrlr\wheelmap.cfg` |
| Dolphin (GC / Wii / Triforce) and Cemu (Wii U) | their templates + per-game action labels |

**In the frontend:** the game list fades the card in bottom-right about 1 s after you stop on a game (`am_controls` art type). PC games use their own in-game control menus, so they get no card.

**First run:** 64 cards. They already show real binding problems, e.g. GRID (TeknoParrot) has Brake bound to the clutch pedal.

## Controls card: the real wheel, live (2026-11-22)

When a game is highlighted, the card at the bottom of the game list shows:
- **Left:** the real G29, using the product picture that Logitech G HUB installs (`C:\ProgramData\LGHUB\depots\*\g29\`). These pictures are read on each cabinet and never copied into the repo. Without G HUB, a simple outline wheel is drawn instead. The buttons that game uses are filled in colour and numbered, and the steering number sits at the top of the rim. **The drawing turns as you turn the real wheel**, and any button or D-pad direction you press lights up.
- **Middle:** the real pedal set, clutch LEFT, brake MIDDLE and gas RIGHT. Each one **lights up as you press it**. Next to them are the shifter and handbrake.
- **Right:** the game's name and what each numbered control does in that game, in plain words (for example "Shift up: Right paddle (behind the wheel)").

How it's made:
- `tools/New-GameControlsArt.ps1` draws the card (`am_controls`) and the wheel (`am_controls_wheel`) for every game.
- It also draws one glow picture per button and pedal into `layouts/ArcadeMaster/images/controls/`.
- RetroFE patch 0007 adds layout settings that tie a picture to the controller: `liveSteer`, `liveButton`, `liveHat` and `liveAxis`.
- The pedal glows follow G29 axes gas 1, brake 2 and clutch 3. If a pedal lights the wrong bar, swap the `liveAxis` numbers in `layout.xml`.
## The menu follows your hands (2026-11-24)

On wheel cabinets the main menu and the game lists react to the real controls. This uses RetroFE's live attributes (patches 0007, 0008 and 0010 on the controls card pull request), with `liveDevice="wheel"`, so nothing moves on cabinets without a wheel:

| What you do | What the menu shows | Layout attribute |
|---|---|---|
| turn the wheel | the centre wheel turns: upright when centred, G HUB's picture of your wheel (`New-RealWheelArt`) | `am_realwheel`: `liveSteer="450"` |
| press the gas | both needles rise: the rev counter quickly, the speedo with a lag | `liveNeedle="1" liveNeedleSpan liveNeedleSmooth` |
| press the brake | red glow around the speedo, brighter the harder you press | `liveAxis="2"` |
| put the shifter in a gear | 1-6 or R above the rev counter's hub | `liveButton="12"`...`"18"` |
| pull a shift paddle | up or down arrow beside the hub | `liveButton="4"` / `"5"` |

The overlay pictures come from `tools\New-LiveDashArt.ps1` (about 100 KB in all).

**Wheels and pedals read stale values until their first report.** Until a wheel or pedal sends its first report, SDL holds a stale value (full lock, or half travel). Steering and pedals therefore count as centred or released until the reading first changes.

**Menu clicks in the wheel are off** (`ffbTick = 0`, the default since patch 0009). On the G29, the click on each menu scroll pushed the rim the same way every time, and the wheel stepped round with every scroll. The centring spring is `ffbCenter` (50 on the racing cabinet).

## Checking the wheel bindings

`tools\Test-WheelBindings.ps1` reads every TeknoParrot game profile and checks its wheel, pedal, paddle and gear
bindings against the G29: steering X axis, gas Y, brake RotationZ, clutch Slider 0 (clutch LEFT, brake MIDDLE, gas
RIGHT), right paddle button 4 = shift up, left paddle button 5 = shift down, shifter gears 1-6 = buttons 12-17,
reverse = button 18 (a 4-speed game may put gears 3 and 4 on shifter 5 and 6, like Daytona). It changes nothing. It
reports WRONG (another axis or button), MISSING (no steering, gas or brake: the game can't be driven) and KEYS
(keyboard only). Fix a profile with WheelMap (`tools\wheelmap\WheelMap.ps1 -Generate`, then `-Apply -Commit`, or copy
only the staged files you checked), which backs up every live file first.

Every live element (liveSteer, liveButton, liveHat, liveAxis, liveNeedle, liveShiftX, liveZoomAxis) needs
`liveDevice="wheel"`. Without it RetroFE follows the FIRST controller it opened, which on a cabinet with a handbrake
or a control panel is not the wheel: the picture then sits at that controller's resting value and never turns.

## Force feedback in TeknoParrot games (FFB Arcade Plugin)

Games with the FFB Arcade Plugin (FFBPlugin.ini beside the game) push the wheel only when `DeviceGUID` is exactly the
SDL id the plugin's OWN SDL2.dll (in the same folder) gives the wheel. That id depends on the SDL version: before 2.26
the G29 is `030000006d0400004fc2000000000000`; from 2.26 on SDL adds a checksum of the device name
(`03004ed76d0400004fc2000000000000` for "Logitech G HUB G29 Driving Force Racing Wheel USB"). A config copied from
another game or PC can name an id that never matches, and the game then has no force feedback with no error.
`tools\Repair-FFBPluginDevice.ps1` asks each folder's SDL2.dll for the wheel's id and fixes DeviceGUID (dry run;
`-Apply` backs up first).


## Flight games on a racing cabinet

A racing cabinet has no flight stick, so the arcade flight games (After Burner Climax, MachStorm, Star Wars Battle Pod) had no controls at all. `tools\Set-FlightOnWheel.ps1` maps them to the G29:

| Flight control | G29 |
|---|---|
| Bank / turn | wheel |
| Nose up | right paddle |
| Nose down | left paddle |
| Throttle | gas pedal |
| Air brake | brake pedal |
| Guns / missiles | face buttons |
| Start | start button |

- The bindings are copied from a driving game that already works on this wheel (Daytona3), so the device and axes are right.
- Only controls with nothing bound are filled in, so a cabinet with a real stick keeps its own bindings.
- Dry run by default. `-Apply` backs up to `*.am-flight-<time>.bak`.

## After a reboot or a USB port change (2026-11-25)
Windows can give a controller a new DirectInput id (instance GUID) and a new place in the list (JOY1, JOY2) after a
reboot, a USB port change, or unplugging and replugging. Each emulator records the controllers its own way:

| Emulator | Stores | Kept right by |
|---|---|---|
| TeknoParrot (all copies) | the device's id | `Update-ControllerIds.ps1` (device history) |
| Dolphin / Triforce | the device's name | nothing needed; `Set-DolphinControllers.ps1` for Wii Remotes / GC adapter |
| FFB Arcade Plugin | SDL id (from VID / PID / name) | `Repair-FFBPluginDevice.ps1` |
| MAME | `mapdevice` id in `ctrlr\wheelmap.cfg` (JOYCODE_n pinned to it) | `Repair-EmulatorDevices.ps1` |
| Cemu | `<uuid>` id in `controllerProfiles\*.xml` | `Repair-EmulatorDevices.ps1` |
| Supermodel (Model 3) | `JOYn_` numbers in `Config\Supermodel.ini` | `Repair-EmulatorDevices.ps1` |
| Model 2 | device number inside each control code in `CFG\*.input` (keys untouched) | `Repair-EmulatorDevices.ps1` |
| Assetto Corsa Competizione | `instanceGuid` per device in `Documents\...\Config\controls.json` | `Repair-EmulatorDevices.ps1` (`catalog\controller-files.json`) |
| DiRT 4, GRID | the **product** GUID (VID / PID) in `input\devices\device_defines.xml` | nothing needed: it never changes |
| RetroArch (pedestal, RetroBat systems) | `input_playerN_joypad_index` (a number) | to do on the pedestal: pin players with `input_playerN_reserved_device` (VID:PID name) |

`Repair-EmulatorDevices.ps1` keeps `manifest\emulator-devices.json` (the ids and numbers the files are written with;
on RACE1 seeded from `profiles\G29.json`, on other cabinets the first run records what is plugged in). Each run
matches devices by USB VID / PID (then name, then old id when two are the same), swaps only those tokens, and backs
each changed file up as `<file>.ids-<time>.bak`. It covers the frontend's own `emulators\` folder and the WheelMap
targets of this cabinet. It runs at boot (Start-ArcadeMaster, after Update-ControllerIds) and on plug / unplug
(Update-Controllers), reading the DirectInput scan Get-CabinetDevices has just refreshed (about 0.4 s).
Every config file on RACE1 was searched for the wheel's and handbrake's GUIDs (2026-11-25): only MAME, Cemu and ACC store
them; RetroArch, PCSX2 and Flycast are not installed here. Tested on copies with the wheel and handbrake swapped and new ids: 9 files fixed (MAME, Cemu, Supermodel, six Model 2
games), and a second run changed nothing.

## Favourites on the wheel (2026-11-25, numbers corrected 2026-11-26)
In the menus: **Options** (G29 button 9; also R3, 10) marks or unmarks the selected game as a favourite; **Share**
(button 8; also L3, 11) jumps to the Favourites list; Circle / Triangle cycle the lists, Favourites second (skipped
while nothing is marked). The first note said Options 10 / Share 11: on the G29, 10 and 11 are R3 and L3
(New-GameControlsArt's measured table), so those still work but the named buttons are 9 and 8. RetroFE keeps the list
in `collections\<menu>\playlists\favorites.txt`; New-SeriesPlaylists only replaces the playlists it made, and the menu
rebuild keeps every menu's playlists, so favourites survive. In a game, Options is still the game's Start.

## One menu layout on every cabinet (2026-11-25)
James: "the same experience with settings and menu controls regardless of Arcade Standup, Sitdown, Racing Rig,
Flight Rig". The menu buttons are now defined once, in `catalog\menu-controls.json`, by **position**: the order the
Xbox pad, the CoinOPS wiring table and the G29 already share. `tools\Set-MenuControls.ps1` writes it into each
cabinet's controls.conf at every boot (silent once it matches).

| Menu action | Pad (Xbox order) | Arcade panel, joystick mode | Arcade panel, keyboard mode (I-PAC P1 keys) | Wheel (G29) | Keyboard (no panel) |
|---|---|---|---|---|---|
| Move | D-pad / left stick | stick | stick (arrow keys) | D-pad, steer left / right | arrows |
| Play / open | A, Start | button 1, Start | button 1 (Left Ctrl), Start 1 | Cross, L2 | Enter |
| Back | B | button 2 | button 2 (Left Alt) | Square | Esc |
| Previous / next list | X / Y | buttons 3 / 4 | buttons 3 / 4 (Space / Left Shift) | Circle / Triangle | O / P |
| Letter jump | LB / RB | buttons 5 / 6 | buttons 5 / 6 (Z / X) | right / left paddle | N / M |
| Random game | Back | button 7 (Select) | Coin 1 (5) | R2 | R |
| Mark favourite | right stick click | button 10 | button 7 (C) | Options (or R3) | F |
| Favourites list | left stick click | button 9 | button 8 (V) | Share (or L3) | V |
| Close the frontend | - | - | - | - | Q |

The numbers are shared (button n is button n on every joystick); the Xbox pad and the CoinOPS wiring put the same
*places* on those numbers, the G29 names them its own way (0 Cross, 1 Square, 2 Circle, 3 Triangle ...), so the wheel
keeps its original build's layout. **Letter shortcuts (O P N M R F Q) are only added on cabinets without a control
panel**, and taken off random / quit on a panel cabinet: a keyboard-wired panel sends letters for player 2 (stick R F D
G, buttons A S Q W ...), so R or Q there would make player 2 jump to a random game or close the frontend.
**Tools > Menu Buttons** shows this table for the cabinet you stand at, with its own button names.

Each cabinet keeps what it has on top: RACE1's pedal axes, the pedestal's touch gestures, a panel's own keys. A button
the layout gives to one action is taken off any other action line, so one press never does two things. The settings
are already shared: Tools and Cabinet Settings are made by the same tools on every cabinet; only hardware entries
change (Wheel Setup with a wheel, Panel Test with a panel, Flight Stick Setup with a stick).

## Coin, start and exit on the wheel (2026-11-26)
James, stuck in OutRunners at the cabinet: "Share credit and Options start for this controller" and "I want to hold PS
for 5 secs".

| In any game | Press |
|---|---|
| Insert a coin (credit) | **Share** |
| Start | **Options** |
| Leave the game, back to the menu | **hold PS for 5 seconds** |
| Test (operator menu, calibration) | **Plus (+)** |
| Service | **Minus (-)** |

- **Coin / start** (`tools\Set-CoinStartButtons.ps1`): before, MAME had coin on L3 and start on R3, Supermodel coin on
  Options, Daytona 3 coin on Cross and start on the keyboard's Enter. The tool sets ONLY those two bindings in every
  TeknoParrot profile that uses the wheel, MAME (ctrlr + cfg; a keyboard key keeps working and gets the wheel button
  too), Supermodel.ini and the Model 2 `.input` files, in every copy of the emulators; a control that sat on Share /
  Options moves to the freed button; every changed file is backed up as `<file>.coinstart-<time>.bak`. Applied on RACE1:
  105 files; Test-WheelBindings still 313 of 313. `profiles\G29.json` now has Start = 9, Coin = 8. A full WheelMap
  regenerate was NOT used: it would rewrite 129 files and undo later fixes (pedals, flight on the wheel, FFB ids).
- **Test / service** (same tool, `-Test 19 -Service 20`): James asked whether to map everything to F1-F8 or to L2 / R2.
  Neither: L2 and R2 are game buttons in several games (Nitrous, Hazard, Overtake, Reset, View Change) and are easy to
  press by accident, and most games already had Test / Service on Plus / Minus. Now Plus = Test and Minus = Service in
  every TeknoParrot profile on the wheel, MAME (SERVICE = the test switch, SERVICE1) and Supermodel; keyboard keys that
  were there (F2, keypad + / -) keep working. Three Raw Thrills games (Cars, Dirty Drivin', H2Overdrive) use Plus /
  Minus as Volume Up / Down, which their test menu needs, so their Test / Service stay where they were (D-pad / keys).
  Applied on RACE1: 54 files; Test-WheelBindings 313 of 313.
- **Hold PS to exit** (`tools\Watch-GameExit.ps1`, started by Start-ArcadeMaster; James at the cabinet: "PS is working"): reads the controller itself (winmm),
  so it is the same in MAME, TeknoParrot, Model 2 / 3, Dolphin and PC games. After 1 s a card says "KEEP HOLDING TO
  EXIT"; at 5 s every program RetroFE started for the game is asked to close, and ended 3 s later if still there. A pad
  uses Back + Start. In the menus it does nothing. Log: `manifest\game-exit.log`. The old exit (L2 + R2 together, through
  JoyToKey's Alt+F4 and MAME's own cancel) still works.

## The wheel's red dial, and life without G HUB (2026-11-26)
- **Dial press = Enter, dial right / left = Down / Up** (JoyToKey, the frontend's own `JoyToKey\Profile 1.cfg`: buttons 24 /
  22 / 23, counted from 1). James: "need to find what the enter button is on the wheel". It selects and scrolls in the
  menus and answers "press Enter" in games and in Windows. `Set-MenuControls.ps1` adds it on any cabinet with a wheel.
  In the menus Cross (and L2) select as before.
- **G HUB uninstalled on DESKTOP-RACE1.** The wheel is unchanged for everything we bind: same name ("Logitech G HUB G29
  ..."), same instance GUID, 25 buttons, 4 axes, force feedback reported. What went with G HUB: its pictures of the
  wheel, pedals and shifter (`C:\ProgramData\LGHUB\depots\<n>\g29`), which the controls cards are drawn on.
  `New-GameControlsArt.ps1` now keeps a copy in `C:\ProgramData\ArcadeMaster\wheels\g29` and on
  `Z:\ArcadeMaster\media\ghub-g29` whenever G HUB is present, and uses that copy on a PC without G HUB. Until a cabinet
  with G HUB has run it once, a redraw on RACE1 gives the plain drawing; the cards made earlier keep their photo.
- **No force feedback after uninstalling G HUB.** The G29's force feedback driver belongs to Logitech's software. The
  uninstall removes it but leaves the registry entry that says the wheel has force feedback (`OEMForceFeedback` CLSID
  `{1ED6DDBB-0401-4498-A093-7D249203200C}`, no longer registered), so Windows still lists it and every program fails
  to open it: RetroFE logs "SDL_HapticOpen failed: Resetting device", and no game has force either. System Health has
  a line for it (**Wheel force feedback driver**). Fix: install G HUB again, or the older Logitech Gaming Software.
  With Logitech Gaming Software the wheel's name changes (no "G HUB" in it): Repair-EmulatorDevices,
  Repair-FFBPluginDevice and Set-DolphinControllers follow that at the next boot.
