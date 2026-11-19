#!/usr/bin/env python3
"""Generates files/panel-JC11S.json and files/panel-JC11.json: the Prime 4+ and Prime 4 control
surface for the emulator's browser panel (the two look and map the same).

Every MIDI number comes from Engine's own assignment files
(/usr/Engine/AssignmentFiles/PresetAssignmentFiles/JC11S/JC11S_Controller_Assignments.qml) and the
ControlSurfaceModules they use. Positions follow the top panel drawing in Denon's PRIME 4 user
guide (v5.3.0, page 6): D() takes coordinates in that drawing rendered 981 x 654, scaled 1.9x.

Everything goes to the Controller (MIDI device 0): Engine's Controller assignment covers the decks,
the mixer channels, FX and browsing. Controls the real unit handles in its own mixer hardware
(master level, headphones) have "hw" set instead of MIDI: the emulator's audio mixer reads them.
The mic, booth and zone sections aren't emulated (no audio comes in or goes out there).

Control types as in make_panel.py.
"""
import json
import os
import sys

G = 15  # global MIDI channel
C = []
S = 1.9
OX, OY = 20, 20


def X(x): return round(OX + x * S)
def Y(y): return round(OY + y * S)
def L(v): return round(v * S)


def add(**k):
    C.append(k)


