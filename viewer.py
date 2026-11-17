#!/usr/bin/env python3
"""EngineX emulator viewer: the emulated SC LIVE 4 in a browser.

Serves http://localhost:PORT/ with the deck's top panel: the touchscreen in the middle (frames
from the shim in Engine) and every control around it, wired to Engine as the deck's internal
MIDI control surface would be. Also streams Engine's audio output, manages the emulated USB
drives / SD card, and can reboot the emulated deck. Standard library only.

Files shared with the shim inside the chroot (<rootfs>/tmp/emu):
  fb            frames (32-byte header + 32-bit pixels)
  input         FIFO, touch commands for the screen
  midi-in       FIFO, raw MIDI from the panel to Engine (hex bytes, one message per line)
  midi-out      MIDI Engine sends to the controller (LEDs, meters, SysEx), appended hex lines
  audio         ring of the selected output pair (64-byte header + 16-bit stereo)
  audio-pcms    audio devices Engine opened; audio-select picks the pair to hear
"""
import argparse
import json
import mmap
import os
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


# ------------------------------------------------------------------------------ frames
class Frames:
    def __init__(self, path):
        self.path = path
        self.mm, self.ino = None, None
        self.cond = threading.Condition()
        self.seq = 0
        threading.Thread(target=self.watch, daemon=True).start()

    def open(self):
        if self.mm is not None and len(self.mm) and os.path.exists(self.path) and \
                os.stat(self.path).st_ino != self.ino:
            self.mm = None  # Engine restarted and made a new file
        if self.mm is None and os.path.exists(self.path) and os.path.getsize(self.path) > 32:
            f = open(self.path, "rb")
            self.ino = os.fstat(f.fileno()).st_ino
            self.mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        return self.mm

    def header(self):
        try:
            m = self.open()
        except (OSError, ValueError):
            self.mm = None
            return None
        if m is None or m[:4] != b"EMUF":
            return None
        return struct.unpack_from("<5I", m, 4)  # w, h, bpl, format, seq

    def watch(self):
        while True:
            h = self.header()
            if h and h[4] != self.seq:
                with self.cond:
                    self.seq = h[4]
                    self.cond.notify_all()
            time.sleep(0.02)

    def get(self, since, timeout=2.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != since, timeout)
        h = self.header()
        if not h or h[4] == since:
            return None
        w, hgt, bpl, _fmt, seq = h
        return struct.pack("<4I", seq, w, hgt, bpl) + self.mm[32:32 + bpl * hgt]


class Fifo:
    """Writer that survives the reader (Engine) going away and coming back."""

    def __init__(self, path):
        self.path, self.f, self.lock = path, None, threading.Lock()

    def send(self, text):
        with self.lock:
            for _ in range(2):
                try:
                    if self.f is None:
                        fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
                        os.set_blocking(fd, True)
                        self.f = os.fdopen(fd, "w")
                    self.f.write(text)
                    self.f.flush()
                    return True
                except OSError:
                    self.f = None
            return False


