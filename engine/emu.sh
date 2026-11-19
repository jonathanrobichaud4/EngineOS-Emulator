#!/bin/bash
# EngineOS Emulator: runs the real ARM Engine binary from a deck's stock firmware under qemu-user
# in a chroot, with EngineX's hook preloaded when it's installed. The browser page shows the whole
# deck: touchscreen, every control (as the deck's internal MIDI devices), LEDs, displays and
# audio out. Meant for WSL2 (Ubuntu), any x86_64 or ARM64 Linux, or macOS through
# apps/mac/engineos-emu (a Lima VM). The models it emulates are in models/.
#
#   sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]   build ./rootfs (once per firmware)
#   sudo ./emu.sh product [MODEL]                        which deck to be (./emu.sh models)
#   sudo ./emu.sh --profile NAME <command>               use a separate deck (e.g. a stock Engine OS one)
#   sudo ./emu.sh profile new NAME [MODEL] | rename OLD NEW | delete NAME | model NAME [MODEL]
#   ./emu.sh profiles [--json] | models [--json] | info [--json] | version
#   sudo ./emu.sh install ENGINEX_BUNDLE                 (re)install EngineX into the rootfs
#   sudo ./emu.sh start [--stock]                        boot it, open http://localhost:8090
#                                                        (sudo EMU_NET=0 ./emu.sh start: no network)
#   sudo ./emu.sh drive add FOLDER [--sd] [--label NAME]  plug a folder in as a USB drive / SD card
#   sudo ./emu.sh drive remove LABEL | rename LABEL NEW | type LABEL usb|sd | list [--json]
#   sudo ./emu.sh mod-install MOD.tar.gz                 install and enable a mod (while running)
#   sudo ./emu.sh dump-qml OUTDIR [FILTER]               write Engine's built-in QML out as files
#   sudo ./emu.sh stop | reboot | restart | status | shell | log | tap X Y | reset-data
#   sudo ./emu.sh graphics [auto|gl|software] | identify FILE | unmount
#
# The code is split by subject in engine/lib (see docs/layout.md); this file reads the options
# and runs the command.
set -euo pipefail
# Repair a /dev/pts that emu.sh 0.1.0 unmounted (symptom: "sudo: unable to allocate pty").
mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=000 2>/dev/null || :

ENGINE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The deck to work on: --profile NAME, or EMU_PROFILE, or the default one.
PROFILE=${EMU_PROFILE:-}
if [ "${1:-}" = --profile ]; then PROFILE=${2:-}; shift 2 || :; fi
case "$PROFILE" in ""|default) PROFILE= ;; *[!A-Za-z0-9_-]*) echo "emu: deck names are letters, digits, - and _" >&2; exit 1 ;; esac

for _lib in common host rootfs net firmware run drives profiles info mods; do
    # shellcheck source=/dev/null
    . "$ENGINE/lib/$_lib.sh"
done

# The deck's processes run in the background after `start` returns. When start is run through
# `wsl.exe -- bash -c ...` (the Windows app does this), WSL ends that whole session once the
# command returns and takes the background processes with it. Running start in a session of its
# own keeps them alive; -w still waits for start itself, so its output and exit code come back.
case "${1:-}" in
    start|reboot)
        if [ -z "${EMU_OWN_SESSION:-}" ] && command -v setsid >/dev/null; then
            EMU_OWN_SESSION=1 EMU_PROFILE=${PROFILE:-default} exec setsid -w "$ENGINE/emu.sh" "$@"
        fi ;;
esac

migrate_drive_paths

case "${1:-}" in
    setup) shift; cmd_setup "$@" ;;
    install) need_root; shift; install_bundle "${1:-}"; running || mounts_down ;;
    start) shift; cmd_start "$@" ;;
    stop) cmd_stop ;;
    restart) cmd_restart_engine; say "Engine restarting" ;;
    status) cmd_status ;;
    log) tail -f "$STATE/engine.log" ;;
    shell) need_root; binfmt; mounts_up; in_deck TERM=xterm /bin/sh -l ;;
    reboot) need_root; cmd_stop; cmd_start ;;
    tap) cmd_tap "$2" "$3" ;;
    drive) shift; cmd_drive "$@" ;;
    dump-qml) shift; cmd_dump_qml "$@" ;;
    info) shift; cmd_info "$@" ;;
    profiles) shift; cmd_profiles "$@" ;;
    profile) shift; cmd_profile "$@" ;;
    models) shift; cmd_models "$@" ;;
    version) cmd_version ;;
    unmount) need_root; running && die "stop it first"; mounts_down ;;
    product) shift; cmd_product "$@" ;;
    identify) shift; cmd_identify "$@" ;;
    graphics) shift; cmd_graphics "$@" ;;
    mod-install) shift; cmd_mod_install "$@" ;;
    reset-data) cmd_reset_data ;;
    *) sed -n '2,21p' "$ENGINE/emu.sh" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
