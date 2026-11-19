#!/usr/bin/env python3
"""Pull one partition (default: rootfs) out of a Denon/inMusic AZ0x firmware .img
and decompress it to a raw image. Usage: az0x_extract.py FIRMWARE.img OUT.img [name]"""
import lzma, struct, sys

HEADER_SIZE = 0x450

def records(f):
    hdr = f.read(HEADER_SIZE)
    if hdr[:4] != b"AZ0x":
        sys.exit("not an AZ0x firmware image (bad magic)")
    str_base = struct.unpack("<I", hdr[0x10:0x14])[0] or 0x38
    start = struct.unpack("<I", hdr[0x18:0x1c])[0] or 0xC8
    end = struct.unpack("<I", hdr[0x1c:0x20])[0] or 0x348
    for roff in range(start, end, 64):
        tag, flags, off, size, name_off, mask = struct.unpack("<4sIQQII", hdr[roff:roff + 32])
        name = "boot" if tag == b"BOOT" else ""
        if name_off:
            s = str_base + name_off
            name = hdr[s:hdr.index(b"\0", s)].decode("ascii", "replace")
        yield tag.decode("ascii", "replace"), name, off, size

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    want = sys.argv[3] if len(sys.argv) > 3 else "rootfs"
    with open(src, "rb") as f:
        recs = [r for r in records(f) if r[1] == want]
        if not recs:
            sys.exit(f"no '{want}' partition in {src}")
        _, _, off, size = recs[0]
        f.seek(off)
        dec = lzma.LZMADecompressor()
        left, done = size, 0
        with open(dst, "wb") as out:
            while left:
                chunk = f.read(min(left, 1 << 20))
                if not chunk:
                    sys.exit("firmware file is truncated")
                left -= len(chunk)
                out.write(dec.decompress(chunk))
                done += len(chunk)
                pct = done * 100 // size
                if pct != getattr(main, "_pct", -1):
                    main._pct = pct
                    print(f"\r  {want}: {pct}%", end="", flush=True)
    print()

if __name__ == "__main__":
    main()
