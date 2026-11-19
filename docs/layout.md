# How the project is laid out

The emulator has three parts that talk to each other through files and one command line:

- **engine/** runs on Linux (WSL, the Mac's Lima VM, or any Linux). `engine/emu.sh` sets a deck up
  from firmware, starts Engine under qemu in a chroot, and manages decks and drives.
- **viewer/** is the deck page in the browser. emu.sh starts it with each deck; it talks to Engine
  through the shim's files in the deck's `/tmp/emu`.
- **apps/** are the Mac and Windows windows around `emu.sh`. They only run its commands and read
  what it prints ([cli.md](cli.md)).

What the emulator knows about each deck model is in **models/**, and everything else reads it
from there.

```
VERSION                  the release number (changing it on main makes a release)
emu.sh                   forwards to engine/emu.sh, so ./emu.sh keeps working
engine/
  emu.sh                 the command line: reads --profile, loads lib/, runs the command
  lib/common.sh          paths, the selected deck, its model, helpers
  lib/host.sh            packages, qemu-arm, binfmt, whether OpenGL can be used
  lib/rootfs.sh          what the emulator adds to the firmware's files, and mounting them
  lib/net.sh             the deck's network namespace, DHCP and NAT
  lib/firmware.sh        setup from a firmware file, installing EngineX, identify
  lib/run.sh             start, stop, the Engine loop, reset-data
  lib/drives.sh          drive add / remove / rename / type / list
  lib/profiles.sh        decks: profile new / rename / delete / model, product
  lib/info.sh            info, models, version: what the apps read
  lib/mods.sh            mod-install, dump-qml
  state.py               the JSON behind info --json, profiles --json, drive list --json
  edisks_emu.py          the deck's drive service (Engine asks it to mount drives)
  shim/                  libemushim.so, preloaded into Engine (screen, input, audio, MIDI)
  firmware/              reading inMusic update images (from QEngine)
  tools/                 helpers emu.sh runs (unpacking QML dumps)
viewer/
  server.py              the HTTP server and its options (python3 -m viewer --help)
  frames.py              the touchscreen's frames; the FIFOs into Engine
  surface.py             controls to MIDI, Engine's MIDI to LEDs
  displays.py            the Prime 4's platter screens and FX OLEDs
  audio.py drives.py forward.py
  web/                   index.html, panel.css, panel.js (controls), displays.js, audio.js,
                         drives.js, main.js (starts it)
models/
  models.py              reads the models; makes the shell, JSON, C and app versions of them
  JP21/ JC11S/ JC11/     model.json and panel.json for each model
  gen/                   the panel generators
assets/                  copied into the deck: fake /sys, the virgl Mesa driver, systemctl
apps/mac/                engineos-emu (the launcher), lima.yaml, app/ (the SwiftUI app)
apps/windows/            src/ (the WinForms app), installer.nsi, build.sh
mac/                     forwarders for the old mac/ paths
tests/                   run.sh and the Python tests
tools/                   things only a developer runs (rebuilding the Mesa driver)
docs/                    these notes
```

## Where the decks live

Decks are `rootfs[-NAME]/` and `state[-NAME]/` at the top of the checkout, next to `drives.txt`,
as they always have been. git ignores them, so updating the code (the apps move
the checkout to the matching release) never touches them. `EMU_DATA=/some/folder` puts them
somewhere else; the tests use that.

## Adding things

- **A command:** a `cmd_*` function in the `lib/` file for its subject, and a line in the `case`
  at the end of `engine/emu.sh` (and its usage at the top). If the apps need its output, give
  it a `--json` form and describe it in [cli.md](cli.md).
- **A model:** see [models.md](models.md).
- **A display or control type on the page:** decode it in `viewer/displays.py` (or
  `surface.py`), add it to the state in `Surface.state`, draw it in `viewer/web/displays.js` and
  add a builder in `panel.js`. Put a test with a recorded message in `tests/test_displays.py`.

## Old paths

`./emu.sh`, `mac/engineos-emu` and `mac/Start EngineOS Emulator.command` forward to the new
places, so clones, Finder shortcuts and apps from before the move keep working. The root
`emu.sh` keeps a `cmd_info()` line because Windows apps before 1.2 look for it to tell a current
emulator from an old one.
