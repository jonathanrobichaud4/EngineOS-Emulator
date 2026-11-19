// Running commands in WSL.

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
    // ------------------------------------------------------------------------------- WSL
    class Wsl
    {
        public const string RepoUrl = "https://github.com/jonathanrobichaud4/EngineOS-Emulator";
        public string Distro = "";   // empty = WSL's default distro
        public string EmuDir = "";   // where emu.sh lives inside WSL

        static string WslExe
        {
            get
            {
                // A 32-bit process sees System32 redirected; Sysnative reaches the real wsl.exe.
                string sysnative = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative", "wsl.exe");
                if (File.Exists(sysnative)) return sysnative;
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wsl.exe");
            }
        }

        public static bool Installed { get { return File.Exists(WslExe); } }

        // The bash script travels base64-encoded, so no Windows command-line quoting gets in the way.
        string Args(string script)
        {
            string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(script));
            string d = DistroArg();
            return d + "-u root -- bash -c \"echo " + b64 + " | base64 -d | bash\"";
        }

        public Task<int> Run(string script, Action<string> onLine)
        {
            var tcs = new TaskCompletionSource<int>();
            var p = new Process();
            p.StartInfo = new ProcessStartInfo(WslExe, Args(script))
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            };
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += (s, e) => { if (e.Data != null && onLine != null) onLine(Clean(e.Data)); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null && onLine != null) onLine(Clean(e.Data)); };
            p.Exited += (s, e) => { p.WaitForExit(); tcs.TrySetResult(p.ExitCode); p.Dispose(); };
            try
            {
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                if (onLine != null) onLine("Couldn't run WSL: " + ex.Message);
                tcs.TrySetResult(-1);
            }
            return tcs.Task;
        }

        public async Task<string> Capture(string script)
        {
            var sb = new StringBuilder();
            await Run(script, l => { lock (sb) sb.AppendLine(l); });
            return sb.ToString();
        }

        // wsl.exe's own messages are UTF-16 and show up with NULs when read as UTF-8.
        static string Clean(string s) { return s.Replace("\0", ""); }

        public static List<string> ListDistros()
        {
            // wsl.exe -l -q prints UTF-16 on most systems but UTF-8 when WSL_UTF8 is set or on some
            // versions, so read raw bytes and pick the encoding from what's there.
            var list = new List<string>();
            if (!Installed) return list;
            try
            {
                var p = new Process();
                p.StartInfo = new ProcessStartInfo(WslExe, "-l -q") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
                p.Start();
                var ms = new MemoryStream();
                p.StandardOutput.BaseStream.CopyTo(ms);
                p.WaitForExit(15000);
                byte[] b = ms.ToArray();
                int zeros = b.Count(x => x == 0);
                string all = zeros > b.Length / 4 ? Encoding.Unicode.GetString(b) : Encoding.UTF8.GetString(b);
                foreach (var l in all.Split('\n'))
                {
                    string t = new string(l.Where(c => c != '\0' && c != '\uFEFF' && !char.IsControl(c)).ToArray()).Trim();
                    if (t.Length > 0 && !t.StartsWith("docker-desktop")) list.Add(t);
                }
            }
            catch { }
            return list;
        }

        // Asks the distro for its own name from inside Linux; empty if it can't be started that way.
        public async Task<string> Probe(string distro)
        {
            string keep = Distro;
            Distro = distro;
            string name = (await Capture("echo \"ok:$WSL_DISTRO_NAME\"")).Trim();
            Distro = keep;
            foreach (var l in name.Split('\n'))
            {
                string t = l.Trim();
                if (t.StartsWith("ok:")) return t.Substring(3).Length > 0 ? t.Substring(3) : (distro.Length > 0 ? distro : "(default)");
            }
            return "";
        }

        public Process KeepAlive()
        {
            // WSL can stop a distro once no wsl.exe is attached; this keeps it up while the deck runs.
            string d = DistroArg();
            var psi = new ProcessStartInfo(WslExe, d + "-u root -- sleep infinity") { UseShellExecute = false, CreateNoWindow = true };
            try { return Process.Start(psi); } catch { return null; }
        }

        public static string ToWslPath(string win)
        {
            win = Path.GetFullPath(win);
            if (win.Length >= 2 && win[1] == ':')
                return "/mnt/" + char.ToLowerInvariant(win[0]) + win.Substring(2).Replace('\\', '/');
            throw new InvalidOperationException("Only files on a drive letter can be used (not " + win + ")");
        }

        // Moves the git checkout in the current folder to the release vWANT, or the newest release,
        // or main while there are no releases. $want and $force (--force for the app's own copy,
        // which may drop local edits) are set first. Prints "up to date (X)" or "updated X -> Y".
        public const string UpdateToRelease =
            "before=$(git describe --tags --always)\n" +
            "git fetch -q --tags --force origin || { echo 'update check failed (no internet?)'; exit 1; }\n" +
            "tag=; [ -n \"$want\" ] && git rev-parse -q --verify \"refs/tags/v$want\" >/dev/null && tag=v$want\n" +
            "[ -n \"$tag\" ] || tag=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)\n" +
            "if [ -n \"$tag\" ]; then git checkout -q $force --detach \"$tag\" || { echo \"could not switch to $tag (local changes?)\"; exit 1; }\n" +
            "else git checkout -q $force main && git merge -q --ff-only origin/main || { echo 'could not update (local changes?)'; exit 1; }; fi\n" +
            "after=$(git describe --tags --always)\n" +
            "if [ \"$before\" = \"$after\" ]; then echo \"up to date ($after)\"; else echo \"updated $before -> $after\"; fi\n";

        public static string Q(string s) { return "'" + s.Replace("'", "'\\''") + "'"; }

        // wsl.exe takes the name as-is and does not strip quotes, so -d "Ubuntu" looks for a distro
        // literally named "Ubuntu" with the quotes. Names can only use letters, digits, . - and _.
        public static bool ValidName(string n)
        {
            return n.Length > 0 && n.All(c => (c < 128 && char.IsLetterOrDigit(c)) || c == '.' || c == '-' || c == '_');
        }

        string DistroArg() { return ValidName(Distro) ? "-d " + Distro + " " : ""; }

        public string Emu(string profile, string args)
        {
            string p = (profile.Length > 0 && profile != "default") ? "--profile " + Q(profile) + " " : "";
            return "cd " + Q(EmuDir) + " && ./emu.sh " + p + args;
        }
    }
}
