// The floating card: a borderless, always-on-top window holding the shared card.html in WebView2.
// It never takes the keyboard by itself (WS_EX_NOACTIVATE); Ctrl+Alt+R hands it over and back.
// "Hidden" means parked off screen: the WebView stays loaded and never flips visibility,
// which is what can make WebView2 grab focus when a window reappears.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Ravi
{
    sealed class CardWindow : Form
    {
        const string Host = "ravi.example";   // .example is reserved, so this never clashes with a real site
        readonly WebView2 web = new WebView2();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        IntPtr previous = IntPtr.Zero;        // the window you were in before Ctrl+Alt+R
        bool quitting;

        public event Action<Dictionary<string, object>> MessageReceived;
        public event Action UserClosing;
        public bool Ready => web.CoreWebView2 != null;

        public CardWindow()
        {
            Text = "Ravi";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(0xFB, 0xFC, 0xFA);
            var off = OffscreenPoint(new Size(440, 220));
            Bounds = new Rectangle(off, new Size(440, 220));
            web.Dock = DockStyle.Fill;
            Controls.Add(web);
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.RoundCorners(Handle);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!quitting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;          // Alt+F4 hides the card instead of quitting Ravi
                UserClosing?.Invoke();
                return;
            }
            base.OnFormClosing(e);
        }

        public void CloseForGood()
        {
            quitting = true;
            Close();
        }

        public async Task InitAsync(string sharedDir, string dataDir, bool dev, Color background)
        {
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(dataDir, "WebView2"));
            await web.EnsureCoreWebView2Async(env);
            var core = web.CoreWebView2;
            var s = core.Settings;
            s.AreDefaultContextMenusEnabled = dev;
            s.AreDevToolsEnabled = dev;
            s.IsStatusBarEnabled = false;
            s.IsZoomControlEnabled = false;
            s.AreBrowserAcceleratorKeysEnabled = false;   // no Ctrl+R reload, F5, Ctrl+P …
            s.IsPasswordAutosaveEnabled = false;
            s.IsGeneralAutofillEnabled = false;
            web.DefaultBackgroundColor = background;
            core.SetVirtualHostNameToFolderMapping(Host, sharedDir, CoreWebView2HostResourceAccessKind.Allow);
            core.WebMessageReceived += (_, e) =>
            {
                try
                {
                    var text = e.TryGetWebMessageAsString();
                    if (json.DeserializeObject(text) is Dictionary<string, object> msg) MessageReceived?.Invoke(msg);
                }
                catch (Exception ex) { App.Log("bad message from card: " + ex.Message); }
            };
            core.NavigationStarting += (_, e) =>
            {
                if (!e.Uri.StartsWith("https://" + Host + "/", StringComparison.OrdinalIgnoreCase))
                {
                    e.Cancel = true;
                    OpenInBrowser(e.Uri);
                }
            };
            core.NewWindowRequested += (_, e) => { e.Handled = true; OpenInBrowser(e.Uri); };
            core.ProcessFailed += (_, e) => { App.Log("WebView2 process failed: " + e.ProcessFailedKind); BeginInvoke((Action)(() => web.Reload())); };
            core.Navigate("https://" + Host + "/card.html");
        }

        static void OpenInBrowser(string uri)
        {
            if (uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); } catch (Exception) { }
            }
        }

        public void SetBackground(Color c)
        {
            BackColor = c;
            if (Ready) web.DefaultBackgroundColor = c;
        }

        public void Exec(string script)
        {
            if (!Ready || IsDisposed) return;
            _ = web.CoreWebView2.ExecuteScriptAsync(script);
        }

        public float DpiScale => DeviceDpi / 96f;

        // ------------------------------------------------------------ placement
        static Point OffscreenPoint(Size size)
        {
            var vs = SystemInformation.VirtualScreen;
            return new Point(vs.Left - size.Width - 400, vs.Top - size.Height - 400);
        }

        /// <summary>Top right of the main screen's work area (above the taskbar), without activating.</summary>
        public void PlaceOnScreen(Size px)
        {
            var wa = Screen.PrimaryScreen.WorkingArea;
            int m = (int)Math.Round(12 * DpiScale);
            Native.SetWindowPos(Handle, Native.HWND_TOPMOST, wa.Right - px.Width - m, wa.Top + m, px.Width, px.Height,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        public void PlaceOffscreen(Size px)
        {
            var p = OffscreenPoint(px);
            Native.SetWindowPos(Handle, Native.HWND_TOPMOST, p.X, p.Y, px.Width, px.Height, Native.SWP_NOACTIVATE);
        }

        // ------------------------------------------------------------ keyboard focus
        void SetNoActivate(bool on)
        {
            var ex = Native.GetExStyle(Handle);
            ex = on ? ex | Native.WS_EX_NOACTIVATE : ex & ~(long)Native.WS_EX_NOACTIVATE;
            Native.SetExStyle(Handle, ex);
        }

        public void GrabFocus()
        {
            var fg = Native.GetForegroundWindow();
            if (fg != IntPtr.Zero && fg != Handle) previous = fg;
            SetNoActivate(false);
            Native.SetForegroundWindow(Handle);
            Activate();
            web.Focus();
        }

        public void ReleaseFocus()
        {
            SetNoActivate(true);
            var prev = previous;
            previous = IntPtr.Zero;
            if (prev != IntPtr.Zero && Native.IsWindow(prev) && Native.IsWindowVisible(prev))
            {
                Native.SetForegroundWindow(prev);
            }
            else
            {
                // let Windows pick the window you used last
                Native.ShowWindow(Handle, Native.SW_HIDE);
                Native.ShowWindow(Handle, Native.SW_SHOWNOACTIVATE);
            }
        }
    }
}
