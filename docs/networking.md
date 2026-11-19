# The deck on your network

The emulated deck always has the internet. It can also be on your own network, where other
devices and apps see it the way they see a real deck:

- other Denon gear, through Engine Link
- Engine DJ desktop
- SoundSwitch, Resolume, Now Playing and other StageLinQ apps
- EngineX's stems helper on another computer

Pioneer gear (Pro DJ Link) isn't supported yet: the deck doesn't speak that protocol, so it needs
a translator, which is planned.

## Turning it on

| Where the emulator runs | What to do |
| --- | --- |
| Linux | Nothing: it's on by default. |
| Windows | More... > **Put the deck on my network**. Needs Windows 11 22H2 or later. It switches WSL to mirrored networking (`%UserProfile%\.wslconfig`), lets other devices reach WSL through the Hyper-V firewall (Windows asks for permission once), and restarts WSL. |
| Mac | Settings > **Put the deck on my network**, or `engineos-emu network on`. It installs Lima's `socket_vmnet` helper (Homebrew, then `/opt/socket_vmnet` and Lima's sudoers file, so it asks for your password once), adds a bridged network on the interface your Mac uses for the internet, and restarts the VM with it. Run it again after switching between Wi-Fi and Ethernet. |

`emu.sh network` shows the state; `sudo emu.sh network local` keeps decks to this computer
(internet only) and `sudo emu.sh network on` puts them back. Each deck has a name on the network,
by default its model's (`SCLIVE4`, `PRIME4PLUS`, `PRIME4`); `sudo emu.sh network name NAME` gives
it another, for example when two emulated decks or a real one would share a name.

## How it works

The deck runs in its own network namespace behind NAT (`engine/lib/net.sh`): its address is
10.77.0.2 and this computer is 10.77.0.1. That's how it gets the internet without touching the
computer's own network settings. `engine/linkbridge.py`, started with the deck, does the rest:

- **Announcements out.** Engine announces itself with UDP broadcasts: StageLinQ discovery on 51337
  (the `airD` frames, which name a TCP port to connect to), Engine DJ's EAAS beacon on 11224, and
  EngineX's stems discovery on 17891 and mDNS. The bridge sends them on again on each of this
  computer's networks, from its own address. Answers come back to the deck's original port.
- **Its ports, reachable.** Every TCP port the deck listens on is opened at the same number on
  this computer and passed through to the deck. Peers that heard an announcement connect to this
  computer's address, which is where the announcement came from.
- **Other devices, as neighbours.** Engine only answers StageLinQ requests from devices on its own
  subnet. So each device the bridge hears gets a stand-in address on the deck's subnet
  (10.77.0.100 and up): the deck hears that device's announcements from it, the device's
  connections reach the deck from it, and what the deck sends to it is forwarded to the real
  device (an `EMU_LINK` DNAT chain, then the NAT out). Engine also only takes announcements that
  arrive as broadcasts, so they're passed in as broadcasts.

On Windows, mirrored networking puts WSL on Windows' own networks; on a Mac, the VM gets its own
address on your network through the bridged interface. In both cases the bridge then works as it
does on Linux.

## StageLinQ notes

What the emulated deck does, from testing against it (engine 5.3):

- It announces three endpoints: the deck itself (software `JP20`), and two `OfflineAnalyzer`
  processes, which offer FileTransfer.
- Connecting to an endpoint: it first asks for the client's services (`0x00000002` + its token),
  then sends a timestamp every few seconds (`0x00000001`). The client sends its own services
  request (`0x00000002` + token), and the deck answers with one announcement per service
  (`0x00000000` + token + UTF-16 name + port): StateMap, Broadcast, TimeSynchronization, BeatInfo,
  FileTransfer.
- It only lists its services to tokens it knows. SoundSwitch's token works, which is the one the
  StageLinq libraries use; a made-up token gets an empty list.
- It only lists them to a device it has heard announcing (as a broadcast), connecting from the
  address it announced from, on its own subnet.
- A service connection only works while the client's main connection stays open.

## Checking it

`tools/stagelinq_probe.py --announce --state /Engine/DeckCount /Engine/Deck1/CurrentBPM` on
another computer (or a network namespace standing in for one) lists every Engine device it hears,
its services, and the values it reads. The real StageLinq library (`npm install stagelinq`)
connects too. `emu.sh network` shows what the bridge has seen, and the full log is
`state/linkbridge.log`.
