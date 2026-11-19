// Start-up (finding WSL and the emulator) and reading the deck's state.

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
        // ---------------------------------------------------------------- start-up and state
        void ActionsEnabled(bool on)
        {
            foreach (var c in new Control[] { startButton, stopButton, rebootButton, deckButton, consoleButton, profileBox }) c.Enabled = on;
        }

        string legacyDir = "";

        async Task Init()
        {
            ActionsEnabled(false);
            NoteInstalledVersion();
            if (Option("AutoUpdateApp", true)) _ = CheckAppUpdate(false);
            else Log("Automatic app updates are off (More... > Update this app automatically).");
            if (!Wsl.Installed)
            {
                ShowSetup("WSL isn't installed. The emulator runs in WSL (Windows Subsystem for Linux), so that comes first. " +
                          "It needs admin rights and a restart afterwards.", "Install WSL");
                statusLabel.Text = "WSL not installed";
                return;
            }
            var distros = Wsl.ListDistros();
            string saved;
            settings.TryGetValue("Distro", out saved);
            // Try the saved one, then Ubuntu, then the rest, then WSL's default; use the first that runs.
            var order = new List<string>();
            if (!string.IsNullOrEmpty(saved)) order.Add(saved);
            order.AddRange(distros.Where(d => d.StartsWith("Ubuntu", StringComparison.OrdinalIgnoreCase)));
            order.AddRange(distros);
            order.Add("");
            string chosen = null;
            foreach (var d in order.Distinct().Where(x => x.Length == 0 || Wsl.ValidName(x)))
            {
                statusLabel.Text = "Checking WSL " + (d.Length > 0 ? d : "default") + "...";
                string name = await wsl.Probe(d);
                if (name.Length == 0) continue;
                if (name.StartsWith("docker-desktop")) continue;
                chosen = name == "(default)" ? "" : name;
                break;
            }
            if (chosen == null)
            {
                ShowSetup("WSL has no Linux installed that can be started. Ubuntu is what the emulator is tested on.", "Install Ubuntu");
                statusLabel.Text = "No Linux distro in WSL";
                Log("WSL distros found: " + (distros.Count > 0 ? string.Join(", ", distros) : "none"));
                return;
            }
            wsl.Distro = chosen;
            settings["Distro"] = wsl.Distro;
            Settings.Save(settings);
            Log("Using WSL distro: " + (chosen.Length > 0 ? chosen : "(default)"));

            string emuDir;
            settings.TryGetValue("EmuDir", out emuDir);
            // An install from before the rename: /opt/sclive4-emulator becomes /opt/engineos-emulator
            // (with a link at the old path), once no deck is running from it.
            await wsl.Run("o=" + AppInfo.OldEmuDir + " d=" + AppInfo.EmuDir + "; " +
                "if [ -d \"$o\" ] && [ ! -L \"$o\" ] && [ ! -e \"$d\" ] && ! grep -q \" $o/\" /proc/mounts; then " +
                "mv \"$o\" \"$d\" && ln -s \"$d\" \"$o\" && echo \"Moved $o to $d.\"; fi", Log);
            if (emuDir == AppInfo.OldEmuDir) emuDir = AppInfo.EmuDir;
            // A current emulator has the commands this app uses (info, profiles, identify, mod-install).
            string found = (await wsl.Capture(
                "for d in " + (string.IsNullOrEmpty(emuDir) ? "" : Wsl.Q(emuDir) + " ") +
                AppInfo.EmuDir + " " + AppInfo.OldEmuDir + " /root/sclive4-emulator /home/*/sclive4-emulator /home/*/enginex-emu; do " +
                "[ -x \"$d/emu.sh\" ] || continue; " +
                "if grep -q '^cmd_info()' \"$d/emu.sh\"; then echo \"current $d\"; else echo \"old $d\"; fi; done")).Trim();
            var lines = found.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            var current = lines.FirstOrDefault(l => l.StartsWith("current "));
            var older = lines.FirstOrDefault(l => l.StartsWith("old "));
            if (current == null && older != null)
            {
                legacyDir = older.Substring(4);
                ShowSetup("Found an older copy of the emulator in " + legacyDir + ". This app needs the current one: it'll be installed in " +
                          AppInfo.EmuDir + " and your deck, settings and drives moved over.", "Update emulator");
                statusLabel.Text = "Emulator needs updating";
                return;
            }
            if (current == null)
            {
                ShowSetup("The emulator isn't installed in WSL (" + wsl.Distro + ") yet. It'll be downloaded from GitHub into " + AppInfo.EmuDir + ".",
                          "Install emulator");
                statusLabel.Text = "Emulator not installed";
                return;
            }
            found = current.Substring(8);
            wsl.EmuDir = found.Split('\n')[0].Trim();
            settings["EmuDir"] = wsl.EmuDir;
            Settings.Save(settings);
            setupBar.Visible = setupGap.Visible = false;
            ActionsEnabled(true);
            Log("Emulator: " + wsl.EmuDir + " in WSL " + wsl.Distro);
            if (Option("AutoUpdate", true)) { statusLabel.Text = "Checking for emulator updates..."; await UpdateEmulator(true); }
            await LoadProfiles();
            await RefreshAll();
            pollTimer.Start();
            if (Option("AutoStart", false))
            {
                if (Get("running", "no") == "yes") Log("The deck is already running.");
                else if (Get("setup", "yes") == "no") Log("Not starting automatically: this deck isn't set up yet.");
                else await StartDeck();
            }
        }

        void ShowSetup(string text, string button)
        {
            setupText.Text = text;
            setupButton.Text = button;
            setupBar.Visible = setupGap.Visible = true;
        }

        async Task SetupAction()
        {
            string t = setupButton.Text;
            if (t == "Install WSL" || t == "Install Ubuntu")
            {
                var psi = new ProcessStartInfo("wsl.exe", "--install -d Ubuntu") { UseShellExecute = true, Verb = "runas" };
                try { Process.Start(psi); }
                catch (Exception ex) { Log("Couldn't start the WSL installer: " + ex.Message); return; }
                MessageBox.Show(this,
                    "The WSL installer is running in its own window.\n\nWhen it finishes, restart Windows if it asks, open Ubuntu once from the Start menu " +
                    "to create your Linux user, then open this app again.", "Installing WSL", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (t == "Update emulator" && legacyDir.Length > 0)
            {
                SetBusy(true, "Updating the emulator");
                string o = Wsl.Q(legacyDir);
                int mrc = await wsl.Run(
                    "set -e; command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }; " +
                    o + "/emu.sh stop >/dev/null 2>&1 || :; " +
                    "[ -d " + AppInfo.EmuDir + "/.git ] || git clone " + Wsl.RepoUrl + " " + AppInfo.EmuDir + "; " +
                    "for x in rootfs state drives.txt; do " +
                    "  if [ -e " + o + "/$x ] && [ ! -e " + AppInfo.EmuDir + "/$x ]; then mv " + o + "/$x " + AppInfo.EmuDir + "/ && echo \"moved $x\"; fi; " +
                    "done; echo 'Done. The old folder " + legacyDir.Replace("'", "") + " can be deleted.'", Log);
                SetBusy(false);
                legacyDir = "";
                settings["EmuDir"] = AppInfo.EmuDir;
                Settings.Save(settings);
                if (mrc == 0) await Init(); else Log("Updating failed; see above.");
                return;
            }
            if (t == "Install emulator")
            {
                SetBusy(true, "Installing the emulator");
                int rc = await wsl.Run(
                    "set -e; command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }; " +
                    "git clone " + Wsl.RepoUrl + " " + AppInfo.EmuDir + " && echo 'Installed in " + AppInfo.EmuDir + ".'", Log);
                SetBusy(false);
                if (rc == 0) await Init();
                else Log("Installing the emulator failed; see above.");
            }
        }

        List<DeckRow> decks = new List<DeckRow>();

        async Task<List<DeckRow>> ReadDecks()
        {
            string outp = await wsl.Capture(wsl.Emu("default", "profiles --json"));
            var json = EmuJson.Parse(outp);
            if (json != null) return EmuJson.List(json).Select(DeckRow.From).ToList();
            // An emulator from before 1.2 (until it updates): tab-separated lines.
            var list = new List<DeckRow>();
            foreach (var line in outp.Split('\n'))
            {
                var f = line.Trim('\r').Split('\t');
                if (f.Length < 3 || f[0].Length == 0) continue;
                list.Add(new DeckRow { Name = f[0], SetUp = f[1] == "yes", EngineX = f[2],
                                       Model = f.Length > 3 && f[3].Length > 0 ? f[3] : "JP21", Running = f.Length > 4 && f[4] == "yes" });
            }
            return list;
        }

        async Task LoadProfiles(string select = null)
        {
            string keep = select ?? (settings.ContainsKey("Profile") ? settings["Profile"] : CurrentProfile);
            decks = await ReadDecks();
            var items = decks.Select(d => d.ToString()).ToList();
            // No decks at all yet: offer the default one, to set up by dropping a firmware file.
            if (items.Count == 0) items.Add(new DeckRow { Name = "default", EngineX = "" }.ToString());
            profileBox.Items.Clear();
            profileBox.Items.AddRange(items.ToArray());
            profileBox.SelectedItem = items.FirstOrDefault(i => i.StartsWith(keep + "  (")) ?? items[0];
        }

        async Task RefreshAll()
        {
            if (wsl.EmuDir.Length == 0) return;
            await Poll(true);
            await LoadDrives();
        }

        async Task Poll(bool force = false)
        {
            if (wsl.EmuDir.Length == 0 || polling || (busy && !force)) return;
            polling = true;
            try
            {
                string outp = await wsl.Capture(wsl.Emu(CurrentProfile, "info --json"));
                var json = EmuJson.Parse(outp) as Dictionary<string, object>;
                Dictionary<string, string> d;
                if (json != null)
                {
                    d = EmuJson.Flat(json);
                    object n;
                    netInfo = json.TryGetValue("network", out n) ? n as Dictionary<string, object> : null;
                }
                else
                {
                    // An emulator from before 1.2: key=value lines.
                    d = new Dictionary<string, string>();
                    foreach (var l in outp.Split('\n'))
                    {
                        int i = l.IndexOf('=');
                        if (i > 0) d[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
                    }
                }
                info = d;
                bool setup = Get("setup", "no") == "yes", running = Get("running", "no") == "yes";
                string sys = !setup ? "not set up: drop the firmware .img or updater here"
                           : Get("enginex", "").Length > 0 ? "EngineX " + Get("enginex", "") : "stock Engine OS";
                string state = !running ? "stopped" : Get("engine", "down") == "up" ? "running" : "starting";
                string err = Get("engine_error", "");
                if (!busy && err.Length > 0)
                {
                    statusLabel.Text = "Engine stopped: " + (err.Length > 70 ? err.Substring(0, 70) + "..." : err);
                    SetDot("error");
                    if (err != lastEngineError) Log("Engine stopped: " + err);
                }
                else if (!busy)
                {
                    statusLabel.Text = state + "  \u00B7  " + sys + (running && Get("ip", "").Length > 0 ? "  \u00B7  deck " + Get("ip", "") : "");
                    SetDot(state);
                }
                lastEngineError = err;
                startButton.Enabled = !busy && setup && !running;
                stopButton.Enabled = !busy && running;
                rebootButton.Enabled = !busy && running;
                deckButton.Enabled = running;
                consoleButton.Enabled = running && Get("enginex", "").Length > 0;
            }
            finally { polling = false; }
        }

        async Task LoadDrives()
        {
            string outp = await wsl.Capture(wsl.Emu(CurrentProfile, "drive list --json"));
            drivesList.Items.Clear();
            var json = EmuJson.Parse(outp);
            if (json != null)
            {
                foreach (var d in EmuJson.List(json))
                    drivesList.Items.Add(new ListViewItem(new[] { EmuJson.Str(d, "label"), EmuJson.Str(d, "kind") == "sd" ? "SD card" : "USB",
                                                                  EmuJson.Str(d, "folder") + (EmuJson.Bool(d, "ok") ? "" : "  (missing)") }));
            }
            else
            {
                // An emulator from before 1.2: "  LABEL  KIND  FOLDER" lines.
                foreach (var line in outp.Split('\n'))
                {
                    var t = line.Trim();
                    if (t.Length == 0 || t.StartsWith("emu:")) continue;
                    var parts = t.Split(new[] { ' ' }, 3, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 3) continue;
                    drivesList.Items.Add(new ListViewItem(new[] { parts[0], parts[1] == "sd" ? "SD card" : "USB", parts[2].Trim() }));
                }
            }
            drivesEmpty.Visible = drivesList.Items.Count == 0;
        }

        // ---------------------------------------------------------------- actions
        async Task StartDeck()
        {
            if (keepAlive == null || keepAlive.HasExited) keepAlive = wsl.KeepAlive();
            int rc = await Emu("Starting", "start");
            if (rc == 0 && Option("OpenDeck", true))
            {
                Log("Engine takes a minute or two to show its first screen. Opening the deck page...");
                OpenUrl(Get("deck_url", "http://localhost:8090/"));
            }
            else if (rc == 0) Log("Deck started. Engine takes a minute or two to show its first screen.");
        }
    }
}
