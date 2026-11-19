#!/usr/bin/env python3
"""Puts the emulated deck on the real network for Engine Link and StageLinQ.

The deck lives in its own network namespace behind NAT (engine/lib/net.sh), so on its own nobody
on the network can see it. Denon gear, Engine DJ desktop, SoundSwitch and lighting apps find
each other with StageLinQ: every device broadcasts a discovery frame ("airD") to UDP port 51337
saying which TCP port to connect to, and peers connect to that port at the frame's source
address. This bridge, running next to the deck as root:

  - re-broadcasts the deck's announcements on the network, from this machine's address: StageLinQ
    discovery, Engine DJ's EAAS beacon, EngineX's stems discovery and mDNS (RELAY below);
    answers to them go back to the deck
  - makes every TCP port the deck listens on reachable at this machine's address (the same
    port number), so peers that heard an announcement can connect; it follows the deck's ports
    as they open and close
  - passes the network's announcements into the deck with their original source address, so
    the deck connects straight to those devices (through the NAT)
  - with --prolink (EngineX only): Pro DJ Link too. The deck's keep-alive, beat and status packets
    (UDP 50000-50002, sent to its own link's broadcast) go out on the network with this machine's
    address and MAC written in, so CDJs and rekordbox see it as a player at this address; theirs
    come in. The UDP services CDJs use to read from the deck (portmap 111 and EngineX's NFS
    server) are forwarded to it, and its dbserver (TCP 12523 and up) goes through like any other
    TCP port.

Where "the network" is: every IPv4 interface with a broadcast address except loopback, the
deck's own link and container bridges (on Linux, the PC's own network; in WSL with mirrored
networking, Windows' networks; in the Mac's VM, its bridged interface). --lan names them instead.

  linkbridge.py --deck-ip 10.77.0.2 --deck-if emu0 --netns enginex [--lan IF ...] [--exclude PORT ...] [--prolink]

Standard library only. The protocol notes are in docs/networking.md.
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import threading
import time

DISCOVERY_PORT = 51337
MAGIC = b"airD"
SKIP_IF_PREFIXES = ("lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "tailscale", "zt")


def log(msg):
    print(f"linkbridge: {msg}", flush=True)


# ---------------------------------------------------------------------------------- discovery

def parse_discovery(data):
    """An airD frame -> dict (token, name, action, software, version, port), or None."""
    if len(data) < 22 or data[:4] != MAGIC:
        return None
    out = {"token": data[4:20].hex()}
    pos = 20
    try:
        for key in ("name", "action", "software", "version"):
            n = struct.unpack_from(">I", data, pos)[0]
            pos += 4
            if n > 1024 or pos + n > len(data):
                return None
            out[key] = data[pos:pos + n].decode("utf-16-be", "replace")
            pos += n
        out["port"] = struct.unpack_from(">H", data, pos)[0]
    except struct.error:
        return None
    return out


def local_addresses():
    """Every IPv4 address of this machine (its own, never a device on the network)."""
    try:
        text = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {f[f.index("inet") + 1].split("/")[0] for f in (line.split() for line in text.splitlines()) if "inet" in f}


def interfaces():
    """{name: (address, broadcast or None)} for the IPv4 interfaces (their first address)."""
    out = {}
    try:
        text = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return out
    for line in text.splitlines():
        f = line.split()
        if len(f) < 4 or "inet" not in f:
            continue
        name = f[1].split("@")[0]
        addr = f[f.index("inet") + 1].split("/")[0]
        brd = f[f.index("brd") + 1] if "brd" in f else None
        if name not in out:
            out[name] = (addr, brd)
    return out


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def udp_packet(src, sport, dst, dport, payload):
    """An IPv4 + UDP packet, for sending with a source address that isn't ours."""
    udp_len = 8 + len(payload)
    s, d = socket.inet_aton(src), socket.inet_aton(dst)
    pseudo = s + d + struct.pack("!BBH", 0, socket.IPPROTO_UDP, udp_len)
    udp = struct.pack("!HHHH", sport, dport, udp_len, 0) + payload
    csum = checksum(pseudo + udp) or 0xFFFF
    udp = udp[:6] + struct.pack("!H", csum) + udp[8:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + udp_len, os.getpid() & 0xFFFF, 0, 64, socket.IPPROTO_UDP, 0, s, d)
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return ip + udp


