// Updating the app itself and the emulator in WSL.

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
    partial class MainForm
    {
        // Each release (vX.Y.Z) carries version.txt with its version. A newer one than this app's
        // (BuildInfo.Version, set by windows/build.sh) means an update: download that release's exe
        // next to this one, and once this app has quit, a small batch file moves it into place and
        // starts it. Test builds ("dev") never update.
        const string AppRelease = "https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/";

        // Installed with the setup program: keep the version in Windows' installed-apps list right
        // after the app has updated itself.
        static void NoteInstalledVersion()
        {
            if (BuildInfo.Version == "dev") return;
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\EngineOSEmulator", true))
                {
                    if (k == null) return;
                    string dir = (k.GetValue("InstallLocation") as string ?? "").TrimEnd('\\');
                    if (string.Equals(dir, Path.GetDirectoryName(Application.ExecutablePath), StringComparison.OrdinalIgnoreCase))
                        k.SetValue("DisplayVersion", BuildInfo.Version);
                }
            }
            catch { }
        }

        // True if version a (like 1.2.10) is newer than b.
        static bool Newer(string a, string b)
        {
            var x = a.Split('.'); var y = b.Split('.');
            for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                int p = 0, q = 0;
                if (i < x.Length) int.TryParse(x[i], out p);
                if (i < y.Length) int.TryParse(y[i], out q);
                if (p != q) return p > q;
            }
            return false;
        }

        async Task CheckAppUpdate(bool manual)
        {
            if (BuildInfo.Version == "dev")
            {
                if (manual) Log("This is a test build (not from a release), so it doesn't update itself.");
                return;
            }
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                string latest;
                using (var wc = new WebClient())
                {
                    wc.Headers[HttpRequestHeader.CacheControl] = "no-cache";
                    latest = (await wc.DownloadStringTaskAsync(AppRelease + "version.txt")).Trim();
                }
                if (latest.Length == 0 || !char.IsDigit(latest[0])) { Log("Couldn't read the latest app version."); return; }
                if (!Newer(latest, BuildInfo.Version))
                {
                    settings.Remove("UpdateAttempt"); Settings.Save(settings);
                    Log("The app is up to date (v" + BuildInfo.Version + ").");
                    return;
                }
                // Already tried this version and it's still not running: don't loop.
                string tried;
                if (!manual && settings.TryGetValue("UpdateAttempt", out tried) && tried == latest)
                {
                    Log("The update to v" + latest + " didn't install last time. Use Check for app updates to try again, or download it from the release page.");
                    return;
                }

                string exe = Application.ExecutablePath, dir = Path.GetDirectoryName(exe);
                string fresh = Path.Combine(dir, "EngineOSEmulator.update.exe");
                try { File.WriteAllText(fresh, ""); }
                catch
                {
                    Log("A new app version is out, but this folder isn't writable (" + dir + "). Download it from the Windows app release on GitHub.");
                    return;
                }
                Log("Downloading " + AppInfo.Name + " v" + latest + "...");
                using (var wc = new WebClient()) await wc.DownloadFileTaskAsync(AppRelease + AppInfo.Exe, fresh);
                if (new FileInfo(fresh).Length < 20000) { File.Delete(fresh); Log("The app download looked wrong; skipped."); return; }

                string pid = Process.GetCurrentProcess().Id.ToString();
                string bat = Path.Combine(Path.GetTempPath(), "engineos-emulator-update.cmd");
                File.WriteAllText(bat,
                    "@echo off\r\n" +
                    ":wait\r\n" +
                    "tasklist /FI \"PID eq " + pid + "\" 2>nul | find \"" + pid + "\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
                    "move /y \"" + fresh + "\" \"" + exe + "\" >nul\r\n" +
                    "start \"\" \"" + exe + "\"\r\n" +
                    "del \"%~f0\"\r\n");
                Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"") { CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden, UseShellExecute = false });
                settings["UpdateAttempt"] = latest; Settings.Save(settings);
                Log("Restarting with the new app...");
                await Task.Delay(800);
                Application.Exit();
            }
            catch (Exception ex)
            {
                Log("Couldn't check for app updates: " + ex.Message);
            }
        }

        // Moves the emulator in WSL to the release matching this app (or the newest release, or main
        // before there are any). The copy this app installed in /opt is the app's own, so local edits
        // there are overwritten; your decks, settings and drives live in ignored folders (rootfs*,
        // state*, drives.txt) and are never touched.
        async Task UpdateEmulator(bool quiet)
        {
            string dir = Wsl.Q(wsl.EmuDir);
            string script =
                "cd " + dir + " || exit 1\n" +
                "git rev-parse --git-dir >/dev/null 2>&1 || { echo 'not a git checkout, skipping update'; exit 0; }\n" +
                "git config --global --add safe.directory " + dir + " 2>/dev/null\n" +
                // Clones from before the repository was renamed get its new address.
                "case $(git remote get-url origin) in *jonathanrobichaud4/sclive4-emulator*) git remote set-url origin " + Wsl.RepoUrl + " ;; esac\n" +
                "want=" + (BuildInfo.Version == "dev" ? "" : BuildInfo.Version) + "\n" +
                "force=" + (wsl.EmuDir == AppInfo.EmuDir || wsl.EmuDir == AppInfo.OldEmuDir ? "--force" : "") + "\n" +
                Wsl.UpdateToRelease;
            var lines = new List<string>();
            int rc = await wsl.Run(script, l => lines.Add(l));
            bool news = lines.Any(l => !l.StartsWith("up to date"));
            if (!quiet || news || rc != 0) foreach (var l in lines) Log("Emulator update: " + l);
            else if (lines.Count > 0) Log("Emulator " + lines[0]);
        }

        async Task ShowEngineLog()
        {
            string state = CurrentProfile == "default" ? "state" : "state-" + CurrentProfile;
            await wsl.Run("tail -n 80 " + Wsl.Q(wsl.EmuDir + "/" + state + "/engine.log") + " | cut -c1-160", Log);
        }
    }
}