# ------------------------------------------------------------------------------ controls
class Surface:
    """The control surface: panel events -> JP21 MIDI, Engine's MIDI -> LED state."""

    def __init__(self, emu, panel):
        self.emu = emu
        self.midi = Fifo(os.path.join(emu, "midi-in"))
        self.out_path = os.path.join(emu, "midi-out")
        self.ctl = {c["id"]: c for c in panel["controls"] if "id" in c}
        self.values = {}
        for c in self.ctl.values():
            t = c["t"]
            if t in ("knob", "fader", "xfader"):
                self.values[c["id"]] = c.get("d", 0)
            elif t in ("sw", "sel"):
                self.values[c["id"]] = c.get("d", 0)  # index into vals
            elif t == "pitch":
                self.values[c["id"]] = 8192
            elif t == "jog":
                self.values[c["id"]] = 0
        self.leds = {}
        self.seq = 0
        self.cond = threading.Condition()
        threading.Thread(target=self.follow, daemon=True).start()

    def msgs_for(self, c, v):
        """Absolute control value -> MIDI lines."""
        ch, t = c["ch"], c["t"]
        if t in ("knob", "fader", "xfader"):
            return [f"{0xB0 | ch:02x} {c['cc']:02x} {max(0, min(127, int(v))):02x}"]
        if t in ("pitch", "jog"):
            v = int(v) & 0x3FFF
            if t == "pitch":
                v = 16383 - v  # panel: top = 0; the deck sends top = max, so down means faster
            return [f"{0xB0 | ch:02x} {c['cc']:02x} {v >> 7:02x}", f"{0xB0 | ch:02x} {c['cc2']:02x} {v & 127:02x}"]
        if t == "sw":
            val = c["vals"][int(v)]
            return [f"{0x90 | ch:02x} {c['n']:02x} {val:02x}" if val else f"{0x80 | ch:02x} {c['n']:02x} 00"]
        if t == "sel":
            val = c["vals"][int(v)]
            if "n" in c:  # a switch Engine reads as a note whose velocity is the position
                return [f"{0x90 | ch:02x} {c['n']:02x} {val:02x}"]
            return [f"{0xB0 | ch:02x} {c['cc']:02x} {val:02x}"]
        return []

    def event(self, line):
        """One panel event: '<id> <action> [value]'."""
        parts = line.split()
        if len(parts) < 2 or parts[0] not in self.ctl:
            return
        c, act = self.ctl[parts[0]], parts[1]
        arg = float(parts[2]) if len(parts) > 2 else 0
        ch, t, out = c["ch"], c["t"], []
        if act in ("press", "release"):
            note = c.get("n") if t in ("btn", "pad") else c.get("push") if t == "enc" else c.get("touch")
            if note is None:
                return
            out.append(f"{0x90 | ch:02x} {note:02x} 7f" if act == "press" else f"{0x80 | ch:02x} {note:02x} 00")
        elif act == "set":
            if t in ("sw", "sel"):
                arg = max(0, min(len(c["vals"]) - 1, int(arg)))
            elif t == "pitch":
                arg = max(0, min(16383, int(arg)))
            self.values[c["id"]] = arg
            out += self.msgs_for(c, arg)
        elif act == "turn" and t == "enc":
            n = int(arg)
            for _ in range(min(abs(n), 32)):
                out.append(f"{0xB0 | ch:02x} {c['cc']:02x} {'01' if n > 0 else '7f'}")
        elif act == "spin" and t == "jog":
            v = (int(self.values[c["id"]]) + int(arg)) & 0x3FFF
            self.values[c["id"]] = v
            out += self.msgs_for(c, v)
        if out:
            self.midi.send("\n".join(out) + "\n")
            with self.cond:
                self.seq += 1
                self.cond.notify_all()

    def replay(self):
        """Answer Engine's 'report absolute controls' SysEx like the hardware does."""
        out = []
        for cid, v in self.values.items():
            c = self.ctl[cid]
            if c["t"] == "jog":
                continue
            out += self.msgs_for(c, v)
        self.midi.send("\n".join(out) + "\n")

    def follow(self):
        """Tail midi-out: LED notes, meter CCs, and the SysEx queries."""
        pos, ino = 0, None
        while True:
            try:
                st = os.stat(self.out_path)
            except FileNotFoundError:
                time.sleep(0.5)
                continue
            if st.st_ino != ino or st.st_size < pos:
                ino, pos = st.st_ino, 0
                with self.cond:
                    self.leds.clear()
            if st.st_size == pos:
                time.sleep(0.03)
                continue
            with open(self.out_path, "rb") as f:
                f.seek(pos)
                data = f.read()
            end = data.rfind(b"\n") + 1
            pos += end
            changed = False
            for line in data[:end].decode("ascii", "ignore").splitlines():
                b = [int(x, 16) for x in line.split() if x]
                if not b:
                    continue
                st_, ch = b[0] & 0xF0, b[0] & 0x0F
                if st_ in (0x90, 0x80) and len(b) >= 3:
                    self.leds[f"n{ch}.{b[1]}"] = b[2] if st_ == 0x90 else 0
                    changed = True
                elif st_ == 0xB0 and len(b) >= 3:
                    self.leds[f"c{ch}.{b[1]}"] = b[2]
                    changed = True
                elif b[0] == 0xF0 and b[1:7] == [0x00, 0x02, 0x0B, 0x7F, 0x12, 0x04]:
                    threading.Thread(target=self.replay, daemon=True).start()
            if changed:
                with self.cond:
                    self.seq += 1
                    self.cond.notify_all()

    def state(self, since, timeout=2.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != since, timeout)
            return {"seq": self.seq, "leds": dict(self.leds), "values": dict(self.values)}


