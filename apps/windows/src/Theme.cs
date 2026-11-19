// The app's dark look.

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
}
