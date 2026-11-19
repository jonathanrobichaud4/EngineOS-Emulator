// Deck models and decks. The model list itself (Codes, Names, FirmwareNote) is generated from
// models/ when the app is built (Models.generated.cs, see build.sh).

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
    // The deck models the emulator knows, by inMusic product code: Codes, Names and FirmwareNote
    // come from models/ (Models.generated.cs).
    static partial class DeckModels
    {
        public static string Name(string code) { int i = Array.IndexOf(Codes, code); return i < 0 ? code : Names[i]; }
    }

    // One deck (an emu.sh profile), as `emu.sh profiles` lists it.
    class DeckRow
    {
        public string Name, EngineX, Model = "JP21";
        public bool SetUp, Running;
        public string What { get { return !SetUp ? "not set up" : (EngineX.Length > 0 ? "EngineX " + EngineX : "stock Engine OS"); } }
        public override string ToString() { return Name + "  (" + DeckModels.Name(Model) + ", " + What + ")"; }

        public static DeckRow From(Dictionary<string, object> d)
        {
            return new DeckRow { Name = EmuJson.Str(d, "name", "default"), SetUp = EmuJson.Bool(d, "setup"), EngineX = EmuJson.Str(d, "enginex"),
                                 Model = EmuJson.Str(d, "model", "JP21"), Running = EmuJson.Bool(d, "running") };
        }
    }

    // Reading what emu.sh prints with --json (docs/cli.md).
    static class EmuJson
    {
        static readonly System.Web.Script.Serialization.JavaScriptSerializer Json = new System.Web.Script.Serialization.JavaScriptSerializer();

        // The JSON object or array in the output, or null when there isn't one (an emulator from
        // before 1.2, which prints text).
        public static object Parse(string output)
        {
            string t = output.Trim();
            if (t.Length == 0 || (t[0] != '{' && t[0] != '[')) return null;
            try { return Json.DeserializeObject(t); } catch { return null; }
        }

        public static string Str(Dictionary<string, object> d, string k, string def = "")
        {
            object v;
            return d != null && d.TryGetValue(k, out v) && v is string ? (string)v : def;
        }

        public static bool Bool(Dictionary<string, object> d, string k)
        {
            object v;
            return d != null && d.TryGetValue(k, out v) && v is bool && (bool)v;
        }

        public static IEnumerable<Dictionary<string, object>> List(object o)
        {
            var a = o as object[];
            if (a == null) yield break;
            foreach (var x in a) { var d = x as Dictionary<string, object>; if (d != null) yield return d; }
        }

        // The object's strings as key=value, with true / false as yes / no, as the text output had.
        public static Dictionary<string, string> Flat(Dictionary<string, object> d)
        {
            var r = new Dictionary<string, string>();
            foreach (var kv in d)
            {
                if (kv.Value is string) r[kv.Key] = (string)kv.Value;
                else if (kv.Value is bool) r[kv.Key] = (bool)kv.Value ? "yes" : "no";
            }
            return r;
        }
    }
}
