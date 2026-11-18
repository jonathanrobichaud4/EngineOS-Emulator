#!/usr/bin/env python3
"""Stand-in for the deck's edisksd (io.github.inmusicdev.edisksd) for EngineOS Emulator.

On the deck, edisksd watches USB sticks and SD cards and mounts them under /media/<label> when
Engine asks. Engine only talks to it over D-Bus, so this service answers on the emulated deck's
system bus and presents folders on the PC as drives instead. The drive list is a plain text
file (one drive per line: label, usb|sd, folder) that `emu.sh drive add/remove` edits; changes
show up in Engine as a drive being plugged in or pulled out.

Runs on the PC side (not under qemu) as root, next to the chroot. Needs python3-jeepney.
"""
import argparse
import os
import subprocess
import sys
import time

from jeepney import DBusAddress, HeaderFields, MessageType, new_error, new_method_return, new_signal
from jeepney.bus_messages import message_bus
from jeepney.io.blocking import open_dbus_connection

NAME = "io.github.inmusicdev.edisksd"
ROOT = "/io/github/inmusicdev/edisksd"
I_BLOCK = NAME + ".Block"
I_FS = NAME + ".Filesystem"
I_DAEMON = NAME + ".Daemon"
I_PROPS = "org.freedesktop.DBus.Properties"
I_OM = "org.freedesktop.DBus.ObjectManager"
I_INTRO = "org.freedesktop.DBus.Introspectable"

# Generic device paths of the SC LIVE 4's own ports (from its device tree, nothing per-unit).
# Engine tells the SD slot from USB ports by these paths, so they follow the real layout.
SYSPATH = {
    "usb0": "/sys/devices/platform/ff540000.usb/usb2/2-1/2-1:1.0/host{n}/target{n}:0:0/{n}:0:0:0/block/sd{l}/sd{l}1",
    "usb": "/sys/devices/platform/ff500000.usb/usb1/1-1/1-1.{p}/1-1.{p}:1.0/host{n}/target{n}:0:0/{n}:0:0:0/block/sd{l}/sd{l}1",
    "sd": "/sys/devices/platform/ff0c0000.dwmmc/mmc_host/mmc1/mmc1:0001/block/mmcblk1/mmcblk1p1",
}


def log(*a):
    print("edisks-emu:", *a, flush=True)


class Drive:
    def __init__(self, idx, label, kind, folder):
        self.idx, self.label, self.kind, self.folder = idx, label, kind, folder
        letter = "abcdefgh"[idx % 8]
        if kind == "sd":
            self.dev = "/dev/mmcblk1p1"
            self.syspath = SYSPATH["sd"]
            self.devnum = (179 << 8) | 33
        else:
            self.dev = f"/dev/sd{letter}1"
            key = "usb0" if idx == 0 else "usb"
            self.syspath = SYSPATH[key].format(n=idx, l=letter, p=idx + 1)
            self.devnum = (8 << 8) | (idx * 16 + 1)
        self.path = f"{ROOT}/block/{os.path.basename(self.dev)}"
        self.mountpoint = ""
        # Placeholder volume ID (FAT/exFAT style), derived from the label only.
        h = sum(ord(c) * (i + 1) for i, c in enumerate(label)) & 0xFFFFFFFF
        self.uuid = f"{(h >> 16) & 0xFFFF:04X}-{h & 0xFFFF:04X}"

    def size(self):
        try:
            st = os.statvfs(self.folder)
            return st.f_blocks * st.f_frsize
        except OSError:
            return 64 << 30

    def props(self):
        mp = [self.mountpoint.encode() + b"\0"] if self.mountpoint else []
        return {
            I_BLOCK: {
                "Device": ("ay", self.dev.encode() + b"\0"),
                "DeviceLinks": ("aay", [f"/dev/disk/by-label/{self.label}".encode() + b"\0"]),
                "DeviceNumber": ("t", self.devnum),
                "HintIgnore": ("b", False),
                "ReadOnly": ("b", not os.access(self.folder, os.W_OK)),
                "Removable": ("b", True),
                "Size": ("t", self.size()),
                "SysPath": ("s", self.syspath),
                "ConnectionBus": ("s", "mmc" if self.kind == "sd" else "usb"),
                "Media": ("s", "flash_sd" if self.kind == "sd" else "thumb"),
            },
            I_FS: {
                "Type": ("s", "exfat"),
                "Label": ("s", self.label),
                "UUID": ("s", self.uuid),
                "Mountpoints": ("aay", mp),
            },
        }


