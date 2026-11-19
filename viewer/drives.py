"""drives.txt: the folders plugged into the deck (label <TAB> usb|sd <TAB> folder)."""
import os


class Drives:
    def __init__(self, path):
        self.path = path

    def list(self):
        out = []
        try:
            for line in open(self.path):
                p = line.rstrip("\n").split("\t")
                if len(p) == 3:
                    out.append({"label": p[0], "kind": p[1], "folder": p[2], "ok": os.path.isdir(p[2])})
        except FileNotFoundError:
            pass
        return out

    def add(self, folder, kind, label):
        folder = os.path.abspath(os.path.expanduser(folder))
        if not os.path.isdir(folder):
            return f"no such folder: {folder}"
        kind = "sd" if kind == "sd" else "usb"
        label = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in (label or os.path.basename(folder)))[:11] or "MUSIC"
        cur = self.list()
        if any(d["label"] == label for d in cur):
            return f"a drive called {label} is already attached"
        if kind == "sd" and any(d["kind"] == "sd" for d in cur):
            return "the deck has one SD slot and it's in use"
        with open(self.path, "a") as f:
            f.write(f"{label}\t{kind}\t{folder}\n")
        return None

    def remove(self, label):
        keep = [d for d in self.list() if d["label"] != label]
        with open(self.path + ".tmp", "w") as f:
            for d in keep:
                f.write(f"{d['label']}\t{d['kind']}\t{d['folder']}\n")
        os.replace(self.path + ".tmp", self.path)
