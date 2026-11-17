#!/bin/bash
# EngineX emulator for SC LIVE 4 (JP21). Runs the real ARM Engine binary from the stock
# firmware under qemu-user in a chroot, with EngineX's hook preloaded. The browser page shows
# the whole deck: touchscreen, every control (as the internal MIDI control surface), LEDs and
# audio out. Meant for WSL2 (Ubuntu) or any x86_64 Linux.
#
#   sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]   build ./rootfs (once per firmware)
#   sudo ./emu.sh --profile NAME <command>               use a separate deck (e.g. a stock Engine OS one)
#   sudo ./emu.sh install ENGINEX_BUNDLE                 (re)install EngineX into the rootfs
#   sudo ./emu.sh start [--stock]                        boot it, open http://localhost:8090
#                                                        (sudo EMU_NET=0 ./emu.sh start: no network)
#   sudo ./emu.sh drive add FOLDER [--sd] [--label NAME]  plug a folder in as a USB drive / SD card
#   sudo ./emu.sh drive remove LABEL | drive list
#   sudo ./emu.sh dump-qml OUTDIR [FILTER]               write Engine's built-in QML out as files
#   sudo ./emu.sh stop | reboot | restart | status | shell | log | tap X Y | reset-data
set -euo pipefail
# Repair a /dev/pts that emu.sh 0.1.0 unmounted (symptom: "sudo: unable to allocate pty").
mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=000 2>/dev/null || :

HERE=$(cd "$(dirname "$0")" && pwd)
# Profiles: separate decks side by side, e.g. a stock Engine OS one next to the EngineX one.
# `./emu.sh --profile stock setup FIRMWARE.img` (no bundle), then `./emu.sh --profile stock start`.
# Each profile has its own rootfs-NAME/ and state-NAME/; the default profile uses rootfs/ and state/.
PROFILE=${EMU_PROFILE:-}
if [ "${1:-}" = --profile ]; then PROFILE=${2:-}; shift 2 || :; fi
case "$PROFILE" in ""|default) PROFILE= ;; *[!A-Za-z0-9_-]*) echo "emu: profile names are letters, digits, - and _" >&2; exit 1 ;; esac
SUFFIX=${PROFILE:+-$PROFILE}
R=${EMU_ROOTFS:-$HERE/rootfs$SUFFIX}
STATE=$HERE/state$SUFFIX
VIEW_PORT=${VIEW_PORT:-8090}
CONSOLE_PORT=${CONSOLE_PORT:-8080}
QEMU=/usr/bin/qemu-arm-static
# Emulated USB Ethernet: the deck lives in its own network namespace behind NAT.
EMU_NET=${EMU_NET:-1}
NETNS=enginex
NET_HOST_IF=emu0
NET_HOST_IP=10.77.0.1
NET_DECK_IP=10.77.0.2
NET_DECK_MAC=02:4a:50:32:31:00

