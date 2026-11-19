"""The deck page's HTTP server and the viewer's command line (python3 -m viewer --help)."""
import argparse
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .audio import Audio
from .drives import Drives
from .forward import forward
from .frames import Fifo, Frames
from .surface import Surface
from .waves import Waves

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WEB = os.path.join(HERE, "web")
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8"}


def panel_for(product):
    """models/<CODE>/panel.json, or the first model's when a model has none."""
    p = os.path.join(ROOT, "models", product, "panel.json")
    if not os.path.exists(p):
        p = os.path.join(ROOT, "models", "JP21", "panel.json")
    with open(p, encoding="utf-8") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(prog="python3 -m viewer", description=__doc__)
    ap.add_argument("--rootfs", default=os.environ.get("EMU_ROOTFS", os.path.join(ROOT, "rootfs")))
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--product", default="JP21", help="the deck's model code: picks models/CODE/panel.json")
    ap.add_argument("--profile", default="default", help="the deck (emu.sh profile), for the Reboot button")
    ap.add_argument("--console", default="http://localhost:8080/", help="link to EngineX's web console")
    ap.add_argument("--forward", action="append", default=[], metavar="PORT=HOST:PORT",
                    help="forward a local TCP port into the deck's network namespace")
    ap.add_argument("--drives", default=os.path.join(ROOT, "drives.txt"))
    a = ap.parse_args()
    emu = os.path.join(a.rootfs, "tmp/emu")
    panel_json = panel_for(a.product)
    frames = Frames(os.path.join(emu, "fb"))
    touch = Fifo(os.path.join(emu, "input"))
    surface = Surface(emu, json.loads(panel_json))
    audio = Audio(emu)
    drives = Drives(a.drives)
    Waves(a.rootfs)
    with open(os.path.join(WEB, "index.html"), encoding="utf-8") as f:
        page = f.read().replace("__CONSOLE__", a.console).encode()
    statics = {}
    for name in os.listdir(WEB):
        ext = os.path.splitext(name)[1]
        if ext in (".css", ".js"):
            with open(os.path.join(WEB, name), "rb") as f:
                statics["/" + name] = (f.read(), TYPES[ext])

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def reply(self, code, body=b"", ctype="application/octet-stream"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def json(self, obj, code=200):
            self.reply(code, json.dumps(obj).encode(), "application/json")

        def q(self, key, default="0"):
            for kv in self.path.partition("?")[2].split("&"):
                k, _, v = kv.partition("=")
                if k == key:
                    return v
            return default

        def do_GET(self):
            p = self.path.partition("?")[0]
            if p in ("/", "/index.html"):
                self.reply(200, page, TYPES[".html"])
            elif p in statics:
                self.reply(200, *statics[p])
            elif p == "/panel.json":
                self.reply(200, panel_json.encode(), "application/json")
            elif p == "/frame":
                body = frames.get(int(self.q("since")))
                self.reply(200, body) if body else self.reply(204)
            elif p == "/state":
                self.json(surface.state(int(self.q("since"))))
            elif p == "/audio":
                self.reply(200, audio.get(int(self.q("pos"))))
            elif p == "/platter-art":
                # a Prime 4 jog screen's artwork: ?dev=2|3&slot=N (the PNG Engine sent it)
                png = surface.artwork(int(self.q("dev")), int(self.q("slot")))
                self.reply(200, png, "image/png") if png else self.reply(404)
            elif p == "/audio-devices":
                self.json(audio.devices())
            elif p == "/drives":
                self.json(drives.list())
            elif p == "/status":
                self.json({"frame": frames.header(), "product": a.product, "profile": a.profile})
            else:
                self.reply(404)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            text = self.rfile.read(n).decode("utf-8", "ignore")
            p = self.path.partition("?")[0]
            if p == "/input":
                ok = touch.send(text if text.endswith("\n") else text + "\n")
                self.reply(204 if ok else 503)
            elif p == "/control":
                for line in text.splitlines():
                    surface.event(line)
                self.reply(204)
            elif p == "/audio-select":
                idx, l, r = (int(x) for x in text.split())
                audio.select(idx, l, r)
                self.reply(204)
            elif p == "/drives":
                d = json.loads(text or "{}")
                if d.get("action") == "remove":
                    drives.remove(d.get("label", ""))
                    err = None
                else:
                    err = drives.add(d.get("folder", ""), d.get("kind", "usb"), d.get("label", ""))
                self.json({"error": err, "drives": drives.list()}, 400 if err else 200)
            elif p == "/reboot":
                # Like power-cycling the deck: stop and start the whole emulator (this deck).
                # Runs detached, since stopping it also stops this viewer; the page reconnects.
                emu_sh = os.path.join(ROOT, "engine", "emu.sh")
                subprocess.Popen(["setsid", "sh", "-c", 'sleep 0.5; "$0" --profile "$1" stop; "$0" --profile "$1" start',
                                  emu_sh, a.profile],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
                self.reply(204)
            else:
                self.reply(404)

    print(f"EngineOS Emulator viewer: http://localhost:{a.port}/", flush=True)
    for f in a.forward:
        lp, tgt = f.split("=", 1)
        forward(int(lp), tgt)
    ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()
