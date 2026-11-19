// The app's name and folders, in one place.

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
    // The app's name, in one place, and the folders from before the rename (SC LIVE 4 Emulator),
    // which are moved to the new names the first time they're used.
    static class AppInfo
    {
        public const string Name = "EngineOS Emulator";
        public const string OldName = "SC LIVE 4 Emulator";
        public const string Exe = "EngineOSEmulator.exe";
        public const string EmuDir = "/opt/engineos-emulator";
        public const string OldEmuDir = "/opt/sclive4-emulator";
        public static string Folder(Environment.SpecialFolder root)
        {
            string b = Environment.GetFolderPath(root), old = Path.Combine(b, OldName), now = Path.Combine(b, Name);
            if (Directory.Exists(old) && !Directory.Exists(now))
            {
                try { Directory.Move(old, now); } catch { return old; }   // in use: try again next time
            }
            return now;
        }
    }
}
