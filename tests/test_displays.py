"""The viewer's decoders for the decks' displays and its control surface."""
import os
import struct
import tempfile
import unittest
import zlib

from helpers import pack7
from viewer.displays import FxScreens, PlatterScreens, bits7
from viewer.surface import Surface


class Bits7(unittest.TestCase):
    def test_round_trip(self):
        data = bytes(range(256)) * 3
        self.assertEqual(bits7(pack7(data), len(data)), data)


class Fx(unittest.TestCase):
    def test_whole_screen(self):
        img = bytes((i * 37) & 0xFF for i in range(512))
        b = FxScreens.PREFIX + [0, 0, 5, 0, 4, 0, 127] + pack7(img) + [0xF7]
        fx = FxScreens()
        self.assertTrue(fx.wants(0, b))
        self.assertFalse(fx.wants(1, b))
        self.assertTrue(fx.msg(b))
        self.assertEqual(bytes(fx.screens[5]), img)

    def test_part(self):
        fx = FxScreens()
        # page 1, columns 10-12 of OLED 2
        b = FxScreens.PREFIX + [0, 0, 2, 1, 2, 10, 12] + pack7(b"\xff\x81\xff") + [0xF7]
        fx.msg(b)
        s = fx.screens[2]
        self.assertEqual(bytes(s[128 + 10:128 + 13]), b"\xff\x81\xff")
        self.assertEqual(sum(s) - (0xff + 0x81 + 0xff), 0)

    def test_rejects_out_of_range(self):
        fx = FxScreens()
        self.assertFalse(fx.msg(FxScreens.PREFIX + [0, 0, 9, 0, 1, 0, 0, 0, 0xF7]))
        self.assertFalse(fx.msg(FxScreens.PREFIX + [0, 0, 1, 0, 5, 0, 0, 0, 0xF7]))


def sysex(dev_id, cmd, data):
    return [0xF0, 0x00, 0x02, 0x0B, dev_id, 0x08, cmd, *data, 0xF7]


def tiny_png():
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff")) + chunk(b"IEND", b""))


class Platters(unittest.TestCase):
    def test_angle_colour_show(self):
        p = PlatterScreens()
        self.assertTrue(p.msg(2, [0xE0, 0x00, 0x40]))  # half a turn
        self.assertAlmostEqual(p.screens["2"]["angle"], 0.5)
        self.assertTrue(p.msg(2, sysex(0x11, 0x0B, [0, 9, 2, 0xF, 0xF, 1, 2, 3, 4, 5, 6])))
        self.assertEqual(p.screens["2"]["colors"]["2"], [255, 0x12, 0x34, 0x56])
        self.assertTrue(p.msg(2, sysex(0x11, 0x0A, [0, 4, 5, 2, 1, 4])))
        self.assertEqual(p.screens["2"]["show"], [5, 2, 1, 4])
        self.assertEqual(p.screens["2"]["loop"], "1/4")

    def test_artwork_upload(self):
        p, png = PlatterScreens(), tiny_png()
        n = len(png)
        p.msg(3, sysex(0x12, 0x0C, [0, 3, n >> 14, (n >> 7) & 127, n & 127]))
        p.msg(3, sysex(0x12, 0x0D, [0, 0, 0, 0, 0] + pack7(png)))
        self.assertTrue(p.msg(3, sysex(0x12, 0x0E, [0, 9, 7])))
        self.assertEqual(p.artwork(3, 7), png)
        self.assertEqual(p.screens["3"]["art"]["7"], 1)


class Controls(unittest.TestCase):
    PANEL = {"controls": [
        {"id": "play", "t": "btn", "ch": 0, "n": 0x00},
        {"id": "vol", "t": "fader", "ch": 1, "cc": 0x13, "d": 0},
        {"id": "pitch", "t": "pitch", "ch": 0, "cc": 0x1F, "cc2": 0x3F},
        {"id": "mx", "t": "knob", "ch": 2, "cc": 5, "dev": 1},
        {"id": "master", "t": "knob", "hw": 1, "ch": 0, "cc": 0},
    ]}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.mkfifo(os.path.join(self.tmp.name, "midi-in"))
        self.rd = os.open(os.path.join(self.tmp.name, "midi-in"), os.O_RDONLY | os.O_NONBLOCK)
        self.s = Surface(self.tmp.name, self.PANEL)

    def tearDown(self):
        os.close(self.rd)
        self.tmp.cleanup()

    def sent(self):
        return os.read(self.rd, 4096).decode().split("\n")[:-1]

    def test_events(self):
        self.s.event("play press")
        self.assertEqual(self.sent(), ["90 00 7f"])
        self.s.event("vol set 100")
        self.assertEqual(self.sent(), ["b1 13 64"])
        self.s.event("pitch set 0")  # the top of the fader: fastest, the deck sends the max
        self.assertEqual(self.sent(), ["b0 1f 7f", "b0 3f 7f"])
        self.s.event("mx set 3")
        self.assertEqual(self.sent(), ["@1 b2 05 03"])

    def test_hw_controls_stay_here(self):
        self.s.event("master set 80")
        self.assertEqual(self.s.values["master"], 80)
        try:
            got = os.read(self.rd, 10)  # no writer yet: end of file
        except BlockingIOError:
            got = b""  # a writer, but nothing written
        self.assertEqual(got, b"")

    def test_leds(self):
        self.assertTrue(self.s.handle(0, [0x90, 0x00, 0x7F]))
        self.assertTrue(self.s.handle(1, [0xB2, 0x05, 0x40]))
        self.assertEqual(self.s.leds, {"n0.0": 127, "d1c2.5": 64})


if __name__ == "__main__":
    unittest.main()
