"""The touchscreen's frames (from the shim), and the FIFOs the viewer writes into Engine."""
import mmap
import os
import struct
import threading
import time


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
