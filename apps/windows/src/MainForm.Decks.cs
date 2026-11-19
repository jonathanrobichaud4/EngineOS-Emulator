// The Decks window: add, rename and delete decks, and pick each one's model.

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
                foreach (var n in DeckModels.Names) model.Items.Add(n);
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
                    await DeckCommand("Changing the model", "profile model " + Wsl.Q(d.Name) + " " + code);
                    await reload(d.Name);
                };
                add.Click += async (s, e) =>
                {
                    string name = Prompt("New deck", "Name for the new deck (letters, digits, - and _). It's an " + DeckModels.Names[0] + "; change the model here after.",
                                         decks.Any(d => d.Name == "stock") ? "" : "stock");
                    if (string.IsNullOrEmpty(name)) return;
                    if (!ValidDeckName(name)) { MessageBox.Show(f, "Use letters, digits, - and _ only.", "Decks"); return; }
                    if (decks.Any(d => d.Name == name)) { MessageBox.Show(f, "There's already a deck called " + name + ".", "Decks"); return; }
                    if (await DeckCommand("Making the deck", "profile new " + Wsl.Q(name) + " " + DeckModels.Codes[0]) == 0)
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
    }
}
