#!/bin/sh
# Builds SCLive4Emulator.exe on Linux with Mono's C# compiler. The exe runs on the .NET
# Framework 4.8 that ships with Windows 10 and 11.  sudo apt install mono-mcs mono-devel
set -e
cd "$(dirname "$0")"
mcs -sdk:4.5 -target:winexe -optimize+ -out:SCLive4Emulator.exe -win32icon:app.ico \
    -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:System.Core.dll SCLive4Emulator.cs
echo "built windows/SCLive4Emulator.exe"
