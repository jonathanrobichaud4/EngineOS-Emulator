# The decks' displays over MIDI

Engine drives the decks' small displays with MIDI to the deck's internal devices. The shim
appends everything Engine sends to `/tmp/emu/midi-out` as hex lines, with `@N ` in front for
device N > 0; `viewer/surface.py` follows that file and `viewer/displays.py` decodes the
displays. Binary data in SysEx is one bit stream of 7-bit bytes (`displays.bits7`).

## SC LIVE 4 jog wheel LCDs (device 0)

Segment LCDs driven on the deck's channel (`ControlSurfaceModules/LcdWheelDisplay.qml`):

- CC 0x30: the position ring, 1-48 lights that segment, +64 lights all but it, 0 off
- CC 0x31-0x34: ring quadrants; 0x35 / 0x36 top / bottom box; 0x37 "DECK"; 0x39 "BPM";
  0x3a time label; 0x3c dividing line; 0x3e BPM digits; 0x3f time digits
- note 0x38: the deck number as velocity
- `F0 00 02 0B <ch> 00|01 h m s cs F7`: the time (01: counting down)
- `F0 00 02 0B <ch> 02 <6 hex nibbles> F7`: the BPM x 100

## Prime 4 jog wheel screens (devices 2 and 3)

`JC11S_Display_Device.qml`: pitch bend on channel 1 / 2 is the platter / slip position as a
fraction of a turn. `F0 00 02 0B <id> 08 <cmd> ... F7` sets the rest:

| cmd | data | meaning |
| --- | --- | --- |
| 0B | `00 09 <element> <A R G B as nibble pairs>` | an element's colour: 0 artwork alpha, 1 logo, 2 ring, 3 position, 4 slip overlay, 5 slip position, 8 loop text, 10 jump, 11 loop icon |
| 0A | `00 04 <s0> <s1> <artwork slot> <loop size>` | what's shown: s0 bit 0 artwork, 1 logo, 2 position, 4 slip; s1 bit 1 loop text, 3 jump, 4 loop icon |
| 7C | `00 01 <brightness>` | |
| 0C | `00 03 <size, 3 x 7 bits>` | an artwork upload starts |
| 0D | `<len, 2 x 7> <offset, 3 x 7> <data>` | a chunk of it (3500 bytes) |
| 0E | `00 09 <slot> ...` | it's done: a 198 x 198 PNG for that slot |

The page turns the artwork with the platter (it's drawn upside down, so it's rotated 180°).

## Prime 4 FX OLEDs (device 0)

Eight 128 x 32 OLEDs on the Controller (`JC11S_Controller_Device.qml`), 0-3 over FX 1's knobs
and 4-7 over FX 2's:

`F0 00 02 0B 7F 08 0B <len, 2 x 7> <oled> <first page> <end page> <first column> <last column> <pixels> F7`

Pages are rows 8 pixels tall; each byte is one column of a page, low bit on top. Engine usually
sends a whole screen (pages 0-4, columns 0-127). The page area-averages it down to the size it's
drawn at, so thin lines stay visible as grey.
