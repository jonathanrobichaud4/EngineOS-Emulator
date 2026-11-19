// The main window: its layout and the helpers the other MainForm files use. The rest of the
// window is in MainForm.*.cs.

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
    // ------------------------------------------------------------------------------- window
    partial class MainForm : Form
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
