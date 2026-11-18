// SC LIVE 4 Emulator for Windows: a window for the emulator that runs in WSL.
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
// emulator itself is the GitHub repo jonathanrobichaud4/sclive4-emulator; this app can install
// WSL and the emulator, and update the emulator with git pull.
//
// Builds against .NET Framework 4.x (included in Windows 10/11): see build.sh next to this file.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SCLive4Emulator
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

    // ------------------------------------------------------------------------------- WSL
    class Wsl
    {
        public const string RepoUrl = "https://github.com/jonathanrobichaud4/sclive4-emulator";
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

    class Settings
    {
        static string Dir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SC LIVE 4 Emulator"); } }
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
                string m = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "SC LIVE 4 Emulator");
                Directory.CreateDirectory(m);
                return m;
            }
        }
    }

    // ------------------------------------------------------------------------------- window
    class MainForm : Form
    {
        readonly Wsl wsl = new Wsl();
        Dictionary<string, string> settings;
        Dictionary<string, string> info = new Dictionary<string, string>();
        Process keepAlive;
        bool busy, polling;

        // controls
        Control setupBar, setupGap;
        Label setupText;
        Button setupButton;
        ComboBox profileBox;
        Label statusLabel;
        Button startButton, stopButton, rebootButton, deckButton, consoleButton;
        Panel dropZone;
        Label dropText;
        ListView drivesList;
        TextBox logBox;
        Timer pollTimer;

        static readonly Color Bg = Color.FromArgb(24, 26, 29);
        static readonly Color Panel1 = Color.FromArgb(34, 37, 41);
        static readonly Color Fg = Color.FromArgb(222, 225, 229);
        static readonly Color Dim = Color.FromArgb(140, 146, 154);

        public MainForm()
        {
            // Sizes below are written for 100% scaling (96 dpi). WinForms scales them up to the
            // display's setting when the layout resumes, the same way designer-made forms do.
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Text = "SC LIVE 4 Emulator";
            Font = new Font("Segoe UI", 9.5f);
            ClientSize = new Size(980, 720);
            MinimumSize = new Size(820, 600);
            BackColor = Bg;
            ForeColor = Fg;
            AllowDrop = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            settings = Settings.Load();
            Build();
            ResumeLayout(false);
            PerformLayout();
            RestoreWindow();
            DragEnter += OnDragEnter;
            DragDrop += OnDragDrop;
            Shown += async (s, e) => await Init();
            FormClosing += OnClosing;
        }

        // ---------------------------------------------------------------- window position
        bool startMaximized;
        SplitContainer body;
        bool placing;

        // Where the divider between the files area and the log sits, as a share of the height,
        // so it looks the same after resizing, maximising or a different display scale.
        void PlaceDivider()
        {
            double f;
            if (!double.TryParse(Get(settings, "LogSplit"), System.Globalization.NumberStyles.Float,
                                 System.Globalization.CultureInfo.InvariantCulture, out f) || f < 0.2 || f > 0.85) f = 0.55;
            int min1 = S(180), min2 = S(120);
            int h = body.Height - body.SplitterWidth;
            if (h <= min1 + min2) return;
            // WinForms throws if the minimums and the distance disagree even briefly, hence the order and try.
            try
            {
                body.SplitterDistance = Math.Max(min1, Math.Min(h - min2, (int)(h * f)));
                if (body.Panel1MinSize != min1) body.Panel1MinSize = min1;
                if (body.Panel2MinSize != min2) body.Panel2MinSize = min2;
            }
            catch { }
        }

        void SaveDivider()
        {
            int h = body.Height - body.SplitterWidth;
            if (h <= 0) return;
            settings["LogSplit"] = ((double)body.SplitterDistance / h).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture);
            Settings.Save(settings);
        }

        void RestoreWindow()
        {
            string v;
            if (!settings.TryGetValue("Window", out v)) { StartPosition = FormStartPosition.CenterScreen; return; }
            var n = v.Split(',').Select(x => { int i; return int.TryParse(x, out i) ? i : int.MinValue; }).ToArray();
            if (n.Length < 4 || n.Any(i => i == int.MinValue)) { StartPosition = FormStartPosition.CenterScreen; return; }
            var r = new Rectangle(n[0], n[1], Math.Max(n[2], MinimumSize.Width), Math.Max(n[3], MinimumSize.Height));
            // Only use it if the title bar would land on a screen that's still connected.
            var bar = new Rectangle(r.X + 40, r.Y, Math.Max(r.Width - 80, 40), 30);
            if (!Screen.AllScreens.Any(sc => sc.WorkingArea.IntersectsWith(bar))) { StartPosition = FormStartPosition.CenterScreen; Size = r.Size; return; }
            StartPosition = FormStartPosition.Manual;
            Bounds = r;
            startMaximized = Get(settings, "Maximized") == "1";
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            if (startMaximized) WindowState = FormWindowState.Maximized;
            placing = true; PlaceDivider(); placing = false;
            body.SplitterMoved += (s, ev) => { if (!placing) SaveDivider(); };
            // Keep the same proportions when the window changes size.
            body.SizeChanged += (s, ev) => { placing = true; PlaceDivider(); placing = false; };
        }

        void SaveWindow()
        {
            if (WindowState == FormWindowState.Minimized && RestoreBounds.Width == 0) return;
            var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            settings["Window"] = r.X + "," + r.Y + "," + r.Width + "," + r.Height;
            settings["Maximized"] = WindowState == FormWindowState.Maximized ? "1" : "0";
            Settings.Save(settings);
        }

        static string Get(Dictionary<string, string> d, string k) { string v; return d.TryGetValue(k, out v) ? v : ""; }
        bool Option(string k, bool def) { string v = Get(settings, k); return v.Length == 0 ? def : v == "1"; }
        void SetOption(string k, bool on) { settings[k] = on ? "1" : "0"; Settings.Save(settings); }

        // Pixel sizes that WinForms doesn't scale on its own (list columns).
        int S(int px)
        {
            using (var g = CreateGraphics()) return (int)Math.Round(px * g.DpiX / 96f);
        }

        // ---------------------------------------------------------------- layout
        Button MakeButton(string text, EventHandler click, bool primary = false)
        {
            var b = new Button
            {
                Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                MinimumSize = new Size(primary ? 110 : 90, 34), Padding = new Padding(10, 2, 10, 2), FlatStyle = FlatStyle.Flat,
                BackColor = primary ? Color.FromArgb(32, 110, 70) : Color.FromArgb(48, 52, 58),
                ForeColor = Fg, Margin = new Padding(0, 0, 8, 0), Cursor = Cursors.Hand,
            };
            b.FlatAppearance.BorderColor = Color.FromArgb(70, 75, 82);
            b.Click += click;
            return b;
        }

        void Build()
        {
            // Plain docking: the bars stack at the top and the files/log area fills the rest. (A
            // TableLayoutPanel with a percent row left that area at its default height on Windows.)
            var root = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16), BackColor = Bg };
            Controls.Add(root);

            // setup bar (shown when WSL or the emulator is missing)
            var bar = new TableLayoutPanel
            {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 2, RowCount = 1,
                BackColor = Color.FromArgb(70, 52, 20), Visible = false, Margin = new Padding(0, 0, 0, 12), Padding = new Padding(12, 10, 12, 10),
            };
            bar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            bar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            // AutoSize + left/right anchors makes a label wrap to its column and grow taller as needed.
            setupText = new Label { AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Right, ForeColor = Color.FromArgb(255, 226, 170), Margin = new Padding(0, 0, 12, 0) };
            setupButton = MakeButton("Install", async (s, e) => await SetupAction(), true);
            setupButton.Anchor = AnchorStyles.Right; setupButton.Margin = new Padding(0);
            bar.Controls.Add(setupText, 0, 0);
            bar.Controls.Add(setupButton, 1, 0);
            setupBar = bar;
            setupGap = new Panel { Dock = DockStyle.Top, Height = 12, Visible = false, BackColor = Bg };

            // header: title, deck picker, status
            var header = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, 10) };
            var title = new Label { Text = "SC LIVE 4 Emulator", AutoSize = true, Font = new Font("Segoe UI Semibold", 15f), Margin = new Padding(0, 2, 18, 0) };
            var deckLabel = new Label { Text = "Deck:", AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 9, 6, 0) };
            profileBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 210, Margin = new Padding(0, 5, 6, 0), BackColor = Panel1, ForeColor = Fg, FlatStyle = FlatStyle.Flat };
            profileBox.SelectedIndexChanged += async (s, e) => { settings["Profile"] = CurrentProfile; Settings.Save(settings); await RefreshAll(); };
            var newDeck = MakeButton("New deck...", (s, e) => NewDeck());
            newDeck.MinimumSize = new Size(0, 30); newDeck.Margin = new Padding(0, 3, 18, 0);
            statusLabel = new Label { AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 9, 0, 0), Text = "Checking WSL..." };
            header.Controls.AddRange(new Control[] { title, deckLabel, profileBox, newDeck, statusLabel });
            header.Padding = new Padding(0, 0, 0, 10);

            // action buttons
            var actions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = new Padding(0, 0, 0, 12) };
            startButton = MakeButton("Start", async (s, e) => await StartDeck(), true);
            stopButton = MakeButton("Stop", async (s, e) => await Do("Stopping", "stop"));
            rebootButton = MakeButton("Reboot", async (s, e) => await Do("Rebooting", "reboot"));
            deckButton = MakeButton("Open deck", (s, e) => OpenUrl(Get("deck_url", "http://localhost:8090/")));
            consoleButton = MakeButton("EngineX console", (s, e) => OpenUrl(Get("console_url", "http://localhost:8080/")));
            var more = MakeButton("More...", (s, e) => ShowMoreMenu((Control)s));
            actions.Controls.AddRange(new Control[] { startButton, stopButton, rebootButton, deckButton, consoleButton, more });
            actions.Padding = new Padding(0, 0, 0, 12);

            // drop zone (left) + drives (right)
            // Drop zone + drives on top, activity log underneath, with a divider you can drag.
            body = new SplitContainer
            {
                Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, Margin = new Padding(0),
                SplitterWidth = 10, BackColor = Bg, FixedPanel = FixedPanel.None,
            };
            body.Panel1.BackColor = Bg; body.Panel2.BackColor = Bg;
            var split = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0) };
            split.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 55));
            split.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 45));
            dropZone = new Panel { Dock = DockStyle.Fill, BackColor = Panel1, Margin = new Padding(0, 0, 10, 0), AllowDrop = true, Cursor = Cursors.Hand };
            dropZone.Paint += (s, e) =>
            {
                using (var pen = new Pen(Color.FromArgb(80, 86, 94), 2) { DashStyle = System.Drawing.Drawing2D.DashStyle.Dash })
                    e.Graphics.DrawRectangle(pen, 6, 6, dropZone.Width - 13, dropZone.Height - 13);
            };
            dropZone.DragEnter += OnDragEnter;
            dropZone.DragDrop += OnDragDrop;
            dropZone.Click += (s, e) => BrowseFiles();
            dropText = new Label
            {
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Dim, AllowDrop = true,
                Text = "Drop files or folders here\n(or click to choose files)\n\n" +
                       "Firmware .img: sets up this deck\n" +
                       "EngineX bundle: installs EngineX\n" +
                       "Mod .tar.gz: installs the mod\n" +
                       "Folder: plugs in as a USB drive (hold Shift for SD card)\n" +
                       "Music files: added to the emulator's music drive",
            };
            dropText.DragEnter += OnDragEnter;
            dropText.DragDrop += OnDragDrop;
            dropText.Click += (s, e) => BrowseFiles();
            dropZone.Controls.Add(dropText);
            split.Controls.Add(dropZone, 0, 0);

            var drivesPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = new Padding(0) };
            drivesPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            drivesPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            drivesPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            drivesPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            drivesPanel.Controls.Add(new Label { Text = "Drives plugged into this deck", AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 0, 0, 4) });
            drivesList = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable, BackColor = Panel1, ForeColor = Fg, BorderStyle = BorderStyle.None };
            drivesList.Columns.Add("Label", S(100));
            drivesList.Columns.Add("Type", S(80));
            drivesList.Columns.Add("Folder", S(260));
            drivesPanel.Controls.Add(drivesList);
            var driveButtons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 6, 0, 0) };
            var addUsb = MakeButton("Add USB folder", async (s, e) => await PickDrive(false));
            var addSd = MakeButton("Add SD folder", async (s, e) => await PickDrive(true));
            var eject = MakeButton("Eject", async (s, e) => await EjectSelected());
            foreach (var b in new[] { addUsb, addSd, eject }) b.MinimumSize = new Size(0, 30);
            driveButtons.Controls.AddRange(new Control[] { addUsb, addSd, eject });
            drivesPanel.Controls.Add(driveButtons);
            split.Controls.Add(drivesPanel, 1, 0);
            body.Panel1.Controls.Add(split);
            root.Controls.Add(body);      // Fill: takes what's left after the bars below
            root.Controls.Add(actions);
            root.Controls.Add(header);
            root.Controls.Add(setupGap);
            root.Controls.Add(setupBar);  // added last, so it docks first and sits at the very top

            var logPanel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = new Padding(0) };
            logPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            logPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            logPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            logPanel.Controls.Add(new Label { Text = "Activity", AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 0, 0, 4) });
            logBox = new TextBox
            {
                Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true,
                BackColor = Color.FromArgb(16, 17, 19), ForeColor = Color.FromArgb(190, 196, 204), BorderStyle = BorderStyle.None,
                Font = new Font("Consolas", 9f),
            };
            logPanel.Controls.Add(logBox);
            body.Panel2.Controls.Add(logPanel);

            pollTimer = new Timer { Interval = 3000 };
            pollTimer.Tick += async (s, e) => await Poll();
        }

        // ---------------------------------------------------------------- helpers
        string CurrentProfile
        {
            get
            {
                if (profileBox.SelectedItem == null) return "default";
                string t = profileBox.SelectedItem.ToString();
                int i = t.IndexOf("  (");
                return i > 0 ? t.Substring(0, i) : t;
            }
        }

        string Get(string k, string def) { string v; return info.TryGetValue(k, out v) && v.Length > 0 ? v : def; }

        void Log(string line)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(Log), line); return; }
            if (logBox.TextLength > 200000) logBox.Text = logBox.Text.Substring(100000);
            logBox.AppendText(line + Environment.NewLine);
        }

        void SetBusy(bool b, string what = null)
        {
            busy = b;
            foreach (var c in new Control[] { startButton, stopButton, rebootButton, profileBox, setupButton }) c.Enabled = !b;
            if (b && what != null) statusLabel.Text = what + "...";
            UseWaitCursor = b;
        }

        static void OpenUrl(string url) { try { Process.Start(url); } catch { } }

        async Task<int> Emu(string what, string args)
        {
            SetBusy(true, what);
            Log("> emu.sh " + (CurrentProfile != "default" ? "--profile " + CurrentProfile + " " : "") + args);
            int rc = await wsl.Run(wsl.Emu(CurrentProfile, args), Log);
            SetBusy(false);
            await RefreshAll();
            return rc;
        }

        async Task Do(string what, string args)
        {
            int rc = await Emu(what, args);
            if (rc != 0) Log("(that didn't work; see above)");
            if (args == "stop") StopKeepAlive();
        }

        void StopKeepAlive()
        {
            try { if (keepAlive != null && !keepAlive.HasExited) keepAlive.Kill(); } catch { }
            keepAlive = null;
        }

        // ---------------------------------------------------------------- start-up and state
        void ActionsEnabled(bool on)
        {
            foreach (var c in new Control[] { startButton, stopButton, rebootButton, deckButton, consoleButton, profileBox }) c.Enabled = on;
        }

        string legacyDir = "";

        async Task Init()
        {
            ActionsEnabled(false);
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
            // A current emulator has the commands this app uses (info, profiles, identify, mod-install).
            string found = (await wsl.Capture(
                "for d in " + (string.IsNullOrEmpty(emuDir) ? "" : Wsl.Q(emuDir) + " ") +
                "/opt/sclive4-emulator /root/sclive4-emulator /home/*/sclive4-emulator /home/*/enginex-emu; do " +
                "[ -x \"$d/emu.sh\" ] || continue; " +
                "if grep -q '^cmd_info()' \"$d/emu.sh\"; then echo \"current $d\"; else echo \"old $d\"; fi; done")).Trim();
            var lines = found.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            var current = lines.FirstOrDefault(l => l.StartsWith("current "));
            var older = lines.FirstOrDefault(l => l.StartsWith("old "));
            if (current == null && older != null)
            {
                legacyDir = older.Substring(4);
                ShowSetup("Found an older copy of the emulator in " + legacyDir + ". This app needs the current one: it'll be installed in " +
                          "/opt/sclive4-emulator and your deck, settings and drives moved over.", "Update emulator");
                statusLabel.Text = "Emulator needs updating";
                return;
            }
            if (current == null)
            {
                ShowSetup("The emulator isn't installed in WSL (" + wsl.Distro + ") yet. It'll be downloaded from GitHub into /opt/sclive4-emulator.",
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
                    "[ -d /opt/sclive4-emulator/.git ] || git clone " + Wsl.RepoUrl + " /opt/sclive4-emulator; " +
                    "for x in rootfs state drives.txt; do " +
                    "  if [ -e " + o + "/$x ] && [ ! -e /opt/sclive4-emulator/$x ]; then mv " + o + "/$x /opt/sclive4-emulator/ && echo \"moved $x\"; fi; " +
                    "done; echo 'Done. The old folder " + legacyDir.Replace("'", "") + " can be deleted.'", Log);
                SetBusy(false);
                legacyDir = "";
                settings["EmuDir"] = "/opt/sclive4-emulator";
                Settings.Save(settings);
                if (mrc == 0) await Init(); else Log("Updating failed; see above.");
                return;
            }
            if (t == "Install emulator")
            {
                SetBusy(true, "Installing the emulator");
                int rc = await wsl.Run(
                    "set -e; command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git; }; " +
                    "git clone " + Wsl.RepoUrl + " /opt/sclive4-emulator && echo 'Installed in /opt/sclive4-emulator.'", Log);
                SetBusy(false);
                if (rc == 0) await Init();
                else Log("Installing the emulator failed; see above.");
            }
        }

        async Task LoadProfiles()
        {
            string keep = settings.ContainsKey("Profile") ? settings["Profile"] : CurrentProfile;
            string outp = await wsl.Capture(wsl.Emu("default", "profiles"));
            var items = new List<string>();
            foreach (var line in outp.Split('\n'))
            {
                var f = line.Trim('\r').Split('\t');
                if (f.Length < 3 || f[0].Length == 0) continue;
                string desc = f[1] != "yes" ? "not set up" : (f[2].Length > 0 ? "EngineX " + f[2] : "stock Engine OS");
                items.Add(f[0] + "  (" + desc + ")");
            }
            if (!items.Any(i => i.StartsWith("default  ("))) items.Insert(0, "default  (not set up)");
            if (!items.Any(i => i.StartsWith(keep + "  ("))) items.Add(keep + "  (not set up)");
            profileBox.Items.Clear();
            profileBox.Items.AddRange(items.ToArray());
            profileBox.SelectedItem = items.First(i => i.StartsWith(keep + "  ("));
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
                string outp = await wsl.Capture(wsl.Emu(CurrentProfile, "info"));
                var d = new Dictionary<string, string>();
                foreach (var l in outp.Split('\n'))
                {
                    int i = l.IndexOf('=');
                    if (i > 0) d[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
                }
                info = d;
                bool setup = Get("setup", "no") == "yes", running = Get("running", "no") == "yes";
                string sys = !setup ? "not set up: drop the firmware .img or updater here"
                           : Get("enginex", "").Length > 0 ? "EngineX " + Get("enginex", "") : "stock Engine OS";
                string state = !running ? "stopped" : Get("engine", "down") == "up" ? "running" : "starting";
                if (!busy) statusLabel.Text = sys + "  |  " + state + (running && Get("ip", "").Length > 0 ? "  |  deck " + Get("ip", "") : "");
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
            string outp = await wsl.Capture(wsl.Emu(CurrentProfile, "drive list"));
            drivesList.Items.Clear();
            foreach (var line in outp.Split('\n'))
            {
                var t = line.Trim();
                if (t.Length == 0 || t.StartsWith("emu:")) continue;
                var parts = t.Split(new[] { ' ' }, 3, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 3) continue;
                var it = new ListViewItem(new[] { parts[0], parts[1] == "sd" ? "SD card" : "USB", parts[2].Trim() });
                drivesList.Items.Add(it);
            }
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

        void NewDeck()
        {
            string name = Prompt("New deck", "Name for the new deck (letters, digits, - and _), for example \"stock\":", "stock");
            if (string.IsNullOrEmpty(name)) return;
            if (name.Any(c => !(char.IsLetterOrDigit(c) || c == '-' || c == '_'))) { MessageBox.Show(this, "Use letters, digits, - and _ only."); return; }
            string item = name + "  (not set up)";
            if (!profileBox.Items.Cast<object>().Any(o => o.ToString().StartsWith(name + "  ("))) profileBox.Items.Add(item);
            profileBox.SelectedItem = profileBox.Items.Cast<object>().First(o => o.ToString().StartsWith(name + "  ("));
            Log("New deck \"" + name + "\": drop a firmware .img to set it up (add an EngineX bundle too, or leave it stock).");
        }

        void ShowMoreMenu(Control anchor)
        {
            var m = new ContextMenuStrip();
            m.Items.Add("Show Engine log", null, async (s, e) => await ShowEngineLog());
            m.Items.Add("Reset Engine settings and library on this deck", null, async (s, e) =>
            {
                if (MessageBox.Show(this, "Clear Engine's settings and library on this deck? EngineX and drives are kept.", "Reset", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
                    await Do("Resetting", "reset-data");
            });
            m.Items.Add("Update the emulator now", null, async (s, e) =>
            {
                SetBusy(true, "Updating");
                await UpdateEmulator(false);
                SetBusy(false);
            });
            m.Items.Add("Open music folder", null, (s, e) => OpenUrl(Settings.MusicFolder));
            m.Items.Add(new ToolStripSeparator());
            var auto = new ToolStripMenuItem("Start the deck when the app opens") { Checked = Option("AutoStart", false), CheckOnClick = true };
            auto.CheckedChanged += (s, e) => SetOption("AutoStart", auto.Checked);
            var open = new ToolStripMenuItem("Open the deck page after starting") { Checked = Option("OpenDeck", true), CheckOnClick = true };
            open.CheckedChanged += (s, e) => SetOption("OpenDeck", open.Checked);
            var upd = new ToolStripMenuItem("Update the emulator when the app opens") { Checked = Option("AutoUpdate", true), CheckOnClick = true };
            upd.CheckedChanged += (s, e) => SetOption("AutoUpdate", upd.Checked);
            // OpenGL through virgl is the default; this is the way back if it misbehaves on a PC.
            var sw = new ToolStripMenuItem("Software rendering (if the screen looks wrong)") { Checked = Option("SoftwareRender", false), CheckOnClick = true };
            sw.CheckedChanged += async (s, e) =>
            {
                SetOption("SoftwareRender", sw.Checked);
                await wsl.Run(wsl.Emu(CurrentProfile, "graphics " + (sw.Checked ? "software" : "auto")), Log);
                Log("Restart the deck for this to take effect.");
            };
            m.Items.Add(auto);
            m.Items.Add(upd);
            m.Items.Add(sw);
            m.Items.Add(open);
            m.Show(anchor, new Point(0, anchor.Height));
        }

        // Brings the emulator in WSL up to date with GitHub. The copy this app installed in /opt is the
        // app's own, so local edits there are overwritten; your decks, settings and drives live in
        // ignored folders (rootfs*, state*, drives.txt) and are never touched.
        async Task UpdateEmulator(bool quiet)
        {
            string dir = Wsl.Q(wsl.EmuDir);
            string script =
                "cd " + dir + " || exit 1\n" +
                "git rev-parse --git-dir >/dev/null 2>&1 || { echo 'not a git checkout, skipping update'; exit 0; }\n" +
                "git config --global --add safe.directory " + dir + " 2>/dev/null\n" +
                "before=$(git rev-parse --short HEAD)\n" +
                "git fetch -q origin || { echo 'update check failed (no internet in WSL?)'; exit 1; }\n" +
                "br=$(git rev-parse --abbrev-ref HEAD)\n" +
                "if ! git merge -q --ff-only origin/$br 2>/dev/null; then\n" +
                (wsl.EmuDir == "/opt/sclive4-emulator"
                    ? "  echo 'local changes were in the way; resetting to the GitHub version'; git reset -q --hard origin/$br\n"
                    : "  echo 'could not fast-forward (local changes?); run git pull in '" + dir + "' yourself'; exit 1\n") +
                "fi\n" +
                "after=$(git rev-parse --short HEAD)\n" +
                "if [ \"$before\" = \"$after\" ]; then echo \"up to date ($after)\"; else echo \"updated $before -> $after\"; git log --oneline $before..$after | head -n 8; fi\n";
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

        void BrowseFiles()
        {
            using (var dlg = new OpenFileDialog
            {
                Multiselect = true, Title = "Firmware, EngineX bundle, mods or music",
                Filter = "Emulator files (*.img;*.tar.gz;*.tgz;*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.aac;*.ogg)|*.img;*.tar.gz;*.tgz;*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.aac;*.ogg|All files (*.*)|*.*",
            })
            {
                if (dlg.ShowDialog(this) == DialogResult.OK) HandleDrop(dlg.FileNames, false);
            }
        }

        async Task PickDrive(bool sd)
        {
            using (var dlg = new FolderBrowserDialog { Description = sd ? "Folder to use as the SD card" : "Folder to plug in as a USB drive" })
            {
                if (dlg.ShowDialog(this) == DialogResult.OK) await AddDrive(dlg.SelectedPath, sd);
            }
        }

        async Task AddDrive(string folder, bool sd, string label = null)
        {
            string lin;
            try { lin = Wsl.ToWslPath(folder); } catch (Exception ex) { Log(ex.Message); return; }
            await Emu("Plugging in", "drive add " + Wsl.Q(lin) + (sd ? " --sd" : "") + (label != null ? " --label " + Wsl.Q(label) : ""));
        }

        async Task EjectSelected()
        {
            if (drivesList.SelectedItems.Count == 0) { Log("Pick a drive in the list first."); return; }
            await Emu("Ejecting", "drive remove " + Wsl.Q(drivesList.SelectedItems[0].Text));
        }

        // ---------------------------------------------------------------- drag and drop
        void OnDragEnter(object sender, DragEventArgs e)
        {
            e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) && !busy ? DragDropEffects.Copy : DragDropEffects.None;
        }

        void OnDragDrop(object sender, DragEventArgs e)
        {
            var paths = e.Data.GetData(DataFormats.FileDrop) as string[];
            if (paths == null) return;
            bool shift = (ModifierKeys & Keys.Shift) != 0;
            HandleDrop(paths, shift);
        }

        static readonly string[] AudioExt = { ".mp3", ".flac", ".wav", ".aiff", ".aif", ".m4a", ".aac", ".ogg", ".alac", ".mp4" };

        async void HandleDrop(string[] paths, bool shift)
        {
            if (busy) return;
            if (wsl.EmuDir.Length == 0) { Log("Finish the setup at the top first."); return; }
            var firmware = new List<string>(); var bundles = new List<string>(); var mods = new List<string>();
            var folders = new List<string>(); var music = new List<string>();
            foreach (var p in paths)
            {
                if (Directory.Exists(p)) { folders.Add(p); continue; }
                string ext = Path.GetExtension(p).ToLowerInvariant();
                if (AudioExt.Contains(ext)) { music.Add(p); continue; }
                // .exe and .zip: inMusic's firmware updaters (the emulator takes the image out)
                if (ext == ".img" || ext == ".gz" || ext == ".tgz" || ext == ".exe" || ext == ".zip")
                {
                    string lin;
                    try { lin = Wsl.ToWslPath(p); } catch (Exception ex) { Log(ex.Message); continue; }
                    string kind = (await wsl.Capture(wsl.Emu(CurrentProfile, "identify " + Wsl.Q(lin)))).Trim();
                    if (kind == "firmware") firmware.Add(lin);
                    else if (kind == "enginex") bundles.Add(lin);
                    else if (kind == "mod") mods.Add(lin);
                    else Log("Not sure what " + Path.GetFileName(p) + " is (not firmware, an EngineX bundle or a mod).");
                    continue;
                }
                Log("Skipped " + Path.GetFileName(p) + ": not firmware, an EngineX bundle, a mod, a folder or music.");
            }

            // firmware first, then EngineX, then mods; drives and music any time
            if (firmware.Count > 0)
            {
                bool running = Get("running", "no") == "yes";
                bool setup = Get("setup", "no") == "yes";
                string deck = CurrentProfile;
                string msg = setup
                    ? "Set up the deck \"" + deck + "\" again from " + Path.GetFileName(firmware[0]) + "?\n\nIts system, Engine settings and library are replaced (your drives aren't touched)."
                    : "Set up the deck \"" + deck + "\" from " + Path.GetFileName(firmware[0]) + "?" + (bundles.Count == 0 ? "\n\nWithout an EngineX bundle it'll be stock Engine OS." : "");
                if (MessageBox.Show(this, msg, "Set up deck", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
                if (running) await Emu("Stopping", "stop");
                string args = "setup " + Wsl.Q(firmware[0]) + (bundles.Count > 0 ? " " + Wsl.Q(bundles[0]) : "");
                if (bundles.Count > 0) bundles.RemoveAt(0);
                if (await Emu("Setting up (about a minute)", args) == 0) { await LoadProfiles(); Log("Deck ready. Press Start."); }
            }
            foreach (var b in bundles)
            {
                if (Get("setup", "no") != "yes") { Log("Set this deck up with a firmware .img before installing EngineX."); break; }
                bool wasRunning = Get("running", "no") == "yes";
                if (wasRunning) await Emu("Stopping", "stop");
                if (await Emu("Installing EngineX", "install " + Wsl.Q(b)) == 0) { await LoadProfiles(); Log("EngineX installed."); }
                if (wasRunning) await StartDeck();
            }
            foreach (var m in mods)
            {
                if (Get("running", "no") != "yes" || Get("enginex", "").Length == 0) { Log("Start a deck with EngineX first, then drop the mod again."); break; }
                await Emu("Installing mod", "mod-install " + Wsl.Q(m));
            }
            foreach (var f in folders) await AddDrive(f, shift);
            if (music.Count > 0) await AddMusic(music);
        }

        async Task AddMusic(List<string> files)
        {
            string dest = Settings.MusicFolder;
            int n = 0;
            await Task.Run(() =>
            {
                foreach (var f in files)
                {
                    try { File.Copy(f, Path.Combine(dest, Path.GetFileName(f)), true); n++; }
                    catch (Exception ex) { Log("Couldn't copy " + Path.GetFileName(f) + ": " + ex.Message); }
                }
            });
            Log("Copied " + n + " track(s) to " + dest + ".");
            bool attached = drivesList.Items.Cast<ListViewItem>().Any(i => i.Text == "EMULATOR");
            if (!attached) await AddDrive(dest, false, "EMULATOR");
            else Log("They're on the EMULATOR drive. Engine picks up new files when you browse its folder.");
        }

        // ---------------------------------------------------------------- closing
        async void OnClosing(object sender, FormClosingEventArgs e)
        {
            SaveWindow();
            if (Get("running", "no") != "yes" || wsl.EmuDir.Length == 0) { StopKeepAlive(); return; }
            var r = MessageBox.Show(this, "The emulated deck is still running.\n\nStop it before closing?\n(No leaves it running in the background.)",
                                    "SC LIVE 4 Emulator", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Cancel) { e.Cancel = true; return; }
            if (r == DialogResult.Yes)
            {
                e.Cancel = true;
                Hide();
                await wsl.Run(wsl.Emu(CurrentProfile, "stop"), null);
                StopKeepAlive();
                FormClosing -= OnClosing;
                Close();
            }
            // No: keepAlive is left running, so WSL keeps the deck up after this window closes.
        }

        // ---------------------------------------------------------------- small dialog
        static string Prompt(string title, string text, string value)
        {
            using (var f = new Form { AutoScaleDimensions = new SizeF(96F, 96F), AutoScaleMode = AutoScaleMode.Dpi, Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, ClientSize = new Size(420, 130), BackColor = Bg, ForeColor = Fg, Font = new Font("Segoe UI", 9.5f) })
            {
                f.SuspendLayout();
                var l = new Label { Text = text, Left = 12, Top = 12, Width = 396, Height = 36 };
                var t = new TextBox { Text = value, Left = 12, Top = 52, Width = 396, BackColor = Panel1, ForeColor = Fg };
                var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = 238, Top = 88, Width = 80, Height = 30, FlatStyle = FlatStyle.Flat };
                var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = 328, Top = 88, Width = 80, Height = 30, FlatStyle = FlatStyle.Flat };
                f.Controls.AddRange(new Control[] { l, t, ok, cancel });
                f.AcceptButton = ok; f.CancelButton = cancel;
                f.ResumeLayout(false);
                return f.ShowDialog() == DialogResult.OK ? t.Text.Trim() : null;
            }
        }
    }
}
