# shellcheck shell=bash
# The Linux host: the packages the emulator needs and qemu-arm for Engine's ARM code.

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
# vtest instead of a VM's virtio-gpu): Engine's Mesa gets a virgl driver (assets/gl, built by
# tools/build_mesa_virgl.sh for the firmware's exact Mesa version) and sends its GL over a socket
# to virgl_test_server, which draws it natively on the PC. It's the only way the emulator renders,
# so this stops with the reason when it can't work.
gl_ready() {
    local want have=""
    want=$(cat "$ASSETS/gl/MESA_VERSION" 2>/dev/null)
    have=$(grep -aoE -m1 'Mesa [0-9]+\.[0-9]+(\.[0-9]+)?' "$R/usr/lib/dri/swrast_dri.so" 2>/dev/null | head -n1 | sed 's/^Mesa //')
    [ -n "$want" ] && [ -f "$ASSETS/gl/swrast_dri.so" ] || die "no virgl Mesa driver in assets/gl (see tools/build_mesa_virgl.sh)"
    [ "$have" = "$want" ] || die "this firmware has Mesa ${have:-?}, and assets/gl is built for Mesa $want. Rebuild it for this firmware: sudo tools/build_mesa_virgl.sh $have"
    command -v virgl_test_server >/dev/null || die "virgl_test_server is missing (sudo apt install virgl-server)"
}
