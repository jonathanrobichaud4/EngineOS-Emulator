"""Shared bits for the tests: paths, and packing data the way Engine sends it."""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "models"))
EMU = os.path.join(ROOT, "engine", "emu.sh")


def pack7(data):
    """8-bit bytes -> the 7-bit stream inMusic's SysEx carries (the inverse of displays.bits7)."""
    acc = n = 0
    out = []
    for byte in data:
        acc, n = (acc << 8) | byte, n + 8
        while n >= 7:
            n -= 7
            out.append((acc >> n) & 0x7F)
        acc &= (1 << n) - 1
    if n:
        out.append((acc << (7 - n)) & 0x7F)
    return out


def emu(*args, data=None, check=True):
    """Runs engine/emu.sh with its decks in `data` (a scratch folder). Returns its output."""
    env = dict(os.environ, EMU_DATA=data or "", EMU_ROOTFS="")
    env.pop("EMU_PROFILE", None)
    r = subprocess.run([EMU, *args], capture_output=True, text=True, env=env)
    if check and r.returncode:
        raise AssertionError(f"emu.sh {' '.join(args)} failed ({r.returncode}): {r.stderr or r.stdout}")
    return r.stdout
