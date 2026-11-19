#!/usr/bin/env python3
"""Generates models/JP21/panel.json: the SC LIVE 4 control surface for the emulator's browser panel.

Every MIDI number here comes from Engine's own JP21 assignment file
(/usr/Engine/AssignmentFiles/PresetAssignmentFiles/JP21/JP21_Controller_Assignments.qml) and
the ControlSurfaceModules it uses. Positions follow the top panel drawing in Denon's SC LIVE 4
user guide: each control is placed at its spot in that drawing (D() below takes drawing
coordinates, a 1475 x 844 image) scaled up 1.36x. The one exception is the touchscreen, drawn
larger than life (it grows into the empty space above the decks) so it stays usable on a monitor;
the buttons beside it move out with it. Coordinates are in a 1900 x 1120 space.

Control types:
  btn    momentary button: note on 127 / note off. LED = same channel+note.
  pad    performance pad (RGB LED from velocity: rrggbb, 2 bits each)
  knob   absolute pot, CC 0-127
  enc    endless encoder: relative CC (1 = +1, 127 = -1), optional push note
  fader  vertical fader, CC 0-127 (top = 127)
  xfader horizontal crossfader, CC 0-127
  pitch  14-bit pitch fader (cc = MSB, cc2 = LSB), value 0-16383, top = 0
  jog    14-bit absolute jog position (cc/cc2) + touch note
  sw     switch: a note whose velocity is the position (vals), latched
  sel    rotary selector: one value per position (vals), sent as CC `cc` or as note `n` + velocity
  vu     LED meter driven by a CC (bitwise: 0,1,3,7,15,31,63)
  label  text only
"""
import json
import os

G = 15  # global MIDI channel (16 on the panel)
C = []


def add(**k):
    C.append(k)


S = 1.36                 # drawing -> panel scale
BX, BY = 52, 395         # where drawing point (75, 265) lands: the body's left edge, the mixer's top


def X(x): return round(BX + (x - 75) * S)
def Y(y): return round(BY + (y - 265) * S)
def L(v): return round(v * S)  # a length


