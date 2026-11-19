# EngineOS Emulator (Engine OS + EngineX)

Runs Denon DJ's Engine OS on your computer. It started as an SC LIVE 4 emulator, and the SC LIVE 4 is still the deck it supports today.

Runs the real Engine binary from the stock SC LIVE 4 firmware on your PC, with EngineX loaded the same way it is on the deck. Your browser shows the whole deck: the touchscreen in the middle, every button, knob, fader, jog wheel and pad around it, the LEDs Engine lights, and the audio coming out of it. Folders on your PC plug in as USB drives or an SD card, and the EngineX web console runs too, so you can install and test mods like on the real thing.

## What's emulated

| Part | How |
|---|---|
| Touchscreen | Engine's real UI at 1280x800. Click or drag on it. |
| Controls | The deck's internal MIDI control surface. Engine identifies it as a JP21 controller and loads its real mapping, so every control does what it does on the hardware. |
| LEDs and meters | Engine's LED and VU meter messages light up the panel: button LEDs, RGB pads, channel and master meters, the pitch centre LED. |
| Audio out | The deck's 8-channel output (Main, Booth, Phones). Click **Listen** to hear it; pick the output next to it. |
| USB drives and SD card | Any folder on your PC. Engine sees it plugged in, mounts it, writes its Engine Library to it and plays from it. |
| Network | Wired, like a USB Ethernet adapter on the deck. The deck gets internet access, so streaming logins, update checks and online features should work. |
| Reboot | The **Reboot** button restarts the whole emulated deck. |
| Graphics | Engine renders with real OpenGL, sent through virgl to your PC, so its own waveforms, beat grids, coloured icons and effects all draw. See "Graphics" below. |

Not emulated yet:

- Mic and aux inputs (silent), the USB audio gadget, Bluetooth and Wi-Fi. On the Prime 4 and 4+, the mic, booth and zone sections.
- Other devices on your LAN can't see the emulated deck (it's behind NAT), so no Pro DJ Link, StageLinQ or phone QR logins that need the same network.
- Speed. Engine is ARM code running on an x86 CPU through qemu, so it boots in 1 to 2 minutes and the UI is slower than the real deck. Audio plays in real time.

## Downloads

Every [release](https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest) has both apps:

- **Mac:** [EngineOSEmulator-mac.dmg](https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/EngineOSEmulator-mac.dmg). Open it and drag the app into Applications.
- **Windows:** [EngineOSEmulator-Setup.exe](https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/EngineOSEmulator-Setup.exe) installs it for your user (no admin needed) with a Start menu entry and an uninstaller, or [EngineOSEmulator.exe](https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/EngineOSEmulator.exe) runs without installing.

The apps update themselves to newer releases (an option in their settings) and keep the emulator they run on the same release. Releasing: change `VERSION` (like `1.0.1`) on main, and the Release workflow builds both apps and the installers and publishes them as `v1.0.1`. Every other change only makes test builds, kept as workflow artifacts.

## Windows app (no command line)

