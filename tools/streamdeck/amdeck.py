"""ArcadeMaster Stream Deck controller.

Drives an Elgato Stream Deck directly over USB (no Elgato app):
  - menu page: theme picker (previews), Tools switches with live ON/OFF state, volume, deck light, frontend restart
  - in-game page, shown by itself while a game runs: coin / start P1-P4, pause, exit, save / load, service,
    and the running game's own logo (found from RetroFE's launch log)
  - animated keys: press flash, busy spinner, pulse, animated PNG / GIF art (art/, made by New-DeckArt.py)
  - frames are rendered once and cached; deck.json is reloaded when it changes; the deck dims when idle
Layout and bindings: deck.json next to this file. Docs: docs/12-stream-deck.md.

  pythonw tools\\streamdeck\\amdeck.py --retrofe <RetroFE root> --manifest <manifest dir>
  python  tools\\streamdeck\\amdeck.py --retrofe ... --manifest ... --once      (draw the menu page and exit)

Started by tools\\Start-ArcadeMaster.ps1 at boot. Needs: pip install -r tools\\streamdeck\\requirements.txt
and hidapi.dll (tools\\streamdeck\\bin\\). Elgato's Stream Deck app owns the device while it runs, so this waits
until StreamDeck.exe is gone.
"""
import argparse, ctypes, json, math, os, re, sys, threading, time
from ctypes import wintypes

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BIN = os.path.join(HERE, "bin")
if os.path.isdir(BIN):
    os.environ["PATH"] = BIN + os.pathsep + os.environ.get("PATH", "")
    os.add_dll_directory(BIN)

from PIL import Image, ImageDraw, ImageFont, ImageSequence   # noqa: E402
from StreamDeck.DeviceManager import DeviceManager            # noqa: E402
from StreamDeck.ImageHelpers import PILHelper                 # noqa: E402

import subprocess  # noqa: E402

NO_WINDOW = 0x08000000
LOGO = os.path.join(REPO, "layouts", "ArcadeMaster", "images", "studio_realz.png")
FONT = os.path.join(REPO, "layouts", "ArcadeMaster", "fonts", "OpenSans.ttf")
LOG = None


def log(msg):
    line = time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg
    if LOG:
        try:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass
    if sys.stdout:
        try:
            print(line, flush=True)
        except OSError:
            pass


# ---------------------------------------------------------------- Windows helpers
class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                ("szExeFile", ctypes.c_wchar * 260)]


_k32 = ctypes.windll.kernel32
_k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
_k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
_k32.Process32FirstW.argtypes = _k32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
_k32.CloseHandle.argtypes = [wintypes.HANDLE]


def processes():
    """lower-case exe names of running processes (toolhelp snapshot: ~1 ms, no child process)."""
    names = set()
    snap = _k32.CreateToolhelp32Snapshot(0x2, 0)          # TH32CS_SNAPPROCESS
    if not snap or snap == wintypes.HANDLE(-1).value:
        return names
    try:
        e = PROCESSENTRY32W(); e.dwSize = ctypes.sizeof(e)
        ok = _k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            names.add(e.szExeFile.lower()); ok = _k32.Process32NextW(snap, ctypes.byref(e))
    finally:
        _k32.CloseHandle(snap)
    return names


SCAN = {"ESC": 0x01, "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06, "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A,
        "0": 0x0B, "TAB": 0x0F, "ENTER": 0x1C, "SPACE": 0x39, "SHIFT": 0x2A, "CTRL": 0x1D, "ALT": 0x38,
        "F1": 0x3B, "F2": 0x3C, "F3": 0x3D, "F4": 0x3E, "F5": 0x3F, "F6": 0x40, "F7": 0x41, "F8": 0x42, "F9": 0x43,
        "F10": 0x44, "F11": 0x57, "F12": 0x58}
SCAN.update({c: s for c, s in zip("QWERTYUIOP", range(0x10, 0x1A))})
SCAN.update({c: s for c, s in zip("ASDFGHJKL", range(0x1E, 0x27))})
SCAN.update({c: s for c, s in zip("ZXCVBNM", range(0x2C, 0x33))})


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