die() { echo "emu: $*" >&2; exit 1; }
say() { echo "emu: $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }
in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"; }
# Like in_root, but inside the deck's own network namespace when emulated networking is on.
in_deck() {
    if [ -e /run/netns/$NETNS ]; then nsenter --net=/run/netns/$NETNS -- chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"
    else in_root "$@"; fi
}

deps() {
    local miss=()
    [ -x $QEMU ] || miss+=(qemu-user-static)
    command -v debugfs >/dev/null || miss+=(e2fsprogs)
    command -v python3 >/dev/null || miss+=(python3)
    command -v curl >/dev/null || miss+=(curl)
    command -v ip >/dev/null || miss+=(iproute2)
    command -v iptables >/dev/null || miss+=(iptables)
    command -v nsenter >/dev/null || miss+=(util-linux)
    python3 -c 'import jeepney' 2>/dev/null || miss+=(python3-jeepney)
    if [ ${#miss[@]} -gt 0 ]; then
        say "installing ${miss[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}"
    fi
}

binfmt() {
    [ -d /proc/sys/fs/binfmt_misc ] || modprobe binfmt_misc 2>/dev/null || :
    [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    # Ubuntu's qemu-user-static registers qemu-arm with the F flag when systemd is on; otherwise do it here.
    if [ -e /proc/sys/fs/binfmt_misc/qemu-arm ]; then
        grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-arm || echo 1 > /proc/sys/fs/binfmt_misc/qemu-arm
        return
    fi
    echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'$QEMU':F' \
        > /proc/sys/fs/binfmt_misc/register
}

prepare_rootfs() {
    mkdir -p "$R/etc/emu" "$R/usr/bin"
    rm -rf "$R/sys" && tar -C "$R" -xzf "$HERE/files/fakesys.tar.gz"
    cp $QEMU "$R/usr/bin/qemu-arm-static"
    cp "$HERE/shim/libemushim.so" "$R/usr/lib/libemushim.so"
    cp "$HERE/files/screen.json" "$R/etc/emu/screen.json"
    rm -rf "$R/etc/emu/qml"; [ ! -d "$HERE/files/qml" ] || cp -r "$HERE/files/qml" "$R/etc/emu/qml"
    # Engine items that need OpenGL (waveforms); found per Engine build, cached by its size+mtime
    local stamp; stamp=$(stat -c '%s %Y' "$R/usr/Engine/Engine")
    if [ "$(head -n1 "$R/etc/emu/gl-items.txt" 2>/dev/null)" != "# $stamp" ]; then
        { echo "# $stamp"; python3 "$HERE/tools/gl_items.py" "$R/usr/Engine/Engine" "$R/lib/libQt6Quick.so.6" 2>/dev/null; } \
            > "$R/etc/emu/gl-items.txt" || :
    fi
    cp "$HERE/files/systemctl" "$R/etc/emu/systemctl"; chmod 755 "$R/etc/emu/systemctl"
    [ -e "$R/etc/emu/systemctl.real" ] || cp -a "$R/usr/bin/systemctl" "$R/etc/emu/systemctl.real"
}

mounts_up() {
    mountpoint -q "$R/proc" || mount -t proc proc "$R/proc"
    # Engine looks up the control-surface UARTs' IRQs by name in /proc/interrupts, then writes
    # /proc/irq/<n>/smp_affinity_list, and aborts if either fails. WSL2 has no serial ports and
    # no writable IRQ settings, so the chroot gets its own list naming the deck's UARTs and a
    # scratch /proc/irq where those writes land harmlessly.
    if ! mountpoint -q "$R/proc/interrupts"; then
        mkdir -p "$STATE"
        { grep -v ' ttyS[0-9]*$' /proc/interrupts
          echo " 250:          0          0  GICv3  54 Level     ttyS0"
          echo " 251:          0          0  GICv3  58 Level     ttyS4"
        } > "$STATE/interrupts"
        mount --bind "$STATE/interrupts" "$R/proc/interrupts"
    fi
    if ! mountpoint -q "$R/proc/irq"; then
        mount -t tmpfs -o size=1m tmpfs "$R/proc/irq"
        for n in 250 251; do
            mkdir -p "$R/proc/irq/$n"
            echo 0-3 > "$R/proc/irq/$n/smp_affinity_list"; echo f > "$R/proc/irq/$n/smp_affinity"
        done
    fi
    mountpoint -q "$R/dev" || { mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"; }
    mountpoint -q "$R/tmp" || mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
    mountpoint -q "$R/run" || mount -t tmpfs tmpfs "$R/run"
    mountpoint -q "$R/media" || mount -t tmpfs -o mode=755 tmpfs "$R/media"  # as on the deck
    mountpoint -q "$R/usr/bin/systemctl" || mount --bind "$R/etc/emu/systemctl" "$R/usr/bin/systemctl"
    mkdir -p "$R/run/dbus" "$R/tmp/emu" "$R/tmp/sc5000-engine-home"
    chmod 700 "$R/tmp/sc5000-engine-home"
    [ -p "$R/tmp/emu/input" ] || mkfifo "$R/tmp/emu/input"
    if [ "$EMU_NET" != 1 ]; then  # no connman: give the deck the PC's resolvers directly
        mkdir -p "$R/run/connman"  # /etc/resolv.conf -> resolv-conf.connman -> /run/connman/resolv.conf
        grep -v '^nameserver 127' /etc/resolv.conf > "$R/run/connman/resolv.conf" 2>/dev/null || :
        echo "nameserver 1.1.1.1" >> "$R/run/connman/resolv.conf"
    fi
}

mounts_down() {
    # Everything mounted under the rootfs, deepest first (boot-activate.sh adds its own bind mounts).
    local m
    mountpoint -q "$R/dev" && mount --make-rslave "$R/dev" 2>/dev/null || :
    for m in $(awk -v r="$R" '$2 == r || index($2, r "/") == 1 {print $2}' /proc/self/mounts | sort -r); do
        umount -l "$m" 2>/dev/null || :
    done
}

dns_servers() {
    # The host's resolvers, if the deck's namespace can reach them, then public fallbacks.
    local out=""
    for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null); do
        case "$ns" in 127.*|::*|*:*) ;; *) out="$out $ns" ;; esac
    done
    echo $out 1.1.1.1 8.8.8.8
}

net_up() {
    [ "$EMU_NET" = 1 ] || return 0
    [ -e /run/netns/$NETNS ] || ip netns add $NETNS
    if ! ip link show $NET_HOST_IF >/dev/null 2>&1; then
        ip link add $NET_HOST_IF type veth peer name eth0 netns $NETNS
        ip -n $NETNS link set eth0 address $NET_DECK_MAC
    fi
    ip addr replace $NET_HOST_IP/24 dev $NET_HOST_IF
    ip link set $NET_HOST_IF up
    ip -n $NETNS link set lo up
    # connman classifies interfaces from sysfs uevent; with none it ignores the device.
    # No DEVTYPE means plain Ethernet, which is how a USB Ethernet adapter shows up.
    local idx; idx=$(ip -n $NETNS -o link show eth0 | cut -d: -f1)
    mkdir -p "$R/sys/class/net/eth0"
    printf 'INTERFACE=eth0\nIFINDEX=%s\n' "$idx" > "$R/sys/class/net/eth0/uevent"
    echo 1 > "$R/sys/class/net/eth0/type"
    echo $NET_DECK_MAC > "$R/sys/class/net/eth0/address"
    sysctl -qw net.ipv4.ip_forward=1
    iptables -t nat -C POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE
    iptables -C FORWARD -i $NET_HOST_IF -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $NET_HOST_IF -j ACCEPT
    iptables -C FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
    # DHCP server on the PC side (the firmware's own busybox udhcpd), fixed lease for the deck
    cat > "$R/etc/emu/udhcpd.conf" <<CONF
start 10.77.0.2
end 10.77.0.20
interface $NET_HOST_IF
lease_file /tmp/emu/udhcpd.leases
pidfile /tmp/emu/udhcpd.pid
static_lease $NET_DECK_MAC $NET_DECK_IP
opt subnet 255.255.255.0
opt router $NET_HOST_IP
opt dns $(dns_servers)
opt domain lan
opt lease 86400
CONF
    touch "$R/tmp/emu/udhcpd.leases"
    in_root /usr/sbin/udhcpd -f /etc/emu/udhcpd.conf > "$STATE/udhcpd.log" 2>&1 &
    echo $! > "$STATE/udhcpd.pid"
    # connman as on the deck, but it must never set the PC's clock (the clock isn't namespaced)
    sed -e '/^TimeUpdates/d' -e '/^TimezoneUpdates/d' "$R/etc/connman/main.conf" > "$R/etc/emu/connman.conf"
    printf 'TimeUpdates=manual\nTimezoneUpdates=manual\n' >> "$R/etc/emu/connman.conf"
    mkdir -p "$R/var/lib/connman"
    mkdir -p "$R/run/connman"  # connman writes resolv.conf here (/etc/resolv.conf links to it)
    in_deck /usr/sbin/connmand -n -c /etc/emu/connman.conf > "$STATE/connman.log" 2>&1 &
    echo $! > "$STATE/connman.pid"
}

net_down() {
    [ -e /run/netns/$NETNS ] || return 0
    ip link del $NET_HOST_IF 2>/dev/null || :
    ip netns del $NETNS 2>/dev/null || :
    iptables -t nat -D POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE 2>/dev/null || :
    iptables -D FORWARD -i $NET_HOST_IF -j ACCEPT 2>/dev/null || :
    iptables -D FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || :
}

install_bundle() {
    local src=$1 tmp
    [ -e "$src" ] || die "no such bundle: $src"
    [ -d "$R/usr/Engine" ] || die "run setup first"
    binfmt; mounts_up
    tmp=$R/tmp/emu-bundle; rm -rf "$tmp"; mkdir -p "$tmp"
    case "$src" in
        *.tar.gz|*.tgz) tar -xzf "$src" -C "$tmp" ;;
        *.img) cp "$src" "$tmp/" ;;
        *) [ -d "$src" ] || die "bundle must be a .tar.gz, an EngineX Update .img or a folder"; cp -a "$src" "$tmp/" ;;
    esac
    local inst img
    img=$(ls "$tmp"/*.img 2>/dev/null | head -1 || :)
    inst=$(ls "$tmp"/*/install.sh "$tmp"/install.sh 2>/dev/null | head -1 || :)
    if [ -n "$img" ]; then
        # The Update .img carries its own install.sh; any stock bundle's install.sh can unpack it.
        [ -x "$R/data/enginex/bundle/install.sh" ] || die "an Update .img needs EngineX installed once from the .tar.gz bundle"
        in_root sh /data/enginex/bundle/install.sh "/tmp/emu-bundle/${img##*/}"
    else
        [ -n "$inst" ] || die "no install.sh found in $src"
        in_root sh "${inst#$R}"
    fi
    in_root sh /data/enginex/bundle/boot-activate.sh >/dev/null 2>&1 || :
    rm -rf "$tmp"
    say "EngineX $(cat "$R/data/enginex/version.txt" 2>/dev/null || echo '?') installed"
}