# ------------------------------------------------------------------------------ audio
class Audio:
    def __init__(self, emu):
        self.path = os.path.join(emu, "audio")
        self.emu = emu
        self.mm, self.ino = None, None

    def open(self):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            self.mm = None
            return None
        if self.mm is None or st.st_ino != self.ino:
            f = open(self.path, "rb")
            self.ino = st.st_ino
            self.mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        return self.mm

    def get(self, pos):
        """Frames written after `pos` (a running frame counter), as 16-bit stereo."""
        deadline = time.time() + 0.5
        while True:
            m = self.open()
            if m is not None and m[:4] == b"EMUA":
                rate, frames, _idx, written = struct.unpack_from("<IIIQ", m, 4)
                if pos == 0 or pos > written or written - pos > frames - rate:
                    pos = max(0, written - rate // 5)  # (re)start 200 ms behind
                n = written - pos
                if n >= rate // 50 or time.time() > deadline:
                    n = min(n, rate)
                    a = pos % frames
                    first = min(n, frames - a)
                    body = m[64 + a * 4:64 + (a + first) * 4] + m[64:64 + (n - first) * 4]
                    return struct.pack("<QI", pos + n, rate) + body
            elif time.time() > deadline:
                return struct.pack("<QI", 0, 0)
            time.sleep(0.01)

    def devices(self):
        out = []
        try:
            for line in open(os.path.join(self.emu, "audio-pcms")):
                idx, kind, name, ch, rate = line.rstrip("\n").split("\t")
                if kind == "playback":
                    out.append({"index": int(idx), "name": name, "channels": int(ch), "rate": int(rate)})
        except FileNotFoundError:
            pass
        sel = None
        try:
            sel = [int(x) for x in open(os.path.join(self.emu, "audio-select")).read().split()]
        except (FileNotFoundError, ValueError):
            pass
        return {"devices": out, "select": sel}

    def select(self, idx, left, right):
        with open(os.path.join(self.emu, "audio-select"), "w") as f:
            f.write(f"{idx} {left} {right}\n")


# ------------------------------------------------------------------------------ waveforms
class Waves:
    """Waveform pictures for Engine's waveform views.

    Engine draws its waveforms with OpenGL, which the software renderer can't run, so the
    emulator turns those items off and the QML it injects (files/qml-inject) shows these PNGs
    instead: one strip at PPS pixels per second that scrolls with the play position, and a
    small one for the overview. Three bands (low, mid, high) drawn on top of each other, like
    Engine's own. Made with ffmpeg + numpy; cached by file, size and date."""

    PPS, H, OV_W, OV_H = 100, 160, 1024, 96

    def __init__(self, rootfs):
        self.rootfs = rootfs
        self.dir = os.path.join(rootfs, "tmp/emu/wave")
        self.jobs = {}  # keys being rendered
        self.lock = threading.Lock()
        os.makedirs(os.path.join(self.dir, "req"), exist_ok=True)
        threading.Thread(target=self.watch, daemon=True).start()

    def resolve(self, net):
        """Engine's TrackNetworkPath (net://<uuid>/<volume>/<path>) -> file in the rootfs."""
        if not net.startswith("net://"):
            return None
        parts = net[6:].split("/", 2)
        if len(parts) < 3 or parts[1] in ("", "(Unknown)"):
            return None
        f = os.path.join(self.rootfs, "media", parts[1], parts[2])
        return f if os.path.isfile(f) else None

    def watch(self):
        """Engine's QML asks by writing wave/req/<md5 of the track path> (QML can write files,
        not reach this server: the deck may have no network). The answer is wave/<md5>.json."""
        import hashlib
        req = os.path.join(self.dir, "req")
        while True:
            try:
                names = os.listdir(req)
            except FileNotFoundError:
                names = []
            for name in names:
                path = os.path.join(req, name)
                try:
                    net = open(path, encoding="utf-8", errors="replace").read().strip()
                    os.unlink(path)
                except OSError:
                    continue
                key = hashlib.md5(net.encode()).hexdigest()
                f = self.resolve(net)
                if not f:
                    self.answer(key, {"state": "none"})
                    continue
                st = os.stat(f)
                sig = f"{f}|{st.st_size}|{int(st.st_mtime)}"
                try:
                    old = json.load(open(os.path.join(self.dir, key + ".json")))
                    if old.get("sig") == sig and old.get("state") == "ready":
                        continue
                except (OSError, ValueError):
                    pass
                with self.lock:
                    if key in self.jobs:
                        continue
                    self.jobs[key] = True
                threading.Thread(target=self.make, args=(key, f, sig), daemon=True).start()
            time.sleep(0.3)

    def answer(self, key, obj):
        os.makedirs(self.dir, exist_ok=True)
        tmp = os.path.join(self.dir, key + ".json.tmp")
        json.dump(obj, open(tmp, "w"))
        os.replace(tmp, os.path.join(self.dir, key + ".json"))

    def make(self, key, f, sig):
        try:
            res = dict(self.render(key, f), state="ready", sig=sig)
        except Exception as e:  # shown in Engine's log; the view just stays empty
            res = {"state": f"error: {e}"}
        self.answer(key, res)
        with self.lock:
            self.jobs.pop(key, None)

    def render(self, key, f):
        import numpy as np
        os.makedirs(self.dir, exist_ok=True)
        sr = 22050
        pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                             capture_output=True, check=True, timeout=600).stdout
        x = np.frombuffer(pcm, dtype=np.float32)
        hop = sr // self.PPS
        n = max(1, len(x) // hop)
        frames = np.zeros((n, hop * 2), dtype=np.float32)
        pad = np.concatenate([x, np.zeros(hop * 2, dtype=np.float32)])
        idx = np.arange(n)[:, None] * hop + np.arange(hop * 2)[None, :]
        frames[:] = pad[idx] * np.hanning(hop * 2)[None, :]
        spec = np.abs(np.fft.rfft(frames, axis=1)) ** 2
        hz = np.fft.rfftfreq(hop * 2, 1 / sr)
        bands = [np.sqrt(spec[:, (hz >= lo) & (hz < hi)].sum(axis=1)) for lo, hi in ((0, 250), (250, 2500), (2500, sr))]
        peak = max(float(np.percentile(b, 99.5)) for b in bands) or 1.0
        lvl = [np.clip(b / peak, 0, 1) for b in bands]
        # Engine's look: low (bass) fullest underneath, mid and high on top, mirrored.
        cols = [(0x1f, 0x5f, 0xd6), (0xd8, 0x7a, 0x1e), (0xf2, 0xf2, 0xf2)]
        scale = [1.0, 0.75, 0.5]

        def picture(levels, w, h):
            img = np.zeros((h, w, 4), dtype=np.uint8)
            mid = h / 2
            ys = np.abs(np.arange(h) + 0.5 - mid)[:, None]  # distance from the centre line
            for lv, c, k in zip(levels, cols, scale):
                reach = (lv * k * mid)[None, :]
                on = ys <= reach
                img[on] = (*c, 255)
            return img

        main = picture(lvl, n, self.H)
        # The overview: the same bands, max over each column's span.
        cuts = np.linspace(0, n, self.OV_W + 1).astype(int)
        ov = [np.array([b[a:max(a + 1, z)].max() for a, z in zip(cuts[:-1], cuts[1:])]) for b in lvl]
        overview = picture(ov, self.OV_W, self.OV_H)
        self.png(os.path.join(self.dir, key + "-main.png"), main)
        self.png(os.path.join(self.dir, key + "-ov.png"), overview)
        return {"main": f"file:///tmp/emu/wave/{key}-main.png", "overview": f"file:///tmp/emu/wave/{key}-ov.png",
                "seconds": len(x) / sr, "pps": self.PPS}

    @staticmethod
    def png(path, rgba):
        import zlib
        h, w = rgba.shape[:2]
        raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))
        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
        tmp = path + ".tmp"
        open(tmp, "wb").write(data)
        os.replace(tmp, path)


