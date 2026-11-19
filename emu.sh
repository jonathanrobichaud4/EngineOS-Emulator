#!/bin/bash
# EngineOS Emulator: emulates the SC LIVE 4 (JP21). Runs the real ARM Engine binary from the stock
# firmware under qemu-user in a chroot, with EngineX's hook preloaded. The browser page shows
# the whole deck: touchscreen, every control (as the internal MIDI control surface), LEDs and
# audio out. Meant for WSL2 (Ubuntu), any x86_64 or ARM64 Linux, or macOS through mac/engineos-emu
# (a Lima VM).
#
#   sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]   build ./rootfs (once per firmware)
#   sudo ./emu.sh product [JP21|JC11|JC11S]              which deck to be: SC LIVE 4 (default),
#                                                        Prime 4 or Prime 4+ (same firmware)
#   sudo ./emu.sh --profile NAME <command>               use a separate deck (e.g. a stock Engine OS one)
#   sudo ./emu.sh profile new NAME [MODEL] | rename OLD NEW | delete NAME | model NAME [MODEL]
#   ./emu.sh profiles                                    the decks: name, set up, EngineX, model, running
#   sudo ./emu.sh install ENGINEX_BUNDLE                 (re)install EngineX into the rootfs
#   sudo ./emu.sh start [--stock]                        boot it, open http://localhost:8090
#                                                        (sudo EMU_NET=0 ./emu.sh start: no network)
#   sudo ./emu.sh drive add FOLDER [--sd] [--label NAME]  plug a folder in as a USB drive / SD card
#   sudo ./emu.sh drive remove LABEL | drive list
#   sudo ./emu.sh mod-install MOD.tar.gz                 install and enable a mod (while running)
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
QEMU=/usr/bin/qemu-arm-static   # replaced by find_qemu() if the distro names it differently
# Emulated USB Ethernet: the deck lives in its own network namespace behind NAT.
# Saved settings (emu.sh graphics ...); the environment still wins.
if [ -f "$HERE/emu.conf" ]; then
    _gl_env=${EMU_GL:-}
    # shellcheck source=/dev/null
    . "$HERE/emu.conf"
    [ -z "$_gl_env" ] || EMU_GL=$_gl_env
fi
EMU_NET=${EMU_NET:-1}
# Rendering: EMU_GL=1 real OpenGL through virgl (see gl_ready), 0 Qt's software renderer,
# auto (default) GL when it's available for this firmware.
EMU_GL=${EMU_GL:-auto}
NETNS=enginex
NET_HOST_IF=emu0
NET_HOST_IP=10.77.0.1
NET_DECK_IP=10.77.0.2
NET_DECK_MAC=02:4a:50:32:31:00

# Which deck this profile is, by inMusic product code: JP21 SC LIVE 4, JC11 Prime 4, JC11S Prime 4+.
# The SC LIVE 4's Engine OS 5.3.0 carries Engine's support for all of them; Engine picks its
# product from the devicetree, which the emulator writes (prepare_rootfs).
PRODUCTS="JP21 JC11 JC11S"
product_name() { case "$1" in JP21) echo "SC LIVE 4" ;; JC11) echo "Prime 4" ;; JC11S) echo "Prime 4+" ;; *) echo "$1" ;; esac; }
PRODUCT=$(cat "$STATE/product" 2>/dev/null || :)
case " $PRODUCTS " in *" $PRODUCT "*) ;; *) PRODUCT=JP21 ;; esac

die() { echo "emu: $*" >&2; exit 1; }
say() { echo "emu: $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }
in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"; }
# Like in_root, but inside the deck's own network namespace when emulated networking is on.
in_deck() {
    if [ -e /run/netns/$NETNS ]; then nsenter --net=/run/netns/$NETNS -- chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"
    else in_root "$@"; fi
}

# True if the file is an ELF with no program interpreter (statically linked), so it still runs
# inside the deck's chroot where the host's libraries aren't.
is_static() {
    [ -x "$1" ] && python3 - "$1" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); h = f.read(64)
if h[:4] != b'\x7fELF' or h[4] != 2: sys.exit(1)
phoff, = struct.unpack_from('<Q', h, 32); phentsize, phnum = struct.unpack_from('<HH', h, 54)
for i in range(phnum):
    f.seek(phoff + i * phentsize)
    if struct.unpack('<I', f.read(4))[0] == 3: sys.exit(1)   # PT_INTERP: dynamically linked
PY
}

# Ubuntu up to 24.10 ships /usr/bin/qemu-arm-static (qemu-user-static). Newer Ubuntu and Debian 13
# dropped that package: qemu-user itself is static there and installs /usr/bin/qemu-arm.
find_qemu() {
    local q
    for q in /usr/bin/qemu-arm-static /usr/bin/qemu-arm; do
        if is_static "$q"; then QEMU=$q; return 0; fi
    done
    return 1
}

