// EngineOS Emulator for Windows: a window for the emulator that runs in WSL.
//
// Drop files on it instead of typing commands:
//   firmware .img          sets up the selected deck (stock Engine OS); inMusic's updater
//                          .exe or .zip works too
//   EngineX bundle/.img    installs EngineX on it
//   mod .tar.gz            installs and enables the mod (deck running)
//   folder                 plugs in as a USB drive (hold Shift for the SD card)
//   music files            copied to an emulator music folder that is plugged in as a drive
//
// Everything runs as root in the WSL distro through wsl.exe, so no passwords are asked. The
// emulator itself is the GitHub repo jonathanrobichaud4/EngineOS-Emulator; this app can install
// WSL and the emulator, and keeps the emulator on the release that matches it.
//
// Builds against .NET Framework 4.x (included in Windows 10/11): see build.sh. The files are
// described in docs/layout.md.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EngineOSEmulator
{
    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main()
        {
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
