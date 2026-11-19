"""The model data (models/) and everything made from it."""
import json
import os
import subprocess
import unittest

from helpers import ROOT
import models

KNOWN = {"screen", "panel", "label", "btn", "pad", "knob", "enc", "fader", "pitch", "xfader", "jog", "sw", "sel", "oled", "vu"}


class Models(unittest.TestCase):
    def setUp(self):
        self.models = models.load()

    def test_fields(self):
        self.assertTrue(self.models)
        for m in self.models:
            with self.subTest(m["code"]):
                for k in ("code", "name", "firmware", "audio", "midi"):
                    self.assertIn(k, m)
                self.assertIn(m["firmware"]["container"], ("AZ0x", "AZ01"))
                self.assertTrue(m["midi"]["devices"])
                self.assertLessEqual(len(m["midi"]["devices"]), 4)  # the shim's table holds 4

    def test_one_default_per_firmware(self):
        for cont in {m["firmware"]["container"] for m in self.models}:
            defaults = [m["code"] for m in self.models if m["firmware"]["container"] == cont and m["firmware"].get("default")]
            self.assertEqual(len(defaults), 1, f"{cont}: {defaults}")

    def test_panels(self):
        for m in self.models:
            with self.subTest(m["code"]):
                with open(os.path.join(ROOT, "models", m["code"], "panel.json")) as f:
                    p = json.load(f)
                self.assertEqual(p["name"], m["name"])
                self.assertEqual(p["outs"], m["audio"]["outputs"])
                ids = [c["id"] for c in p["controls"] if "id" in c]
                self.assertEqual(len(ids), len(set(ids)), "control ids repeat")
                ndev = len(m["midi"]["devices"])
                for c in p["controls"]:
                    self.assertIn(c["t"], KNOWN)
                    self.assertLess(c.get("dev", 0), ndev, c.get("id"))
                    self.assertTrue(0 <= c["x"] and c["x"] + c["w"] <= p["w"] and 0 <= c["y"] and c["y"] + c["h"] <= p["h"], c.get("id"))

    def test_shell(self):
        out = subprocess.run(["bash", "-c", 'eval "$(python3 models/models.py shell)"; echo "$MODEL_CODES"; '
                              'for c in $MODEL_CODES; do v=model_${c}_name; echo "${!v}"; done'],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
        self.assertEqual(out[0].split(), [m["code"] for m in self.models])
        self.assertEqual(out[1:1 + len(self.models)], [m["name"] for m in self.models])

    def test_note(self):
        self.assertEqual(models.note(self.models), "SC LIVE 4 and Prime 4+ decks are set up with the SC LIVE 4 firmware; "
                                                    "a Prime 4 deck with Prime 4 firmware.")

    def test_shim_header_is_current(self):
        with open(os.path.join(ROOT, "engine", "shim", "models.h")) as f:
            self.assertEqual(f.read(), models.header(self.models), "run: make -C engine/shim")


if __name__ == "__main__":
    unittest.main()
