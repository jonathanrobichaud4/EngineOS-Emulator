"""Engine's audio output: the ring the shim writes the selected output pair into."""
import mmap
import os
import struct
import time


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
