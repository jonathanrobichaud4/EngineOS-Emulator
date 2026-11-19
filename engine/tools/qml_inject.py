#!/usr/bin/env python3
"""Insert an emulator snippet into a QML file (assets/qml-inject/*.inject).

An .inject file is a header, a line with ---, then QML:
    path: /Skins/.../Waveform.qml     the resource the snippet goes into
    after: id: waveformView           insert after the first line that reads exactly this (trimmed)
The snippet takes that line's indentation. The shim does the same for Engine's compiled-in
files; this is for files on disk, i.e. EngineX's UI pack (see emu.sh, qml_inject_packs).

Usage: qml_inject.py SPEC IN OUT      (exit 2 if the anchor isn't there)
"""
import sys


def parse(spec):
    head, _, body = open(spec, encoding="utf-8").read().partition("\n---\n")
    meta = dict(l.split(":", 1) for l in head.splitlines() if ":" in l)
    return {k.strip(): v.strip() for k, v in meta.items()}, body


def inject(text, after, body):
    lines = text.splitlines(keepends=True)
    for i, l in enumerate(lines):
        if l.strip() == after:
            indent = l[:len(l) - len(l.lstrip())]
            add = "".join((indent + b if b.strip() else b) + "\n" for b in body.rstrip("\n").split("\n"))
            return "".join(lines[:i + 1]) + add + "".join(lines[i + 1:])
    return None


if __name__ == "__main__":
    meta, body = parse(sys.argv[1])
    out = inject(open(sys.argv[2], encoding="utf-8").read(), meta["after"], body)
    if out is None:
        sys.exit(2)
    open(sys.argv[3], "w", encoding="utf-8").write(out)