def _send(scan, up):
    i = INPUT(type=1); i.ki = KEYBDINPUT(0, scan, 0x0008 | (0x0002 if up else 0), 0, 0)   # KEYEVENTF_SCANCODE (| KEYUP)
    ctypes.windll.user32.SendInput(1, ctypes.byref(i), ctypes.sizeof(INPUT))


def send_keys(combo):
    """'SHIFT+F7' -> hold the keys in order, release in reverse. Scancodes, so DirectInput/raw-input games see them."""
    codes = [SCAN[k.strip().upper()] for k in combo.split("+")]
    for c in codes:
        _send(c, False)
    time.sleep(0.08)
    for c in reversed(codes):
        _send(c, True)


def volume(what):
    vk = {"mute": 0xAD, "down": 0xAE, "up": 0xAF}[what]
    for _ in range(1 if what == "mute" else 2):
        ctypes.windll.user32.keybd_event(vk, 0, 0, 0); ctypes.windll.user32.keybd_event(vk, 0, 2, 0)


# ---------------------------------------------------------------- ArcadeMaster state
class Cabinet:
    def __init__(self, retrofe, manifest):
        self.retrofe, self.manifest = retrofe, manifest
        self._conf = (None, {})
        self._logos = None

    def settings(self):
        p = os.path.join(self.retrofe, "settings.conf")
        try:
            m = os.path.getmtime(p)
        except OSError:
            return {}
        if self._conf[0] != m:
            vals = {}
            with open(p, encoding="utf-8", errors="replace") as f:
                for ln in f:
                    k, sep, v = ln.partition("=")
                    if sep and not k.lstrip().startswith("#"):
                        vals[k.strip()] = v.strip()
            self._conf = (m, vals)
        return self._conf[1]

    def setting(self, key):
        return self.settings().get(key)

    def themes(self):
        try:
            with open(os.path.join(self.manifest, "themes.json"), encoding="utf-8-sig") as f:
                reg = json.load(f).get("themes", [])
        except (OSError, ValueError):
            reg = []
        found = [t for t in reg if os.path.exists(os.path.join(self.retrofe, "layouts", t.get("name", ""), "layout.xml"))]
        if not any(t.get("name") == "ArcadeMaster" for t in found) and os.path.exists(os.path.join(self.retrofe, "layouts", "ArcadeMaster", "layout.xml")):
            found.insert(0, {"name": "ArcadeMaster", "score": 100})
        return found

    # --- the running game, from RetroFE's launch log
    def current_game(self):
        """(rom, collection) of the last launch in <retrofe>\\log.txt, or (None, None)."""
        p = os.path.join(self.retrofe, "log.txt")
        try:
            with open(p, "rb") as f:
                f.seek(0, 2); f.seek(max(0, f.tell() - 65536)); tail = f.read().decode("utf-8", "replace")
        except OSError:
            return None, None
        rom = coll = None
        for ln in tail.splitlines():
            if "Attempting to launch:" not in ln:
                continue
            m = re.search(r'LEDBlinky\.exe"?\s+\d+\s+"([^"]+)"\s+"([^"]+)"', ln, re.I)
            if m:
                rom, coll = m.group(1), m.group(2); continue
            m = re.search(r'--profile="?([^"\s]+?)(?:\.xml)?"?(\s|$)', ln, re.I)
            if m:
                rom = os.path.splitext(os.path.basename(m.group(1)))[0]; continue
            args = re.findall(r'"([^"]+)"|(\S+)', ln.split("Attempting to launch:", 1)[1])
            toks = [a or b for a, b in args][1:]
            for t in reversed(toks):
                if not t.startswith("-"):
                    rom = os.path.splitext(os.path.basename(t))[0]; break
        return rom, coll

    def game_logo(self, rom, coll):
        if not rom:
            return None
        if coll:
            for ext in (".png", ".jpg", ".gif"):
                p = os.path.join(self.retrofe, "collections", coll, "medium_artwork", "logo", rom + ext)
                if os.path.exists(p):
                    return p
        if self._logos is None:                           # one directory scan per run, then a dict lookup
            self._logos = {}
            root = os.path.join(self.retrofe, "collections")
            try:
                for c in os.listdir(root):
                    d = os.path.join(root, c, "medium_artwork", "logo")
                    if os.path.isdir(d):
                        for fn in os.listdir(d):
                            self._logos.setdefault(os.path.splitext(fn)[0].lower(), os.path.join(d, fn))
            except OSError:
                pass
        return self._logos.get(rom.lower())

    def tool(self, name, extra=()):
        args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(REPO, "tools", "Invoke-CabinetTool.ps1"),
                "-Tool", name, "-RetroFE", self.retrofe, "-ManifestDir", self.manifest, *extra]
        r = subprocess.run(args, capture_output=True, text=True, creationflags=NO_WINDOW, timeout=900)
        log(f"tool {name} {' '.join(extra)} -> exit {r.returncode}")
        return r.returncode == 0

    def restart(self, why):
        """Ask the Start-ArcadeMaster watchdog for a clean restart, then close RetroFE (gracefully first)."""
        if "retrofe.exe" not in processes():
            log("restart: RetroFE is not running"); return False
        with open(os.path.join(self.manifest, "restart.request"), "w", encoding="utf-8") as f:
            f.write(why)
        subprocess.run(["taskkill", "/IM", "retrofe.exe"], capture_output=True, creationflags=NO_WINDOW)
        for _ in range(16):
            time.sleep(0.5)
            if "retrofe.exe" not in processes():
                break
        else:
            subprocess.run(["taskkill", "/F", "/IM", "retrofe.exe"], capture_output=True, creationflags=NO_WINDOW)
        log(f"restart requested: {why}")
        return True


