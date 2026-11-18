#!/bin/sh
# Builds EngineOSEmulator.exe on Linux with Mono's C# compiler. The exe runs on the .NET
# Framework 4.8 that ships with Windows 10 and 11.  sudo apt install mono-mcs mono-devel
# BUILD_VERSION (a release build sets it from VERSION) is what the app compares with the newest
# release to update itself; any other build is "dev" and never replaces itself. BUILD_COMMIT is
# shown in the app.
set -e
cd "$(dirname "$0")"
info=$(mktemp --suffix=.cs)
trap 'rm -f "$info"' EXIT
v=${BUILD_VERSION:-dev}
{
    # File properties in Explorer (attributes have to come first).
    printf '[assembly: System.Reflection.AssemblyTitle("EngineOS Emulator")]\n[assembly: System.Reflection.AssemblyProduct("EngineOS Emulator")]\n'
    case $v in [0-9]*) printf '[assembly: System.Reflection.AssemblyVersion("%s.0")]\n[assembly: System.Reflection.AssemblyFileVersion("%s.0")]\n' "$v" "$v" ;; esac
    printf 'static class BuildInfo { public static readonly string Version = "%s", Commit = "%s"; }\n' "$v" "${BUILD_COMMIT:-dev}"
} > "$info"
mcs -sdk:4.5 -target:winexe -optimize+ -out:EngineOSEmulator.exe -win32icon:app.ico \
    -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:System.Core.dll EngineOSEmulator.cs "$info"
echo "built windows/EngineOSEmulator.exe"
