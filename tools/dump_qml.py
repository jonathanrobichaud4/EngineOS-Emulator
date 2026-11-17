#!/usr/bin/env python3
"""Turn the shim's raw resource dumps into plain files.

`emu.sh dump-qml OUT [FILTER]` starts Engine for a few seconds with EMU_QML_FIND=FILTER; the shim
writes every matching compiled-in Qt resource to <rootfs>/tmp/emu/dump<path with / as _> and logs
"emushim: resource <path> flags <hex>". This decompresses each one (zlib or zstd, as Qt stores
them) into OUT/<path>. Usage: dump_qml.py LOG DUMPDIR OUTDIR
"""
import os
import re
import subprocess
import sys
import zlib

ZSTD = b"\x28\xb5\x2f\xfd"


def decode(blob, flags):
    p = blob[4:]  # 4-byte big-endian size, then the payload
    if flags & 4 or p[:4] == ZSTD:
        return subprocess.run(["zstd", "-dcq"], input=p, capture_output=True, check=True).stdout
    if flags & 1:
        return zlib.decompress(p[4:])  # zlib payloads start with the uncompressed size
    return p


def main():
    log, dumpdir, out = sys.argv[1:4]
    seen = 0
    for line in open(log, errors="replace"):
        m = re.match(r"emushim: resource (\S+) flags ([0-9a-f]+)", line)
        if not m:
            continue
        path, flags = m.group(1), int(m.group(2), 16)
        src = os.path.join(dumpdir, "dump" + path.replace("/", "_"))
        if not os.path.exists(src):
            continue
        dst = os.path.join(out, path.lstrip("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(decode(open(src, "rb").read(), flags))
        seen += 1
    print(f"{seen} files written to {out}")


if __name__ == "__main__":
    main()