def state_on(cab, rule):
    """rule {"setting": "numScreens", "on": "^2$"} -> True/False; None when there is no rule."""
    if not rule:
        return None
    v = cab.setting(rule.get("setting", "")) or ""
    return bool(re.search(rule.get("on", "^(yes|true|1)$"), v, re.I))


# ---------------------------------------------------------------- key art (PIL images)
def _rgb(c):
    c = c.lstrip("#"); return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def _mix(a, b, t):
    return tuple(int(x + (y - x) * t) for x, y in zip(a, b))


class Painter:
    PULSE = 16          # frames in one pulse cycle
    SPIN = 12           # frames in one spinner turn

    def __init__(self, size):
        self.size = size
        self.font = ImageFont.truetype(FONT, int(size[1] * 0.2))
        self.small = ImageFont.truetype(FONT, int(size[1] * 0.15))
        self.logo = Image.open(LOGO).convert("RGBA") if os.path.exists(LOGO) else None

    def canvas(self, bg=(0, 0, 0)):
        return Image.new("RGB", self.size, bg)

    def _text(self, d, lines, color, font=None):
        font = font or self.font; w, h = self.size
        lines = [t for t in lines if t]
        y = h / 2 - len(lines) * font.size * 0.6
        for t in lines:
            tw = d.textlength(t, font=font); d.text(((w - tw) / 2, y), t, font=font, fill=color); y += font.size * 1.2

    def label(self, lines, color="#ffffff", glow=0.0, dim=False):
        c = _rgb(color)
        if dim:
            c = _mix((0, 0, 0), c, 0.35)
        w, h = self.size; img = self.canvas(); d = ImageDraw.Draw(img)
        if glow > 0:
            d.rounded_rectangle([0, 0, w - 1, h - 1], radius=12, fill=_mix((0, 0, 0), c, 0.18 * glow))
        frame = _mix(c, (255, 255, 255), 0.35 * glow)
        d.rounded_rectangle([2, 2, w - 3, h - 3], radius=10, outline=frame, width=3 + int(round(2 * glow)))
        self._text(d, lines, frame)
        return img

    def pulse(self, lines, color):
        return [self.label(lines, color, glow=(1 - math.cos(2 * math.pi * i / self.PULSE)) / 2) for i in range(self.PULSE)]

    def flash(self, base, color):
        """press feedback: solid key colour fading back into the normal key over 6 frames; text drawn dark on top."""
        c = _rgb(color); out = []
        for i in range(6):
            t = 1 - i / 6
            out.append(Image.blend(base.convert("RGB"), Image.new("RGB", self.size, c), 0.8 * t))
        return out

    def spinner(self, color="#ffffff"):
        c = _rgb(color); w, h = self.size; out = []
        for i in range(self.SPIN):
            img = self.canvas(); d = ImageDraw.Draw(img)
            d.rounded_rectangle([2, 2, w - 3, h - 3], radius=10, outline=_mix((0, 0, 0), c, 0.5), width=2)
            a = 360 * i / self.SPIN
            d.arc([14, 10, w - 14, h - 18], a, a + 250, fill=c, width=5)
            t = "WAIT"; tw = d.textlength(t, font=self.small); d.text(((w - tw) / 2, h - self.small.size - 5), t, font=self.small, fill=c)
            out.append(img)
        return out

    def logo_frames(self, caption=""):
        w, h = self.size; out = []; base = self.canvas()
        if self.logo:
            s = h - (16 if caption else 6); lg = self.logo.copy(); lg.thumbnail((s, s)); base.paste(lg, ((w - lg.width) // 2, 3), lg)
        for i in range(self.PULSE):
            g = (1 - math.cos(2 * math.pi * i / self.PULSE)) / 2
            img = base.copy(); d = ImageDraw.Draw(img)
            if caption:
                c = caption[:11]; tw = d.textlength(c, font=self.small)
                d.text(((w - tw) / 2, h - self.small.size - 3), c, font=self.small, fill=_mix((40, 140, 80), (61, 255, 140), g))
            d.rounded_rectangle([0, 0, w - 1, h - 1], radius=10, outline=_mix((20, 20, 30), (255, 43, 214), g), width=2)
            out.append(img)
        return out

    def caption(self, frames, text, color="#3ddc84"):
        """draw a small caption strip over existing frames (used for the theme name on the logo art)."""
        if not text:
            return frames
        out = []
        for f in frames:
            f = f.copy(); d = ImageDraw.Draw(f); w, h = self.size; t = text[:11]
            d.rectangle([3, h - self.small.size - 6, w - 4, h - 3], fill=(0, 0, 0))
            tw = d.textlength(t, font=self.small); d.text(((w - tw) / 2, h - self.small.size - 5), t, font=self.small, fill=color)
            out.append(f)
        return out

    def shine(self, path):
        """a game logo with a light sweep: 24 frames (sweep over the first 6)."""
        w, h = self.size; base = self.canvas()
        try:
            lg = Image.open(path).convert("RGBA"); lg.thumbnail((w - 6, h - 6)); base.paste(lg, ((w - lg.width) // 2, (h - lg.height) // 2), lg)
        except OSError:
            return [base]
        out = []
        for i in range(24):
            img = base.copy()
            if i < 6:
                band = Image.new("L", self.size, 0); d = ImageDraw.Draw(band); x = -30 + i * 22
                d.polygon([(x, 0), (x + 14, 0), (x + 14 - h // 2, h), (x - h // 2, h)], fill=110)
                img = Image.composite(Image.new("RGB", self.size, (255, 255, 255)), img, band)
            ImageDraw.Draw(img).rounded_rectangle([0, 0, w - 1, h - 1], radius=10, outline=(61, 220, 132), width=2)
            out.append(img)
        return out

    def theme_frames(self, name, preview, current):
        w, h = self.size; base = self.canvas()
        if preview and os.path.exists(preview):
            try:
                p = Image.open(preview).convert("RGB"); p.thumbnail((w, h)); base.paste(p, ((w - p.width) // 2, (h - p.height) // 2))
            except OSError:
                pass
        d = ImageDraw.Draw(base); title = name.replace("CO-", "")[:10]
        d.rectangle([0, h - self.small.size - 6, w, h], fill="black")
        tw = d.textlength(title, font=self.small); d.text(((w - tw) / 2, h - self.small.size - 4), title, font=self.small, fill="#ffffff")
        if not current:
            img = base.copy(); ImageDraw.Draw(img).rounded_rectangle([1, 1, w - 2, h - 2], radius=8, outline="#2ec8ff", width=2); return [img]
        out = []
        for i in range(self.PULSE):
            g = (1 - math.cos(2 * math.pi * i / self.PULSE)) / 2
            img = base.copy(); ImageDraw.Draw(img).rounded_rectangle([1, 1, w - 2, h - 2], radius=8, outline=_mix((30, 120, 70), (120, 255, 170), g), width=3 + int(round(2 * g)))
            out.append(img)
        return out

    def file_frames(self, path):
        """animated PNG / GIF (or a still image) -> (frames, per-frame seconds)."""
        im = Image.open(path); frames, durs = [], []
        for fr in ImageSequence.Iterator(im):
            f = fr.convert("RGBA")
            if f.size != self.size:
                f.thumbnail(self.size)
            bg = self.canvas(); bg.paste(f, ((self.size[0] - f.width) // 2, (self.size[1] - f.height) // 2), f)
            frames.append(bg); durs.append(max(fr.info.get("duration", 100), 40) / 1000)
        return frames, durs


# ---------------------------------------------------------------- controller
class Controller:
    def __init__(self, deck, cab, cfg_path):
        self.deck, self.cab, self.cfg_path = deck, cab, cfg_path
        self.paint = Painter(deck.key_image_format()["size"])
        self.page, self.menu_page, self.theme_offset = "home", "home", 0
        self.busy = None                 # key index while an action runs
        self.restart_pending = False
        self.bright = 1
        self.lock = threading.RLock()
        self.keys = {}       # key -> {"frames": [native], "src": [PIL], "dur": [s], "t0": time}
        self.flashes = {}    # key -> (frames native, t0)
        self.shown = {}      # key -> frame object last written (only changed keys are rewritten)
        self.cache = {}      # (what, args...) -> (PIL frames, durations, native frames): rendered once per run
        self.in_game, self.game = False, (None, None)
        self.last_input, self.dimmed = time.monotonic(), False
        self.load_config()

    def load_config(self):
        with open(self.cfg_path, encoding="utf-8") as f:
            self.cfg = json.load(f)
        self.cfg_mtime = os.path.getmtime(self.cfg_path)
        self.fps = float(self.cfg.get("fps", 12))
        self.games = {p.lower() for p in self.cfg.get("gameProcesses", [])}
        self.cache.clear()

    # --- frames (cached: a page switch only looks frames up)
    def native(self, img):
        return PILHelper.to_native_key_format(self.deck, img)

    def frames(self, key_id, make):
        if key_id not in self.cache:
            imgs, durs = make()
            durs = durs or [1 / self.fps] * len(imgs)
            self.cache[key_id] = (imgs, durs, [self.native(i) for i in imgs])
        return self.cache[key_id]

    def art(self, path):
        p = path if os.path.isabs(path) else os.path.join(HERE, path)
        return p if os.path.exists(p) else None

    def put(self, k, key_id, make):
        imgs, durs, nat = self.frames(key_id, make)
        self.keys[k] = {"frames": nat, "src": imgs, "dur": durs, "t0": time.monotonic()}

    def spec_frames(self, k, spec):
        """frames for one configured key, honouring state (ON/OFF art), art files, pulse and the special images."""
        on = state_on(self.cab, spec.get("state"))
        color = spec.get("color", "#ffffff"); lines = list(spec.get("label", []))
        if on is not None:
            img = spec.get("imageOn" if on else "imageOff")
            if img and self.art(img):
                p = self.art(img); return self.put(k, ("file", p), lambda: self.paint.file_frames(p))
            lines = [lines[0] if lines else "", "ON" if on else "OFF"]
            return self.put(k, ("label", tuple(lines), color, not on, on), lambda: ((self.paint.pulse(lines, color) if on else [self.paint.label(lines, color, dim=True)]), None))
        img = spec.get("image")
        if img == "logo":
            cap = ((self.cab.setting("layout") or "").replace("CO-", "")) if spec.get("status") == "theme" else ""
            art = self.art(spec.get("art", "art/logo.png"))
            if art:
                return self.put(k, ("logoart", art, cap), lambda: (lambda fr, du: (self.paint.caption(fr, cap), du))(*self.paint.file_frames(art)))
            return self.put(k, ("logo", cap), lambda: (self.paint.logo_frames(cap), None))
        if img == "game":
            rom, coll = self.game; p = self.cab.game_logo(rom, coll)
            if p:
                return self.put(k, ("game", p), lambda: (self.paint.shine(p), [0.09] * 24))
            lines = [((rom or "GAME")[:8]).upper(), "ON"]; color = spec.get("color", "#3ddc84")
            return self.put(k, ("label", tuple(lines), color, False, False), lambda: ([self.paint.label(lines, color)], None))
        if img and self.art(img):
            p = self.art(img); return self.put(k, ("file", p), lambda: self.paint.file_frames(p))
        if not spec.get("action"):
            return self.put(k, ("blank",), lambda: ([self.paint.canvas()], None))
        pulsing = spec.get("anim") == "pulse" or (spec.get("action") == "restart" and self.restart_pending)
        if pulsing:
            return self.put(k, ("pulse", tuple(lines), color), lambda: (self.paint.pulse(lines, color), None))
        return self.put(k, ("label", tuple(lines), color, False, False), lambda: ([self.paint.label(lines, color)], None))

    def build(self):
        """(re)build the frame list of every key on the current page."""
        with self.lock:
            self.keys.clear(); self.shown.clear()
            if self.page == "themes":
                return self._build_themes()
            spec_page = self.cfg["pages"].get(self.page, {})
            for k in range(self.deck.key_count()):
                spec = spec_page.get(str(k)) or {}
                if self.busy == k:
                    c = spec.get("color", "#ffffff"); self.put(k, ("spin", c), lambda: (self.paint.spinner(c), None))
                else:
                    self.spec_frames(k, spec)

    def _build_themes(self):
        themes = self.cab.themes(); cur = self.cab.setting("layout"); n = self.deck.key_count(); per = n - 2
        page = themes[self.theme_offset:self.theme_offset + per]
        nav = self.cfg.get("themePicker", {})
        for k in range(n):
            if self.busy == k:
                self.put(k, ("spin", "#3ddc84"), lambda: (self.paint.spinner("#3ddc84"), None))
            elif k < len(page):
                t = page[k]; is_cur = t["name"] == cur
                self.put(k, ("theme", t["name"], t.get("preview"), is_cur), lambda t=t, c=is_cur: (self.paint.theme_frames(t["name"], t.get("preview"), c), None))
            elif k == n - 2 and len(themes) > per:
                self.spec_frames(k, nav.get("more") or {"label": ["MORE", ">"], "color": "#ff2bd6", "action": "more"})
            elif k == n - 1:
                self.spec_frames(k, nav.get("back") or {"label": ["BACK", "<"], "color": "#ff2bd6", "action": "back"})
            else:
                self.put(k, ("blank",), lambda: ([self.paint.canvas()], None))

    def prerender(self):
        """warm the cache for every configured page in the background, so the first visit is instant."""
        def work():
            t0 = time.monotonic()
            for p in list(self.cfg["pages"]):
                with self.lock:                           # the visible page's key table is put back untouched
                    saved = dict(self.keys)
                    for k in range(self.deck.key_count()):
                        spec = self.cfg["pages"][p].get(str(k)) or {}
                        if spec.get("image") != "game":
                            try:
                                self.spec_frames(k, spec)
                            except Exception as e:
                                log(f"prerender {p}/{k}: {e!r}")
                    self.keys = saved
            log(f"prerendered {len(self.cache)} keys in {time.monotonic() - t0:.1f} s")
        threading.Thread(target=work, daemon=True).start()

    def key_color(self, key):
        if self.page == "themes":
            return "#3ddc84" if key < self.deck.key_count() - 2 else "#ff2bd6"
        return (self.cfg["pages"].get(self.page, {}).get(str(key)) or {}).get("color", "#ffffff")

    def render(self):
        """write every key whose current frame differs from what the deck shows."""
        now = time.monotonic()
        with self.lock:
            for k, st in list(self.keys.items()):
                frame = None
                fl = self.flashes.get(k)
                if fl:
                    i = int((now - fl[1]) * 24)            # flash runs at 24 fps (~250 ms)
                    if i < len(fl[0]):
                        frame = fl[0][i]
                    else:
                        del self.flashes[k]
                if frame is None:
                    frames, durs = st["frames"], st["dur"]
                    if len(frames) == 1:
                        frame = frames[0]
                    else:
                        t = (now - st["t0"]) % sum(durs); i = 0
                        while i < len(durs) - 1 and t >= durs[i]:
                            t -= durs[i]; i += 1
                        frame = frames[i]
                if self.shown.get(k) is not frame:
                    with self.deck:
                        self.deck.set_key_image(k, frame)
                    self.shown[k] = frame

    def animate(self):
        while self.deck.connected():
            try:
                self.render()
            except Exception as e:
                log(f"render: {e!r}"); time.sleep(1)
            time.sleep(1 / max(self.fps, 1))

    # --- input
    def on_key(self, deck, key, pressed):
        if not pressed:
            return
        self.last_input = time.monotonic()
        if self.dimmed:                                   # first press only wakes the deck
            self.wake(); return
        with self.lock:                                   # instant visual answer, before the action runs
            st = self.keys.get(key)
            if st:
                self.flashes[key] = ([self.native(f) for f in self.paint.flash(st["src"][0], self.key_color(key))], time.monotonic())
        self.render()
        if self.busy is not None:
            return
        try:
            self.handle(key)
        except Exception as e:  # never let one key kill the controller
            log(f"key {key} on {self.page} failed: {e!r}")

    def handle(self, key):
        if self.page == "themes":
            themes = self.cab.themes(); n = self.deck.key_count(); per = n - 2
            if key == n - 1:
                return self.go(self.menu_page)
            if key == n - 2 and len(themes) > per:
                self.theme_offset = (self.theme_offset + per) % len(themes); return self.build()
            page = themes[self.theme_offset:self.theme_offset + per]
            if key < len(page):
                name = page[key]["name"]
                if name == self.cab.setting("layout"):
                    return
                return self.run(key, lambda: self.cab.tool("Themes", ["-Choice", name]) and self.cab.restart(f"theme {name}"))
            return
        spec = self.cfg["pages"].get(self.page, {}).get(str(key)) or {}
        act = spec.get("action", "")
        if not act:
            return
        kind, _, arg = act.partition(":")
        if kind == "page":
            self.go(arg)
        elif kind == "themes":
            self.theme_offset = 0; self.go("themes")
        elif kind == "keys":
            send_keys(arg)
        elif kind == "volume":
            volume(arg)
        elif kind == "brightness":
            levels = self.cfg.get("brightness", [30, 60, 100]); self.bright = (self.bright + 1) % len(levels); self.deck.set_brightness(levels[self.bright])
        elif kind == "restart":
            if self.in_game:
                return log("restart ignored: a game is running")
            self.run(key, lambda: self.cab.restart("deck"))
        elif kind == "tool":
            def job():
                ok = self.cab.tool(arg)
                if ok and spec.get("restart"):
                    if self.in_game:
                        self.restart_pending = True
                    else:
                        self.cab.restart(f"tool {arg}")
                return ok
            self.run(key, job)

    def go(self, page):
        if page not in ("themes", "ingame"):
            self.menu_page = page
        self.page = page; self.build()

    def run(self, key, fn):
        self.busy = key; self.build()

        def worker():
            try:
                fn()
            except Exception as e:
                log(f"action failed: {e!r}")
            finally:
                self.busy = None; self.build()
        threading.Thread(target=worker, daemon=True).start()

    # --- idle dimming
    def wake(self):
        self.dimmed = False; self.deck.set_brightness(self.cfg.get("brightness", [30, 60, 100])[self.bright])

    def check_idle(self):
        mins = float(self.cfg.get("idleDimMinutes", 10))
        if mins > 0 and not self.dimmed and not self.in_game and time.monotonic() - self.last_input > mins * 60:
            self.dimmed = True; self.deck.set_brightness(int(self.cfg.get("idleBrightness", 8)))

    # --- once a second: game start/end, config edits, settings changes, idle
    def tick(self):
        try:
            if os.path.getmtime(self.cfg_path) != self.cfg_mtime:
                self.load_config(); log("deck.json changed - reloaded"); self.build()
        except (OSError, ValueError) as e:
            log(f"deck.json: {e}")
        running = bool(self.games & processes())
        if running != self.in_game:
            self.in_game = running; self.last_input = time.monotonic()
            if self.dimmed:
                self.wake()
            if running:
                time.sleep(0.5)                           # let RetroFE finish writing the launch to log.txt
                self.game = self.cab.current_game()
                log(f"game started: {self.game[0] or '?'} ({self.game[1] or '?'}) - in-game keys")
                self.go("ingame")
            else:
                log("game ended - menu keys"); self.game = (None, None)
                self.go(self.menu_page)
                if self.restart_pending:
                    self.restart_pending = False; self.run(4, lambda: self.cab.restart("deferred tool change"))
        stamp = self.cab._conf[0]
        self.cab.settings()
        if self.cab._conf[0] != stamp and self.page != "themes" and self.busy is None:
            self.build()                                  # settings.conf changed (state keys, theme caption)
        self.check_idle()


def main():
    global LOG
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--retrofe", required=True); ap.add_argument("--manifest", required=True)
    ap.add_argument("--config", default=os.path.join(HERE, "deck.json")); ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.manifest, exist_ok=True); LOG = os.path.join(a.manifest, "amdeck.log")

    _k32.CreateMutexW(None, False, "Global\\ArcadeMasterStreamDeck")
    if _k32.GetLastError() == 183:                         # ERROR_ALREADY_EXISTS
        log("another amdeck is running - exiting"); return 0
    cab = Cabinet(a.retrofe, a.manifest)
    told = False
    while True:
        if "streamdeck.exe" in processes():                # Elgato's app owns the deck: wait for it to close
            if a.once:
                log("Elgato Stream Deck app is running and owns the deck"); return 1
            if not told:
                log("Elgato Stream Deck app is running - waiting for it to close (take it out of startup)"); told = True
            time.sleep(30); continue
        decks = DeviceManager().enumerate()
        if not decks:
            if a.once:
                log("no Stream Deck found"); return 1
            time.sleep(10); continue
        deck = decks[0]
        try:
            deck.open(); deck.reset()
            ctl = Controller(deck, cab, a.config)
            deck.set_brightness(ctl.cfg.get("brightness", [30, 60, 100])[ctl.bright])
            log(f"{deck.deck_type()} {deck.get_serial_number()} ({deck.key_count()} keys) - RetroFE {a.retrofe}")
            ctl.build(); ctl.render()
            if a.once:
                deck.close(); return 0
            deck.set_key_callback(ctl.on_key)
            threading.Thread(target=ctl.animate, daemon=True).start()
            ctl.prerender()
            while deck.connected():
                ctl.tick(); time.sleep(1)
            log("deck disconnected - waiting for it")
        except Exception as e:
            log(f"deck error: {e!r}")
        finally:
            try:
                deck.close()
            except Exception:
                pass
        told = False
        time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())