# What gets relayed: UDP port -> what it is. Broadcasts (and the mDNS group) on these ports go
# both ways; replies to the deck's own packets find their way back to it.
RELAY = {
    51337: "StageLinQ discovery",
    11224: "Engine DJ (EAAS) beacon",
    17891: "EngineX stems discovery",
    5353: "mDNS",
}
# The ones whose packets get answers sent back to the sender (the others are announcements, and
# peers connect to the TCP port in them). StageLinQ uses a new source port for every frame, so
# keeping a socket per source port there would pile up hundreds.
ANSWERED = {17891, 5353}
MDNS_GROUP = "224.0.0.251"

# Pro DJ Link (with --prolink): every packet starts with this, and devices put their own IP and
# MAC in their keep-alives, so the deck's get this machine's written in on the way out.
PROLINK = {
    50000: "Pro DJ Link keep-alive",
    50001: "Pro DJ Link beat",
    50002: "Pro DJ Link status",
}
PROLINK_MAGIC = b"Qspt1WmJOL"


def mac_of(name, netns=None):
    """An interface's MAC address as 6 bytes, or None."""
    cmd = (["ip", "-n", netns] if netns else ["ip"]) + ["-o", "link", "show", name]
    try:
        f = subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.split()
        mac = f[f.index("link/ether") + 1]
        return bytes.fromhex(mac.replace(":", ""))
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return None


def rewrite_prolink(data, old_ip, new_ip, old_mac, new_mac):
    """The deck's Pro DJ Link packet as it should look coming from this machine."""
    if not data.startswith(PROLINK_MAGIC):
        return data
    data = data.replace(socket.inet_aton(old_ip), socket.inet_aton(new_ip))
    if old_mac and new_mac:
        data = data.replace(old_mac, new_mac)
    return data


class Peers:
    """A stand-in address on the deck's own subnet for each device on the network.

    Engine only answers StageLinQ service requests from devices on its own subnet, and the
    deck's subnet is the link to this machine (10.77.0.0/24). So each device found on the network
    gets an address there (10.77.0.100 and up): the deck hears that device's announcements from
    it, the device's connections reach the deck from it, and what the deck sends to it goes on to
    the real device (DNAT here, then the NAT out to the network)."""

    CHAIN = "EMU_LINK"

    def __init__(self, a):
        self.a = a
        self.lock = threading.Lock()
        self.by_real, self.by_alias = {}, {}
        prefix = a.deck_ip.rsplit(".", 1)[0]
        self.free = [f"{prefix}.{n}" for n in range(100, 251)]
        self.reset()

    def run(self, *args):
        return subprocess.run(list(args), capture_output=True, text=True).returncode == 0

    def reset(self):
        """No stand-ins: drop the ones a previous run left."""
        for alias in self.free:
            self.run("ip", "addr", "del", f"{alias}/32", "dev", self.a.deck_if)
        if not self.run("iptables", "-t", "nat", "-N", self.CHAIN):
            self.run("iptables", "-t", "nat", "-F", self.CHAIN)
        jump = ["PREROUTING", "-i", self.a.deck_if, "-j", self.CHAIN]
        if not self.run("iptables", "-t", "nat", "-C", *jump):
            self.run("iptables", "-t", "nat", "-I", *jump)

    def alias(self, real):
        """The stand-in for the device at `real`, made the first time it's seen."""
        with self.lock:
            if real in self.by_real:
                return self.by_real[real]
            if not self.free:
                return None
            alias = self.free.pop(0)
            if not self.run("ip", "addr", "add", f"{alias}/32", "dev", self.a.deck_if):
                self.free.insert(0, alias)
                return None
            self.run("iptables", "-t", "nat", "-A", self.CHAIN, "-d", alias, "-j", "DNAT", "--to-destination", real)
            self.by_real[real], self.by_alias[alias] = alias, real
        log(f"{real} is {alias} to the deck")
        return alias

    def known(self, real):
        with self.lock:
            return self.by_real.get(real)