cmd_setup() {
    need_root
    local fw=${1:-}; [ -f "$fw" ] || die "usage: sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]"
    case "$R" in /mnt/[a-z]/*) die "keep the emulator folder in your Linux home (e.g. ~/enginex-emu), not on a Windows drive under /mnt: the rootfs needs Linux permissions and symlinks" ;; esac
    deps
    [ ! -e "$R/usr/Engine/Engine" ] || { cmd_stop >/dev/null 2>&1 || :; say "replacing existing rootfs"; mounts_down; rm -rf "$R"; }
    mkdir -p "$STATE"
    say "extracting rootfs from ${fw##*/}"
    python3 "$HERE/tools/az0x_extract.py" "$fw" "$STATE/rootfs.img" rootfs
    say "unpacking ext4 image"
    mkdir -p "$R"
    debugfs -R "rdump / $R" "$STATE/rootfs.img" >/dev/null 2>"$STATE/debugfs.log" || die "debugfs failed, see $STATE/debugfs.log"
    rm -f "$STATE/rootfs.img"
    [ -x "$R/usr/Engine/Engine" ] || die "no /usr/Engine/Engine in that firmware; is it an SC LIVE 4 image?"
    prepare_rootfs
    say "Engine OS ready in $R"
    [ -z "${2:-}" ] || install_bundle "$2"
    mounts_down
    say "done. Start it with: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }start"
}

