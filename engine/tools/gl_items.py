#!/usr/bin/env python3
"""Find Engine's scene-graph items that need OpenGL, so the emulator can switch them off.

The emulator renders with Qt's software backend (no GPU, no GL context). A few of Engine's own
QQuickItem subclasses (waveform views) build OpenGL framebuffers in updatePaintNode() and
crash without a GL context. This finds those overrides in the stripped Engine binary:

  1. C++ type info gives the vtables of all polymorphic classes.
  2. The updatePaintNode slot is the one where non-overriding subclasses point at
     QQuickItem::updatePaintNode in libQt6Quick.
  3. Call sites of QOpenGLFramebufferObject's constructor (through the PLT) are matched to the
     updatePaintNode override that contains them; any other function start in between means the
     call isn't in that override, and it is skipped.

Output, one line per item: address, original first 8 bytes (hex), class name. The shim checks
the bytes before patching each function to "return oldNode" (mov r0, r1; bx lr), so a different
Engine build can never be patched in the wrong place.

The waveform items reach the framebuffer through a shared helper (RMSNodeCache), so besides
items that create one directly, every QQuickItem subclass named WaveForm* is included.

Usage: gl_items.py ENGINE_ELF LIBQT6QUICK > patches.txt   (pure Python, runs at setup)
"""
import re
import struct
import sys

R_ARM_ABS32, R_ARM_GLOB_DAT, R_ARM_JUMP_SLOT, R_ARM_RELATIVE = 2, 21, 22, 23
FBO_CTORS = {
    "_ZN24QOpenGLFramebufferObjectC1ERK5QSizeRK30QOpenGLFramebufferObjectFormat",
    "_ZN24QOpenGLFramebufferObjectC2ERK5QSizeRK30QOpenGLFramebufferObjectFormat",
    "_ZN24QOpenGLFramebufferObjectC1ERK5QSizeNS_10AttachmentEjj",
    "_ZN24QOpenGLFramebufferObjectC1EiiNS_10AttachmentEjj",
    "_ZN24QOpenGLFramebufferObjectC1ERK5QSizej",
    "_ZN24QOpenGLFramebufferObjectC1Eiij",
}
BASE_UPN = "_ZN10QQuickItem15updatePaintNodeEP7QSGNodePNS_19UpdatePaintNodeDataE"
TI_VTABLES = ("_ZTVN10__cxxabiv117__class_type_infoE", "_ZTVN10__cxxabiv120__si_class_type_infoE",
              "_ZTVN10__cxxabiv121__vmi_class_type_infoE")


