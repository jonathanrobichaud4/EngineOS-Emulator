# Deck models

Each model is a folder in `models/` named by inMusic's product code, holding `model.json` and
`panel.json`. `models/models.py` reads them, and every other part gets the model list from it:

| Who | How |
| --- | --- |
| engine/emu.sh | `eval "$(python3 models/models.py shell)"`: `MODEL_CODES` and `model_<CODE>_<field>` |
| the shim | `engine/shim/models.h` (`models.py header`, made by `make -C engine/shim`) |
| the viewer | `models/<CODE>/panel.json` |
| the apps | `models.py swift` / `models.py csharp`, run by their build scripts |
| `emu.sh models --json`, `info --json` | `models.py json` |

## model.json

```jsonc
{
  "code": "JC11S",                 // product code: the folder's name, written to the devicetree
  "name": "Prime 4+",              // what people see
  "hostname": "PRIME4PLUS",        // the deck's default name on the network (emu.sh network name)
  "order": 2,                      // place in lists; the first model is the default for new decks
  "firmware": {
    "container": "AZ0x",           // the update image's format: AZ0x (SC LIVE 4 and newer), AZ01 (Prime 4)
    "name": "SC LIVE 4",           // whose firmware it's set up with
    "default": false               // setting a deck up from this format makes it this model
  },                               //   (one default per container)
  "enginex": true,                 // EngineX can be installed (it's built from SC LIVE 4 firmware)
  "efuse": true,                   // write RK3288 eFuses with the product code (Prime decks check them)
  "audio": {
    "card": "PRIME 4 Audio",       // the sound card name Engine looks for
    "pcm": "PRIME 4 Audio PCM",
    "out_channels": 0,             // 0: whatever Engine asks for
    "in_channels": 0,
    "outputs": ["Main", "Booth", "Phones", "Zone"]   // names of the output pairs, for the page
  },
  "midi": {
    "family": 8,                   // the identity reply's family byte
    "devices": [                   // the internal MIDI devices, in sound card order (4 at most)
      {"name": "PRIME 4+ Controller", "board": "Controller", "client": 20, "tail": 0, "usb_pid": "9001"}
    ]
  }
}
```

A device's `tail` is the identity reply's last byte (the Prime 4 tells its boards apart with
it). A device with `usb_pid` is a USB board: emu.sh gives it a USB device in the fake `/sys`
(Engine binds the Prime 4 displays by product ID) and the shim names its card `USB15e4:<pid>`.

## panel.json

The browser panel: `name`, `w`, `h`, `outs` (from the model) and `controls`. It's made by a
generator in `models/gen` rather than edited by hand, since the MIDI numbers come from Engine's
own assignment files. Control types and their fields are described at the top of
`models/gen/make_panel_jp21.py`. A control's `dev` is which of the model's MIDI devices it's on.

## Adding a model

1. Make `models/<CODE>/model.json`. The MIDI devices and sound card names come from Engine's
   files for that deck (`/usr/Engine/AssignmentFiles/PresetAssignmentFiles/<CODE>/` and
   `KnownDevices`).
2. Write its panel generator in `models/gen` and run it.
3. `make -C engine/shim`, so the shim knows the model.
4. If its displays are new, decode them in `viewer/displays.py` and draw them in
   `viewer/web/displays.js` (see [display-protocol.md](display-protocol.md)).
5. `sudo tests/run.sh`, then set a deck up with the model's firmware and check it boots.

The apps pick the new model up when they're next built.