# ------------------------------------------------------------------------------ drives
class Drives:
    def __init__(self, path):
        self.path = path

    def list(self):
        out = []
        try:
            for line in open(self.path):
                p = line.rstrip("\n").split("\t")
                if len(p) == 3:
                    out.append({"label": p[0], "kind": p[1], "folder": p[2], "ok": os.path.isdir(p[2])})
        except FileNotFoundError:
            pass
        return out

    def add(self, folder, kind, label):
        folder = os.path.abspath(os.path.expanduser(folder))
        if not os.path.isdir(folder):
            return f"no such folder: {folder}"
        kind = "sd" if kind == "sd" else "usb"
        label = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in (label or os.path.basename(folder)))[:11] or "MUSIC"
        cur = self.list()
        if any(d["label"] == label for d in cur):
            return f"a drive called {label} is already attached"
        if kind == "sd" and any(d["kind"] == "sd" for d in cur):
            return "the deck has one SD slot and it's in use"
        with open(self.path, "a") as f:
            f.write(f"{label}\t{kind}\t{folder}\n")
        return None

    def remove(self, label):
        keep = [d for d in self.list() if d["label"] != label]
        with open(self.path + ".tmp", "w") as f:
            for d in keep:
                f.write(f"{d['label']}\t{d['kind']}\t{d['folder']}\n")
        os.replace(self.path + ".tmp", self.path)