class Relay:
    """Broadcast / multicast UDP between the deck and the network."""

    def __init__(self, a, peers):
        self.a = a
        self.peers = peers
        self.subnet = a.deck_ip.rsplit(".", 1)[0] + "."  # the deck's link: never the network
        self.lans = {}
        self.local = set()
        self.seen = set()
        self.replies = {}   # (port, deck source port, interface) -> socket the deck's packet went out on
        self.lock = threading.Lock()
        self.raw = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
        self.raw.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, a.deck_if.encode())
        self.raw.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
        self.raw.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.listen = {}
        self.ports = dict(RELAY)
        if a.prolink:
            self.ports.update(PROLINK)
        self.deck_bcast = self.subnet + "255"
        self.deck_mac = mac_of("eth0", a.netns) if a.prolink else None
        self.macs = {}
        for port in self.ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.setsockopt(socket.IPPROTO_IP, socket.IP_PKTINFO, 1)
            s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
            try:
                s.bind(("0.0.0.0", port))
            except OSError as e:
                log(f"can't relay {self.ports[port]} (UDP {port}): {e.strerror}")
                continue
            self.listen[port] = s
        self.joined = set()

    def refresh(self):
        all_ifs = interfaces()
        if self.a.lan:
            lans = {k: v for k, v in all_ifs.items() if k in self.a.lan}
        else:
            lans = {k: v for k, v in all_ifs.items()
                    if k != self.a.deck_if and v[1] and not k.startswith(SKIP_IF_PREFIXES)}
        if lans != self.lans:
            log("network: " + (", ".join(f"{k} {v[0]}" for k, v in sorted(lans.items())) or "none found"))
        self.lans = lans
        self.local = local_addresses()
        if self.a.prolink:
            self.macs = {name: mac_of(name) for name in lans}
            self.deck_mac = self.deck_mac or mac_of("eth0", self.a.netns)
        # mDNS: listen to the group on the network and on the deck's link
        mdns = self.listen.get(5353)
        if mdns:
            for name, (addr, _) in list(lans.items()) + [(self.a.deck_if, (all_ifs.get(self.a.deck_if, ("",))[0], ""))]:
                if addr and (name, addr) not in self.joined:
                    try:
                        mdns.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                                        socket.inet_aton(MDNS_GROUP) + socket.inet_aton(addr))
                        self.joined.add((name, addr))
                    except OSError:
                        pass

    def run(self):
        self.refresh()
        threading.Thread(target=self.refresher, daemon=True).start()
        for port, s in self.listen.items():
            threading.Thread(target=self.receive, args=(port, s), daemon=True).start()
        while True:
            time.sleep(3600)

    def refresher(self):
        while True:
            time.sleep(5)
            self.refresh()
            now = time.time()
            with self.lock:
                for k, (s, t) in list(self.replies.items()):
                    if now - t > 30:
                        s.close()
                        del self.replies[k]

    def receive(self, port, s):
        while True:
            try:
                data, anc, _flags, (src, sport) = s.recvmsg(9000, socket.CMSG_SPACE(12))
            except OSError:
                return
            dst = ""
            for level, kind, val in anc:
                if level == socket.IPPROTO_IP and kind == socket.IP_PKTINFO and len(val) >= 12:
                    dst = socket.inet_ntoa(val[8:12])
            if src == self.a.deck_ip:
                self.from_deck(port, data, src, sport, dst)
            elif src not in self.local and not src.startswith("127.") and not src.startswith(self.subnet):
                self.to_deck(port, data, src, sport, dst)

    def note(self, port, what, d=None):
        key = (port, what)
        if key in self.seen:
            return
        self.seen.add(key)
        if d:
            log(f"{what}: {d['name']} ({d['software']} {d['version']}) port {d['port']}")
        else:
            log(f"{what} ({self.ports[port]})")

    def from_deck(self, port, data, src, sport, dst):
        multicast = dst == MDNS_GROUP
        prolink = port in PROLINK
        # Pro DJ Link goes to the deck's own link's broadcast (10.77.0.255); the rest to everyone
        if not multicast and dst not in ("255.255.255.255", "", None) and not (prolink and dst == self.deck_bcast):
            return  # sent to this machine or its own link's broadcast: not for the network
        d = parse_discovery(data) if port == DISCOVERY_PORT else None
        self.note(port, "deck announces" if d else "deck sends", d)
        for name, (addr, brd) in list(self.lans.items()):
            out = self.reply_socket(port, sport, name, addr)
            if not out:
                continue
            payload, to = data, MDNS_GROUP if multicast else "255.255.255.255"
            if prolink:
                payload = rewrite_prolink(data, self.a.deck_ip, addr, self.deck_mac, self.macs.get(name))
                to = brd or to   # CDJs send to their subnet's broadcast, so do the same
            try:
                out.sendto(payload, (to, port))
            except OSError as e:
                self.note(port, f"can't send on {name}: {e.strerror}")

    def reply_socket(self, port, sport, name, addr):
        """The socket the deck's packets from `sport` go out on through `name`. Answers to it go
        back to the deck, to that port. Ports nobody answers share one socket per interface.
        Pro DJ Link goes out from its own port (devices expect 50000 from 50000), which the socket
        listening for the network's packets already has."""
        if port in PROLINK:
            return self.listen.get(port)
        if port not in ANSWERED:
            sport = 0
        key = (port, sport, name)
        with self.lock:
            if key in self.replies:
                s, _ = self.replies[key]
                self.replies[key] = (s, time.time())
                return s
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, name.encode())
                s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(addr))
                s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
                s.bind((addr, 0))
            except OSError:
                s.close()
                return None
            self.replies[key] = (s, time.time())
        if sport:
            threading.Thread(target=self.answers, args=(s, sport), daemon=True).start()
        return s

    def answers(self, s, deck_port):
        while True:
            try:
                data, (src, sport) = s.recvfrom(9000)
            except OSError:
                return
            if src not in self.local:
                self.inject(data, self.peers.alias(src) or src, sport, self.a.deck_ip, deck_port)

    def to_deck(self, port, data, src, sport, dst):
        d = parse_discovery(data) if port == DISCOVERY_PORT else None
        self.note(port, f"found on the network at {src}" if d else f"passing {src}'s packets to the deck", d)
        # As it was sent: Engine only takes a device's discovery frame as a broadcast (a unicast copy
        # is ignored), and the mDNS group stays the group.
        to = MDNS_GROUP if dst == MDNS_GROUP else "255.255.255.255" if dst in ("255.255.255.255", "") or dst.endswith(".255") else self.a.deck_ip
        self.inject(data, self.peers.alias(src) or src, sport, to, port)

    def inject(self, data, src, sport, dst, dport):
        try:
            self.raw.sendto(udp_packet(src, sport, dst, dport, data), (dst, 0))
        except OSError as e:
            self.note(dport, f"can't pass packets to the deck: {e.strerror}")


