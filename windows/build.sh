#!/bin/sh
# Builds SCLive4Emulator.exe on Linux with Mono's C# compiler. The exe runs on the .NET
# Framework 4.8 that ships with Windows 10 and 11.  sudo apt install mono-mcs mono-devel
# BUILD_COMMIT (the release build sets it to the git commit) is what the app compares with the
# release's version.txt to update itself; a local build is "dev" and never replaces itself.
set -e
cd "$(dirname "$0")"
info=$(mktemp --suffix=.cs)
trap 'rm -f "$info"' EXIT
printf 'static class BuildInfo { public static readonly string Commit = "%s"; }\n' "${BUILD_COMMIT:-dev}" > "$info"
mcs -sdk:4.5 -target:winexe -optimize+ -out:SCLive4Emulator.exe -win32icon:app.ico \
    -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:System.Core.dll SCLive4Emulator.cs "$info"
echo "built windows/SCLive4Emulator.exe"
