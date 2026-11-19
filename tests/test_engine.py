"""engine/emu.sh's commands that don't need a firmware: decks, drives, identify, info.

Run as root (the deck commands need it, like on WSL or in the VM), in a scratch data folder.
"""
import io
import json
import os
import tarfile
import tempfile
import unittest

from helpers import emu


@unittest.skipUnless(os.geteuid() == 0, "needs root (sudo tests/run.sh)")
class Decks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def profiles(self):
        return [line.split("\t") for line in emu("profiles", data=self.d).splitlines()]

    def test_lifecycle(self):
        self.assertEqual(self.profiles(), [])
        emu("profile", "new", "stock", data=self.d)
        emu("profile", "new", "p4", "jc11s", data=self.d)
        self.assertEqual(self.profiles(), [["p4", "no", "", "JC11S", "no"], ["stock", "no", "", "JP21", "no"]])
        emu("profile", "rename", "p4", "prime", data=self.d)
        emu("profile", "model", "prime", "JC11", data=self.d)
        self.assertEqual(emu("profile", "model", "prime", data=self.d).strip(), "JC11")
        emu("profile", "delete", "stock", data=self.d)
        self.assertEqual([p[0] for p in self.profiles()], ["prime"])
        info = json.loads(emu("--profile", "prime", "info", "--json", data=self.d))
        self.assertEqual((info["product"], info["product_name"], info["setup"], info["running"]), ("JC11", "Prime 4", False, False))
        self.assertEqual([m["code"] for m in info["models"]], ["JP21", "JC11S", "JC11"])

    def test_refuses(self):
        emu("profile", "new", "a", data=self.d)
        for args in (["profile", "new", "a"], ["profile", "new", "b c"], ["profile", "new", "b", "XX99"],
                     ["profile", "rename", "nope", "x"], ["product", "XX99"]):
            with self.subTest(args):
                with self.assertRaises(AssertionError):
                    emu(*args, data=self.d)

    def test_drives(self):
        music = os.path.join(self.d, "Music")
        os.mkdir(music)
        emu("drive", "add", music, data=self.d)
        emu("drive", "add", self.d, "--sd", "--label", "CARD", data=self.d)
        with self.assertRaises(AssertionError):
            emu("drive", "type", "Music", "sd", data=self.d)  # one SD slot
        emu("drive", "rename", "Music", "TUNES", data=self.d)
        drives = json.loads(emu("drive", "list", "--json", data=self.d))
        self.assertEqual([(x["label"], x["kind"], x["ok"]) for x in drives], [("TUNES", "usb", True), ("CARD", "sd", True)])
        emu("drive", "remove", "CARD", data=self.d)
        emu("drive", "type", "TUNES", "sd", data=self.d)
        self.assertEqual(json.loads(emu("info", "--json", data=self.d))["drives"][0]["kind"], "sd")

    def test_identify(self):
        def make(name, data):
            p = os.path.join(self.d, name)
            with open(p, "wb") as f:
                f.write(data)
            return p

        def tgz(name, members):
            p = os.path.join(self.d, name)
            with tarfile.open(p, "w:gz") as t:
                for m in members:
                    ti = tarfile.TarInfo(m)
                    ti.size = 2
                    t.addfile(ti, io.BytesIO(b"{}"))
            return p

        cases = {make("fw.img", b"AZ0x" + bytes(60)): "firmware", make("p4.img", b"AZ01" + bytes(60)): "firmware",
                 make("ex.img", b"hsqs" + bytes(60)): "enginex", make("up.exe", b"MZ" + bytes(60)): "firmware",
                 make("up.zip", b"PK\x03\x04" + bytes(60)): "firmware", make("x.txt", b"hi"): "unknown",
                 tgz("mod.tar.gz", ["m/mod.json", "m/main.qml"]): "mod", tgz("bundle.tar.gz", ["b/install.sh"]): "enginex"}
        for path, want in cases.items():
            with self.subTest(os.path.basename(path)):
                self.assertEqual(emu("identify", path, data=self.d).strip(), want)


class Cli(unittest.TestCase):
    def test_models(self):
        self.assertEqual(emu("models").split("\n")[0], "JP21\tSC LIVE 4")

    def test_graphics_is_opengl_only(self):
        # Older apps run `graphics auto|software` before starting a deck; it has to keep working.
        self.assertIn("OpenGL", emu("graphics", "software"))

    def test_help(self):
        out = emu(check=False)
        self.assertIn("sudo ./emu.sh setup FIRMWARE.img", out)


if __name__ == "__main__":
    unittest.main()
