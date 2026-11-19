// Dropped and chosen files, and drives.

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
    }
}