deps() {
    local miss=()
    command -v python3 >/dev/null || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3; }
    if ! find_qemu; then
        say "installing the ARM emulator (qemu)"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-user-static 2>/dev/null ||
            { say "qemu-user-static isn't available here; installing qemu-user instead";
              DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-user; }
        find_qemu || die "couldn't find a statically linked qemu-arm after installing qemu ($(lsb_release -ds 2>/dev/null))"
    fi
    command -v debugfs >/dev/null || miss+=(e2fsprogs)
    command -v python3 >/dev/null || miss+=(python3)
    command -v curl >/dev/null || miss+=(curl)
    command -v ip >/dev/null || miss+=(iproute2)
    command -v iptables >/dev/null || miss+=(iptables)
    command -v nsenter >/dev/null || miss+=(util-linux)
    python3 -c 'import jeepney' 2>/dev/null || miss+=(python3-jeepney)
    # The software waveforms: ffmpeg decodes the tracks, numpy splits them into bands.
    python3 -c 'import numpy' 2>/dev/null || miss+=(python3-numpy)
    command -v ffmpeg >/dev/null || miss+=(ffmpeg)
    command -v virgl_test_server >/dev/null || miss+=(virgl-server)
    # virgl draws with the host's Mesa (llvmpipe when there's no GPU, as in a VM). A minimal
    # Ubuntu, such as Lima's cloud image on a Mac, may have no Mesa EGL or DRI drivers at all.
    # libEGL.so.1 itself (glvnd's loader) is its own package; without it virgl_test_server
    # starts but can't open EGL, and drops every client.
    dpkg -s libegl1 >/dev/null 2>&1 || miss+=(libegl1)
    dpkg -s libegl-mesa0 >/dev/null 2>&1 || miss+=(libegl-mesa0)
    dpkg -s libgl1-mesa-dri >/dev/null 2>&1 || miss+=(libgl1-mesa-dri)
    if [ ${#miss[@]} -gt 0 ]; then
        say "installing ${miss[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}"
    fi
}

binfmt() {
    find_qemu || die "qemu-arm isn't installed; run: sudo ./emu.sh setup FIRMWARE.img"
    [ -d /proc/sys/fs/binfmt_misc ] || modprobe binfmt_misc 2>/dev/null || :
    [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    # Ubuntu's qemu packages register qemu-arm when systemd is on; otherwise do it here.
    if [ -e /proc/sys/fs/binfmt_misc/qemu-arm ]; then
        grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-arm || echo 1 > /proc/sys/fs/binfmt_misc/qemu-arm
        return
    fi
    echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'$QEMU':F' \
        > /proc/sys/fs/binfmt_misc/register
}

# OpenGL through virgl (the approach QEngine uses, https://github.com/Peyton-C/QEngine, here over
# vtest instead of a VM's virtio-gpu): Engine's Mesa gets a virgl driver (files/gl, built by
# tools/build_mesa_virgl.sh for the firmware's exact Mesa version) and sends its GL over a socket
# to virgl_test_server, which draws it natively on the PC. Shaders work, so Engine's own
# waveforms, coloured icons and effects draw, and the software stand-ins stand down.
# Sets GL=1 or 0.
gl_ready() {
    GL=0
    [ "$EMU_GL" = 0 ] && return 0
    local want have=""
    want=$(cat "$HERE/files/gl/MESA_VERSION" 2>/dev/null)
    have=$(grep -aoE -m1 'Mesa [0-9]+\.[0-9]+(\.[0-9]+)?' "$R/usr/lib/dri/swrast_dri.so" 2>/dev/null | head -n1 | sed 's/^Mesa //')
    if [ -z "$want" ] || [ ! -f "$HERE/files/gl/swrast_dri.so" ]; then
        [ "$EMU_GL" = 1 ] && die "no virgl Mesa driver in files/gl (see tools/build_mesa_virgl.sh)"
        return 0
    fi
    if [ "$have" != "$want" ]; then
        [ "$EMU_GL" = 1 ] && die "this firmware has Mesa ${have:-?}; files/gl is built for $want (rebuild with tools/build_mesa_virgl.sh $have)"
        say "note: firmware Mesa ${have:-?} doesn't match the bundled $want driver; using software rendering"
        return 0
    fi
    command -v virgl_test_server >/dev/null || {
        [ "$EMU_GL" = 1 ] && die "virgl_test_server is missing (sudo apt install virgl-server)"
        return 0; }
    GL=1
}

# Point inMusic's telemetry hosts at localhost so nothing the emulated deck does reaches
# inMusic's error reporting or analytics. List from QEngine (rootfs_steps/block_telemetry.sh,
# MIT, Copyright (c) Peyton-C); Engine handles the failed connections.
block_telemetry() {
    local host
    for host in o230257.ingest.sentry.io analytics.inmusicbrands.com posthog.data.aws.inmusic.dev \
                posthog.inmusic-cloud.prod.aws.inmusic.dev ssl.google-analytics.com; do
        grep -qxF "127.0.0.1 $host" "$R/etc/hosts" 2>/dev/null || echo "127.0.0.1 $host" >> "$R/etc/hosts"
    done
}

# The Prime 4's four internal boards are USB MIDI devices, sound cards 0-3 in the order the shim
# gives them (Controller, Mixer, Left Display, Right Display). Engine binds the displays by USB
# product ID as well as by their identity reply (KnownDevices: Left 9008, Right b008), reading it
# from the device behind /sys/class/sound/cardN/device, so each card gets a USB device here.
usb_boards() {
    local i name pid hub=/sys/devices/platform/ff500000.usb/usb1/1-1
    rm -rf "$R/sys/class/sound" "$R$hub"; mkdir -p "$R/sys/class/sound"
    for i in 0 1 2 3; do
        name=$(echo "Controller Mixer Left_Display Right_Display" | cut -d' ' -f$((i + 1)) | tr _ ' ')
        pid=$(echo "9001 9002 9008 b008" | cut -d' ' -f$((i + 1)))
        local dev=$hub/1-1.$((i + 1)) intf=$hub/1-1.$((i + 1))/1-1.$((i + 1)):1.0
        mkdir -p "$R$intf/sound/card$i"
        printf '15e4\n' > "$R$dev/idVendor"; printf '%s\n' "$pid" > "$R$dev/idProduct"
        printf '%s\n' "$name" > "$R$dev/product"; printf 'inMusic\n' > "$R$dev/manufacturer"
        printf '1\n' > "$R$dev/busnum"; printf '%s\n' $((i + 2)) > "$R$dev/devnum"; printf '1.%s\n' $((i + 1)) > "$R$dev/devpath"
        printf 'Surface%s\n' "$([ $i = 0 ] || echo $i)" > "$R$intf/sound/card$i/id"; printf '%s\n' $i > "$R$intf/sound/card$i/number"
        ln -sfn "../../devices/platform/ff500000.usb/usb1/1-1/1-1.$((i + 1))/1-1.$((i + 1)):1.0/sound/card$i" "$R/sys/class/sound/card$i"
        ln -sfn "../../../1-1.$((i + 1)):1.0" "$R$intf/sound/card$i/device"
    done
}

prepare_rootfs() {
    mkdir -p "$R/etc/emu" "$R/usr/bin"
    rm -rf "$R/sys" && tar -C "$R" -xzf "$HERE/files/fakesys.tar.gz"
    printf %s "$PRODUCT" > "$R/sys/firmware/devicetree/base/inmusic,product-code"  # no newline, as on the unit
    # Engine runs only as a deck its firmware was built for: it checks the product code against
    # its own list and otherwise quits to "TestApp" (engine_loop says so). The SC LIVE 4 firmware
    # covers the SC LIVE 4 and the Prime 4+; the original Prime 4 needs Prime 4 firmware.
    # RK3288 Prime decks also read their eFuses: the secure one holds the product code, the CPU-id
    # one "RK3288" + board + product at byte 7. Contents as QEngine writes them
    # (rootfs_steps/write_fake_dt.sh, MIT, Copyright (c) Peyton-C). The SC LIVE 4's stand-ins
    # (fakesys) already pass, so they stay.
    if [ "$PRODUCT" != JP21 ]; then
        local ef=$R/sys/devices/platform
        mkdir -p "$ef/ffb10000.efuse/rockchip-efuse0" "$ef/ffb40000.efuse/rockchip-efuse0"
        { printf %s "$PRODUCT"; head -c $((128 - ${#PRODUCT})) /dev/zero; } > "$ef/ffb10000.efuse/rockchip-efuse0/nvmem"
        { head -c 7 /dev/zero; printf %s "RK3288AZ01$PRODUCT"; head -c $((128 - 17 - ${#PRODUCT})) /dev/zero; } \
            > "$ef/ffb40000.efuse/rockchip-efuse0/nvmem"
        usb_boards
    fi
    # Both names, so it works whichever path the kernel's binfmt entry was registered with.
    cp "$QEMU" "$R/usr/bin/qemu-arm-static"
    cp "$QEMU" "$R/usr/bin/qemu-arm"
    cp "$HERE/shim/libemushim.so" "$R/usr/lib/libemushim.so"
    cp "$HERE/files/screen.json" "$R/etc/emu/screen.json"
    rm -rf "$R/etc/emu/qml"; [ ! -d "$HERE/files/qml" ] || cp -r "$HERE/files/qml" "$R/etc/emu/qml"
    # Engine items that need OpenGL (waveforms); found per Engine build, cached by its size+mtime
    local stamp; stamp=$(stat -c '%s %Y' "$R/usr/Engine/Engine")
    if [ "$(head -n1 "$R/etc/emu/gl-items.txt" 2>/dev/null)" != "# $stamp" ]; then
        { echo "# $stamp"; python3 "$HERE/tools/gl_items.py" "$R/usr/Engine/Engine" "$R/lib/libQt6Quick.so.6" 2>/dev/null; } \
            > "$R/etc/emu/gl-items.txt" || :
    fi
    block_telemetry
    rm -rf "$R/usr/lib/emu-dri"
    if [ -f "$HERE/files/gl/swrast_dri.so" ]; then
        mkdir -p "$R/usr/lib/emu-dri"; cp "$HERE/files/gl/swrast_dri.so" "$R/usr/lib/emu-dri/swrast_dri.so"
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

# The emulator's QML additions (files/qml-inject): Engine's waveforms need OpenGL, so the emulator
# switches those items off and adds its own software-drawn waveform to their QML. The shim adds
# the snippets to Engine's compiled-in files; EngineX's UI pack has its own copies of some of
# them, so those get an injected copy bind-mounted over them while the deck runs.
qml_inject() {
    local spec res src rel gen
    rm -rf "$R/etc/emu/qml-inject" "$R/etc/emu/qml-gen"
    for spec in "$HERE"/files/qml-inject/*.inject; do
        [ -f "$spec" ] || continue
        res=$(sed -n 's/^path: //p' "$spec" | head -n1)
        mkdir -p "$R/etc/emu/qml-inject$(dirname "$res")"
        cp "$spec" "$R/etc/emu/qml-inject$res"
        for src in "$R"/data/enginex/ui/packs/*"$res"; do
            [ -f "$src" ] || continue
            grep -qF " $src " /proc/self/mounts && continue
            rel=${src#"$R"/data/enginex/ui/}; gen="$R/etc/emu/qml-gen/$rel"
            mkdir -p "$(dirname "$gen")"
            if python3 "$HERE/tools/qml_inject.py" "$spec" "$src" "$gen"; then
                mount --bind "$gen" "$src" || :
            else
                say "note: ${spec##*/} doesn't fit EngineX's $rel (waveforms stay blank there)"
            fi
        done
    done
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
    # A namespace left over from before a restart (of WSL, the VM or the computer) is just a
    # dead file; clear it so it can be made again.
    if [ -e /run/netns/$NETNS ] && ! ip netns exec $NETNS true 2>/dev/null; then ip netns del $NETNS 2>/dev/null || rm -f /run/netns/$NETNS; fi
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
    # EngineX is built from the SC LIVE 4 firmware: on a Prime 4 deck (Prime 4 firmware) it would
    # swap that Engine for the SC LIVE 4 one.
    [ "$PRODUCT" != JC11 ] || die "EngineX is made for the SC LIVE 4 firmware, so it can't go on a Prime 4 deck. Use it on an SC LIVE 4 (or, untested, a Prime 4+) deck."
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
    case "$R" in /mnt/[a-z]/*) die "keep the emulator folder in your Linux home (e.g. ~/engineos-emulator), not on a Windows drive under /mnt: the rootfs needs Linux permissions and symlinks" ;; esac
    deps
    [ ! -e "$R/usr/Engine/Engine" ] || { cmd_stop >/dev/null 2>&1 || :; say "replacing existing rootfs"; mounts_down; rm -rf "$R"; }
    mkdir -p "$STATE"
    # A Windows updater .exe, a Mac updater zip or a zipped image carry the same update image;
    # QEngine's readers (tools/qengine) take it out and check the rootfs's own digest.
    local magic; magic=$(head -c4 "$fw" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        504b0304|4d5a*|377abcaf)
            say "taking the update image out of ${fw##*/}"
            python3 "$HERE/tools/qengine/extract_updater.py" "$fw" "$STATE/update.img" >/dev/null ||
                die "couldn't find an update image in ${fw##*/}"
            fw="$STATE/update.img" ;;
    esac
    say "extracting rootfs from ${fw##*/} (checking its digest)"
    # "AZ01" images (Prime 4, Prime GO, SC6000) have the older container layout.
    if [ "$(head -c 4 "$fw")" = AZ01 ]; then
        python3 "$HERE/tools/qengine/extract_az01_rootfs.py" "$fw" "$STATE/rootfs.img" >/dev/null 2>"$STATE/extract.log" ||
            die "couldn't read ${fw##*/}: $(tail -n1 "$STATE/extract.log")"
    elif ! python3 "$HERE/tools/qengine/extract_az0x_rootfs.py" "$fw" "$STATE/rootfs.img" >/dev/null 2>"$STATE/extract.log"; then
        say "note: $(tail -n1 "$STATE/extract.log"); trying the plain reader"
        python3 "$HERE/tools/az0x_extract.py" "$fw" "$STATE/rootfs.img" rootfs
    fi
    # Which models this firmware runs as: Prime 4 firmware ("AZ01") as a Prime 4, SC LIVE 4
    # firmware as an SC LIVE 4 or a Prime 4+. A deck set to a model its firmware can't run follows
    # the firmware.
    local want=
    if [ "$(head -c 4 "$fw")" = AZ01 ]; then [ "$PRODUCT" = JC11 ] || want=JC11
    elif [ "$PRODUCT" = JC11 ]; then want=JP21; fi
    rm -f "$STATE/update.img"
    say "unpacking ext4 image"
    mkdir -p "$R"
    debugfs -R "rdump / $R" "$STATE/rootfs.img" >/dev/null 2>"$STATE/debugfs.log" || die "debugfs failed, see $STATE/debugfs.log"
    rm -f "$STATE/rootfs.img"
    [ -x "$R/usr/Engine/Engine" ] || die "no /usr/Engine/Engine in that firmware; is it an Engine OS update?"
    if [ -n "$want" ]; then
        say "this is $(product_name "$want") firmware, so the deck is now a $(product_name "$want") (it was set to $(product_name "$PRODUCT"))"
        PRODUCT=$want; echo "$want" > "$STATE/product"
    fi
    prepare_rootfs
    say "Engine OS ready in $R"
    [ -z "${2:-}" ] || install_bundle "$2"
    mounts_down
    say "done. Start it with: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }start"
}

running() { [ -f "$STATE/emu.pid" ] && kill -0 "$(cat "$STATE/emu.pid")" 2>/dev/null; }

engine_loop() {
    rm -f "$STATE/engine-error"
    # Restarts Engine when it exits, like engine.service does (also how the console's restart works).
    local stock=$1 gl=$2 preload=/usr/lib/libemushim.so n=0 render t0 glfail=0
    local soft="QT_QPA_PLATFORM=offscreen:configfile=/etc/emu/screen.json QT_QUICK_BACKEND=software"
    if [ "$gl" = 1 ]; then
        # eglfs on Mesa's surfaceless EGL; the shim turns its window into a pbuffer and reads
        # frames back at each swap. eglfs insists on opening a framebuffer device but only
        # needs it for the size, which is given here, so /dev/null does. 339x212 mm keeps Qt's 96 dpi, the same as software mode.
        render="QT_QPA_PLATFORM=eglfs QT_QPA_EGLFS_INTEGRATION=none QT_QPA_EGLFS_WIDTH=1280 QT_QPA_EGLFS_HEIGHT=800
            QT_QPA_EGLFS_PHYSICAL_WIDTH=339 QT_QPA_EGLFS_PHYSICAL_HEIGHT=212 QT_QPA_EGLFS_HIDECURSOR=1
            QT_QPA_EGLFS_DISABLE_INPUT=1 QT_QPA_EGLFS_NO_LIBINPUT=1 QT_QPA_EGLFS_FB=/dev/null EGL_PLATFORM=surfaceless
            LIBGL_DRIVERS_PATH=/usr/lib/emu-dri GALLIUM_DRIVER=virpipe VTEST_SOCKET_NAME=/tmp/emu/virgl.sock EMU_GL=1"
    else
        render=$soft
    fi
    if [ "$stock" = 0 ] && [ -f "$R/data/enginex/bundle/lib/libengine-ui-hook.so" ]; then
        preload=$preload:${EMU_HOOK:-/data/enginex/bundle/lib/libengine-ui-hook.so}
    fi
    while :; do
        if [ -f "$R/tmp/emu/engine-ctl" ] && [ "$(cat "$R/tmp/emu/engine-ctl")" = stop ]; then sleep 1; continue; fi
        rm -f "$R/tmp/emu/engine-ctl"
        n=$((n + 1)); t0=$(date +%s)
        echo "=== Engine start #$n $(date '+%F %T') preload=$preload" >> "$STATE/engine.log"
        # shellcheck disable=SC2086  # $render is a list of VAR=value words
        in_deck EMU_DEBUG=${EMU_DEBUG:-0} EMU_QML_FIND=${EMU_QML_FIND:-} LD_PRELOAD="$preload" $render \
            MALLOC_ARENA_MAX=1 QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 \
            /usr/Engine/Engine -d0 -skipFirmwareUpdate -loggerOptions "Type, Message, Thread, Category, SplitLongLines" \
            >> "$STATE/engine.log" 2>&1 || :
        echo "=== Engine exited $(date '+%F %T')" >> "$STATE/engine.log"
        # Quit straight to "TestApp": this firmware doesn't run as this model. Say so and stop
        # restarting it.
        if [ "$(cat "$R/tmp/engine-quit-reason" 2>/dev/null)" = TestApp ] && [ $(($(date +%s) - t0)) -lt 120 ]; then
            local msg="this firmware doesn't run as a $(product_name "$PRODUCT"): the SC LIVE 4 firmware runs as an SC LIVE 4 or Prime 4+, Prime 4 firmware as a Prime 4. Change the deck's model or set it up with the right firmware."
            echo "=== emu: $msg" >> "$STATE/engine.log"
            echo "$msg" > "$STATE/engine-error"
            rm -f "$R/tmp/engine-quit-reason"
            return 0
        fi
        rm -f "$STATE/engine-error"
        # GL that starts but doesn't work (virgl drops Engine as soon as it connects, seen in a
        # Lima VM on a Mac), or a virgl server that has died: after two of those, finish this run in
        # software.
        if [ "$gl" = 1 ] && { { [ $(($(date +%s) - t0)) -lt 30 ] &&
               tail -n 40 "$STATE/engine.log" | grep -q 'lost connection to rendering server'; } ||
             ! kill -0 "$(cat "$STATE/virgl.pid" 2>/dev/null)" 2>/dev/null; }; then
            glfail=$((glfail + 1))
            if [ $glfail -ge 2 ]; then
                echo "=== emu: GL rendering isn't working here (Engine keeps losing the virgl server, see $STATE/virgl.log); switching to software rendering. 'emu.sh graphics software' makes that the default." >> "$STATE/engine.log"
                kill "$(cat "$STATE/virgl.pid" 2>/dev/null)" 2>/dev/null || :; rm -f "$STATE/virgl.pid"
                gl=0; render=$soft; qml_inject >> "$STATE/engine.log" 2>&1 || :
            fi
        fi
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
    deps; binfmt; prepare_rootfs >/dev/null; mounts_up; gl_ready
    [ "$GL" = 1 ] || qml_inject
    mkdir -p "$STATE"; : > "$STATE/engine.log"
    rm -rf "$R/tmp/emu/wave/req"
    [ -S "$R/run/dbus/system_bus_socket" ] || in_root /usr/bin/dbus-daemon --system --fork --nopidfile
    net_up
    python3 "$HERE/edisks_emu.py" --rootfs "$R" --drives "$HERE/drives.txt" </dev/null > "$STATE/edisks.log" 2>&1 &
    echo $! > "$STATE/edisks.pid"
    if [ $stock = 0 ] && [ -x "$R/data/enginex/bundle/bin/stream-sync" ]; then
        in_deck /data/enginex/bundle/bin/stream-sync --listen ":$CONSOLE_PORT" > "$STATE/stream-sync.log" 2>&1 &
        echo $! > "$STATE/stream-sync.pid"
    fi
    if [ "$GL" = 1 ]; then
        mkdir -p "$R/tmp/emu"; rm -f "$R/tmp/emu/virgl.sock"
        virgl_test_server --use-egl-surfaceless --socket-path "$R/tmp/emu/virgl.sock" \
            </dev/null > "$STATE/virgl.log" 2>&1 &
        echo $! > "$STATE/virgl.pid"
        local w
        for w in $(seq 1 20); do [ -S "$R/tmp/emu/virgl.sock" ] && break; sleep 0.25; done
        if [ ! -S "$R/tmp/emu/virgl.sock" ]; then
            say "note: the virgl server didn't start (see $STATE/virgl.log); using software rendering"
            kill "$(cat "$STATE/virgl.pid")" 2>/dev/null || :; rm -f "$STATE/virgl.pid"
            GL=0; qml_inject
        fi
    fi
    engine_loop $stock "$GL" </dev/null >/dev/null 2>&1 & echo $! > "$STATE/emu.pid"
    local fwd=""; [ "$EMU_NET" = 1 ] && fwd="--forward $CONSOLE_PORT=$NET_DECK_IP:$CONSOLE_PORT"
    python3 "$HERE/viewer.py" --rootfs "$R" --product "$PRODUCT" --port "$VIEW_PORT" --console "http://localhost:$CONSOLE_PORT/" $fwd \
        < /dev/null > "$STATE/viewer.log" 2>&1 &
    echo $! > "$STATE/viewer.pid"
    # Don't report success unless the deck page is actually answering.
    local i
    for i in $(seq 1 30); do
        curl -sf -o /dev/null -m 2 "http://127.0.0.1:$VIEW_PORT/" && break
        if ! kill -0 "$(cat "$STATE/viewer.pid")" 2>/dev/null; then
            echo "emu: the deck page server stopped; its log:" >&2; tail -n 20 "$STATE/viewer.log" >&2; cmd_stop >/dev/null 2>&1 || :
            die "start failed"
        fi
        sleep 0.5
    done
    [ "$i" -lt 30 ] || { tail -n 20 "$STATE/viewer.log" >&2; die "the deck page isn't answering on port $VIEW_PORT"; }
    say "booting${PROFILE:+ profile $PROFILE} (first screen takes 1-2 minutes under emulation)"
    say "deck:    http://localhost:$VIEW_PORT/  (screen, controls, audio, drives)"
    if [ "$GL" = 1 ]; then say "graphics: OpenGL through virgl (EMU_GL=0 for software rendering)"
    else say "graphics: software rendering"; fi
    [ $stock = 1 ] || [ ! -x "$R/data/enginex/bundle/bin/stream-sync" ] || say "EngineX console: http://localhost:$CONSOLE_PORT/"
    [ "$EMU_NET" != 1 ] || say "network: USB Ethernet on eth0, deck $NET_DECK_IP via NAT (EMU_NET=0 to turn off)"
    say "logs:    sudo ./emu.sh ${PROFILE:+--profile $PROFILE }log      stop: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }stop"
}

cmd_stop() {
    need_root
    local f
    for f in emu viewer stream-sync connman udhcpd edisks virgl; do
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
        rename)
            # the name the deck shows for the drive
            local old=${2:-} new=${3:-}
            [ -n "$old" ] && [ -n "$new" ] || die "usage: ./emu.sh drive rename LABEL NEWLABEL"
            case "$new" in */*|.*|*[!A-Za-z0-9_-]*) die "drive names are letters, digits, - and _" ;; esac
            [ ${#new} -le 11 ] || die "drive names are at most 11 characters (like a real USB stick)"
            grep -q "^$old	" "$f" || die "no drive called $old"
            [ "$old" = "$new" ] || ! grep -q "^$new	" "$f" || die "a drive called $new is already attached"
            awk -F'\t' -v o="$old" -v n="$new" 'BEGIN{OFS="\t"} $1==o{$1=n} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            say "renamed $old to $new" ;;
        type)
            # plugged into a USB port or the SD card slot (there's one)
            local label=${2:-} kind=${3:-}
            case "$kind" in usb|sd) ;; *) die "usage: ./emu.sh drive type LABEL usb|sd" ;; esac
            grep -q "^$label	" "$f" || die "no drive called $label"
            [ "$kind" != sd ] || ! grep -v "^$label	" "$f" | grep -q "	sd	" || die "the deck has one SD slot and it's in use"
            awk -F'\t' -v l="$label" -v k="$kind" 'BEGIN{OFS="\t"} $1==l{$2=k} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            say "$label is now $([ "$kind" = sd ] && echo 'in the SD slot' || echo 'a USB drive')" ;;
        list|"")
            [ -s "$f" ] || { say "no drives attached (./emu.sh drive add FOLDER [--sd] [--label NAME])"; return; }
            awk -F'\t' '{printf "  %-12s %-4s %s\n", $1, $2, $3}' "$f" ;;
        *) die "usage: ./emu.sh drive add FOLDER [--sd] [--label NAME] | remove LABEL | rename LABEL NEW | type LABEL usb|sd | list" ;;
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

cmd_info() {
    # Machine-readable state for the Windows app: key=value lines.
    echo "profile=${PROFILE:-default}"
    echo "product=$PRODUCT"
    echo "product_name=$(product_name "$PRODUCT")"
    [ -x "$R/usr/Engine/Engine" ] && echo "setup=yes" || echo "setup=no"
    echo "engine_error=$(cat "$STATE/engine-error" 2>/dev/null)"
    if [ -f "$R/data/enginex/version.txt" ]; then echo "enginex=$(head -n1 "$R/data/enginex/version.txt")"; else echo "enginex="; fi
    running && echo "running=yes" || echo "running=no"
    pgrep -f '/usr/Engine/Engine -d0' >/dev/null && echo "engine=up" || echo "engine=down"
    if [ -e /run/netns/$NETNS ]; then echo "ip=$(ip -n $NETNS -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"; else echo "ip="; fi
    echo "deck_url=http://localhost:$VIEW_PORT/"
    echo "console_url=http://localhost:$CONSOLE_PORT/"
}

cmd_product() {
    if [ -z "${1:-}" ]; then echo "$PRODUCT ($(product_name "$PRODUCT"))"; return; fi
    local want; want=$(echo "$1" | tr a-z A-Z)
    case " $PRODUCTS " in *" $want "*) ;; *) die "unknown product $1; one of: $PRODUCTS" ;; esac
    need_root; mkdir -p "$STATE"; echo "$want" > "$STATE/product"
    say "this deck is now: $(product_name "$want") ($want)$(running && echo '; restart it (reboot) to switch')"
}

cmd_profiles() {
    # One line per deck: name <TAB> set up? <TAB> EngineX version <TAB> model code <TAB> running?
    # A deck exists once it has a rootfs (set up) or a state folder (made with "profile new").
    local d name sfx code seen=" "
    for d in "$HERE"/rootfs "$HERE"/rootfs-* "$HERE"/state "$HERE"/state-*; do
        [ -d "$d" ] || continue
        case "$d" in "$HERE"/rootfs*) sfx=${d#"$HERE"/rootfs} ;; *) sfx=${d#"$HERE"/state} ;; esac
        name=${sfx#-}; [ -n "$name" ] || name=default
        case "$seen" in *" $name "*) continue ;; esac; seen="$seen$name "
        code=$(cat "$HERE/state$sfx/product" 2>/dev/null || :)
        case " $PRODUCTS " in *" $code "*) ;; *) code=JP21 ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" \
            "$([ -x "$HERE/rootfs$sfx/usr/Engine/Engine" ] && echo yes || echo no)" \
            "$(head -n1 "$HERE/rootfs$sfx/data/enginex/version.txt" 2>/dev/null || :)" "$code" \
            "$([ -f "$HERE/state$sfx/emu.pid" ] && kill -0 "$(cat "$HERE/state$sfx/emu.pid")" 2>/dev/null && echo yes || echo no)"
    done
}

# Managing decks. Each one is rootfs[-NAME]/ and state[-NAME]/ ("default" has no suffix).
profile_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_-]*) die "deck names are letters, digits, - and _" ;;
    esac
}
profile_sfx() { [ "$1" = default ] && echo "" || echo "-$1"; }
profile_exists() { local x; x=$(profile_sfx "$1"); [ -d "$HERE/rootfs$x" ] || [ -d "$HERE/state$x" ]; }
profile_running() { local x; x=$(profile_sfx "$1"); [ -f "$HERE/state$x/emu.pid" ] && kill -0 "$(cat "$HERE/state$x/emu.pid")" 2>/dev/null; }
# Stopped, with nothing of the host (drives, /dev, /proc) still mounted inside it.
profile_quiet() {
    local x r; x=$(profile_sfx "$1"); r=$HERE/rootfs$x
    profile_running "$1" && die "deck $1 is running; stop it first"
    if awk -v r="$r" 'index($2, r "/") == 1 || $2 == r {f=1} END {exit !f}' /proc/self/mounts; then
        EMU_PROFILE=$1 EMU_ROOTFS= "$HERE/emu.sh" unmount >/dev/null 2>&1 || :
        awk -v r="$r" 'index($2, r "/") == 1 || $2 == r {f=1} END {exit !f}' /proc/self/mounts &&
            die "deck $1 still has folders mounted inside it; restart the computer (or WSL/VM) and try again"
    fi
    return 0
}

cmd_profile() {
    local what=${1:-}; shift || :
    case "$what" in
        new)
            local name=${1:-} model=${2:-JP21}
            profile_name "$name"; need_root
            profile_exists "$name" && die "there's already a deck called $name"
            model=$(echo "$model" | tr a-z A-Z)
            case " $PRODUCTS " in *" $model "*) ;; *) die "unknown model $model; one of: $PRODUCTS" ;; esac
            mkdir -p "$HERE/state$(profile_sfx "$name")"
            echo "$model" > "$HERE/state$(profile_sfx "$name")/product"
            say "made deck $name ($(product_name "$model")); set it up with a firmware file" ;;
        rename)
            local old=${1:-} new=${2:-} a b
            profile_name "$old"; profile_name "$new"; need_root
            profile_exists "$old" || die "there's no deck called $old"
            profile_exists "$new" && die "there's already a deck called $new"
            profile_quiet "$old"
            a=$(profile_sfx "$old"); b=$(profile_sfx "$new")
            [ ! -d "$HERE/rootfs$a" ] || mv "$HERE/rootfs$a" "$HERE/rootfs$b"
            [ ! -d "$HERE/state$a" ] || mv "$HERE/state$a" "$HERE/state$b"
            say "renamed deck $old to $new" ;;
        delete)
            local name=${1:-} x
            profile_name "$name"; need_root
            profile_exists "$name" || die "there's no deck called $name"
            profile_quiet "$name"
            x=$(profile_sfx "$name")
            # --one-file-system: never follow into anything that might still be mounted.
            rm -rf --one-file-system "$HERE/rootfs$x" "$HERE/state$x"
            say "deleted deck $name" ;;
        model)
            local name=${1:-} model=${2:-} x
            profile_name "$name"
            profile_exists "$name" || die "there's no deck called $name"
            x=$(profile_sfx "$name")
            [ -n "$model" ] || { cat "$HERE/state$x/product" 2>/dev/null || echo JP21; return; }
            EMU_PROFILE= "$HERE/emu.sh" --profile "$name" product "$model" ;;
        *) die "usage: ./emu.sh profile new NAME [MODEL] | rename OLD NEW | delete NAME | model NAME [MODEL]" ;;
    esac
}

cmd_identify() {
    # What a dropped file is: firmware | enginex | mod | unknown
    local f=${1:-}
    [ -f "$f" ] || { echo unknown; return; }
    case "$f" in
        *.img|*.IMG)
            # inMusic update images: "AZ0x" (SC LIVE 4 and newer), "AZ01" (Prime 4, older layout)
            case "$(head -c4 "$f" 2>/dev/null)" in AZ0x|AZ01) echo firmware ;; *) echo enginex ;; esac ;;
        *.exe|*.EXE|*.zip|*.ZIP)  # inMusic's desktop updaters and zipped images (tools/qengine)
            case "$(head -c2 "$f" 2>/dev/null)" in MZ|PK) echo firmware ;; *) echo unknown ;; esac ;;
        *.tar.gz|*.tgz|*.TAR.GZ)
            local list; list=$(tar tzf "$f" 2>/dev/null | head -n 400)
            if echo "$list" | grep -q '/mod.json$\|^mod.json$'; then echo mod
            elif echo "$list" | grep -q 'install.sh$'; then echo enginex
            else echo unknown; fi ;;
        *) echo unknown ;;
    esac
}

cmd_mod_install() {
    # Uploads a mod package through EngineX on the deck itself (loopback needs no console
    # login), enables it and restarts Engine so its QML loads.
    need_root
    local f=${1:-}
    [ -f "$f" ] || die "usage: sudo ./emu.sh mod-install MOD.tar.gz"
    running || die "start the emulator first"
    local id
    id=$(tar xzOf "$f" --wildcards '*mod.json' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') ||
        die "not a mod package (no mod.json)"
    cp "$f" "$R/tmp/emu/mod-upload.tar.gz"
    local out
    out=$(in_deck /usr/bin/curl -s -m 60 -F "file=@/tmp/emu/mod-upload.tar.gz" http://127.0.0.1:$CONSOLE_PORT/v1/sc5000/mods/upload) ||
        die "upload failed (is EngineX running?)"
    rm -f "$R/tmp/emu/mod-upload.tar.gz"
    case "$out" in
        *'already installed'*) say "$id is already installed; enabling it" ;;
        *'"error":"'[!\"]*) die "EngineX refused it: $out" ;;
    esac
    in_deck /usr/bin/curl -s -m 30 -H 'Content-Type: application/json' -d "{\"id\":\"$id\",\"enabled\":true}" \
        http://127.0.0.1:$CONSOLE_PORT/v1/sc5000/mods >/dev/null || die "couldn't enable $id"
    echo restart > "$R/tmp/emu/engine-ctl"; pkill -f '/usr/Engine/Engine -d0' || :
    say "installed and enabled $id; Engine is restarting"
}

cmd_tap() { printf 'down %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; sleep 0.2; printf 'up %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; }

# The deck's processes run in the background after `start` returns. When start is run through
# `wsl.exe -- bash -c ...` (the Windows app does this), WSL ends that whole session once the
# command returns and takes the background processes with it. Running start in a session of its
# own keeps them alive; -w still waits for start itself, so its output and exit code come back.
case "${1:-}" in
    start|reboot)
        if [ -z "${EMU_OWN_SESSION:-}" ] && command -v setsid >/dev/null; then
            EMU_OWN_SESSION=1 EMU_PROFILE=${PROFILE:-default} exec setsid -w "$HERE/emu.sh" "$@"
        fi ;;
esac

# Drive folders from before the rename to EngineOS Emulator (~/SCLive4Emulator on a Mac,
# Music\SC LIVE 4 Emulator on Windows) are moved by the apps; point drives.txt at the new place.
migrate_drive_paths() {
    local f="$HERE/drives.txt" line out= changed=
    [ -s "$f" ] && [ -w "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        local new
        new=$(printf '%s\n' "$line" | sed -E 's#/SCLive4Emulator(/|$)#/EngineOSEmulator\1#; s#/SC LIVE 4 Emulator(/|$)#/EngineOS Emulator\1#')
        if [ "$new" != "$line" ] && [ -d "${new##*$'\t'}" ]; then line=$new; changed=1; fi
        out+="$line"$'\n'
    done < "$f"
    [ -z "$changed" ] || printf %s "$out" > "$f"
}
migrate_drive_paths

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
    info) cmd_info ;;
    profiles) cmd_profiles ;;
    profile) shift; cmd_profile "$@" ;;
    unmount) need_root; running && die "stop it first"; mounts_down ;;
    product) shift; cmd_product "$@" ;;
    identify) shift; cmd_identify "$@" ;;
    graphics)
        shift
        case "${1:-}" in
            auto) v=auto ;; gl|opengl) v=1 ;; software|sw) v=0 ;;
            "") echo "${EMU_GL:-auto}"; exit 0 ;;
            *) die "usage: ./emu.sh graphics [auto|gl|software]" ;;
        esac
        { grep -v '^EMU_GL=' "$HERE/emu.conf" 2>/dev/null || :; echo "EMU_GL=$v"; } > "$HERE/emu.conf.tmp"
        mv "$HERE/emu.conf.tmp" "$HERE/emu.conf"
        say "graphics: $1 (takes effect at the next start)" ;;
    mod-install) shift; cmd_mod_install "$@" ;;
    reset-data)
        need_root; running && die "stop it first"
        rm -rf "$R/data/AppDataUser" "$R/data/StreamingAccounts.json"
        say "Engine settings and library reset (EngineX kept)" ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
