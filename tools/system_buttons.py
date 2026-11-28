r"""One table for what each panel button is on each console: the controls card (New-SystemCards.py), the emulator
configs (New-DirectLaunchers.py) and the button lights (New-LedColorsAuto.py) all read it, so the screen, the
emulator and the lit buttons always agree.
"""

# RetroBat's keyboard layout for the panel (es_input.cfg, 2026-11-26 "bottom row"): retropad button -> panel button
PANEL = [("b", "B1"), ("a", "B2"), ("r", "B3"), ("r2", "B4"), ("y", "B5"), ("x", "B6"), ("l", "B7"), ("l2", "B8"),
         ("start", "START"), ("select", "COIN")]
PAD = dict(PANEL)

# retropad -> the console's own button names, only where the default is well known
NATIVE = {
    "nes": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "famicom": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "snes": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "gb": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "gbc": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "gba": {"b": "B", "a": "A", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "nds": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "3ds": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "n64": {"b": "B", "a": "A", "l": "L", "r": "R", "l2": "Z", "start": "START"},
    "wiiu": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "l2": "ZL", "r2": "ZR", "start": "PLUS",
             "select": "MINUS"},
    "switch": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "l2": "ZL", "r2": "ZR", "start": "PLUS",
               "select": "MINUS"},
    "gamecube": {"b": "A", "y": "B", "a": "X", "x": "Y", "r": "Z", "l2": "L", "r2": "R", "start": "START"},
    # an emulated Wii Remote + Nunchuk (Set-EmulatorPanelKeys.py; the trackball is the pointer)
    "wii": {"b": "A", "a": "B", "r": "1", "r2": "2", "y": "C", "x": "Z", "l": "SHAKE", "l2": "HOME", "start": "PLUS",
            "select": "MINUS"},
    "xbox": {"b": "A", "a": "B", "y": "X", "x": "Y", "l": "WHITE", "r": "BLACK", "l2": "LT", "r2": "RT", "start": "START",
             "select": "BACK"},
    "xbox360": {"b": "A", "a": "B", "y": "X", "x": "Y", "l": "LB", "r": "RB", "l2": "LT", "r2": "RT", "start": "START",
                "select": "BACK"},
    "megadrive": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START", "select": "MODE"},
    "sega32x": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START"},
    "segacd": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START"},
    "saturn": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "l2": "L", "r2": "R", "start": "START"},
    "mastersystem": {"b": "1", "a": "2", "start": "PAUSE"},
    "gamegear": {"b": "1", "a": "2", "start": "START"},
    "sg-1000": {"b": "1", "a": "2", "start": "PAUSE"},
    "pcengine": {"b": "II", "a": "I", "start": "RUN", "select": "SELECT"},
    "pcenginecd": {"b": "II", "a": "I", "start": "RUN", "select": "SELECT"},
    "neogeo": {"b": "A", "a": "B", "y": "C", "x": "D", "start": "START", "select": "COIN"},
    "neogeocd": {"b": "A", "a": "B", "y": "C", "x": "D", "start": "START", "select": "SELECT"},
    "psx": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L1", "r": "R1", "l2": "L2", "r2": "R2",
            "start": "START", "select": "SELECT"},
    "ps2": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L1", "r": "R1", "l2": "L2", "r2": "R2",
            "start": "START", "select": "SELECT"},
    "psp": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "dreamcast": {"b": "A", "a": "B", "y": "X", "x": "Y", "l2": "L", "r2": "R", "start": "START"},
    "atari2600": {"b": "FIRE", "start": "RESET", "select": "SELECT"},
    "c64": {"b": "FIRE", "start": "RUN/STOP"},
    "amiga500": {"b": "FIRE", "a": "FIRE 2"},
}
# a modern pad, for systems without a sure table: the button by its place
GENERIC = {"b": "BOTTOM", "a": "RIGHT", "y": "LEFT", "x": "TOP", "l": "L", "r": "R", "l2": "L2", "r2": "R2",
           "start": "START", "select": "SELECT"}
# the card's chip colours; the lights use the same ones
CHIP = {"B1": "ff3b3b", "B2": "ffb000", "B3": "2ec8ff", "B4": "3ddc84", "B5": "ff2fa0", "B6": "7b5cff", "B7": "9be7ff",
        "B8": "ffe259", "START": "ffffff", "COIN": "ffe259"}


def led_rgb(panel_button):
    """A chip colour on LEDBlinky's 0-48 scale."""
    h = CHIP.get(panel_button, "ffffff")
    return [round(int(h[i:i + 2], 16) * 48 / 255) for i in (0, 2, 4)]