class Elf:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        d = self.d
        assert d[:4] == b"\x7fELF" and d[4] == 1 and d[5] == 1, "need a 32-bit little-endian ELF"
        shoff, = struct.unpack_from("<I", d, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x2E)
        secs = [struct.unpack_from("<IIIIIIIIII", d, shoff + i * shentsize) for i in range(shnum)]
        names = secs[shstrndx]
        self.sec = {}
        for s in secs:
            n = d[names[4] + s[0]:d.index(b"\0", names[4] + s[0])].decode()
            self.sec[n] = {"type": s[1], "addr": s[3], "off": s[4], "size": s[5], "link": s[6], "entsize": s[9]}
        phoff, = struct.unpack_from("<I", d, 0x1C)
        phentsize, phnum = struct.unpack_from("<HH", d, 0x2A)
        self.loads = []
        for i in range(phnum):
            t, off, va, pa, fsz, msz, fl, al = struct.unpack_from("<IIIIIIII", d, phoff + i * phentsize)
            if t == 1:
                self.loads.append((va, off, fsz))
        ds, dstr = self.sec[".dynsym"], self.sec[".dynstr"]
        self.syms = []
        for i in range(ds["size"] // 16):
            nm, val, sz, info, oth, shn = struct.unpack_from("<IIIBBH", d, ds["off"] + i * 16)
            self.syms.append(d[dstr["off"] + nm:d.index(b"\0", dstr["off"] + nm)].decode())
        self.rel = {}  # address -> (type, symbol name or None)
        for sname in (".rel.dyn", ".rel.plt"):
            s = self.sec.get(sname)
            if not s:
                continue
            for i in range(s["size"] // 8):
                off, info = struct.unpack_from("<II", d, s["off"] + i * 8)
                self.rel[off] = (info & 0xFF, self.syms[info >> 8] if info >> 8 else None)

    def off(self, va):
        for v, o, sz in self.loads:
            if v <= va < v + sz:
                return o + va - v
        return None

    def word(self, va):
        o = self.off(va)
        return struct.unpack_from("<I", self.d, o)[0] if o is not None else None

    def cstr(self, va):
        o = self.off(va)
        return self.d[o:self.d.index(b"\0", o)].decode("latin1") if o is not None else ""


def main():
    e = Elf(sys.argv[1])
    text = e.sec[".text"]
    t0, t1 = text["addr"], text["addr"] + text["size"]

    # code addresses referenced from data (vtables, function pointers): candidate function starts
    starts = sorted({e.word(a) for a, (t, _) in e.rel.items() if t == R_ARM_RELATIVE and t0 <= (e.word(a) or 0) < t1})

    # type info objects -> class names; vtables are [0][&typeinfo][vfuncs...]
    tinames = {}
    for a, (t, s) in e.rel.items():
        if t == R_ARM_ABS32 and s in TI_VTABLES:
            np = e.word(a + 4)
            if np:
                tinames[a] = e.cstr(np)
    vtables = []  # (address of first slot, class name)
    for a, (t, s) in e.rel.items():
        if t == R_ARM_RELATIVE and e.word(a) in tinames and e.word(a - 4) == 0:
            vtables.append((a + 4, tinames[e.word(a)]))

    def slot(vt, k):
        a = vt + 4 * k
        r = e.rel.get(a)
        if not r:
            return None, None
        return (r[1], None) if r[0] in (R_ARM_ABS32, R_ARM_GLOB_DAT) else (None, e.word(a))

    # which slot is updatePaintNode? Read it from QQuickItem's own vtable in libQt6Quick.
    q = Elf(sys.argv[2])
    qv = None
    for i, n in enumerate(q.syms):
        if n == "_ZTV10QQuickItem":
            ds = q.sec[".dynsym"]
            qv = struct.unpack_from("<I", q.d, ds["off"] + i * 16 + 4)[0]
    upn_slot = next(((a - qv - 8) // 4 for a, (t, sn) in q.rel.items() if sn == BASE_UPN and qv <= a < qv + 1024), None)
    if upn_slot is None:
        sys.exit("gl_items: QQuickItem::updatePaintNode slot not found")
    overrides = {}
    for vt, name in vtables:
        # a QQuickItem vtable: the slots around updatePaintNode point at QQuickItem functions
        near = [slot(vt, k)[0] or "" for k in range(upn_slot - 31, upn_slot + 3)]
        if sum(1 for n in near if "10QQuickItem" in n) < 8:
            continue
        sym, addr = slot(vt, upn_slot)
        if addr and t0 <= addr < t1:
            overrides.setdefault(addr, name)

    # PLT stubs of the FBO constructors: add ip, pc, #a; add ip, ip, #b; ldr pc, [ip, #c]!
    got_of = {a: s for a, (t, s) in e.rel.items() if t == R_ARM_JUMP_SLOT}
    plt = e.sec[".plt"]
    stubs = set()
    a = plt["addr"]
    while a + 12 <= plt["addr"] + plt["size"]:
        i0, i1, i2 = e.word(a), e.word(a + 4), e.word(a + 8)
        if (i0 & 0xFFFFF000) == 0xE28FC000 and (i1 & 0xFFFFF000) == 0xE28CC000 and (i2 & 0xFFFFF000) == 0xE5BCF000:
            def imm(i):
                rot = ((i >> 8) & 15) * 2
                v = i & 0xFF
                return ((v >> rot) | (v << (32 - rot))) & 0xFFFFFFFF
            got = (a + 8 + imm(i0) + imm(i1) + (i2 & 0xFFF)) & 0xFFFFFFFF
            if got_of.get(got) in FBO_CTORS:
                stubs.add(a)
            a += 12
        else:
            a += 4

    calls = []
    o = text["off"]
    for i in range(0, text["size"] - 3, 4):
        ins = struct.unpack_from("<I", e.d, o + i)[0]
        if (ins & 0xFF000000) == 0xEB000000:  # BL, always
            off = ins & 0xFFFFFF
            if off & 0x800000:
                off -= 0x1000000
            if t0 + i + 8 + off * 4 in stubs:
                calls.append(t0 + i)

    import bisect
    found = {}
    for c in calls:
        j = bisect.bisect_right(starts, c) - 1
        if j < 0:
            continue
        f = starts[j]
        if f in overrides and c - f < 0x4000:
            found[f] = overrides[f]
        else:
            print(f"# skipped FBO call at {c:#x}: not inside a known updatePaintNode", file=sys.stderr)
    for f, name in overrides.items():
        # QML-registered types show up as QQmlElement<T>; the slot still holds T's override
        m = re.match(r"N11QQmlPrivate11QQmlElementI\d+(\w+?)EE$", name)
        if re.search(r"Wave[Ff]orm", name):
            found.setdefault(f, re.sub(r"^\d+", "", m.group(1) if m else name))
    for f, name in sorted(found.items()):
        print(f"{f:#x} {e.d[e.off(f):e.off(f) + 8].hex()} {name}")
    print(f"# {len(found)} OpenGL item(s), updatePaintNode slot {upn_slot}, {len(calls)} FBO call site(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