# ------------------------------------------------------------------------------ console forward
def forward(listen_port, target):
    """Plain TCP forwarder: the deck runs in its own network namespace, so its web console
    isn't on the PC's localhost (which is what Windows forwards). This puts it back there."""
    import socket
    host, port = target.rsplit(":", 1)

    def pipe(a, b):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
        except OSError:
            pass
        for x in (a, b):
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def serve():
        ls = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("0.0.0.0", listen_port))
        ls.listen(64)
        while True:
            c, _ = ls.accept()
            try:
                u = socket.create_connection((host, int(port)), timeout=5)
                u.settimeout(None)
            except OSError:
                c.close()
                continue
            threading.Thread(target=pipe, args=(c, u), daemon=True).start()
            threading.Thread(target=pipe, args=(u, c), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rootfs", default=os.environ.get("EMU_ROOTFS", "rootfs"))
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--console", default="http://localhost:8080/", help="link to EngineX's web console")
    ap.add_argument("--forward", action="append", default=[], metavar="PORT=HOST:PORT",
                    help="forward a local TCP port into the deck's network namespace")
    ap.add_argument("--drives", default=os.path.join(HERE, "drives.txt"))
    a = ap.parse_args()
    emu = os.path.join(a.rootfs, "tmp/emu")
    panel_json = open(os.path.join(HERE, "files", "panel.json")).read()
    frames = Frames(os.path.join(emu, "fb"))
    touch = Fifo(os.path.join(emu, "input"))
    surface = Surface(emu, json.loads(panel_json))
    audio = Audio(emu)
    drives = Drives(a.drives)
    waves = Waves(a.rootfs)
    page = open(os.path.join(HERE, "files", "panel.html"), encoding="utf-8").read() \
        .replace("__CONSOLE__", a.console).encode()

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def reply(self, code, body=b"", ctype="application/octet-stream"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def json(self, obj, code=200):
            self.reply(code, json.dumps(obj).encode(), "application/json")

        def q(self, key, default="0"):
            for kv in self.path.partition("?")[2].split("&"):
                k, _, v = kv.partition("=")
                if k == key:
                    return v
            return default

        def do_GET(self):
            p = self.path.partition("?")[0]
            if p in ("/", "/index.html"):
                self.reply(200, page, "text/html; charset=utf-8")
            elif p == "/panel.json":
                self.reply(200, panel_json.encode(), "application/json")
            elif p == "/frame":
                body = frames.get(int(self.q("since")))
                self.reply(200, body) if body else self.reply(204)
            elif p == "/state":
                self.json(surface.state(int(self.q("since"))))
            elif p == "/audio":
                self.reply(200, audio.get(int(self.q("pos"))))
            elif p == "/audio-devices":
                self.json(audio.devices())
            elif p == "/drives":
                self.json(drives.list())
            elif p == "/status":
                self.json({"frame": frames.header()})
            else:
                self.reply(404)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            text = self.rfile.read(n).decode("utf-8", "ignore")
            p = self.path.partition("?")[0]
            if p == "/input":
                ok = touch.send(text if text.endswith("\n") else text + "\n")
                self.reply(204 if ok else 503)
            elif p == "/control":
                for line in text.splitlines():
                    surface.event(line)
                self.reply(204)
            elif p == "/audio-select":
                idx, l, r = (int(x) for x in text.split())
                audio.select(idx, l, r)
                self.reply(204)
            elif p == "/drives":
                d = json.loads(text or "{}")
                if d.get("action") == "remove":
                    drives.remove(d.get("label", ""))
                    err = None
                else:
                    err = drives.add(d.get("folder", ""), d.get("kind", "usb"), d.get("label", ""))
                self.json({"error": err, "drives": drives.list()}, 400 if err else 200)
            elif p == "/reboot":
                # Like power-cycling the deck: stop and start the whole emulator. Runs detached,
                # since stopping it also stops this viewer; the page reconnects on its own.
                emu_sh = os.path.join(HERE, "emu.sh")
                subprocess.Popen(["setsid", "sh", "-c", f"sleep 0.5; '{emu_sh}' stop; '{emu_sh}' start"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
                self.reply(204)
            else:
                self.reply(404)

    print(f"EngineX emulator viewer: http://localhost:{a.port}/", flush=True)
    for f in a.forward:
        lp, tgt = f.split("=", 1)
        forward(int(lp), tgt)
    ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
