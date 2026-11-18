#!/bin/bash
# Builds "SC LIVE 4 Emulator.app" (Apple Silicon and Intel) from SCLive4Emulator.swift.
# Needs Xcode or the Command Line Tools (xcode-select --install; Homebrew installs them too).
#   mac/app/build.sh [OUTDIR]      default OUTDIR: mac/app/build
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-build}
APP="$OUT/SC LIVE 4 Emulator.app"
mkdir -p "$OUT"
rm -rf "$APP" "$OUT/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" -o "$OUT/SCLive4Emulator-$arch" SCLive4Emulator.swift
done
lipo -create -output "$APP/Contents/MacOS/SCLive4Emulator" "$OUT"/SCLive4Emulator-arm64 "$OUT"/SCLive4Emulator-x86_64
rm -f "$OUT"/SCLive4Emulator-arm64 "$OUT"/SCLive4Emulator-x86_64

cp Info.plist "$APP/Contents/Info.plist"
# The launcher and the VM definition travel inside the app.
cp ../sclive4-emu ../lima.yaml "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/sclive4-emu"

# Icon: every size macOS wants, from icon.png (1024 x 1024).
set_ico="$OUT/AppIcon.iconset"; mkdir -p "$set_ico"
for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$set_ico/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) icon.png --out "$set_ico/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_ico" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$set_ico"

# Ad-hoc signature: Apple Silicon won't run an unsigned binary. (Not notarized: the first time,
# right-click the app > Open.)
codesign --force --sign - "$APP"
echo "built $APP"
