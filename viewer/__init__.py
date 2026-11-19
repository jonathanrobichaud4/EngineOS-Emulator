"""EngineOS Emulator viewer: the emulated deck in a browser.

Serves http://localhost:PORT/ with the deck's top panel: the touchscreen in the middle (frames
from the shim in Engine) and every control around it, wired to Engine as the deck's internal
MIDI devices would be. Also streams Engine's audio output, manages the emulated USB drives / SD
card, and can reboot the emulated deck. Standard library only (numpy for the waveforms).

Run by engine/emu.sh as `python3 -m viewer` from the checkout. The modules:

  server     the HTTP server and the command line
  frames     the touchscreen's frames, and the FIFOs into Engine
  surface    the control surface: panel events to MIDI, Engine's MIDI to LED state
  displays   decoders for the decks' own displays (Prime 4 jog wheel screens and FX OLEDs)
  audio      Engine's audio output
  waves      software waveforms for Engine's waveform views
  drives     drives.txt
  forward    a TCP forwarder into the deck's network namespace
  web/       the page itself (index.html, panel.css and the scripts)

Files shared with the shim inside the chroot (<rootfs>/tmp/emu):
  fb            frames (32-byte header + 32-bit pixels)
  input         FIFO, touch commands for the screen
  midi-in       FIFO, raw MIDI from the panel to Engine (hex bytes, one message per line)
  midi-out      MIDI Engine sends to the controller (LEDs, meters, SysEx), appended hex lines
  audio         ring of the selected output pair (64-byte header + 16-bit stereo)
  audio-pcms    audio devices Engine opened; audio-select picks the pair to hear
"""