# ---------------------------------------------------------------------------------- TCP ports

def deck_listening(netns, proto="tcp"):
    """The TCP (or UDP) ports the deck listens on (not just on its loopback)."""
    ports = set()
    state = "0A" if proto == "tcp" else "07"  # LISTEN, or an unconnected UDP socket
    for f in (f"/proc/net/{proto}", f"/proc/net/{proto}6"):
        try:
            text = subprocess.run(["ip", "netns", "exec", netns, "cat", f], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in text.splitlines()[1:]:
            p = line.split()
            if len(p) < 4 or p[3] != state:
                continue
            addr, port = p[1].split(":")
            if addr in ("0100007F", "00000000000000000000000001000000"):  # 127.0.0.1, ::1
                continue
            ports.add(int(port, 16))
    return ports


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class Ports:
    def __init__(self, a, peers):
        self.a = a
        self.peers = peers
        self.subnet = a.deck_ip.rsplit(".", 1)[0] + "."  # the deck's link: never the network
        self.open = {}      # port -> listening socket
        self.failed = set()
        self.warned = set()   # ports already reported as taken

    def serve(self, port, ls):
        while True:
            try:
                c, peer = ls.accept()
            except OSError:
                return  # closed: the deck stopped listening
            # From the device's stand-in, so the deck sees the device it heard announcing.
            alias = self.peers.known(peer[0])
            try:
                d = socket.create_connection((self.a.deck_ip, port), timeout=5,
                                             source_address=(alias, 0) if alias else None)
                d.settimeout(None)
            except OSError:
                c.close()
                continue
            for s in (c, d):
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=pipe, args=(c, d), daemon=True).start()
            threading.Thread(target=pipe, args=(d, c), daemon=True).start()

    def run(self):
        while True:
            want = {p for p in deck_listening(self.a.netns) if p >= 1024 and p not in self.a.exclude}
            for port in sorted(want - set(self.open) - self.failed):
                ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    ls.bind(("0.0.0.0", port))
                    ls.listen(16)
                except OSError as e:
                    if port not in self.warned:
                        log(f"deck port {port} can't be reached from the network: this machine uses it ({e.strerror})")
                        self.warned.add(port)
                    ls.close()
                    self.failed.add(port)
                    continue
                self.open[port] = ls
                threading.Thread(target=self.serve, args=(port, ls), daemon=True).start()
            for port in set(self.open) - want:
                ls = self.open.pop(port)
                # shutdown wakes the thread blocked in accept(); a plain close() leaves the port
                # bound, and when the deck opens the same port again it collides with us
                try:
                    ls.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                ls.close()
            self.failed &= want
            time.sleep(2)