running() { [ -f "$STATE/emu.pid" ] && kill -0 "$(cat "$STATE/emu.pid")" 2>/dev/null; }

engine_loop() {
    # Restarts Engine when it exits, like engine.service does (also how the console's restart works).
    local stock=$1 preload=/usr/lib/libemushim.so n=0
    if [ "$stock" = 0 ] && [ -f "$R/data/enginex/bundle/lib/libengine-ui-hook.so" ]; then
        preload=$preload:${EMU_HOOK:-/data/enginex/bundle/lib/libengine-ui-hook.so}
    fi
    while :; do
        if [ -f "$R/tmp/emu/engine-ctl" ] && [ "$(cat "$R/tmp/emu/engine-ctl")" = stop ]; then sleep 1; continue; fi
        rm -f "$R/tmp/emu/engine-ctl"
        n=$((n + 1))
        echo "=== Engine start #$n $(date '+%F %T') preload=$preload" >> "$STATE/engine.log"
        in_deck EMU_DEBUG=${EMU_DEBUG:-0} EMU_QML_FIND=${EMU_QML_FIND:-} LD_PRELOAD="$preload" \
            QT_QPA_PLATFORM="offscreen:configfile=/etc/emu/screen.json" QT_QUICK_BACKEND=software \
            MALLOC_ARENA_MAX=1 \
            /usr/Engine/Engine -d0 -loggerOptions "Type, Message, Thread, Category, SplitLongLines" \
            >> "$STATE/engine.log" 2>&1 || :
        echo "=== Engine exited $(date '+%F %T')" >> "$STATE/engine.log"
        sleep 2
    done
}

