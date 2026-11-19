"""Software waveforms for Engine's waveform views (when it renders without OpenGL)."""
import json
import os
import struct
import subprocess
import threading
import time


class Waves:
    """Waveform pictures for Engine's waveform views.

    Engine draws its waveforms with OpenGL, which the software renderer can't run, so the
    emulator turns those items off and the QML it injects (assets/qml-inject) shows these PNGs
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