def put(t, cx, cy, w, h, **k):
    pw, ph = max(L(w), k.pop("minw", 0)), max(L(h), k.pop("minh", 0))
    add(t=t, x=X(cx) - pw // 2, y=Y(cy) - ph // 2, w=pw, h=ph, **k)


def lab(text, cx, cy, w=60, big=0):
    add(t="label", lab=text, x=X(cx) - L(w) // 2, y=Y(cy) - 7, w=L(w), h=14, **({"big": 1} if big else {}))


# ---------------------------------------------------------------- body panels
add(t="panel", x=X(2), y=Y(37), w=L(318), h=L(612))      # left deck + FX 1
add(t="panel", x=X(661), y=Y(37), w=L(318), h=L(612))    # right deck + FX 2
add(t="panel", x=X(322), y=Y(243), w=L(337), h=L(406))   # mixer

# ---------------------------------------------------------------- screen and browse
# The real screen sits in the drawing at x 325..660, y 5..240.
SW, SH = 620, 388
add(t="screen", x=X(492) - SW // 2, y=Y(10), w=SW, h=SH)
put("btn", 467, 257, 22, 12, id="back", lab="BACK", ch=G, n=3, small=1)
put("btn", 517, 257, 22, 12, id="forward", lab="FWD", ch=G, n=4, small=1)
put("enc", 492, 280, 26, 26, id="browse", lab="", ch=G, cc=5, push=6)
put("btn", 465, 303, 22, 12, id="load_l", lab="◀ LOAD", ch=G, n=1, small=1)
put("btn", 519, 303, 22, 12, id="load_r", lab="LOAD ▶", ch=G, n=2, small=1)
put("btn", 492, 320, 26, 12, id="view", lab="VIEW", ch=G, n=7, small=1)


# ---------------------------------------------------------------- decks
def deck(side, dx, ch, decks):
    p = f"d{side}_"
    def d(x): return x + dx
    put("enc", d(40), 280, 24, 24, id=p + "autoloop", lab="AUTO LOOP", ch=ch, cc=32, push=39)
    put("btn", d(27), 310, 22, 11, id=p + "loopin", lab="IN", ch=ch, n=37, small=1)
    put("btn", d(55), 310, 22, 11, id=p + "loopout", lab="OUT", ch=ch, n=38, small=1)
    put("btn", d(82), 277, 18, 12, id=p + "slip", lab="SLIP", ch=ch, n=36, small=1)
    put("btn", d(257), 277, 20, 12, id=p + "vinyl", lab="VINYL", ch=ch, n=35, small=1)
    put("btn", d(300), 277, 18, 12, id=p + "keylock", lab="♪", ch=ch, n=34)
    put("btn", d(32), 335, 26, 11, id=p + "censor", lab="CENSOR", ch=ch, n=1, small=1)
    # deck layer buttons: Deck 1/3 on the left, 2/4 on the right (global channel, notes 28-31)
    put("btn", d(32), 374, 18, 18, id=f"deck{decks[0]}", lab=str(decks[0]), ch=G, n=27 + decks[0], round=1)
    put("btn", d(32), 400, 18, 18, id=f"deck{decks[1]}", lab=str(decks[1]), ch=G, n=27 + decks[1], round=1)
    lab("DECK", d(32), 387, 30)
    # platter: the jog wheel's screen is MIDI device 2 (left) or 3 (right); the page draws it
    put("jog", d(167), 387, 205, 205, id=p + "jog", lab=f"DECK {decks[0]}/{decks[1]}", ch=ch, cc=0x37, cc2=0x4D, touch=33, platter=1 + side)
    put("pitch", d(300), 385, 16, 150, id=p + "pitch", lab="TEMPO", ch=ch, cc=0x1F, cc2=0x4B, led=42)
    lab("TRACK SKIP", d(45), 447, 60)
    put("btn", d(32), 459, 16, 14, id=p + "prev", lab="⏮", ch=ch, n=4, round=1)
    put("btn", d(59), 459, 16, 14, id=p + "next", lab="⏭", ch=ch, n=5, round=1)
    lab("BEAT JUMP", d(45), 477, 60)
    put("btn", d(32), 490, 16, 14, id=p + "bjprev", lab="◀", ch=ch, n=6, round=1)
    put("btn", d(59), 490, 16, 14, id=p + "bjnext", lab="▶", ch=ch, n=7, round=1)
    lab("PITCH BEND", d(300), 476, 60)
    put("btn", d(289), 489, 16, 12, id=p + "bendm", lab="−", ch=ch, n=29)
    put("btn", d(311), 489, 16, 12, id=p + "bendp", lab="+", ch=ch, n=30)
    put("btn", d(42), 526, 36, 13, id=p + "sync", lab="SYNC", ch=ch, n=8, col="#3aa0ff")
    for i, (lb, x) in enumerate(zip(["HOT CUE", "LOOP", "ROLL", "SLICER"], [102, 145, 185, 227])):
        put("btn", d(x), 525, 34, 11, id=f"{p}mode{i + 1}", lab=lb, ch=ch, n=11 + i, small=1)
    put("btn", d(295), 526, 24, 11, id=p + "shift", lab="SHIFT", ch=ch, n=28, small=1)
    put("btn", d(45), 562, 44, 31, id=p + "cue", lab="CUE", ch=ch, n=9, big=1)
    put("btn", d(45), 605, 44, 31, id=p + "play", lab="▶❙❙", ch=ch, n=10, big=1, col="#2bd46a")
    for r, y in enumerate([560, 600]):
        for c, x in enumerate([105, 147, 187, 227]):
            i = r * 4 + c
            put("pad", d(x), y, 34, 30, id=f"{p}pad{i + 1}", lab=str(i + 1), ch=ch, n=15 + i)
    put("btn", d(289), 560, 40, 11, id=p + "grid", lab="EDIT GRID", ch=ch, n=27, small=1)
    put("btn", d(277), 586, 18, 12, id=p + "gridl", lab="|◀", ch=ch, n=25, small=1)
    put("btn", d(300), 586, 18, 12, id=p + "gridr", lab="▶|", ch=ch, n=26, small=1)
    put("btn", d(277), 614, 18, 12, id=p + "parml", lab="◀", ch=ch, n=23)
    put("btn", d(300), 614, 18, 12, id=p + "parmr", lab="▶", ch=ch, n=24)


deck(1, 0, 4, (1, 3))
deck(2, 633, 5, (2, 4))


# ---------------------------------------------------------------- FX units (above the decks)
def fx(unit, dx, ch):
    p = f"fx{unit}_"
    def d(x): return x + dx
    lab(f"FX {unit}", d(18), 200, 30, big=1)
    # the four OLEDs over the knobs (Controller OLEDs 0-3 for FX 1, 4-7 for FX 2), 128 x 32
    for k, x in enumerate([67, 132, 200, 265]):
        put("oled", d(x), 172, 64, 17, id=f"{p}oled{k + 1}", oled=(unit - 1) * 4 + k)
    put("enc", d(67), 200, 22, 22, id=p + "select", lab="FX SELECT", ch=ch, cc=1)
    put("knob", d(132), 200, 22, 22, id=p + "param", lab="PARAMETER", ch=ch, cc=2, d=64)
    put("knob", d(200), 200, 22, 22, id=p + "freq", lab="FREQUENCY", ch=ch, cc=3, d=64)
    put("knob", d(265), 200, 22, 22, id=p + "wet", lab="WET/DRY", ch=ch, cc=4, d=0)
    put("btn", d(70), 228, 26, 11, id=p + "on", lab="ON", ch=ch, n=6, col="#2a8cff")
    put("btn", d(132), 228, 26, 11, id=p + "parampush", lab="PARAM", ch=ch, n=7, small=1)
    put("btn", d(197), 228, 26, 11, id=p + "reset", lab="RESET", ch=ch, n=8, small=1)
    put("btn", d(252), 228, 16, 11, id=p + "beatsm", lab="◀", ch=ch, n=9)
    put("btn", d(275), 228, 16, 11, id=p + "beatsp", lab="▶", ch=ch, n=10)


fx(1, 0, 6)
fx(2, 648, 7)

# ---------------------------------------------------------------- top right: master, media
put("knob", 687, 110, 24, 24, id="master", lab="MASTER", hw="master", d=100)
put("btn", 725, 100, 22, 11, id="zone", lab="ZONE", ch=G, n=16, small=1)
put("btn", 927, 147, 18, 12, id="eject", lab="EJECT", ch=G, n=20, small=1)
lab("SD  USB 1  USB 2", 918, 120, 90)
lab("(not emulated: mic, booth and zone audio)", 160, 110, 220)

# ---------------------------------------------------------------- mixer
# channel strips in panel order 3 1 2 4 -> MIDI channels 2 0 1 3; meters sit on the outer side
for (name, mch), x, vx in zip([("3", 2), ("1", 0), ("2", 1), ("4", 3)], [355, 422, 555, 620], [-21, -21, 22, 22]):
    p = f"ch{name}_"
    put("btn", x - 10, 256, 16, 10, id=p + "fx1", lab="1", ch=mch, n=1, small=1)
    put("btn", x + 10, 256, 16, 10, id=p + "fx2", lab="2", ch=mch, n=2, small=1)
    put("knob", x, 281, 20, 20, id=p + "trim", lab="LEVEL", ch=mch, cc=3, d=64)
    lab(name, x + vx, 304, 20, big=1)
    put("vu", x + vx, 378, 6, 100, id=p + "vu", ch=mch, cc=10, inc=1, segs=10)
    put("knob", x, 325, 20, 20, id=p + "hi", lab="HIGH", ch=mch, cc=4, d=64)
    put("knob", x, 365, 20, 20, id=p + "mid", lab="MID", ch=mch, cc=6, d=64)
    put("knob", x, 405, 20, 20, id=p + "lo", lab="LOW", ch=mch, cc=8, d=64)
    put("knob", x, 446, 24, 24, id=p + "sweep", lab="SWEEP FX", ch=mch, cc=11, d=64, ring=1)
    put("btn", x, 476, 24, 11, id=p + "cue", lab="CUE", ch=mch, n=13)
    put("fader", x, 540, 14, 70, id=p + "fader", lab="", ch=mch, cc=14, d=0)
    put("sw", x, 584, 28, 10, id=p + "thru", lab="", ch=mch, n=15, vals=[0, 1, 2], d=1, labs=["A", "THRU", "B"])

# centre column
# Main meters show what you're listening to in the browser; PHONES sets its volume when you
# listen to the headphone output (MASTER does for the main one).
put("vu", 482, 388, 5, 84, id="vuL", hw="vuL", segs=10, inc=1)
put("vu", 502, 388, 5, 84, id="vuR", hw="vuR", segs=10, inc=1)
lab("MAIN", 492, 437, 40)
put("knob", 492, 470, 22, 22, id="phones", lab="PHONES", hw="phones", d=100)
lab("SWEEP FX", 492, 543, 50)
for i, (lb, x, y) in enumerate([("FILTER", 477, 556), ("ECHO", 507, 556), ("WASH", 477, 576), ("NOISE", 507, 576)]):
    put("btn", x, y, 26, 14, id=f"sweep{i + 1}", lab=lb, ch=G, n=12 + i, small=1)
put("xfader", 492, 610, 80, 16, id="xfader", lab="", ch=G, cc=14, d=64)
put("knob", 395, 612, 16, 16, id="contour", lab="CONTOUR", ch=G, cc=26, d=64)

here = os.path.dirname(os.path.abspath(__file__))
for code in sys.argv[1:] or ["JC11S", "JC11"]:
    out = {"name": {"JC11S": "PRIME 4+", "JC11": "PRIME 4"}.get(code, code), "w": X(981) + OX, "h": Y(654) + OY,
           # Engine's output pairs (it mixes the decks itself): 1/2 main, 5/6 headphone cue
           "outs": ["Main", "Booth", "Phones", "Zone"], "controls": C}
    path = os.path.join(here, "..", "files", f"panel-{code}.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=0)
    print(f"{len(C)} controls -> {os.path.normpath(path)}")