cmd_start() {
    need_root
    [ -x "$R/usr/Engine/Engine" ] || die "run: sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]"
    running && die "already running (sudo ./emu.sh stop first)"
    local other
    for other in "$HERE"/state*/emu.pid; do
        [ -f "$other" ] && [ "$other" != "$STATE/emu.pid" ] && kill -0 "$(cat "$other")" 2>/dev/null &&
            die "another profile is running ($(basename "$(dirname "$other")")); stop it first"
    done
    local stock=0; [ "${1:-}" = --stock ] && stock=1
    deps; binfmt; prepare_rootfs >/dev/null; mounts_up
    mkdir -p "$STATE"; : > "$STATE/engine.log"
    [ -S "$R/run/dbus/system_bus_socket" ] || in_root /usr/bin/dbus-daemon --system --fork --nopidfile
    net_up
    python3 "$HERE/edisks_emu.py" --rootfs "$R" --drives "$HERE/drives.txt" </dev/null > "$STATE/edisks.log" 2>&1 &
    echo $! > "$STATE/edisks.pid"
    if [ $stock = 0 ] && [ -x "$R/data/enginex/bundle/bin/stream-sync" ]; then
        in_deck /data/enginex/bundle/bin/stream-sync --listen ":$CONSOLE_PORT" > "$STATE/stream-sync.log" 2>&1 &
        echo $! > "$STATE/stream-sync.pid"
    fi
    engine_loop $stock </dev/null >/dev/null 2>&1 & echo $! > "$STATE/emu.pid"
    local fwd=""; [ "$EMU_NET" = 1 ] && fwd="--forward $CONSOLE_PORT=$NET_DECK_IP:$CONSOLE_PORT"
    python3 "$HERE/viewer.py" --rootfs "$R" --port "$VIEW_PORT" --console "http://localhost:$CONSOLE_PORT/" $fwd \
        < /dev/null > "$STATE/viewer.log" 2>&1 &
    echo $! > "$STATE/viewer.pid"
    say "booting${PROFILE:+ profile $PROFILE} (first screen takes 1-2 minutes under emulation)"
    say "deck:    http://localhost:$VIEW_PORT/  (screen, controls, audio, drives)"
    [ $stock = 1 ] || [ ! -x "$R/data/enginex/bundle/bin/stream-sync" ] || say "EngineX console: http://localhost:$CONSOLE_PORT/"
    [ "$EMU_NET" != 1 ] || say "network: USB Ethernet on eth0, deck $NET_DECK_IP via NAT (EMU_NET=0 to turn off)"
    say "logs:    sudo ./emu.sh ${PROFILE:+--profile $PROFILE }log      stop: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }stop"
}

cmd_stop() {
    need_root
    local f
    for f in emu viewer stream-sync connman udhcpd edisks; do
        [ -f "$STATE/$f.pid" ] && kill "$(cat "$STATE/$f.pid")" 2>/dev/null || :
        rm -f "$STATE/$f.pid"
    done
    pkill -f '/usr/Engine/Engine -d0' 2>/dev/null || :
    pkill -f 'enginex/bundle/bin/' 2>/dev/null || :
    # Mod helper scripts started inside the chroot
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && kill "${p#/proc/}" 2>/dev/null || :
    done
    sleep 2
    mounts_down
    net_down
    say "stopped"
}

cmd_status() {
    running && say "running (pid $(cat "$STATE/emu.pid"))" || say "not running"
    pgrep -f '/usr/Engine/Engine -d0' >/dev/null && say "Engine process up" || say "Engine process not up"
    if [ -e /run/netns/$NETNS ]; then
        say "network: deck $(ip -n $NETNS -4 -o addr show eth0 2>/dev/null | awk '{print $4}') via $NET_HOST_IF ($NET_HOST_IP)"
    fi
    [ -f "$R/data/enginex/version.txt" ] && say "EngineX $(cat "$R/data/enginex/version.txt")" || say "EngineX not installed"
    curl -s "http://localhost:$VIEW_PORT/status" 2>/dev/null && echo || :
}

