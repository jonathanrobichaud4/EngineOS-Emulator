// The app's settings file.

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
    class Settings
    {
        static string Dir { get { return AppInfo.Folder(Environment.SpecialFolder.ApplicationData); } }
        static string FilePath { get { return Path.Combine(Dir, "settings.ini"); } }
        public static Dictionary<string, string> Load()
        {
            var d = new Dictionary<string, string>();
            try { foreach (var l in File.ReadAllLines(FilePath)) { int i = l.IndexOf('='); if (i > 0) d[l.Substring(0, i)] = l.Substring(i + 1); } } catch { }
            return d;
        }
        public static void Save(Dictionary<string, string> d)
        {
            try { Directory.CreateDirectory(Dir); File.WriteAllLines(FilePath, d.Select(kv => kv.Key + "=" + kv.Value)); } catch { }
        }
        public static string MusicFolder
        {
            get
            {
                string m = AppInfo.Folder(Environment.SpecialFolder.MyMusic);
                Directory.CreateDirectory(m);
                return m;
            }
        }
    }
}