class Service:
    def __init__(self, rootfs, drives_file):
        self.rootfs, self.drives_file = rootfs, drives_file
        self.drives = {}  # path -> Drive
        self.mtime = None
        self.conn = open_dbus_connection(bus=f"unix:path={rootfs}/run/dbus/system_bus_socket")
        reply = self.conn.send_and_get_reply(message_bus.RequestName(NAME))
        log("bus name", NAME, "request ->", reply.body)

    # ---- drives file ------------------------------------------------------------------
    def read_drives(self):
        want = []
        try:
            with open(self.drives_file) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3 and parts[0] and os.path.isdir(parts[2]):
                        want.append(parts)
        except FileNotFoundError:
            pass
        return want

    def sync_drives(self):
        try:
            m = os.stat(self.drives_file).st_mtime
        except FileNotFoundError:
            m = 0
        if m == self.mtime:
            return
        self.mtime = m
        want = self.read_drives()
        keep = {(label, kind, folder) for label, kind, folder in want}
        for path, d in list(self.drives.items()):
            if (d.label, d.kind, d.folder) not in keep:
                del self.drives[path]
                self.om_signal("InterfacesRemoved", "oas", (path, [I_BLOCK, I_FS]))
                self.unmount(d, quiet=True)
                log("removed", d.label)
        have = {(d.label, d.kind, d.folder) for d in self.drives.values()}
        used = {d.idx for d in self.drives.values()}
        for label, kind, folder in want:
            if (label, kind, folder) in have:
                continue
            idx = next(i for i in range(16) if i not in used)
            used.add(idx)
            d = Drive(idx, label, kind, folder)
            self.drives[d.path] = d
            self.om_signal("InterfacesAdded", "oa{sa{sv}}", (d.path, d.props()))
            log("added", label, kind, folder)

    def om_signal(self, member, sig, body):
        # Engine's ObjectManager proxy may sit on "/" or on the daemon path; a signal only
        # reaches a proxy on the same path, so send it on both.
        for p in ("/", ROOT):
            self.conn.send(new_signal(DBusAddress(p, interface=I_OM), member, sig, body))

    # ---- mounting ---------------------------------------------------------------------
    def mount(self, d):
        if d.mountpoint:
            return d.mountpoint
        mp = f"/media/{d.label}"
        host = self.rootfs + mp
        os.makedirs(host, exist_ok=True)
        subprocess.run(["mount", "--bind", d.folder, host], check=True)
        d.mountpoint = mp
        self.changed(d)
        log("mounted", d.folder, "at", mp)
        return mp

    def unmount(self, d, quiet=False):
        if not d.mountpoint:
            return
        host = self.rootfs + d.mountpoint
        subprocess.run(["umount", "-l", host], check=False)
        try:
            os.rmdir(host)
        except OSError:
            pass
        log("unmounted", d.mountpoint)
        d.mountpoint = ""
        if not quiet:
            self.changed(d)

    def changed(self, d):
        self.conn.send(new_signal(DBusAddress(d.path, interface=I_PROPS), "PropertiesChanged", "sa{sv}as",
                                  (I_FS, {"Mountpoints": d.props()[I_FS]["Mountpoints"]}, [])))

    # ---- D-Bus ------------------------------------------------------------------------
    def managed(self):
        return {p: d.props() for p, d in self.drives.items()}

    def handle(self, msg):
        h = msg.header
        if h.message_type != MessageType.method_call:
            return
        path = h.fields.get(HeaderFields.path, "")
        iface = h.fields.get(HeaderFields.interface, "")
        member = h.fields.get(HeaderFields.member, "")
        d = self.drives.get(path)
        try:
            if member == "GetManagedObjects":
                return new_method_return(msg, "a{oa{sa{sv}}}", (self.managed(),))
            if member == "Introspect":
                return new_method_return(msg, "s", ("<node/>",))
            if iface == I_PROPS or member in ("Get", "GetAll"):
                if path == ROOT:
                    props = {I_DAEMON: {"Version": ("s", "0.20")}}
                elif d:
                    props = d.props()
                else:
                    return new_error(msg, NAME + ".InvalidArgs", "s", ("no such object",))
                if member == "Get":
                    i, name = msg.body
                    return new_method_return(msg, "v", (props.get(i, {})[name],))
                if member == "GetAll":
                    return new_method_return(msg, "a{sv}", (props.get(msg.body[0], {}),))
                if member == "Set":
                    return new_error(msg, NAME + ".NotImplemented", "s", ("read-only",))
            if d and member == "Mount":
                return new_method_return(msg, "s", (self.mount(d),))
            if d and member == "Unmount":
                if not d.mountpoint:
                    return new_error(msg, NAME + ".NotMounted", "s", ("Not mounted",))
                self.unmount(d)
                return new_method_return(msg)
            if member == "Terminate":
                return new_method_return(msg)
        except Exception as e:  # report, keep serving
            log("error handling", member, e)
            return new_error(msg, NAME + ".Failed", "s", (str(e),))
        return new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "s", (f"{iface}.{member}",))

    def run(self):
        while True:
            self.sync_drives()
            try:
                msg = self.conn.receive(timeout=1.0)
            except TimeoutError:
                continue
            reply = self.handle(msg)
            if reply is not None:
                self.conn.send(reply)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--drives", required=True)
    a = ap.parse_args()
    for _ in range(60):  # wait for the deck's D-Bus to come up
        if os.path.exists(a.rootfs + "/run/dbus/system_bus_socket"):
            break
        time.sleep(1)
    try:
        Service(a.rootfs, a.drives).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