cmd_drive() {
    # drives.txt: label <TAB> usb|sd <TAB> folder. edisks_emu.py picks up changes within a second.
    local f="$HERE/drives.txt"; touch "$f"
    case "${1:-list}" in
        add)
            local folder=${2:-} kind=usb label=""
            [ -d "$folder" ] || die "usage: ./emu.sh drive add FOLDER [--sd] [--label NAME]"
            folder=$(cd "$folder" && pwd); shift 2
            while [ $# -gt 0 ]; do
                case "$1" in --sd) kind=sd ;; --usb) kind=usb ;; --label) label=${2:-}; shift ;; esac; shift
            done
            [ -n "$label" ] || label=$(basename "$folder" | tr -c 'A-Za-z0-9_\n-' '_' | cut -c1-11)
            [ -n "$label" ] && [ "$label" != "/" ] || label=MUSIC
            case "$label" in */*|.*) die "bad label: $label" ;; esac
            grep -q "^$label	" "$f" && die "a drive called $label is already attached"
            [ "$kind" != sd ] || ! grep -q "	sd	" "$f" || die "the deck has one SD slot and it's in use"
            printf '%s\t%s\t%s\n' "$label" "$kind" "$folder" >> "$f"
            say "attached $folder as $([ $kind = sd ] && echo 'SD card' || echo 'USB drive') \"$label\"" ;;
        remove|eject)
            local label=${2:-}; [ -n "$label" ] || die "usage: ./emu.sh drive remove LABEL"
            grep -q "^$label	" "$f" || die "no drive called $label"
            grep -v "^$label	" "$f" > "$f.tmp" || :; mv "$f.tmp" "$f"
            say "removed $label" ;;
        list|"")
            [ -s "$f" ] || { say "no drives attached (./emu.sh drive add FOLDER [--sd] [--label NAME])"; return; }
            awk -F'\t' '{printf "  %-12s %-4s %s\n", $1, $2, $3}' "$f" ;;
        *) die "usage: ./emu.sh drive add FOLDER [--sd] [--label NAME] | remove LABEL | list" ;;
    esac
}

cmd_dump_qml() {
    # Write Engine's compiled-in QML and other resources out as plain files (for building mods
    # whose QML is kept as patches against the stock files).
    need_root
    local out=${1:-}; local filter=${2:-/}
    [ -n "$out" ] || die "usage: sudo ./emu.sh dump-qml OUTDIR [PATH-FILTER]"
    running && die "stop the emulator first (sudo ./emu.sh stop)"
    [ -x "$R/usr/Engine/Engine" ] || die "run setup first"
    command -v zstd >/dev/null || { apt-get install -y -qq zstd >/dev/null 2>&1 || die "needs zstd"; }
    binfmt; prepare_rootfs >/dev/null; mounts_up
    rm -f "$R"/tmp/emu/dump_* "$R"/tmp/emu/dump/* 2>/dev/null || :
    mkdir -p "$STATE"
    in_root EMU_QML_FIND="$filter" LD_PRELOAD=/usr/lib/libemushim.so QT_QPA_PLATFORM=offscreen \
        /usr/Engine/Engine -d0 > "$STATE/dump.log" 2>&1 &
    local n=0 last=-1 i
    for i in $(seq 1 60); do
        sleep 1
        n=$(grep -c 'emushim: resource' "$STATE/dump.log" 2>/dev/null || :)
        [ "${n:-0}" -gt 0 ] && [ "$n" = "$last" ] && break
        last=$n
    done
    pkill -f '/usr/Engine/Engine -d0' 2>/dev/null || :
    sleep 1
    mkdir -p "$out"
    python3 "$HERE/tools/dump_qml.py" "$STATE/dump.log" "$R/tmp/emu" "$out"
    rm -f "$R"/tmp/emu/dump_* 2>/dev/null || :
    mounts_down
}

cmd_tap() { printf 'down %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; sleep 0.2; printf 'up %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; }

case "${1:-}" in
    setup) shift; cmd_setup "$@" ;;
    install) need_root; shift; install_bundle "${1:-}"; running || mounts_down ;;
    start) shift; cmd_start "$@" ;;
    stop) cmd_stop ;;
    restart) need_root; echo restart > "$R/tmp/emu/engine-ctl"; pkill -f '/usr/Engine/Engine -d0' || :; say "Engine restarting" ;;
    status) cmd_status ;;
    log) tail -f "$STATE/engine.log" ;;
    shell) need_root; binfmt; mounts_up; in_deck TERM=xterm /bin/sh -l ;;
    reboot) need_root; cmd_stop; cmd_start ;;
    tap) cmd_tap "$2" "$3" ;;
    drive) shift; cmd_drive "$@" ;;
    dump-qml) shift; cmd_dump_qml "$@" ;;
    reset-data)
        need_root; running && die "stop it first"
        rm -rf "$R/data/AppDataUser" "$R/data/StreamingAccounts.json"
        say "Engine settings and library reset (EngineX kept)" ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