# What CDJs and rekordbox ask a player's portmapper for: mount and NFS, over UDP
NFS_PROGRAMS = ((100005, 1), (100005, 3), (100003, 2), (100003, 3))


def _rpc(host, proc, args=b"", timeout=1.0):
    """One portmapper call (program 100000 v2); the reply after the accept header, or None."""
    xid = (int(time.time() * 1000) + proc) & 0xFFFFFFFF
    call = struct.pack(">10I", xid, 0, 2, 100000, 2, proc, 0, 0, 0, 0) + args
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(call, (host, 111))
        data = s.recv(8192)
    except OSError:
        return None
    finally:
        s.close()
    try:
        rxid, mtype, stat, _flavor, vlen = struct.unpack_from(">5I", data, 0)
        pos = 20 + ((vlen + 3) & ~3)
        if rxid != xid or mtype != 1 or stat != 0 or struct.unpack_from(">I", data, pos)[0] != 0:
            return None  # e.g. PROC_UNAVAIL: EngineX's portmapper has no DUMP
        return data[pos + 4:]
    except struct.error:
        return None


def portmap_udp(host, timeout=1.0):
    """The UDP ports the portmapper at `host` hands out: everything it lists (DUMP), or, when it
    can't list (EngineX's can't), what it answers for mount and NFS (GETPORT). None if nothing
    answers on 111."""
    body = _rpc(host, 4, timeout=timeout)
    if body is not None:
        ports, pos = set(), 0
        try:
            while struct.unpack_from(">I", body, pos)[0] == 1:
                _prog, _vers, proto, port = struct.unpack_from(">4I", body, pos + 4)
                if proto == socket.IPPROTO_UDP:
                    ports.add(port)
                pos += 20
            return ports
        except struct.error:
            pass
    ports, answered = set(), False
    for prog, vers in NFS_PROGRAMS:
        r = _rpc(host, 3, struct.pack(">4I", prog, vers, socket.IPPROTO_UDP, 0), timeout)
        if r is None or len(r) < 4:
            continue
        answered = True
        port = struct.unpack_from(">I", r, 0)[0]
        if port:
            ports.add(port)
    return ports if answered else None


