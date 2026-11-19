# The command line the apps use

The Mac and Windows apps don't know how the emulator works inside; they run `emu.sh` commands
(the Mac app through `apps/mac/engineos-emu`, which runs them in the VM) and read the output.
These are the commands whose output they read. Changing one of these formats needs the apps
changed in the same release.

## emu.sh info --json

The selected deck (`--profile NAME`), every deck, the drives and the models, in one answer:

```json
{
  "version": "1.2.0",
  "profile": "default", "product": "JP21", "product_name": "SC LIVE 4",
  "setup": true, "enginex": "5.3.0.4", "engine_error": "",
  "running": true, "engine": "up", "ip": "10.77.0.2",
  "deck_url": "http://localhost:8090/", "console_url": "http://localhost:8080/",
  "decks": [{"name": "default", "setup": true, "enginex": "5.3.0.4", "model": "JP21", "running": true}],
  "drives": [{"label": "MUSIC", "kind": "usb", "folder": "/home/me/Music", "ok": true}],
  "models": [{"code": "JP21", "name": "SC LIVE 4", "firmware": "SC LIVE 4", "enginex": true}],
  "network": {"mode": "lan", "name": "SCLIVE4", "addresses": ["192.168.1.20"]}
}
```

`engine_error` is set when Engine stopped for good: the firmware doesn't run as the deck's model,
or OpenGL isn't working on this machine.
`engine` is `up` while the Engine process exists, which is a while before its first screen.

`network.mode` is `lan` (the deck is on this computer's networks too), `local` (internet only) or
`off` (no networking); `addresses` are this computer's addresses there ([networking.md](networking.md)).

`emu.sh profiles --json`, `emu.sh drive list --json` and `emu.sh models --json` print the
`decks`, `drives` and `models` lists on their own.

Without `--json`, `info`, `profiles` and `drive list` print the text formats from before 1.2
(key=value lines; tab-separated deck lines; aligned drive lines), which older apps read.

## engineos-emu state (Mac)

`lima=yes|missing`, `brew=yes|no` (only when Lima is missing), `vm=Running|Stopped|none`, and,
when the VM is running, `json=` followed by `emu.sh info --json` on one line. It never starts
the VM. An emulator from before 1.2 in the VM answers with the older key=value, `deck=` and
`drive=` lines instead, which the app still reads.

## emu.sh identify FILE

`firmware`, `enginex`, `mod` or `unknown`: what a dropped file is.

## Exit codes

Every command exits non-zero on failure, with the reason on stderr after `emu: `.
