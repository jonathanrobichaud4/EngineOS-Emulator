"""Decoders for the decks' own displays, driven by Engine over MIDI.

Each class takes the messages for its display (Surface.follow routes them here) and keeps what the
page draws. The SysEx formats are in docs/display-protocol.md. The SC LIVE 4's jog wheel LCDs are
simpler (CCs plus two SysEx), so Surface handles those itself.
"""
import base64
import time


def bits7(vals, nbytes):
    """inMusic's packing for binary data in SysEx: one bit stream of 7-bit bytes, read back as
    8-bit bytes (up to nbytes)."""
    acc = n = 0
    out = bytearray()
    for v in vals:
        acc, n = (acc << 7) | (v & 0x7F), n + 7
        while n >= 8 and len(out) < nbytes:
            n -= 8
            out.append((acc >> n) & 0xFF)
        acc &= (1 << n) - 1
    return bytes(out)


class PlatterScreens:
    """The Prime 4's jog wheel screens, MIDI devices 2 (left) and 3 (right).

    JC11S_Display_Device.qml and _Assignments.qml: pitch bend on channel 1 / 2 is the platter /
    slip position (a fraction of a turn); F0 00 02 0B <id> 08 <cmd> ... F7 sets the rest:
      0B 00 09 <element> <A R G B as nibble pairs>   element colour (0 artwork alpha, 1 logo,
          2 ring, 3 position, 4 slip overlay, 5 slip position, 8 loop text, 10 jump, 11 loop icon)
      0A 00 04 <s0> <s1> <artwork slot> <loop text>  what's shown: s0 bit 0 artwork, 1 logo,
          2 position, 4 slip; s1 bit 1 loop text, 3 jump icon, 4 loop icon
      7C 00 01 <brightness>
      0C 00 03 <size, 3 x 7 bits>, 0D <len, 2 x 7> <offset, 3 x 7> <data>..., 0E 00 09 <slot> ...
          an artwork upload: a 198 x 198 PNG, as one bit stream of 7-bit bytes in 3500-byte chunks
    """

    DEVICES = (2, 3)
    LOOP_TEXT = {0: "1/64", 1: "1/32", 2: "1/16", 3: "1/8", 4: "1/4", 5: "1/2", 6: "1", 7: "2", 0x10: "3",
                 8: "4", 0x11: "6", 9: "8", 0x12: "9", 10: "16", 11: "32", 12: "64", 14: "A", 15: "B"}

    def __init__(self):
        self.clear()

    def clear(self):
        self.screens, self.art, self.art_up, self.last = {}, {}, {}, 0

    def msg(self, dev, b):
        """One message for platter screen `dev`; True if the page should hear about it."""
        p = self.screens.setdefault(str(dev), {"angle": 0, "slip": 0, "colors": {}, "show": [0, 0, 0, 13], "bright": 127, "art": {}})
        if b[0] in (0xE0, 0xE1) and len(b) >= 3:
            p["angle" if b[0] == 0xE0 else "slip"] = ((b[2] << 7) | b[1]) / 16384
            now = time.time()
            if now - self.last < 0.05:  # ~80 a second; the page gets at most ~20
                return False
            self.last = now
            return True
        if b[0] != 0xF0 or b[1:4] != [0x00, 0x02, 0x0B] or len(b) < 8 or b[5] != 0x08:
            return False
        cmd, d = b[6], b[7:-1]
        if cmd == 0x0B and len(d) >= 11:
            n = d[3:11]
            p["colors"][str(d[2])] = [(n[i] << 4 | n[i + 1]) for i in range(0, 8, 2)]
        elif cmd == 0x0A and len(d) >= 6:
            p["show"] = d[2:6]
            p["loop"] = self.LOOP_TEXT.get(d[5], "")
        elif cmd == 0x7C and len(d) >= 3:
            p["bright"] = d[2]
        elif cmd == 0x0C and len(d) >= 5:
            self.art_up[dev] = [(d[2] << 14) | (d[3] << 7) | d[4], bytearray()]
            return False
        elif cmd == 0x0D and len(d) >= 5 and dev in self.art_up:
            total, buf = self.art_up[dev]
            off = (d[2] << 14) | (d[3] << 7) | d[4]
            chunk = bits7(d[5:], min(3500, total - off))
            buf[off:off + len(chunk)] = chunk
            return False
        elif cmd == 0x0E and len(d) >= 3 and dev in self.art_up:
            total, buf = self.art_up.pop(dev)
            slot = d[2]
            if len(buf) == total and buf[:4] == b"\x89PNG":
                self.art[(dev, slot)] = bytes(buf)
                p["art"][str(slot)] = p["art"].get(str(slot), 0) + 1  # a version, for the page's cache
        else:
            return False
        return True

    def artwork(self, dev, slot):
        return self.art.get((dev, slot))

    def state(self):
        return {k: dict(v) for k, v in self.screens.items()}


class FxScreens:
    """The Prime 4's FX screens: eight 128 x 32 OLEDs on the Controller (MIDI device 0,
    JC11S_Controller_Device.qml), 0-3 over FX 1's knobs, 4-7 over FX 2's.

    F0 00 02 0B 7F 08 0B <len, 2 x 7> <oled> <first page> <end page> <first column> <last column>
    <pixels> F7: pages are 8-pixel-tall rows, one byte per column (low bit on top), packed as one
    stream of 7-bit bytes.
    """

    PREFIX = [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x08, 0x0B]
    W, PAGES = 128, 4

    def __init__(self):
        self.clear()

    def clear(self):
        self.screens = {}  # index -> 512 bytes, page by page

    def wants(self, dev, b):
        return dev == 0 and b[:7] == self.PREFIX and len(b) >= 15

    def msg(self, b):
        i, p0, p1, x0, x1 = b[9], b[10], b[11], b[12], b[13]
        if i > 7 or p1 <= p0 or x1 < x0 or p1 > self.PAGES or x1 >= self.W:
            return False
        w = x1 - x0 + 1
        px = bits7(b[14:-1], (p1 - p0) * w)
        buf = self.screens.setdefault(i, bytearray(self.W * self.PAGES))
        for p in range(p0, p1):
            row = px[(p - p0) * w:(p - p0 + 1) * w]
            buf[p * self.W + x0:p * self.W + x0 + len(row)] = row
        return True

    def state(self):
        return {str(k): base64.b64encode(bytes(v)).decode() for k, v in self.screens.items()}
