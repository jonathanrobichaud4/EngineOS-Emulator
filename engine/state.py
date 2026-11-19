#!/usr/bin/env python3
"""The emulator's state for the apps, read from the checkout (engine/emu.sh runs this).

  state.py --root ROOT [--data DIR] profiles [--json]   every deck: name, set up, EngineX, model, running
  state.py --root ROOT drives              the plugged-in drives, as JSON
  state.py --root ROOT info --profile P ...  everything at once, as JSON (emu.sh info --json)

The JSON is described in docs/cli.md. Standard library only.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models"))
import models as model_db  # noqa: E402


def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def alive(pidfile):
    try:
        pid = int(read(pidfile).strip())
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True  # someone else's process (not root), but it's there


def decks(root, codes):
    """A deck exists once it has a rootfs (set up) or a state folder (made with "profile new")."""
    names = []
    for d in sorted(os.listdir(root)):
        m = re.fullmatch(r"(rootfs|state)(-[A-Za-z0-9_-]+)?", d)
        if m and os.path.isdir(os.path.join(root, d)):
            n = (m.group(2) or "")[1:] or "default"
            if n not in names:
                names.append(n)
    names.sort(key=lambda n: (n != "default", n))  # the default deck first, as emu.sh always listed it
    out = []
    for n in names:
        sfx = "" if n == "default" else "-" + n
        rootfs, state = os.path.join(root, "rootfs" + sfx), os.path.join(root, "state" + sfx)
        code = read(os.path.join(state, "product")).strip()
        if code not in codes:
            code = codes[0]
        out.append({"name": n,
                    "setup": os.access(os.path.join(rootfs, "usr/Engine/Engine"), os.X_OK),
                    "enginex": read(os.path.join(rootfs, "data/enginex/version.txt")).split("\n")[0].strip(),
                    "model": code,
                    "running": alive(os.path.join(state, "emu.pid"))})
    return out


def drives(root):
    out = []
    for line in read(os.path.join(root, "drives.txt")).splitlines():
        p = line.split("\t")
        if len(p) == 3:
            out.append({"label": p[0], "kind": p[1], "folder": p[2], "ok": os.path.isdir(p[2])})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="the checkout")
    ap.add_argument("--data", help="where the decks and drives.txt are (default: the checkout)")
    ap.add_argument("what", choices=["profiles", "drives", "info"])
    ap.add_argument("--json", action="store_true")
    for k in ("profile", "product", "rootfs", "state", "engine", "ip", "deck-url", "console-url"):
        ap.add_argument("--" + k, default="")
    a = ap.parse_args()
    data = a.data or a.root
    models = model_db.load()
    codes = [m["code"] for m in models]

    if a.what == "profiles":
        ds = decks(data, codes)
        if a.json:
            print(json.dumps(ds))
        else:
            for d in ds:
                yn = lambda b: "yes" if b else "no"  # noqa: E731
                print(f"{d['name']}\t{yn(d['setup'])}\t{d['enginex']}\t{d['model']}\t{yn(d['running'])}")
        return
    if a.what == "drives":
        print(json.dumps(drives(data)))
        return

    names = {m["code"]: m["name"] for m in models}
    product = a.product if a.product in codes else codes[0]
    print(json.dumps({
        "version": read(os.path.join(a.root, "VERSION")).strip() or "dev",
        "profile": a.profile or "default",
        "product": product,
        "product_name": names.get(product, product),
        "setup": os.access(os.path.join(a.rootfs, "usr/Engine/Engine"), os.X_OK),
        "enginex": read(os.path.join(a.rootfs, "data/enginex/version.txt")).split("\n")[0].strip(),
        "engine_error": read(os.path.join(a.state, "engine-error")).strip(),
        "running": alive(os.path.join(a.state, "emu.pid")),
        "engine": a.engine or "down",
        "ip": a.ip,
        "deck_url": a.deck_url,
        "console_url": a.console_url,
        "decks": decks(data, codes),
        "drives": drives(data),
        "models": model_db.public(models),
    }))


if __name__ == "__main__":
    main()
