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
// WSL and the emulator, and update the emulator with git pull.
//
// Builds against .NET Framework 4.x (included in Windows 10/11): see build.sh next to this file.

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

    // Dark-mode touches Windows doesn't give WinForms by itself: a dark title bar (Windows 10 2004
    // and later), dark scrollbars and dropdowns, and list headers drawn in the app's colors.
    static class Theme
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        public static readonly Color Header = Color.FromArgb(44, 48, 53);
        public static readonly Color Accent = Color.FromArgb(46, 160, 98);

        public static void DarkTitleBar(Form f)
        {
            f.HandleCreated += (s, e) =>
            {
                try
                {
                    int on = 1;
                    // 20 on current Windows, 19 on early Windows 10 builds.
                    if (DwmSetWindowAttribute(f.Handle, 20, ref on, 4) != 0) DwmSetWindowAttribute(f.Handle, 19, ref on, 4);
                }
                catch { }
            };
        }

        // Dark scrollbars (and the dropdown list of a ComboBox).
        public static void DarkScroll(Control c)
        {
            c.HandleCreated += (s, e) =>
            {
                try { SetWindowTheme(c.Handle, c is ComboBox ? "DarkMode_CFD" : "DarkMode_Explorer", null); } catch { }
            };
        }

        // A ListView with a header in the app's colors, and its last column stretched to the edge
        // so there's no strip of system-coloured header beside it.
        public static void DarkList(ListView l, Color fg, Color dim)
        {
            DarkScroll(l);
            l.OwnerDraw = true;
            l.DrawColumnHeader += (s, e) =>
            {
                using (var b = new SolidBrush(Header)) e.Graphics.FillRectangle(b, e.Bounds);
                using (var p = new Pen(Color.FromArgb(60, 65, 72))) e.Graphics.DrawLine(p, e.Bounds.Right - 1, e.Bounds.Top + 4, e.Bounds.Right - 1, e.Bounds.Bottom - 5);
                var r = new Rectangle(e.Bounds.X + 6, e.Bounds.Y, e.Bounds.Width - 8, e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, e.Header.Text, l.Font, r, dim, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
            };
            l.DrawItem += (s, e) => { e.DrawDefault = true; };
            l.DrawSubItem += (s, e) => { e.DrawDefault = true; };
            EventHandler fit = (s, e) =>
            {
                if (l.Columns.Count == 0) return;
                int used = 0;
                for (int i = 0; i < l.Columns.Count - 1; i++) used += l.Columns[i].Width;
                int w = l.ClientSize.Width - used;
                if (w > 40) l.Columns[l.Columns.Count - 1].Width = w;
            };
            l.SizeChanged += fit;
            l.HandleCreated += fit;
        }

        // A dim note in the middle of an empty list.
        public static Label EmptyNote(ListView l, string text, Color dim)
        {
            // Below the header row, which is part of the list's own area.
            var n = new Label { Text = text, ForeColor = dim, BackColor = l.BackColor, AutoSize = false, TextAlign = ContentAlignment.MiddleCenter };
            EventHandler place = (s, e) =>
            {
                int top = l.Font.Height + 12;
                n.Bounds = new Rectangle(0, top, l.ClientSize.Width, Math.Max(0, l.ClientSize.Height - top));
            };
            l.SizeChanged += place;
            l.Controls.Add(n);
            place(null, null);
            return n;
        }
    }

    // The deck models the emulator knows, by inMusic product code. Only the SC LIVE 4 boots so far.
    static class DeckModels
    {
        // The SC LIVE 4 firmware runs as an SC LIVE 4 or a Prime 4+; the Prime 4 needs Prime 4 firmware.
        public static readonly string[] Codes = { "JP21", "JC11S", "JC11" };
        public static readonly string[] Names = { "SC LIVE 4", "Prime 4+", "Prime 4" };
        public static readonly bool[] Ready = { true, true, true };
        public const string FirmwareNote = "SC LIVE 4 and Prime 4+ decks are set up with the SC LIVE 4 firmware; a Prime 4 deck with Prime 4 firmware.";
        public static string Name(string code) { int i = Array.IndexOf(Codes, code); return i < 0 ? code : Names[i]; }
        public static string Label(int i) { return Ready[i] ? Names[i] : Names[i] + " (coming later)"; }
    }

    // One deck (an emu.sh profile), as `emu.sh profiles` lists it.
    class DeckRow
    {
        public string Name, EngineX, Model = "JP21";
        public bool SetUp, Running;
        public string What { get { return !SetUp ? "not set up" : (EngineX.Length > 0 ? "EngineX " + EngineX : "stock Engine OS"); } }
        public override string ToString() { return Name + "  (" + DeckModels.Name(Model) + ", " + What + ")"; }
    }

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
        Label statusDot, drivesEmpty;
        string lastEngineError = "";

        // The dot beside the status: green running, amber busy or starting, grey otherwise.
        void SetDot(string state)
        {
            statusDot.ForeColor = state == "running" ? Theme.Accent
                                : state == "busy" || state == "starting" ? Color.FromArgb(230, 170, 60)
                                : state == "error" ? Color.FromArgb(220, 80, 70) : Dim;
        }
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
            Text = AppInfo.Name + (BuildInfo.Version == "dev" ? " (test build)" : " " + BuildInfo.Version);
            Font = new Font("Segoe UI", 9.5f);
            Theme.DarkTitleBar(this);
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
            b.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(40, 132, 84) : Color.FromArgb(60, 65, 72);
            b.FlatAppearance.MouseDownBackColor = primary ? Color.FromArgb(26, 92, 58) : Color.FromArgb(40, 44, 49);
            if (click != null) b.Click += click;
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
            var title = new Label { Text = AppInfo.Name, AutoSize = true, Font = new Font("Segoe UI Semibold", 15f), Margin = new Padding(0, 2, 18, 0) };
            var deckLabel = new Label { Text = "Deck:", AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 9, 6, 0) };
            profileBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 210, Margin = new Padding(0, 5, 6, 0), BackColor = Panel1, ForeColor = Fg, FlatStyle = FlatStyle.Flat };
            profileBox.SelectedIndexChanged += async (s, e) => { settings["Profile"] = CurrentProfile; Settings.Save(settings); await RefreshAll(); };
            var newDeck = MakeButton("Decks...", async (s, e) => await ManageDecks());
            newDeck.MinimumSize = new Size(0, 30); newDeck.Margin = new Padding(0, 3, 18, 0);
            statusDot = new Label { AutoSize = true, Text = "\u25CF", ForeColor = Dim, Font = new Font("Segoe UI", 11f), Margin = new Padding(0, 6, 2, 0) };
            statusLabel = new Label { AutoSize = true, ForeColor = Dim, Margin = new Padding(0, 9, 0, 0), Text = "Checking WSL..." };
            Theme.DarkScroll(profileBox);
            header.Controls.AddRange(new Control[] { title, deckLabel, profileBox, newDeck, statusDot, statusLabel });
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
                using (var pen = new Pen(dragging ? Theme.Accent : Color.FromArgb(80, 86, 94), 2) { DashStyle = System.Drawing.Drawing2D.DashStyle.Dash })
                    e.Graphics.DrawRectangle(pen, 6, 6, dropZone.Width - 13, dropZone.Height - 13);
            };
            // Lights up while files are dragged over it.
            EventHandler unlit = (s, e) => SetDragging(false);
            DragLeave += unlit; dropZone.DragLeave += unlit;
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
            drivesPanel.Controls.Add(new Label { Text = "Drives plugged into this deck", AutoSize = true, ForeColor = Dim, Font = new Font("Segoe UI Semibold", 9.5f), Margin = new Padding(0, 0, 0, 4) });
            drivesList = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable, BackColor = Panel1, ForeColor = Fg, BorderStyle = BorderStyle.None };
            drivesList.Columns.Add("Label", S(100));
            drivesList.Columns.Add("Type", S(80));
            drivesList.Columns.Add("Folder", S(260));
            Theme.DarkList(drivesList, Fg, Dim);
            drivesEmpty = Theme.EmptyNote(drivesList, "No drives plugged in.\nDrop a folder on the left, or use Add USB folder.", Dim);
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
            logPanel.Controls.Add(new Label { Text = "Activity", AutoSize = true, ForeColor = Dim, Font = new Font("Segoe UI Semibold", 9.5f), Margin = new Padding(0, 0, 0, 4) });
            logBox = new TextBox
            {
                Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true,
                BackColor = Color.FromArgb(16, 17, 19), ForeColor = Color.FromArgb(190, 196, 204), BorderStyle = BorderStyle.None,
                Font = new Font("Consolas", 9f),
            };
            Theme.DarkScroll(logBox);
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
            if (b && what != null) { statusLabel.Text = what + "..."; SetDot("busy"); }
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
            string outp = await wsl.Capture(wsl.Emu("default", "profiles"));
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
                string err = Get("engine_error", "");
                if (!busy && err.Length > 0)
                {
                    statusLabel.Text = "Engine stopped: wrong firmware for this model";
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

        // ---------------------------------------------------------------- managing decks
        static bool ValidDeckName(string n) { return n.Length > 0 && n.All(c => (c < 128 && char.IsLetterOrDigit(c)) || c == '-' || c == '_'); }

        async Task<int> DeckCommand(string what, string args)
        {
            SetBusy(true, what);
            Log("> emu.sh " + args);
            int rc = await wsl.Run(wsl.Emu("default", args), Log);
            SetBusy(false);
            return rc;
        }

        // Add, rename and delete decks, and pick each one's model.
        async Task ManageDecks()
        {
            if (wsl.EmuDir.Length == 0) return;
            // Laid out with auto-sizing panels, and the few pixel sizes scaled by hand (S), so it
            // fits at any display scaling.
            using (var f = new Form { AutoScaleMode = AutoScaleMode.None, Icon = Icon, Text = "Decks", FormBorderStyle = FormBorderStyle.FixedDialog,
                                      StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false,
                                      AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(S(12)),
                                      BackColor = Bg, ForeColor = Fg, Font = new Font("Segoe UI", 9.5f) })
            {
                f.SuspendLayout();
                var root = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
                var note = new Label { Text = "Each deck is its own emulated unit with its own firmware, settings, library and mods. One runs at a time. " + DeckModels.FirmwareNote,
                                       AutoSize = true, MaximumSize = new Size(S(600), 0), ForeColor = Dim, Margin = new Padding(0, 0, 0, S(8)) };
                var list = new ListView { Size = new Size(S(600), S(220)), View = View.Details, FullRowSelect = true, MultiSelect = false,
                                          HideSelection = false, BackColor = Panel1, ForeColor = Fg, BorderStyle = BorderStyle.FixedSingle,
                                          HeaderStyle = ColumnHeaderStyle.Nonclickable, Margin = new Padding(0, 0, 0, S(10)) };
                list.Columns.Add("Deck", S(160)); list.Columns.Add("Model", S(130)); list.Columns.Add("Status", S(290));
                Theme.DarkList(list, Fg, Dim);
                Theme.DarkTitleBar(f);
                var modelRow = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = new Padding(0, 0, 0, S(12)) };
                var modelLabel = new Label { Text = "Model:", AutoSize = true, Margin = new Padding(0, S(5), S(8), 0) };
                var model = new ComboBox { Width = S(240), DropDownStyle = ComboBoxStyle.DropDownList, BackColor = Panel1, ForeColor = Fg, FlatStyle = FlatStyle.Flat, Margin = new Padding(0) };
                modelRow.Controls.AddRange(new Control[] { modelLabel, model });
                Theme.DarkScroll(model);
                for (int i = 0; i < DeckModels.Codes.Length; i++) model.Items.Add(DeckModels.Label(i));
                var add = MakeButton("Add...", null); var ren = MakeButton("Rename...", null); var del = MakeButton("Delete...", null);
                var use = MakeButton("Use this deck", null, true); var close = MakeButton("Close", null);
                foreach (var b in new[] { add, ren, del, use, close }) b.MinimumSize = new Size(S(80), S(32));
                var row = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = new Padding(0) };
                row.Controls.AddRange(new Control[] { add, ren, del, use, close });
                root.Controls.AddRange(new Control[] { note, list, modelRow, row });
                f.Controls.Add(root);
                f.ResumeLayout(true);
                close.DialogResult = DialogResult.Cancel; f.CancelButton = close;

                bool loading = false;
                Func<DeckRow> sel = () => list.SelectedItems.Count == 0 ? null : (DeckRow)list.SelectedItems[0].Tag;
                Action update = () =>
                {
                    var d = sel();
                    loading = true;
                    model.SelectedIndex = d == null ? -1 : Math.Max(0, Array.IndexOf(DeckModels.Codes, d.Model));
                    loading = false;
                    bool idle = !busy;
                    model.Enabled = idle && d != null && !d.Running;
                    ren.Enabled = del.Enabled = idle && d != null && !d.Running;
                    use.Enabled = idle && d != null;
                    add.Enabled = idle;
                };
                Func<string, Task> reload = async (pick) =>
                {
                    await LoadProfiles();
                    list.Items.Clear();
                    foreach (var d in decks)
                    {
                        var it = new ListViewItem(new[] { d.Name, DeckModels.Name(d.Model), d.What + (d.Running ? ", running" : "") }) { Tag = d };
                        list.Items.Add(it);
                        if (d.Name == pick) it.Selected = true;
                    }
                    if (list.SelectedItems.Count == 0 && list.Items.Count > 0) list.Items[0].Selected = true;
                    update();
                };
                list.SelectedIndexChanged += (s, e) => update();

                model.SelectedIndexChanged += async (s, e) =>
                {
                    var d = sel();
                    if (loading || d == null || model.SelectedIndex < 0) return;
                    string code = DeckModels.Codes[model.SelectedIndex];
                    if (code == d.Model) return;
                    if (!DeckModels.Ready[model.SelectedIndex])
                    {
                        MessageBox.Show(f, DeckModels.Names[model.SelectedIndex] + " support isn't ready yet. For now every deck is an SC LIVE 4.", "Decks");
                        update(); return;
                    }
                    await DeckCommand("Changing the model", "profile model " + Wsl.Q(d.Name) + " " + code);
                    await reload(d.Name);
                };
                add.Click += async (s, e) =>
                {
                    string name = Prompt("New deck", "Name for the new deck (letters, digits, - and _). It's an SC LIVE 4; change the model here after.",
                                         decks.Any(d => d.Name == "stock") ? "" : "stock");
                    if (string.IsNullOrEmpty(name)) return;
                    if (!ValidDeckName(name)) { MessageBox.Show(f, "Use letters, digits, - and _ only.", "Decks"); return; }
                    if (decks.Any(d => d.Name == name)) { MessageBox.Show(f, "There's already a deck called " + name + ".", "Decks"); return; }
                    if (await DeckCommand("Making the deck", "profile new " + Wsl.Q(name) + " JP21") == 0)
                        Log("New deck \"" + name + "\": select it and drop a firmware .img to set it up (add an EngineX bundle too, or leave it stock).");
                    await reload(name);
                };
                ren.Click += async (s, e) =>
                {
                    var d = sel(); if (d == null) return;
                    string name = Prompt("Rename deck", "New name for \"" + d.Name + "\" (letters, digits, - and _):", d.Name);
                    if (string.IsNullOrEmpty(name) || name == d.Name) return;
                    if (!ValidDeckName(name)) { MessageBox.Show(f, "Use letters, digits, - and _ only.", "Decks"); return; }
                    if (decks.Any(x => x.Name == name)) { MessageBox.Show(f, "There's already a deck called " + name + ".", "Decks"); return; }
                    bool wasCurrent = CurrentProfile == d.Name;
                    if (await DeckCommand("Renaming the deck", "profile rename " + Wsl.Q(d.Name) + " " + Wsl.Q(name)) == 0 && wasCurrent)
                    { settings["Profile"] = name; Settings.Save(settings); }
                    await reload(name);
                };
                del.Click += async (s, e) =>
                {
                    var d = sel(); if (d == null) return;
                    if (MessageBox.Show(f, "Delete the " + d.Name + " deck?\n\nThis deletes its firmware copy, Engine settings, library and installed mods. " +
                                        "Your music and drive folders aren't touched.", "Delete deck", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                    await DeckCommand("Deleting the deck", "profile delete " + Wsl.Q(d.Name));
                    await reload(null);
                };
                use.Click += (s, e) =>
                {
                    var d = sel(); if (d == null) return;
                    settings["Profile"] = d.Name; Settings.Save(settings);
                    f.DialogResult = DialogResult.OK;
                };

                f.Shown += async (s, e) => await reload(CurrentProfile);
                f.ShowDialog(this);
            }
            await LoadProfiles();
            await RefreshAll();
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
            m.Items.Add("Check for app updates", null, async (s, e) => await CheckAppUpdate(true));
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
            var updApp = new ToolStripMenuItem("Update this app automatically") { Checked = Option("AutoUpdateApp", true), CheckOnClick = true };
            updApp.CheckedChanged += (s, e) => SetOption("AutoUpdateApp", updApp.Checked);
            var stopClose = new ToolStripMenuItem("Stop the deck when this app closes") { Checked = Option("StopOnClose", true), CheckOnClick = true };
            stopClose.CheckedChanged += (s, e) => SetOption("StopOnClose", stopClose.Checked);
            m.Items.Add(auto);
            m.Items.Add(stopClose);
            m.Items.Add(upd);
            m.Items.Add(updApp);
            m.Items.Add(sw);
            m.Items.Add(open);
            m.Show(anchor, new Point(0, anchor.Height));
        }

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
        bool dragging;
        void SetDragging(bool on)
        {
            if (dragging == on) return;
            dragging = on;
            dropZone.BackColor = on ? Color.FromArgb(32, 48, 40) : Panel1;
            dropText.BackColor = dropZone.BackColor;
            dropZone.Invalidate();
        }

        void OnDragEnter(object sender, DragEventArgs e)
        {
            e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) && !busy ? DragDropEffects.Copy : DragDropEffects.None;
            SetDragging(e.Effect != DragDropEffects.None);
        }

        void OnDragDrop(object sender, DragEventArgs e)
        {
            SetDragging(false);
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
                if (Get("setup", "no") != "yes") { Log("Set this deck up with its firmware file first, then drop the EngineX bundle."); break; }
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
            if (Option("StopOnClose", true))
            {
                // Stop the deck so nothing keeps running in the background (Settings can turn this off).
                e.Cancel = true;
                Hide();
                await wsl.Run(wsl.Emu(CurrentProfile, "stop"), null);
                StopKeepAlive();
                FormClosing -= OnClosing;
                Close();
                return;
            }
            var r = MessageBox.Show(this, "The emulated deck is still running.\n\nStop it before closing?\n(No leaves it running in the background.)",
                                    AppInfo.Name, MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
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
            using (var f = new Form { AutoScaleMode = AutoScaleMode.None, Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
                                      MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                                      BackColor = Bg, ForeColor = Fg, Font = new Font("Segoe UI", 9.5f) })
            {
                Theme.DarkTitleBar(f);
                float k; using (var g = f.CreateGraphics()) k = g.DpiX / 96f;
                Func<int, int> S = px => (int)Math.Round(px * k);
                f.SuspendLayout();
                f.Padding = new Padding(S(12));
                var root = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
                var l = new Label { Text = text, AutoSize = true, MaximumSize = new Size(S(420), 0), Margin = new Padding(0, 0, 0, S(8)) };
                var t = new TextBox { Text = value, Width = S(420), BackColor = Panel1, ForeColor = Fg, Margin = new Padding(0, 0, 0, S(12)) };
                var row = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Anchor = AnchorStyles.Right, Margin = new Padding(0) };
                var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(S(80), S(30)), FlatStyle = FlatStyle.Flat };
                var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(S(80), S(30)), FlatStyle = FlatStyle.Flat, Margin = new Padding(S(8), 0, 0, 0) };
                row.Controls.AddRange(new Control[] { ok, cancel });
                root.Controls.AddRange(new Control[] { l, t, row });
                f.Controls.Add(root);
                f.AcceptButton = ok; f.CancelButton = cancel;
                f.ResumeLayout(true);
                return f.ShowDialog() == DialogResult.OK ? t.Text.Trim() : null;
            }
        }
    }
}
