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


class ProDjLink(unittest.TestCase):
    """--prolink: the deck's Pro DJ Link packets get this machine's address and MAC written in."""

    def keepalive(self, ip, mac):
        ka = bytearray(54)
        ka[0:10] = linkbridge.PROLINK_MAGIC
        ka[10] = 0x06
        ka[0x0c:0x0c + 19] = b"EngineX Export Beta"
        ka[0x26:0x2c] = mac
        ka[0x2c:0x30] = socket.inet_aton(ip)
        return bytes(ka)

    def test_rewrites_ip_and_mac(self):
        deck_mac, pc_mac = bytes.fromhex("0277000000 02".replace(" ", "")), bytes.fromhex("52f9f5784224")
        out = linkbridge.rewrite_prolink(self.keepalive("10.77.0.2", deck_mac), "10.77.0.2", "192.168.1.20",
                                         deck_mac, pc_mac)
        self.assertEqual(socket.inet_ntoa(out[0x2c:0x30]), "192.168.1.20")
        self.assertEqual(out[0x26:0x2c], pc_mac)
        self.assertEqual(out[0x0c:0x1f], b"EngineX Export Beta")
        self.assertEqual(len(out), 54)

    def test_leaves_other_packets(self):
        other = b"airD" + socket.inet_aton("10.77.0.2") * 4
        self.assertEqual(linkbridge.rewrite_prolink(other, "10.77.0.2", "192.168.1.20", None, None), other)

    def test_ports(self):
        self.assertEqual(set(linkbridge.PROLINK), {50000, 50001, 50002})
        self.assertFalse(set(linkbridge.PROLINK) & set(linkbridge.RELAY))


class Portmap(unittest.TestCase):
    """portmap_udp asks for everything (DUMP) and falls back to mount/NFS lookups (GETPORT), which
    is all EngineX's portmapper answers."""

    def serve(self, dump):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

        def run():
            while True:
                try:
                    d, a = s.recvfrom(512)
                except OSError:
                    return
                xid, _, _, prog, _, proc = struct.unpack_from(">6I", d, 0)
                head = struct.pack(">5I", xid, 1, 0, 0, 0)
                if proc == 4 and dump:
                    body = struct.pack(">I", 0) + struct.pack(">5I", 1, 100005, 1, 17, 4000) + \
                        struct.pack(">5I", 1, 100003, 3, 6, 2049) + struct.pack(">I", 0)
                elif proc == 4:
                    body = struct.pack(">I", 3)  # PROC_UNAVAIL
                elif proc == 3:
                    want, vers = struct.unpack_from(">2I", d, 40)
                    body = struct.pack(">2I", 0, 37391 if (want, vers) in ((100005, 1), (100003, 2)) else 0)
                else:
                    continue
                s.sendto(head + body, a)
        import threading
        threading.Thread(target=run, daemon=True).start()
        self.addCleanup(s.close)
        return port

    def call(self, port):
        real = linkbridge.socket.socket

        class To(real):  # send portmap calls to the test server's port instead of 111
            def sendto(self, data, addr):
                return real.sendto(self, data, (addr[0], port))
        linkbridge.socket.socket = To
        try:
            return linkbridge.portmap_udp("127.0.0.1")
        finally:
            linkbridge.socket.socket = real

    def test_dump(self):
        self.assertEqual(self.call(self.serve(dump=True)), {4000})

    def test_getport_fallback(self):
        self.assertEqual(self.call(self.serve(dump=False)), {37391})

    def test_nobody(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        self.assertIsNone(self.call(port))
