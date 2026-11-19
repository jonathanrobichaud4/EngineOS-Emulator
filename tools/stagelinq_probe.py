#!/usr/bin/env python3
"""A tiny StageLinQ peer for checking the deck's networking from another machine (or a network
namespace standing in for one).

  stagelinq_probe.py [--announce] [--seconds N] [--state PATH ...]

Listens for discovery frames on UDP 51337 and, for each Engine device it hears, connects to the
port it announces and lists its services. With --state it also subscribes to those StateMap
paths (e.g. /Engine/Deck1/CurrentBPM) and prints the values that arrive. With --announce it
announces itself too, the way Engine DJ desktop does, and reports whether a device connects back.
Exit code 0 when at least one device answered with its services.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))
from linkbridge import parse_discovery  # noqa: E402


SOUNDSWITCH_TOKEN = bytes([82, 253, 252, 7, 33, 130, 101, 79, 22, 63, 95, 15, 154, 98, 29, 114])


def u16s(s):
    b = s.encode("utf-16-be")
    return struct.pack(">I", len(b)) + b


def frame(token, name, action, software, version, port):
    return b"airD" + token + u16s(name) + u16s(action) + u16s(software) + u16s(version) + struct.pack(">H", port)


def read_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def services(ip, port, token):
    """Ask the device at ip:port for its services: ({name: port}, the open connection). Keep
    the connection open while using a service: Engine drops a client's services when it closes."""
    out = {}
    s = socket.create_connection((ip, port), timeout=5)
    if True:
        s.sendall(struct.pack(">I", 2) + token)
        s.settimeout(3)
        try:
            while True:
                kind = struct.unpack(">I", read_exact(s, 4))[0]
                if kind == 0:  # service announcement
                    read_exact(s, 16)
                    n = struct.unpack(">I", read_exact(s, 4))[0]
                    name = read_exact(s, n).decode("utf-16-be", "replace")
                    out[name] = struct.unpack(">H", read_exact(s, 2))[0]
                elif kind == 1:  # reference / timestamp
                    read_exact(s, 16 + 16 + 8)
                elif kind == 2:  # services request (the device asking us back)
                    read_exact(s, 16)
                else:
                    break
        except (socket.timeout, EOFError):
            pass
    return out, s


got_state = []


def state(ip, port, token, paths, seconds):
    with socket.create_connection((ip, port), timeout=5) as s:
        s.sendall(struct.pack(">I", 0) + token + u16s("StateMap") + struct.pack(">H", 0))
        for p in paths:
            body = b"smaa" + struct.pack(">I", 0x7D2) + u16s(p) + struct.pack(">I", 0)
            s.sendall(struct.pack(">I", len(body)) + body)
        s.settimeout(1)
        end = time.time() + seconds
        while time.time() < end:
            try:
                n = struct.unpack(">I", read_exact(s, 4))[0]
                body = read_exact(s, n)
            except socket.timeout:
                continue
            except EOFError:
                return
            if body[:4] == b"smaa" and struct.unpack(">I", body[4:8])[0] == 0:
                ln = struct.unpack(">I", body[8:12])[0]
                path = body[12:12 + ln].decode("utf-16-be")
                ln2 = struct.unpack(">I", body[12 + ln:16 + ln])[0]
                print(f"  {path} = {body[16 + ln:16 + ln + ln2].decode('utf-16-be')}", flush=True)
                got_state.append(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--announce", action="store_true", help="announce ourselves too (Engine only answers devices it has heard)")
    ap.add_argument("--seconds", type=float, default=15)
    ap.add_argument("--state", nargs="*", default=[])
    a = ap.parse_args()
    # Engine only lists its services to tokens it knows: this is SoundSwitch's (the one the
    # StageLinq libraries use too). A made-up token gets an empty list.
    token = SOUNDSWITCH_TOKEN
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind(("0.0.0.0", 51337))
    rx.settimeout(0.5)
    back = []
    if a.announce:
        ls = socket.socket()
        ls.bind(("0.0.0.0", 0))
        ls.listen(4)
        myport = ls.getsockname()[1]

        def accept():
            while True:
                c, peer = ls.accept()
                back.append(peer[0])
                print(f"device at {peer[0]} connected back to us", flush=True)
                c.close()
        threading.Thread(target=accept, daemon=True).start()
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        hello = frame(token, "probe", "DISCOVERER_HOWDY_", "np2", "2.2.0", myport)

        def announce():
            while True:
                tx.sendto(hello, ("255.255.255.255", 51337))
                time.sleep(1)
        threading.Thread(target=announce, daemon=True).start()
        time.sleep(3)  # let devices hear us before we ask them for anything
    done, found = set(), 0
    end = time.time() + a.seconds
    while time.time() < end:
        try:
            data, (ip, _) = rx.recvfrom(2048)
        except socket.timeout:
            continue
        d = parse_discovery(data)
        if not d or d["token"] == token.hex() or (ip, d["port"]) in done:
            continue
        done.add((ip, d["port"]))
        print(f"heard {d['name']} ({d['software']} {d['version']}, {d['action']}) at {ip}:{d['port']}", flush=True)
        try:
            svc, main_conn = services(ip, d["port"], token)
        except OSError as e:
            print(f"  couldn't connect: {e}", flush=True)
            continue
        if svc:
            found += 1
            print("  services: " + ", ".join(f"{k} {v}" for k, v in sorted(svc.items())), flush=True)
            if a.state and "StateMap" in svc:
                state(ip, svc["StateMap"], token, a.state, min(5, max(1, end - time.time())))
            main_conn.close()
    if a.announce:
        print(f"connected back: {', '.join(sorted(set(back))) or 'nobody'}")
    sys.exit(0 if found else 1)


if __name__ == "__main__":
    main()
