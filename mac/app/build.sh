#!/bin/bash
# Builds "EngineOS Emulator.app" (Apple Silicon and Intel) from EngineOSEmulator.swift.
# The name lives in AppInfo (EngineOSEmulator.swift), Info.plist and NAME/BIN here.
# Needs Xcode or the Command Line Tools (xcode-select --install; Homebrew installs them too).
#   mac/app/build.sh [OUTDIR]      default OUTDIR: mac/app/build
# BUILD_COMMIT (the release build sets it to the git commit) is what the app compares with the
# release's version.txt to update itself; a local build is "dev" and never replaces itself.
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-build}
NAME="EngineOS Emulator"; BIN=EngineOSEmulator
APP="$OUT/$NAME.app"
mkdir -p "$OUT"
rm -rf "$APP" "$OUT/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

printf 'enum BuildInfo { static let commit = "%s" }\n' "${BUILD_COMMIT:-dev}" > "$OUT/BuildInfo.swift"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" -o "$OUT/$BIN-$arch" \
        $BIN.swift "$OUT/BuildInfo.swift"
done
lipo -create -output "$APP/Contents/MacOS/$BIN" "$OUT/$BIN-arm64" "$OUT/$BIN-x86_64"
rm -f "$OUT/$BIN-arm64" "$OUT/$BIN-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
[ "${BUILD_COMMIT:-dev}" = dev ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_COMMIT:0:7}" "$APP/Contents/Info.plist"
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