`EngineOSEmulator.exe` is a small Windows program for all of this ([download](#downloads)); it needs nothing installed beyond Windows 10 or 11.

- It installs WSL and the emulator for you if they're missing (the emulator goes into `/opt/engineos-emulator` in Ubuntu), and finds an older copy and moves your deck over.
- **Drop files on it:** a firmware `.img` sets up the selected deck, an EngineX bundle installs EngineX, a mod `.tar.gz` installs and enables the mod, a folder plugs in as a USB drive (hold Shift for the SD card), and music files are copied to `Music\EngineOS Emulator`, which is plugged in as the EMULATOR drive.
- Start, Stop, Reboot, Open deck and EngineX console buttons, a deck picker and a **Decks...** window to add, rename and delete decks and choose each one's model (for example a stock Engine OS deck next to the EngineX one), the drives list, and **More...** for the Engine log, resetting a deck and updating the emulator.

Windows may warn the first time ("Windows protected your PC") because the program isn't signed: click More info, then Run anyway. To build it yourself: `apps/windows/build.sh` (Mono's C# compiler), then `makensis apps/windows/installer.nsi` for the installer.

Installed copies from before the rename to EngineOS Emulator update into the new app and keep their decks, settings and drives: the old folders (`Music\SC LIVE 4 Emulator`, `~/SCLive4Emulator`, `/opt/sclive4-emulator`) move to the new names the next time the deck is stopped, and drives are pointed at the new place.

## macOS (Apple Silicon or Intel)

The emulator needs Linux (qemu-user, chroot and network namespaces), so on a Mac it runs in a small Ubuntu VM made with [Lima](https://lima-vm.io), the way it runs in WSL on Windows.

**The app:** [download EngineOS Emulator for Mac](https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/EngineOSEmulator-mac.dmg) (macOS 13 or later, Apple Silicon and Intel), open the disk image and drag the app into Applications. It isn't notarized, so the first time right-click it and choose Open (on macOS 15, open it once, then System Settings > Privacy & Security > Open Anyway). Click **Install** (it installs Lima with Homebrew and creates the VM), then drop the SC LIVE 4 firmware on the window. After that it has Start, Stop, Reboot, Open deck and EngineX console buttons, takes dropped EngineX bundles, mods and music folders, shows what it's doing, and has the Windows app's options under Settings (Cmd+,). `apps/mac/app/build.sh` builds it yourself.

**From Terminal**, `apps/mac/engineos-emu` does the same (`mac/engineos-emu` still works too):

```sh
git clone https://github.com/jonathanrobichaud4/EngineOS-Emulator engineos-emulator
cd engineos-emulator/apps/mac
./engineos-emu install                                  # installs Lima (Homebrew) and creates the VM
./engineos-emu setup ~/Downloads/<SC LIVE 4 firmware>   # .img, Windows .exe or Mac .zip updater
./engineos-emu start                                    # opens http://localhost:8090
```

- After that, double-click **Start EngineOS Emulator.command** in Finder to start it (the first time, right-click > Open).
- `stop`, `restart`, `status`, `log`, `open`, `console` (the EngineX console at http://localhost:8080), `update`, `vm-stop` (stops the VM to free its memory) and `uninstall`. Anything else goes to `emu.sh` in the VM, so `./engineos-emu graphics software`, `./engineos-emu mod-install ~/Downloads/mod.tar.gz` and so on work as on Linux.
- Your home folder is visible in the VM read-only, so firmware and mod files can be anywhere in it. **Drives:** Engine writes its library onto a drive, so put folders you plug in as drives in `~/EngineOSEmulator` (writable from the VM): `./engineos-emu drive add ~/EngineOSEmulator/Music`.
- It needs [Homebrew](https://brew.sh) for installing Lima, macOS 13 or later, and about 6 GB of memory and 40 GB of disk for the VM (`apps/mac/lima.yaml` sets these).
- On Apple Silicon the VM is ARM64 Linux. Apple's chips can't run Engine's 32-bit ARM code directly, so it still goes through qemu-arm, as on a PC.

Not yet tried on a real Mac: the Linux side is the same as on WSL, but the Lima VM and the launcher have only been checked with dry runs.

## What you need

- Windows 10/11 with WSL2 and Ubuntu (22.04 or 24.04). If you don't have it, open PowerShell as admin and run `wsl --install -d Ubuntu`, then reboot.
- The stock SC LIVE 4 firmware: the Engine OS 5.3.0 `.img` update file from Denon DJ, or the Windows updater `.exe` or Mac updater `.zip`, which carry the same image.
- An EngineX data bundle `.tar.gz` (for example `SCLIVE4-5.3.0.4-EngineX-OS-Data-Bundle.tar.gz`). Optional; you can run stock Engine without it.

## Setup (once)

In the Ubuntu terminal:

```sh
git clone https://github.com/jonathanrobichaud4/EngineOS-Emulator ~/engineos-emulator
cd ~/engineos-emulator
sudo ./emu.sh setup /mnt/c/Users/<you>/Downloads/<firmware>.img \
                    /mnt/c/Users/<you>/Downloads/SCLIVE4-5.3.0.4-EngineX-OS-Data-Bundle.tar.gz
```

Keep the folder in your Linux home, not under `/mnt/c`. Setup installs what it needs from Ubuntu's packages, pulls the root file system out of the firmware and installs EngineX into it. It takes about a minute and uses about 1.2 GB.

Updating: `sudo ./emu.sh stop`, then `git pull`, then `sudo ./emu.sh start`. Your rootfs, settings and drives are kept, since git ignores them.

## Graphics

Engine draws its UI with OpenGL ES. The emulator gives it a Mesa virgl driver (`assets/gl/`, built for the firmware's Mesa 24.0.7), so Engine's GL calls go over a socket to `virgl_test_server` on your PC, which draws them natively with Mesa (on the CPU with llvmpipe, or your GPU where WSL exposes one). The idea comes from [QEngine](https://github.com/Peyton-C/QEngine), which does the same through a QEMU VM's virtual GPU; here it runs over virgl's vtest socket, so the deck keeps running under qemu-user with its audio and controls.

If the screen looks wrong on your PC, switch to software rendering: tick "Software rendering" in the Windows app's More... menu, or run `./emu.sh graphics software` (`auto` to go back), then restart the deck. Software rendering draws everything except shader effects; the emulator then draws its own waveforms from the audio (no beat grid or markers) and plain versions of a few faded and coloured elements.

## Running it

```sh
sudo ./emu.sh start
```

Then open http://localhost:8090/ in your Windows browser. The first boot shows the same first-run pages as a new deck (Wi-Fi, Profiles); tick "Do not show again" and press Next.

### Using the panel

- **Buttons and pads:** click (hold for as long as you'd hold the real one).
- **Knobs and faders:** drag, or use the scroll wheel. Double-click puts a knob or fader back to its default (EQs to the middle, pitch to 0).
- **Encoders** (Browse, Auto Loop, FX Select, FX Param): drag or scroll to turn, click the centre to push.
- **Jog wheels:** drag around the wheel. Grabbing the inner top touches the platter (scratch, like a real jog top); grabbing the outer ring nudges. The scroll wheel nudges too.
- **Switches** (Thru A/THRU/B, Split Cue, Speaker, Mic/Aux): click a position. The FX channel selector turns with a click or the scroll wheel.
- **Listen:** your browser only plays sound after you click something, so audio starts when you press Listen. The menu next to it switches between Main, Booth and Phones.

### Stock Engine OS next to EngineX

Each profile is a separate deck with its own file system, settings and library. Set one up from the firmware alone (no EngineX bundle) to get plain Engine OS:

```sh
sudo ./emu.sh --profile stock setup /mnt/c/Users/<you>/Downloads/<firmware>.img
sudo ./emu.sh --profile stock start
```

Every command takes `--profile NAME` (`stop`, `status`, `drive`, `shell` and so on). Without it you get the default deck in `rootfs/`. One deck runs at a time. `start --stock` is different: it runs the EngineX deck with EngineX's hook switched off, but EngineX's files are still installed.

Managing decks:

```sh
sudo ./emu.sh profile new stock            # an empty deck (then set it up as above)
sudo ./emu.sh profile rename stock plain   # the deck has to be stopped
sudo ./emu.sh profile delete plain         # deletes its rootfs and state; drive folders aren't touched
sudo ./emu.sh profile model plain JC11S    # which deck it is (./emu.sh models lists them)
./emu.sh profiles                          # name, set up, EngineX version, model, running
```

The Mac and Windows apps do the same from their **Decks** window (Cmd+K on a Mac).

### Models

| Model | Firmware to set it up with | Its files |
| --- | --- | --- |
| SC LIVE 4 (JP21) | SC LIVE 4 | `models/JP21/` |
| Prime 4+ (JC11S) | SC LIVE 4 (its Engine also runs as a Prime 4+) | `models/JC11S/` |
| Prime 4 (JC11) | Prime 4 | `models/JC11/` |

Engine only runs as a deck its firmware was built for; the wrong pair stops with a message saying so. On the Prime 4 and 4+ Engine mixes the four decks itself; the page's output menu has Main, Booth, Phones (the headphone cue) and Zone, and the MASTER and PHONES knobs set how loud the browser plays them, as they're the unit's own analog controls. `models/gen/make_panel_p4.py` builds both panels from Denon's user guide drawing and Engine's mapping file. Everything the emulator and the apps know about a model is in its `model.json`; [docs/models.md](docs/models.md) says what's in it and how to add a model.

### Drives

Click **Drives** on the page, or use the command line:

```sh
sudo ./emu.sh drive add /mnt/c/Users/<you>/Music --label MUSIC      # as a USB drive
sudo ./emu.sh drive add /mnt/d/DJ --sd --label DJ                     # as the SD card
sudo ./emu.sh drive list
sudo ./emu.sh drive remove MUSIC
sudo ./emu.sh drive rename DJ GIGS                                    # the name the deck shows (up to 11 characters)
sudo ./emu.sh drive type GIGS usb                                     # move it between a USB port and the SD slot
```

The Mac app has a **Drives** window for the same (the Drives button, or Shift-Cmd-D), and the Windows app's drives list unplugs them. Drives stay attached across restarts. Engine writes its `Engine Library` folder into the folder, like it would on a real drive, so use a copy or a folder you don't mind it writing to. A Windows folder (`/mnt/c/...`) works but is slower than a folder inside Ubuntu.

### Other commands

| Command | What it does |
|---|---|
| `sudo ./emu.sh stop` | Stops everything and unmounts |
| `sudo ./emu.sh reboot` | Same as the Reboot button |
| `sudo ./emu.sh restart` | Restarts only Engine (fast way to reload QML after changing a mod) |
| `sudo ./emu.sh status` | Whether it's running, the deck's address and the EngineX version |
| `sudo ./emu.sh log` | Follows Engine's log |
| `sudo ./emu.sh shell` | Root shell inside the emulated deck (like SSH on the real one) |
| `sudo ./emu.sh install <bundle>` | Installs a different EngineX bundle (`.tar.gz`, Update `.img` or folder) |
| `sudo ./emu.sh start --stock` | Runs stock Engine without the EngineX hook |
| `sudo ./emu.sh reset-data` | Clears Engine's settings and library so first-run starts again |
| `sudo EMU_NET=0 ./emu.sh start` | Runs with no network |
| `sudo ./emu.sh mod-install MOD.tar.gz` | Uploads, enables and loads a mod (deck running) |
| `./emu.sh info --json` / `profiles --json` / `models --json` / `identify FILE` | Machine-readable state, decks, models and file types (what the apps read; see [docs/cli.md](docs/cli.md)) |
| `sudo ./emu.sh dump-qml DIR [FILTER]` | Writes Engine's built-in QML (and other resources) out as files, for reading or for building mods kept as patches |

## Testing mods

Use the Mod Hub in the EngineX console (http://localhost:8080/, linked at the top of the page) the same way as on the deck: upload the mod's `.tar.gz`, enable it, and restart Engine. Restart buttons in the console work in the emulator. You can also edit files directly in `rootfs/data/enginex/mods/<id>/` and run `sudo ./emu.sh restart`.

To test a different stock firmware, run `setup` again with the other `.img`. It replaces the old root file system.

## How it works

- Firmware: QEngine's readers in `engine/firmware/` take the update image out of an updater `.exe` or `.zip` and extract the rootfs, checking its digest (`az0x_extract.py` there is the fallback); `debugfs` copies the ext4 image out to `rootfs/`. Telemetry hosts from QEngine's list are pointed at localhost, and Engine starts with `-skipFirmwareUpdate` so it doesn't try to flash the virtual controller.
- qemu-user runs the ARM binaries through binfmt_misc inside a chroot of that root file system.
- `assets/fakesys.tar.gz` is a fake `/sys` made from the SC LIVE 4 device tree (product code JP21, CPU info, a non-blank eFuse). Without it Engine decides it's on a factory board and drops into test mode. All identifiers in it are placeholders.
- `engine/shim/libemushim.so` is preloaded into Engine (source in `engine/shim/`):
  - `emushim.c` copies every frame into `/tmp/emu/fb` (in OpenGL mode it turns eglfs's window into a pbuffer on Mesa's surfaceless EGL and reads each frame back at the buffer swap), turns screen input into touch events, stubs the CPU affinity calls qemu can't do, swaps in replacement QML from `assets/qml/`, and reports crashes with the library and offset.
  - `alsa_emu.c` stands in for ALSA. The sequencer has the deck's "Control Surface" client (16:0), which answers the MIDI identity request in the JP21 controller's format (with a placeholder serial) and passes MIDI between Engine and the panel through `/tmp/emu/midi-in` and `midi-out`. The sound cards copy the deck's (on the SC LIVE 4: Control Surface, JP21 codec with 8 out and 2 in at 44.1 kHz, UAC2 gadget; each model's cards and MIDI devices come from its `model.json`); playback is paced in real time and one output pair is copied to `/tmp/emu/audio` for the browser.
- Software rendering only: `assets/qml/` replaces built-in QML that needs shaders (`ColoredImage`, which every icon goes through, and the faded scrolling text), and the waveforms come from the viewer (`viewer/waves.py`), which renders each loaded track to PNGs. The QML that shows them is in `assets/qml-inject/`: the shim inserts it into Engine's compiled-in `Waveform.qml` and `WaveformOverview.qml`, and `emu.sh` bind-mounts injected copies over EngineX's pack versions while the deck runs. Engine asks for a track by writing a request file (Engine is started with `QML_XHR_ALLOW_FILE_WRITE=1`), so it works without the deck's network.
- Software rendering only: `engine/tools/gl_items.py` finds Engine's scene-graph items that build OpenGL framebuffers (the waveform views) from the binary's C++ type info, and the shim makes those draw nothing. It checks the original bytes first, so it never patches a different Engine build in the wrong place.
- `engine/edisks_emu.py` stands in for the deck's `edisksd` drive service on the deck's D-Bus. Engine asks it for drives and to mount them, and it bind-mounts your folders at `/media/<label>`, as on the deck.
- The viewer (`viewer/`) serves the page (`viewer/web/`, drawn from the model's `panel.json`), turns panel actions into the deck's MIDI messages (`models/gen` holds the maps, taken from Engine's own assignment files), answers Engine's "report all controls" query like the hardware does, decodes the decks' own displays, and streams the audio.
- Networking: the deck runs in its own network namespace with an `eth0`, gets an address from the firmware's own `udhcpd` on the PC side, and runs its own `connmand` (set to leave your PC's clock alone). `/proc/interrupts` and `/proc/irq` are faked inside so Engine finds its control-surface serial port.
- `assets/systemctl` stands in for systemd so the console can restart Engine.

## Working on it

The code is split by job; [docs/layout.md](docs/layout.md) is the map:

| Folder | What's in it |
| --- | --- |
| `engine/` | The Linux side: `emu.sh` (the command line) and `lib/` (setup, mounts, network, drives, decks, running), the shim, the firmware readers |
| `viewer/` | The deck page: a Python package (`python3 -m viewer`) and the page itself in `viewer/web/` |
| `models/` | One folder per deck model: `model.json` and the panel, and the generators in `models/gen/` |
| `assets/` | Files that go into the deck: the fake `/sys`, QML stand-ins, the virgl Mesa driver |
| `apps/` | The Mac app and launcher, and the Windows app |
| `tests/` | `sudo tests/run.sh` runs every check that doesn't need a firmware file (CI runs it too) |
| `docs/` | How it fits together, the models, the command line the apps use, the display protocol, releasing |

`engine/shim/libemushim.so` is prebuilt. To rebuild it after changing `emushim.c`, `alsa_emu.c` or a model:

```sh
sudo apt install gcc-arm-linux-gnueabihf libasound2-dev
make -C engine/shim
```

The panels are made by `models/gen/make_panel_jp21.py` and `models/gen/make_panel_p4.py`; run them after changing a layout or a MIDI map. The tests fail when the shim or a panel is older than what it's made from.

`assets/gl/swrast_dri.so` is prebuilt too (Mesa, MIT licensed). `sudo tools/build_mesa_virgl.sh [VERSION]` rebuilds it on Ubuntu 24.04, for another firmware's Mesa version if needed.

## Notes

Thanks to [QEngine](https://github.com/Peyton-C/QEngine) (MIT) for the virgl approach, the firmware readers in `engine/firmware/` and the telemetry list.

No Denon firmware, Engine code or anything from a real deck is in this repository: you supply the firmware, and the identifiers the emulator presents (serial numbers, volume IDs) are placeholders. Mods for EngineX are in [enginex-mods](https://github.com/jonathanrobichaud4/enginex-mods).