class UdpServices:
    """With --prolink: the UDP services CDJs and rekordbox use to read the deck's library
    (portmap on 111 and the NFS ports EngineX's portmapper hands out) are forwarded from this
    machine's address to the deck. DNAT, since NFS over UDP needs the replies
    to come from the port that was asked. Each forwarded port also gets a placeholder socket here:
    in WSL's mirrored networking Windows only passes on packets for ports something listens on."""

    CHAIN = "EMU_LINK_IN"
    SKIP = set(RELAY) | set(PROLINK)

    def __init__(self, a):
        self.a = a
        self.open = {}   # port -> placeholder socket or None
        run = Peers.run
        self.run = lambda *args: run(self, *args)
        if not self.run("iptables", "-t", "nat", "-N", self.CHAIN):
            self.run("iptables", "-t", "nat", "-F", self.CHAIN)
        for table, rule in (("nat", ["PREROUTING", "!", "-i", a.deck_if, "-m", "addrtype", "--dst-type", "LOCAL", "-j", self.CHAIN]),
                            ("filter", ["FORWARD", "-d", a.deck_ip, "-m", "conntrack", "--ctstate", "DNAT", "-j", "ACCEPT"])):
            if not self.run("iptables", "-t", table, "-C", *rule):
                self.run("iptables", "-t", table, "-I", *rule)

    def wanted(self):
        listening = deck_listening(self.a.netns, "udp")
        if 111 not in listening:
            return set()
        offered = portmap_udp(self.a.deck_ip) or set()
        return {p for p in offered | {111} if p in listening and p not in self.SKIP and p not in self.a.exclude}

    def run_forever(self):
        while True:
            want = self.wanted()
            for port in sorted(want - set(self.open)):
                self.run("iptables", "-t", "nat", "-A", self.CHAIN, "-p", "udp", "--dport", str(port),
                         "-j", "DNAT", "--to-destination", f"{self.a.deck_ip}:{port}")
                ph = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    ph.bind(("0.0.0.0", port))
                except OSError:
                    ph.close()
                    ph = None
                self.open[port] = ph
                log(f"deck UDP port {port} reachable from the network")
            for port in set(self.open) - want:
                self.run("iptables", "-t", "nat", "-D", self.CHAIN, "-p", "udp", "--dport", str(port),
                         "-j", "DNAT", "--to-destination", f"{self.a.deck_ip}:{port}")
                ph = self.open.pop(port)
                if ph:
                    ph.close()
            time.sleep(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--deck-ip", default="10.77.0.2")
    ap.add_argument("--deck-if", default="emu0", help="this side of the deck's link")
    ap.add_argument("--netns", default="enginex")
    ap.add_argument("--lan", nargs="*", default=[], help="the network interfaces to use (default: all but the deck's)")
    ap.add_argument("--exclude", nargs="*", type=int, default=[], help="deck ports not to open to the network")
    ap.add_argument("--prolink", action="store_true", help="bridge Pro DJ Link too (EngineX's player export and library share)")
    a = ap.parse_args()
    a.exclude = set(a.exclude)
    if os.geteuid() != 0:
        sys.exit("linkbridge: needs root")
    peers = Peers(a)
    relay = Relay(a, peers)
    threading.Thread(target=Ports(a, peers).run, daemon=True).start()
    if a.prolink:
        threading.Thread(target=UdpServices(a).run_forever, daemon=True).start()
    log(f"bridging the deck ({a.deck_ip}) to the network{' (with Pro DJ Link)' if a.prolink else ''}")
    relay.run()


if __name__ == "__main__":
    main()
