#!/usr/bin/env python3
"""Generates files/panel.json: the SC LIVE 4 control surface for the emulator's browser panel.

Every MIDI number here comes from Engine's own JP21 assignment file
(/usr/Engine/AssignmentFiles/PresetAssignmentFiles/JP21/JP21_Controller_Assignments.qml) and
the ControlSurfaceModules it uses. Positions follow the SC LIVE 4 top panel (with the screen
drawn larger than life so it stays usable on a monitor). Coordinates are in a 1900 x 1080 space.

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


# ---------------------------------------------------------------- screen module, browse
SX, SY, SW = 600, 22, 700            # screen 700 x 437.5
add(t="screen", x=SX, y=SY, w=SW, h=SW / 1.6)
add(t="btn", id="lighting", lab="LIGHTING", x=548, y=40, w=40, h=40, ch=G, n=39, round=1)
add(t="btn", id="view", lab="VIEW", x=546, y=110, w=46, h=28, ch=G, n=14)
add(t="btn", id="menu", lab="MENU", x=546, y=160, w=46, h=28, ch=G, n=13)
add(t="btn", id="back", lab="BACK", x=1308, y=60, w=46, h=28, ch=G, n=3)
add(t="enc", id="browse", lab="BROWSE", x=1306, y=150, w=50, h=50, ch=G, cc=5, push=6)
add(t="btn", id="forward", lab="FWD", x=1308, y=262, w=46, h=28, ch=G, n=4)
add(t="btn", id="load_l", lab="LOAD 1", x=546, y=330, w=46, h=28, ch=G, n=1)
add(t="btn", id="load_r", lab="LOAD 2", x=1308, y=330, w=46, h=28, ch=G, n=2)


# ---------------------------------------------------------------- decks
def deck(side, ox, ch):
    p = f"d{side}_"
    # left column
    add(t="enc", id=p + "autoloop", lab="AUTO LOOP", x=ox + 18, y=40, w=60, h=60, ch=ch, cc=32, push=39)
    add(t="btn", id=p + "loopin", lab="IN", x=ox + 14, y=130, w=34, h=26, ch=ch, n=37)
    add(t="btn", id=p + "loopout", lab="OUT", x=ox + 52, y=130, w=34, h=26, ch=ch, n=38)
    add(t="btn", id=p + "censor", lab="CENSOR", x=ox + 14, y=182, w=72, h=28, ch=ch, n=1)
    add(t="btn", id=p + "deck", lab="DECK", x=ox + 28, y=236, w=44, h=44, ch=ch, n=31, round=1)
    add(t="label", lab="TRACK SKIP", x=ox + 10, y=300, w=80, h=14)
    add(t="btn", id=p + "prev", lab="⏮", x=ox + 14, y=316, w=34, h=26, ch=ch, n=4)
    add(t="btn", id=p + "next", lab="⏭", x=ox + 52, y=316, w=34, h=26, ch=ch, n=5)
    add(t="label", lab="BEAT JUMP", x=ox + 10, y=360, w=80, h=14)
    add(t="btn", id=p + "bjprev", lab="◀", x=ox + 14, y=376, w=34, h=26, ch=ch, n=6)
    add(t="btn", id=p + "bjnext", lab="▶", x=ox + 52, y=376, w=34, h=26, ch=ch, n=7)
    add(t="btn", id=p + "cue", lab="CUE", x=ox + 12, y=640, w=78, h=78, ch=ch, n=9, big=1)
    add(t="btn", id=p + "play", lab="▶❙❙", x=ox + 12, y=740, w=78, h=78, ch=ch, n=10, big=1, col="#2bd46a")
    # jog wheel
    add(t="jog", id=p + "jog", lab=f"DECK {side}", x=ox + 112, y=150, w=350, h=350, ch=ch, cc=0x11, cc2=0x31, touch=33)
    # right of the jog
    add(t="btn", id=p + "sync", lab="SYNC", x=ox + 440, y=40, w=66, h=30, ch=ch, n=8, col="#3aa0ff")
    add(t="btn", id=p + "vinyl", lab="VINYL", x=ox + 420, y=90, w=48, h=26, ch=ch, n=35)
    add(t="btn", id=p + "slip", lab="SLIP", x=ox + 472, y=90, w=48, h=26, ch=ch, n=36, col="#3aa0ff")
    add(t="pitch", id=p + "pitch", lab="TEMPO", x=ox + 478, y=200, w=40, h=360, ch=ch, cc=0x1F, cc2=0x4B, led=42)
    add(t="btn", id=p + "keylock", lab="KEY", x=ox + 428, y=470, w=38, h=24, ch=ch, n=34)
    add(t="btn", id=p + "bendm", lab="−", x=ox + 458, y=580, w=30, h=26, ch=ch, n=29)
    add(t="btn", id=p + "bendp", lab="+", x=ox + 492, y=580, w=30, h=26, ch=ch, n=30)
    add(t="label", lab="PITCH BEND", x=ox + 450, y=608, w=80, h=14)
    # pad section
    add(t="btn", id=p + "shift", lab="SHIFT", x=ox + 112, y=640, w=46, h=24, ch=ch, n=28)
    for i, lab in enumerate(["HOT CUE", "LOOP", "ROLL", "SLICER"]):
        add(t="btn", id=f"{p}mode{i + 1}", lab=lab, x=ox + 166 + i * 62, y=640, w=56, h=24, ch=ch, n=11 + i, small=1)
    add(t="btn", id=p + "parml", lab="◀", x=ox + 418, y=640, w=34, h=24, ch=ch, n=23)
    add(t="btn", id=p + "parmr", lab="▶", x=ox + 456, y=640, w=34, h=24, ch=ch, n=24)
    for r in range(2):
        for c in range(4):
            i = r * 4 + c
            add(t="pad", id=f"{p}pad{i + 1}", lab=str(i + 1), x=ox + 112 + c * 96, y=678 + r * 92, w=88, h=84, ch=ch, n=15 + i)


deck(1, 10, 4)
deck(2, 1360, 5)

# ---------------------------------------------------------------- mixer
MY = 482
add(t="panel", x=538, y=MY, w=824, h=590)
# left aux section
add(t="label", lab="SPEAKER/BOOTH", x=548, y=MY + 10, w=130, h=14)
add(t="knob", id="booth", lab="LEVEL", x=558, y=MY + 30, w=40, h=40, ch=G, cc=15, d=0)
add(t="sw", id="speaker", lab="ON", x=616, y=MY + 32, w=46, h=36, ch=G, n=41, vals=[0, 127], d=0, labs=["OFF", "ON"])
add(t="knob", id="mic1", lab="MIC 1", x=558, y=MY + 94, w=40, h=40, ch=G, cc=16, d=0)
add(t="btn", id="mic1on", lab="MIC 1", x=612, y=MY + 100, w=54, h=26, ch=G, n=36)
add(t="knob", id="mic2", lab="MIC 2/AUX", x=558, y=MY + 162, w=40, h=40, ch=G, cc=17, d=0)
add(t="btn", id="mic2on", lab="MIC 2", x=612, y=MY + 168, w=54, h=26, ch=G, n=37)
add(t="sw", id="micaux", lab="MIC/AUX", x=612, y=MY + 202, w=54, h=22, ch=G, n=42, vals=[0, 127], d=0, labs=["MIC", "AUX"])
add(t="label", lab="SWEEP FX", x=548, y=MY + 238, w=130, h=14)
for i, lab in enumerate(["FILTER", "DUB ECHO", "NOISE", "WASH"]):
    add(t="btn", id=f"sweep{i + 1}", lab=lab, x=556 + (i % 2) * 60, y=MY + 256 + (i // 2) * 40, w=54, h=32, ch=G, n=21 + i, small=1)
add(t="label", lab="PHONES", x=548, y=MY + 350, w=130, h=14)
add(t="knob", id="cuemix", lab="CUE MIX", x=580, y=MY + 368, w=44, h=44, ch=G, cc=18, d=64)
add(t="knob", id="cuegain", lab="LEVEL", x=580, y=MY + 436, w=44, h=44, ch=G, cc=19, d=64)
add(t="sw", id="splitcue", lab="SPLIT CUE", x=572, y=MY + 506, w=60, h=22, ch=G, n=11, vals=[0, 127], d=0, labs=["OFF", "ON"])

# channel strips, in panel order 3 1 2 4
for col, (name, mch) in enumerate([("3", 2), ("1", 0), ("2", 1), ("4", 3)]):
    x = 690 + col * 122
    p = f"ch{name}_"
    add(t="knob", id=p + "trim", lab="LEVEL", x=x + 43, y=MY + 10, w=36, h=36, ch=mch, cc=3, d=64)
    add(t="vu", id=p + "vu", x=x + 12, y=MY + 70, w=12, h=150, ch=mch, cc=10)
    add(t="knob", id=p + "hi", lab="HIGH", x=x + 43, y=MY + 72, w=36, h=36, ch=mch, cc=4, d=64)
    add(t="knob", id=p + "mid", lab="MID", x=x + 43, y=MY + 132, w=36, h=36, ch=mch, cc=6, d=64)
    add(t="knob", id=p + "lo", lab="LOW", x=x + 43, y=MY + 192, w=36, h=36, ch=mch, cc=8, d=64)
    add(t="knob", id=p + "sweep", lab="SWEEP FX", x=x + 38, y=MY + 252, w=46, h=46, ch=mch, cc=11, d=64, ring=1)
    add(t="btn", id=p + "cue", lab="CUE", x=x + 30, y=MY + 318, w=62, h=26, ch=mch, n=13)
    add(t="label", lab=name, x=x + 30, y=MY + 350, w=62, h=18, big=1)
    add(t="fader", id=p + "fader", lab="", x=x + 46, y=MY + 372, w=30, h=120, ch=mch, cc=14, d=0)
    add(t="sw", id=p + "thru", lab="THRU", x=x + 31, y=MY + 506, w=60, h=22, ch=mch, n=15, vals=[0, 1, 2], d=1, labs=["A", "THRU", "B"])

# master / FX section
add(t="knob", id="master", lab="MASTER", x=1188 + 52, y=MY + 12, w=46, h=46, ch=G, cc=20, d=90)
add(t="vu", id="vuL", x=1198, y=MY + 70, w=10, h=150, ch=G, cc=32)
add(t="vu", id="vuR", x=1212, y=MY + 70, w=10, h=150, ch=G, cc=33)
add(t="enc", id="fxselect", lab="FX SELECT", x=1250, y=MY + 76, w=48, h=48, ch=G, cc=35, push=30)
# Engine reads the FX channel switch as note 40 with the position in the velocity (DJFxAssignSwitch).
add(t="sel", id="fxassign", lab="FX CHANNEL", x=1246, y=MY + 160, w=56, h=56, ch=G, n=40, vals=[0, 1, 2, 3, 127], labs=["3", "1", "2", "4", "M"], d=1)
add(t="enc", id="fxtime", lab="FX PARAM/TIME", x=1250, y=MY + 250, w=48, h=48, ch=G, cc=36, push=25)
add(t="knob", id="fxamount", lab="FX AMOUNT", x=1250, y=MY + 330, w=48, h=48, ch=G, cc=4, d=0)
add(t="btn", id="fxon", lab="FX ON", x=1240, y=MY + 410, w=68, h=68, ch=G, n=26, round=1, col="#2a8cff", big=1)

# crossfader
add(t="xfader", id="xfader", lab="", x=780, y=MY + 540, w=280, h=34, ch=G, cc=14, d=64)

out = {"w": 1900, "h": 1080, "controls": C}
path = os.path.join(os.path.dirname(__file__), "..", "files", "panel.json")
with open(path, "w") as f:
    json.dump(out, f, indent=0)
print(f"{len(C)} controls -> {os.path.normpath(path)}")
