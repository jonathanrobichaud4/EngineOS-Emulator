"""engine/linkbridge.py's packet handling (the bridge itself needs a running deck; see
docs/networking.md for checking that with tools/stagelinq_probe.py)."""
import os
import socket
import struct
import sys
import unittest

from helpers import ROOT

sys.path.insert(0, os.path.join(ROOT, "engine"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import linkbridge  # noqa: E402
from stagelinq_probe import frame  # noqa: E402

# A discovery frame as the emulated SC LIVE 4 sends it (captured)
DECK_FRAME = bytes.fromhex(
    "616972443ef4333ffafc42b2a60d225e492510d4000000040076006d00000022004400490053004300"
    "4f00560045005200450052005f0048004f005700440059005f00000008004a0050003200300000000a"
    "0035002e0033002e0030a9f9")


class Discovery(unittest.TestCase):
    def test_parse_capture(self):
        d = linkbridge.parse_discovery(DECK_FRAME)
        self.assertEqual((d["name"], d["action"], d["software"], d["version"], d["port"]),
                         ("vm", "DISCOVERER_HOWDY_", "JP20", "5.3.0", 43513))

    def test_round_trip(self):
        f = frame(bytes(16), "SCLIVE4", "DISCOVERER_EXIT_", "np2", "2.2.0", 51515)
        d = linkbridge.parse_discovery(f)
        self.assertEqual((d["name"], d["action"], d["port"]), ("SCLIVE4", "DISCOVERER_EXIT_", 51515))

    def test_rejects(self):
        for bad in (b"", b"airX" + DECK_FRAME[4:], DECK_FRAME[:30], DECK_FRAME[:20] + b"\xff\xff\xff\xff" + DECK_FRAME[24:]):
            self.assertIsNone(linkbridge.parse_discovery(bad))


class Packets(unittest.TestCase):
    def test_udp_packet(self):
        payload = b"EAAS\x01\x00"
        p = linkbridge.udp_packet("192.168.1.50", 40000, "255.255.255.255", 11224, payload)
        self.assertEqual(len(p), 20 + 8 + len(payload))
        self.assertEqual(linkbridge.checksum(p[:20]), 0, "IP header checksum")
        src, dst = socket.inet_aton("192.168.1.50"), socket.inet_aton("255.255.255.255")
        pseudo = src + dst + struct.pack("!BBH", 0, socket.IPPROTO_UDP, 8 + len(payload))
        self.assertEqual(linkbridge.checksum(pseudo + p[20:]), 0, "UDP checksum")
        self.assertEqual(struct.unpack("!HH", p[20:24]), (40000, 11224))
        self.assertEqual(p[28:], payload)

    def test_odd_length(self):
        p = linkbridge.udp_packet("10.0.0.1", 1, "10.0.0.2", 2, b"abc")
        pseudo = socket.inet_aton("10.0.0.1") + socket.inet_aton("10.0.0.2") + struct.pack("!BBH", 0, 17, 11)
        self.assertEqual(linkbridge.checksum(pseudo + p[20:]), 0)


class Interfaces(unittest.TestCase):
    def test_reads_this_machine(self):
        ifs = linkbridge.interfaces()
        self.assertIn("lo", ifs)
        self.assertIn("127.0.0.1", linkbridge.local_addresses())


if __name__ == "__main__":
    unittest.main()
