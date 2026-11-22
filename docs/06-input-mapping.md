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