def put(t, cx, cy, w, h, **k):
    """Adds a control centred on drawing point (cx, cy), w x h in drawing units (min sizes keep it usable)."""
    pw, ph = max(L(w), k.pop("minw", 0)), max(L(h), k.pop("minh", 0))
    add(t=t, x=X(cx) - pw // 2, y=Y(cy) - ph // 2, w=pw, h=ph, **k)


def lab(text, cx, cy, w=60, big=0):
    add(t="label", lab=text, x=X(cx) - L(w) // 2, y=Y(cy) - 7, w=L(w), h=14, **({"big": 1} if big else {}))


# ---------------------------------------------------------------- screen module, browse
# Screen centre is drawing x 742; it spans the space above the mixer and decks.
SW, SH = 600, 375
SCX = X(742)
add(t="screen", x=SCX - SW // 2, y=12, w=SW, h=SH)
def sy(y): return round(12 + (y - 60) / 190 * SH)   # drawing y beside the screen (60..250) -> panel y
LX, RX = SCX - SW // 2 - 40, SCX + SW // 2 + 40      # columns left and right of the screen
add(t="btn", id="view", lab="VIEW", x=LX - 22, y=sy(110) - 22, w=44, h=44, ch=G, n=14, round=1)
add(t="btn", id="menu", lab="MENU", x=LX - 27, y=sy(155) - 15, w=54, h=30, ch=G, n=13)
add(t="btn", id="lighting", lab="LIGHTING", x=LX - 30, y=sy(203) - 15, w=60, h=30, ch=G, n=39, small=1)
add(t="btn", id="back", lab="BACK", x=RX - 47, y=sy(88) - 17, w=44, h=34, ch=G, n=3)
add(t="btn", id="forward", lab="FWD", x=RX + 3, y=sy(88) - 17, w=44, h=34, ch=G, n=4)
add(t="enc", id="browse", lab="BROWSE", x=RX - 30, y=sy(150) - 30, w=60, h=60, ch=G, cc=5, push=6)
add(t="btn", id="load_l", lab="◀ LOAD", x=RX - 47, y=sy(205) - 17, w=44, h=34, ch=G, n=1, small=1)
add(t="btn", id="load_r", lab="LOAD ▶", x=RX + 3, y=sy(205) - 17, w=44, h=34, ch=G, n=2, small=1)


# ---------------------------------------------------------------- decks
# Both decks have the same layout; the right one sits 866 drawing units further right.
def deck(side, dx, ch):
    p = f"d{side}_"
    def d(x): return x + dx
    put("enc", d(119), 304, 42, 42, id=p + "autoloop", lab="AUTO LOOP", ch=ch, cc=32, push=39)
    put("btn", d(103), 364, 26, 16, id=p + "loopin", lab="IN", ch=ch, n=37)
    put("btn", d(136), 364, 26, 16, id=p + "loopout", lab="OUT", ch=ch, n=38)
    put("btn", d(119), 409, 40, 17, id=p + "censor", lab="CENSOR", ch=ch, n=1)
    lab(str(side), d(119), 459, 20, big=1)
    put("btn", d(119), 484, 28, 28, id=p + "deck", lab="DECK", ch=ch, n=31, round=1)
    lab(str(side + 2), d(119), 511, 20, big=1)
    lab("TRACK SKIP", d(119), 537, 70)
    put("btn", d(102), 553, 24, 22, id=p + "prev", lab="⏮", ch=ch, n=4, round=1)
    put("btn", d(137), 553, 24, 22, id=p + "next", lab="⏭", ch=ch, n=5, round=1)
    lab("BEAT JUMP", d(119), 583, 70)
    put("btn", d(102), 600, 24, 22, id=p + "bjprev", lab="◀", ch=ch, n=6, round=1)
    put("btn", d(137), 600, 24, 22, id=p + "bjnext", lab="▶", ch=ch, n=7, round=1)
    put("btn", d(120), 665, 52, 48, id=p + "cue", lab="CUE", ch=ch, n=9, big=1)
    put("btn", d(120), 733, 52, 42, id=p + "play", lab="▶❙❙", ch=ch, n=10, big=1, col="#2bd46a")
    # jog wheel
    put("jog", d(307), 475, 300, 300, id=p + "jog", lab=f"DECK {side}", ch=ch, cc=0x11, cc2=0x31, touch=33)
    # right of the jog
    put("btn", d(495), 330, 34, 19, id=p + "vinyl", lab="VINYL", ch=ch, n=35)
    put("btn", d(480), 391, 28, 17, id=p + "sync", lab="SYNC", ch=ch, n=8, col="#3aa0ff")
    put("btn", d(512), 391, 28, 17, id=p + "keylock", lab="♪", ch=ch, n=34)
    put("pitch", d(496), 563, 22, 226, id=p + "pitch", lab="TEMPO", ch=ch, cc=0x1F, cc2=0x4B, led=42)
    put("btn", d(437), 607, 23, 23, id=p + "slip", lab="SLIP", ch=ch, n=36, round=1, col="#3aa0ff", small=1)
    lab("PITCH BEND", d(496), 716, 60)
    put("btn", d(481), 732, 24, 15, id=p + "bendm", lab="−", ch=ch, n=29)
    put("btn", d(511), 732, 24, 15, id=p + "bendp", lab="+", ch=ch, n=30)
    # pad section
    put("btn", d(215), 646, 24, 14, id=p + "shift", lab="SHIFT", ch=ch, n=28, small=1)
    for i, (lb, x) in enumerate(zip(["CUE", "LOOP", "ROLL", "SLICER"], [245, 276, 307, 338])):
        put("btn", d(x), 646, 26, 14, id=f"{p}mode{i + 1}", lab=lb, ch=ch, n=11 + i, small=1)
    put("btn", d(370), 646, 24, 14, id=p + "parml", lab="◀", ch=ch, n=23)
    put("btn", d(401), 646, 24, 14, id=p + "parmr", lab="▶", ch=ch, n=24)
    for r, y in enumerate([687, 735]):
        for c, x in enumerate([225, 280, 335, 390]):
            i = r * 4 + c
            put("pad", d(x), y, 46, 38, id=f"{p}pad{i + 1}", lab=str(i + 1), ch=ch, n=15 + i)


deck(1, 0, 4)
deck(2, 866, 5)

# ---------------------------------------------------------------- mixer
add(t="panel", x=X(540), y=Y(268), w=L(400), h=L(510))
# aux column
lab("SPEAKER/BOOTH", 572, 276, 70)
put("knob", 557, 300, 26, 26, id="booth", lab="LEVEL", ch=G, cc=15, d=0)
put("sw", 600, 304, 34, 14, id="speaker", lab="SPEAKER", ch=G, n=41, vals=[0, 127], d=0, labs=["OFF", "ON"])
put("knob", 557, 367, 26, 26, id="mic1", lab="MIC 1", ch=G, cc=16, d=0)
put("btn", 597, 367, 22, 22, id="mic1on", lab="ON", ch=G, n=36, round=1)
put("knob", 557, 422, 26, 26, id="mic2", lab="AUX/MIC 2", ch=G, cc=17, d=0)
put("btn", 597, 422, 22, 22, id="mic2on", lab="ON", ch=G, n=37, round=1)
put("sw", 600, 446, 32, 12, id="micaux", lab="MIC/AUX", ch=G, n=42, vals=[0, 127], d=0, labs=["MIC", "AUX"])
lab("SWEEP FX", 577, 498, 50)
for i, (lb, x, y) in enumerate([("FILTER", 559, 479), ("ECHO", 559, 518), ("NOISE", 595, 479), ("WASH", 595, 518)]):
    put("btn", x, y, 22, 22, id=f"sweep{i + 1}", lab=lb, ch=G, n=21 + i, round=1, small=1)
put("knob", 577, 567, 26, 26, id="cuemix", lab="CUE MIX", ch=G, cc=18, d=64)
put("knob", 577, 616, 26, 26, id="cuegain", lab="LEVEL", ch=G, cc=19, d=64)
put("sw", 577, 659, 34, 16, id="splitcue", lab="SPLIT CUE", ch=G, n=11, vals=[0, 127], d=0, labs=["OFF", "ON"])
lab("HEADPHONES", 577, 690, 70)

# channel strips, in panel order 3 1 2 4
for (name, mch), x in zip([("3", 2), ("1", 0), ("2", 1), ("4", 3)], [647, 709, 772, 835]):
    p = f"ch{name}_"
    put("knob", x, 292, 26, 26, id=p + "trim", lab="LEVEL", ch=mch, cc=3, d=64)
    put("vu", x - 25, 368, 7, 74, id=p + "vu", ch=mch, cc=10)
    put("knob", x, 342, 26, 26, id=p + "hi", lab="HIGH", ch=mch, cc=4, d=64)
    put("knob", x, 392, 26, 26, id=p + "mid", lab="MID", ch=mch, cc=6, d=64)
    put("knob", x, 443, 26, 26, id=p + "lo", lab="LOW", ch=mch, cc=8, d=64)
    put("knob", x, 492, 32, 32, id=p + "sweep", lab="SWEEP FX", ch=mch, cc=11, d=64, ring=1)
    put("btn", x, 537, 32, 14, id=p + "cue", lab="CUE", ch=mch, n=13)
    lab(name, x, 559, 20, big=1)
    put("fader", x, 620, 20, 92, id=p + "fader", lab="", ch=mch, cc=14, d=0)
    put("sw", x, 703, 34, 14, id=p + "thru", lab="THRU", ch=mch, n=15, vals=[0, 1, 2], d=1, labs=["A", "THRU", "B"])

# crossfader
put("xfader", 742, 740, 104, 22, id="xfader", lab="", ch=G, cc=14, d=64)

# master / BPM FX column
put("knob", 905, 292, 28, 28, id="master", lab="MAIN VOL", ch=G, cc=20, d=90)
put("vu", 896, 372, 6, 76, id="vuL", ch=G, cc=32)
put("vu", 914, 372, 6, 76, id="vuR", ch=G, cc=33)
lab("BPM FX", 905, 427, 50)
put("enc", 905, 453, 28, 28, id="fxselect", lab="SELECT", ch=G, cc=35, push=30)
# Engine reads the FX channel switch as note 40 with the position in the velocity (DJFxAssignSwitch).
put("sel", 905, 508, 30, 30, id="fxassign", lab="CHANNEL ASSIGN", ch=G, n=40, vals=[0, 1, 2, 3, 127], labs=["3", "1", "2", "4", "M"], d=1)
put("enc", 905, 563, 28, 28, id="fxtime", lab="TIME/PARAMETER", ch=G, cc=36, push=25)
put("knob", 905, 617, 26, 26, id="fxamount", lab="AMOUNT", ch=G, cc=4, d=0)
put("btn", 905, 680, 44, 44, id="fxon", lab="FX ON/OFF", ch=G, n=26, round=1, col="#2a8cff", small=1)

# The name and the output names come from the model.
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "..", "JP21", "model.json")) as f:
    model = json.load(f)
out = {"name": model["name"], "w": 1900, "h": 1120, "outs": model["audio"]["outputs"], "controls": C}
path = os.path.join(here, "..", "JP21", "panel.json")
with open(path, "w") as f:
    json.dump(out, f, indent=0)
print(f"{len(C)} controls -> {os.path.normpath(path)}")
