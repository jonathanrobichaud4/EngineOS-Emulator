"""The control surface: panel events to the deck's MIDI, Engine's MIDI back to LED state."""
import os
import threading
import time

from .displays import FxScreens, PlatterScreens
from .frames import Fifo


class Surface:
    """A control's "dev" (default 0) is which of the deck's internal MIDI devices it belongs to:
    the SC LIVE 4 has one; the Prime 4 has the Controller (0), the Mixer (1) and the left and
    right jog displays (2, 3). Lines for device N > 0 carry "@N " in front, both ways."""

    def __init__(self, emu, panel):
        self.emu = emu
        self.midi = Fifo(os.path.join(emu, "midi-in"))
        self.out_path = os.path.join(emu, "midi-out")
        self.ctl = {c["id"]: c for c in panel["controls"] if "id" in c}
        self.values = {}
        for c in self.ctl.values():
            t = c["t"]
            if t in ("knob", "fader", "xfader", "sw", "sel"):
                self.values[c["id"]] = c.get("d", 0)  # sw / sel: an index into vals
            elif t == "pitch":
                self.values[c["id"]] = 8192
            elif t == "jog":
                self.values[c["id"]] = 0
        self.leds = {}
        self.jog = {}  # SC LIVE 4, per MIDI channel: the jog display's time and BPM
        self.platters = PlatterScreens()
        self.oleds = FxScreens()
        self.seq = 0
        self.cond = threading.Condition()
        threading.Thread(target=self.follow, daemon=True).start()

    def changed(self):
        with self.cond:
            self.seq += 1
            self.cond.notify_all()

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

    @staticmethod
    def tag(c, lines):
        d = c.get("dev", 0)
        return [f"@{d} {x}" for x in lines] if d else lines

    def event(self, line):
        """One panel event: '<id> <action> [value]'."""
        parts = line.split()
        if len(parts) < 2 or parts[0] not in self.ctl:
            return
        c, act = self.ctl[parts[0]], parts[1]
        arg = float(parts[2]) if len(parts) > 2 else 0
        if "hw" in c:
            # The deck's own mixer hardware (master, headphones): nothing goes to Engine; the
            # value is kept for the emulator's audio mixer. Buttons toggle.
            if act == "set":
                self.values[c["id"]] = arg
            elif act == "press" and c["t"] == "btn":
                self.values[c["id"]] = 0 if self.values.get(c["id"]) else 1
            self.changed()
            return
        ch, t, out = c["ch"], c["t"], []
        if act in ("press", "release"):
            note = c.get("n") if t in ("btn", "pad") else c.get("push") if t == "enc" else c.get("touch")
            if note is None:
                return
            out.append(f"{0x90 | ch:02x} {note:02x} 7f" if act == "press" else f"{0x80 | ch:02x} {note:02x} 00")
            out = self.tag(c, out)
        elif act == "set":
            if t in ("sw", "sel"):
                arg = max(0, min(len(c["vals"]) - 1, int(arg)))
            elif t == "pitch":
                arg = max(0, min(16383, int(arg)))
            self.values[c["id"]] = arg
            out += self.tag(c, self.msgs_for(c, arg))
        elif act == "turn" and t == "enc":
            n = int(arg)
            for _ in range(min(abs(n), 32)):
                out.append(f"{0xB0 | ch:02x} {c['cc']:02x} {'01' if n > 0 else '7f'}")
            out = self.tag(c, out)
        elif act == "spin" and t == "jog":
            v = (int(self.values[c["id"]]) + int(arg)) & 0x3FFF
            self.values[c["id"]] = v
            out += self.tag(c, self.msgs_for(c, v))
        if out:
            self.midi.send("\n".join(out) + "\n")
            self.changed()

    def replay(self, dev=0):
        """Answer Engine's 'report absolute controls' SysEx like the hardware does (per device)."""
        out = []
        for cid, v in self.values.items():
            c = self.ctl[cid]
            if c["t"] == "jog" or c.get("dev", 0) != dev:
                continue
            out += self.tag(c, self.msgs_for(c, v))
        self.midi.send("\n".join(out) + "\n")

    def handle(self, dev, b):
        """One message from Engine to device `dev` (bytes as ints). True if the page should hear."""
        pre = f"d{dev}" if dev else ""
        st, ch = b[0] & 0xF0, b[0] & 0x0F
        if st in (0x90, 0x80) and len(b) >= 3:
            self.leds[f"{pre}n{ch}.{b[1]}"] = b[2] if st == 0x90 else 0
            return True
        if st == 0xB0 and len(b) >= 3:
            self.leds[f"{pre}c{ch}.{b[1]}"] = b[2]
            return True
        if b[0] == 0xF0 and b[1:5] == [0x00, 0x02, 0x0B, 0x7F] and len(b) >= 7 and b[6] == 0x04:
            # "report every control's position", F0 00 02 0B 7F <family> 04 F7
            threading.Thread(target=self.replay, args=(dev,), daemon=True).start()
            return False
        if dev in PlatterScreens.DEVICES:
            return self.platters.msg(dev, b)
        if self.oleds.wants(dev, b):
            return self.oleds.msg(b)
        if dev == 0 and b[0] == 0xF0 and b[1:4] == [0x00, 0x02, 0x0B] and len(b) >= 8 and b[4] < 0x10:
            # The SC LIVE 4 jog display's digits (LcdWheelDisplay.qml): F0 00 02 0B <ch> 00|01 h m s cs F7
            # is the time (01: counting down), F0 00 02 0B <ch> 02 <6 hex nibbles> F7 the BPM x 100.
            j = self.jog.setdefault(str(b[4]), {})
            if b[5] in (0, 1) and len(b) >= 11:
                j["time"] = {"minus": b[5] == 1, "h": b[6], "m": b[7], "s": b[8], "cs": b[9]}
                return True
            if b[5] == 2 and len(b) >= 13:
                j["bpm"] = int("".join(f"{x & 0xF:x}" for x in b[6:12]), 16) / 100
                return True
        return False

    def follow(self):
        """Tail midi-out: LED notes, meter CCs, displays and the SysEx queries."""
        pos, ino = 0, None
        while True:
            try:
                st = os.stat(self.out_path)
            except FileNotFoundError:
                time.sleep(0.5)
                continue
            if st.st_ino != ino or st.st_size < pos:
                ino, pos = st.st_ino, 0  # Engine restarted: everything it showed is gone
                with self.cond:
                    self.leds.clear()
                    self.jog.clear()
                    self.platters.clear()
                    self.oleds.clear()
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
                dev = 0
                if line.startswith("@"):
                    tag, _, line = line.partition(" ")
                    dev = int(tag[1:] or 0)
                try:
                    b = [int(x, 16) for x in line.split() if x]
                except ValueError:
                    continue
                if b and self.handle(dev, b):
                    changed = True
            if changed:
                self.changed()

    def artwork(self, dev, slot):
        return self.platters.artwork(dev, slot)

    def state(self, since, timeout=2.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != since, timeout)
            return {"seq": self.seq, "leds": dict(self.leds), "values": dict(self.values),
                    "jog": {k: dict(v) for k, v in self.jog.items()},
                    "platters": self.platters.state(), "oleds": self.oleds.state()}
