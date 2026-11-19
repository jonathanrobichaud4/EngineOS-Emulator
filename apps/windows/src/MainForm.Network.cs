// The deck on your network (Engine Link, Engine DJ, SoundSwitch, lighting apps): WSL's mirrored
// networking puts WSL on Windows' own networks, the Hyper-V firewall lets other devices reach it,
// and emu.sh's bridge (engine/linkbridge.py) does the rest. docs/networking.md has the details.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EngineOSEmulator
{
    static class WslNetwork
    {
        static string ConfigPath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".wslconfig"); } }

        // Mirrored networking needs Windows 11 22H2 (build 22621) or later.
        public static bool Supported
        {
            get
            {
                try
                {
                    using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                    {
                        int build;
                        return k != null && int.TryParse(k.GetValue("CurrentBuildNumber") as string, out build) && build >= 22621;
                    }
                }
                catch { return false; }
            }
        }

        public static bool Mirrored
        {
            get
            {
                try
                {
                    if (!File.Exists(ConfigPath)) return false;
                    string section = "";
                    foreach (var raw in File.ReadAllLines(ConfigPath))
                    {
                        var l = raw.Trim();
                        if (l.StartsWith("[")) { section = l.ToLowerInvariant(); continue; }
                        int eq = l.IndexOf('=');
                        if (section == "[wsl2]" && eq > 0 && l.Substring(0, eq).Trim().ToLowerInvariant() == "networkingmode")
                            return l.Substring(eq + 1).Trim().ToLowerInvariant() == "mirrored";
                    }
                }
                catch { }
                return false;
            }
        }

        // Sets networkingMode in [wsl2], keeping everything else in the file as it was.
        public static void SetMirrored(bool on)
        {
            var lines = File.Exists(ConfigPath) ? File.ReadAllLines(ConfigPath).ToList() : new List<string>();
            int wsl2 = -1, end = lines.Count, found = -1;
            for (int i = 0; i < lines.Count; i++)
            {
                var l = lines[i].Trim();
                if (l.StartsWith("["))
                {
                    if (wsl2 >= 0 && end == lines.Count) end = i;
                    if (l.ToLowerInvariant() == "[wsl2]") { wsl2 = i; end = lines.Count; }
                    continue;
                }
                int eq = l.IndexOf('=');
                if (wsl2 >= 0 && end == lines.Count && eq > 0 && l.Substring(0, eq).Trim().ToLowerInvariant() == "networkingmode") found = i;
            }
            if (found >= 0)
            {
                if (on) lines[found] = "networkingMode=mirrored"; else lines.RemoveAt(found);
            }
            else if (on)
            {
                if (wsl2 < 0) { if (lines.Count > 0 && lines[lines.Count - 1].Trim().Length > 0) lines.Add(""); lines.Add("[wsl2]"); end = lines.Count; }
                lines.Insert(end, "networkingMode=mirrored");
            }
            File.WriteAllLines(ConfigPath, lines.ToArray(), new UTF8Encoding(false));
        }

        // Lets other devices on the network reach WSL (the Hyper-V firewall blocks them by default).
        // Asks Windows for admin rights; false if that was declined.
        public static bool AllowInbound()
        {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Command \"Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow\"")
            { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            try
            {
                using (var p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode == 0; }
            }
            catch { return false; }
        }
    }

    partial class MainForm
    {
        // What info --json says about the deck on the network: mode ("lan", "local", "off"), name, addresses.
        Dictionary<string, object> netInfo;

        string NetworkMenuText()
        {
            string t = "Put the deck on my network";
            if (!WslNetwork.Mirrored || netInfo == null || EmuJson.Str(netInfo, "mode") != "lan" || Get("running", "no") != "yes") return t;
            object raw;
            var addrs = ((netInfo.TryGetValue("addresses", out raw) ? raw as object[] : null) ?? new object[0]).Select(x => x.ToString()).ToArray();
            return t + "  (seen as " + EmuJson.Str(netInfo, "name") + (addrs.Length > 0 ? " at " + string.Join(", ", addrs) : "") + ")";
        }

        async Task SetOnNetwork(bool on)
        {
            if (on && !WslNetwork.Supported)
            {
                MessageBox.Show(this, "Putting the deck on your network needs Windows 11 (version 22H2 or later): it uses WSL's mirrored networking, which older Windows doesn't have.\n\nThe deck still has the internet.",
                                AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (on && MessageBox.Show(this, "This lets Denon gear, Engine DJ, SoundSwitch and lighting apps on your network see the deck.\n\n" +
                                      "It switches WSL to mirrored networking (in " + Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\.wslconfig), " +
                                      "lets other devices reach WSL through Windows' Hyper-V firewall (Windows asks for permission), and restarts WSL, which stops the deck for a moment.\n\nGo ahead?",
                                      AppInfo.Name, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            bool wasRunning = Get("running", "no") == "yes";
            SetBusy(true, on ? "Putting the deck on your network" : "Taking the deck off your network");
            try
            {
                if (on)
                {
                    Log("Allowing other devices on the network to reach WSL (Hyper-V firewall)...");
                    if (!WslNetwork.AllowInbound())
                        Log("That wasn't allowed, so devices may not be able to reach the deck. Try again and accept the Windows prompt.");
                }
                bool change = WslNetwork.Mirrored != on;
                if (change)
                {
                    WslNetwork.SetMirrored(on);
                    Log(on ? "WSL now uses mirrored networking." : "WSL is back to its own private network.");
                }
                await wsl.Run(wsl.Emu(CurrentProfile, "network " + (on ? "on" : "local")), Log);
                if (change)
                {
                    if (wasRunning) await wsl.Run(wsl.Emu(CurrentProfile, "stop"), Log);
                    StopKeepAlive();
                    Log("Restarting WSL...");
                    await Wsl.Shutdown();
                    if (wasRunning) { SetBusy(false); await StartDeck(); return; }
                }
            }
            catch (Exception ex) { Log("Couldn't change the network setting: " + ex.Message); }
            SetBusy(false);
            await RefreshAll();
        }
    }
}
