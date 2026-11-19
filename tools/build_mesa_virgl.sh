#!/bin/bash
# Builds assets/gl/swrast_dri.so: Mesa's DRI megadriver for 32-bit ARM with the virgl and
# swrast gallium drivers, which is what lets Engine render with OpenGL through virgl (see
# gl_ready in emu.sh). Mesa only offers virpipe, virgl over the vtest socket, through its
# software-rasterizer loader, so it goes in under the swrast name in its own directory.
#
# The DRI driver is loaded by the firmware's own libEGL across Mesa's internal DRI interface,
# so it has to be the firmware's exact Mesa version (SC LIVE 4 5.3.0.x: 24.0.7). The firmware
# has glibc 2.39, the same as Ubuntu 24.04, whose armhf cross toolchain this uses.
# The approach and options follow QEngine's build_virgl_mesa.sh.
#
# Usage (Ubuntu 24.04, as root):  tools/build_mesa_virgl.sh [MESA_VERSION]
set -euo pipefail
VER=${1:-24.0.7}
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/mesa-virgl-build}

if ! dpkg --print-foreign-architectures | grep -qx armhf; then
    # Ubuntu's amd64 mirrors don't carry armhf; ports.ubuntu.com does.
    grep -q '^Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources ||
        sed -i '/^Types: deb/a Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources
    cat > /etc/apt/sources.list.d/ports-armhf.sources <<'SRC'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-security
Components: main universe
Architectures: armhf
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
    dpkg --add-architecture armhf
fi
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq crossbuild-essential-armhf meson ninja-build \
    python3-mako python3-yaml bison flex pkg-config curl xz-utils \
    libdrm-dev:armhf libexpat1-dev:armhf zlib1g-dev:armhf libzstd-dev:armhf
mkdir -p "$WORK/bin"
cat > "$WORK/bin/arm-linux-gnueabihf-pkg-config" <<'PC'
#!/bin/sh
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
exec pkg-config "$@"
PC
chmod +x "$WORK/bin/arm-linux-gnueabihf-pkg-config"
export PATH="$WORK/bin:/usr/bin:$PATH"

cd "$WORK"
[ -f "mesa-$VER.tar.xz" ] || curl -fLO "https://archive.mesa3d.org/mesa-$VER.tar.xz"
rm -rf "mesa-$VER"; tar xf "mesa-$VER.tar.xz"
cat > cross.txt <<'X'
[binaries]
c = 'arm-linux-gnueabihf-gcc'
cpp = 'arm-linux-gnueabihf-g++'
ar = 'arm-linux-gnueabihf-ar'
strip = 'arm-linux-gnueabihf-strip'
pkg-config = 'arm-linux-gnueabihf-pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'
[built-in options]
c_args = ['-march=armv7-a', '-mfpu=neon', '-mfloat-abi=hard']
cpp_args = ['-march=armv7-a', '-mfpu=neon', '-mfloat-abi=hard']
X
cd "mesa-$VER"
meson setup build --cross-file ../cross.txt -Dbuildtype=release -Dprefix=/usr -Dlibdir=lib \
    -Dgallium-drivers=virgl,swrast -Dvulkan-drivers= -Dplatforms= -Dglx=disabled -Degl=enabled \
    -Dgbm=enabled -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dllvm=disabled -Dshared-llvm=disabled \
    -Dvideo-codecs= -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dlmsensors=disabled \
    -Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled -Dshared-glapi=enabled
ninja -C build
mkdir -p "$HERE/assets/gl"
arm-linux-gnueabihf-strip -o "$HERE/assets/gl/swrast_dri.so" build/src/gallium/targets/dri/libgallium_dri.so
echo "$VER" > "$HERE/assets/gl/MESA_VERSION"
echo "built assets/gl/swrast_dri.so for Mesa $VER"
