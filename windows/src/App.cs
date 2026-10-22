// Ravi for Windows: tray icon, Ctrl+Alt+R, start at login, lock/sleep handling, and the glue
// between RaviCore (the logic) and CardWindow (the floating card).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace Ravi
{
    sealed class App : ApplicationContext, IRaviHost
    {
        public static readonly string DataDir =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Ravi");
        static readonly string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        static readonly string SharedDir = Path.Combine(BaseDir, "shared");
        static readonly bool Dev = Environment.GetEnvironmentVariable("RAVI_DEV") == "1";

        readonly RaviCore core;
        readonly CardWindow card;
        readonly NotifyIcon tray;
        readonly HotKey hotkey;
        readonly Timer clock = new Timer { Interval = 1000 };
        readonly Timer showFallback = new Timer { Interval = 450 };
        readonly Icon iconNormal, iconDue;

        bool focused, jsReady, pendingShow, wantFocus, onScreen, quitting;
        Size cssSize = new Size(456, 220);
        string lastTheme;

        ToolStripMenuItem miStatus, miRun, miMeeting, miSound, miLogin, miToday;
        readonly Dictionary<int, ToolStripMenuItem> miEvery = new Dictionary<int, ToolStripMenuItem>();

        public App(string command)
        {
            Directory.CreateDirectory(DataDir);
            RaviCore.Log = Log;
            var stateFile = Path.Combine(DataDir, "state.json");
            bool firstRun = !File.Exists(stateFile);
            core = new RaviCore(this, SharedDir, stateFile);
            core.Boot();
            if (firstRun || AutoStart.Enabled) AutoStart.Set(true);   // new install, or keep the path current

            // card window, parked off screen until there's something to show
            card = new CardWindow();
            card.MessageReceived += OnCardMessage;
            card.Activated += (_, __) => SetFocused(true);
            card.Deactivate += (_, __) => SetFocused(false);
            card.UserClosing += () => core.HideCard();
            card.DpiChanged += (_, __) => ApplySize();
            card.Show();
            lastTheme = Theme;
            InitCard();

            // tray
            iconNormal = LoadIcon("ravi-tray.ico") ?? SystemIcons.Application;
            iconDue = LoadIcon("ravi-tray-due.ico") ?? iconNormal;
            tray = new NotifyIcon { Icon = iconNormal, Text = "Ravi", Visible = true, ContextMenuStrip = BuildMenu() };
            tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) core.OnShow(); };

            // Ctrl+Alt+R, the same key as on the Mac (⌃⌥R) and Linux
            hotkey = new HotKey(Native.MOD_CONTROL | Native.MOD_ALT, Keys.R, () => core.OnFocusKey());
            if (!hotkey.Registered)
                tray.ShowBalloonTip(6000, "Ravi", "Ctrl+Alt+R is taken by another app, so use the tray icon instead.", ToolTipIcon.Info);

            // away: screen locked or PC asleep
            SystemEvents.SessionSwitch += OnSessionSwitch;
            SystemEvents.PowerModeChanged += OnPowerMode;
            SystemEvents.UserPreferenceChanged += OnPreferences;

            Ipc.Listen(cmd => card.BeginInvoke((Action)(() => Dispatch(cmd))));
            clock.Tick += (_, __) => core.Tick();
            clock.Start();
            // normally the card reports its size and then shows; this is the safety net if that message never comes
            showFallback.Tick += (_, __) =>
            {
                if (!jsReady) return;          // still loading: keep waiting rather than flash an empty window
                showFallback.Stop();
                if (pendingShow) ShowNow();
            };

            UpdateTray();
            Dispatch(command);
        }

        async void InitCard()
        {
            try
            {
                await card.InitAsync(SharedDir, DataDir, Dev, Background(Theme));
            }
            catch (WebView2RuntimeNotFoundException) { NeedWebView2(); }
            catch (Exception e)
            {
                Log("WebView2 failed to start: " + e);
                MessageBox.Show("Ravi couldn't start its card:\n\n" + e.Message, "Ravi", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Quit();
            }
        }

        void NeedWebView2()
        {
            var r = MessageBox.Show(
                "Ravi shows its card with Microsoft Edge WebView2, which isn't installed on this PC.\n\nOpen the download page?",
                "Ravi", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r == DialogResult.Yes)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://developer.microsoft.com/microsoft-edge/webview2/") { UseShellExecute = true });
            Quit();
        }

        void Dispatch(string cmd)
        {
            switch (cmd)
            {
                case "--autostart": break;
                case "": case "--show": core.OnShow(); break;
                case "--focus": core.OnFocusKey(); break;
                case "--stretch": core.StretchNow(); break;
                case "--toggle": core.ToggleRun(); break;
                case "--meeting": core.ToggleMeeting(); break;
                case "--quit": Quit(); break;
                case "--due" when Dev: core.DevDue(); break;
                case "--away" when Dev: core.CameBack(RaviCore.AwayReset + 1); break;
            }
        }

        // ------------------------------------------------------------ IRaviHost
        public bool HasFocus => focused;

        public string Theme
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                        return k?.GetValue("AppsUseLightTheme") is int v && v == 0 ? "dark" : "light";
                }
                catch (Exception) { return "light"; }
            }
        }

        static Color Background(string theme) => theme == "dark" ? Color.FromArgb(0x19, 0x1E, 0x1B) : Color.FromArgb(0xFB, 0xFC, 0xFA);

        public void Render(string stateJson)
        {
            if (jsReady) card.Exec("window.Ravi && Ravi.update(" + stateJson + ")");
        }

        public void Present(bool focus)
        {
            wantFocus |= focus;
            core.Push();
            if (onScreen)
            {
                if (wantFocus) { wantFocus = false; card.GrabFocus(); }
            }
            else
            {
                pendingShow = true;      // shown once the card reports its size for this mode
                showFallback.Stop();
                showFallback.Start();
            }
        }

        void ShowNow()
        {
            pendingShow = false;
            showFallback.Stop();
            if (core.Mode == "none") return;
            card.PlaceOnScreen(PxSize());
            onScreen = true;
            if (wantFocus) { wantFocus = false; card.GrabFocus(); }
        }

        public void HideCard()
        {
            pendingShow = false;
            wantFocus = false;
            if (focused) card.ReleaseFocus();
            card.PlaceOffscreen(PxSize());
            onScreen = false;
        }

        public void ReleaseFocus()
        {
            if (!focused) return;
            card.ReleaseFocus();
        }

        public void StatusChanged() => UpdateTray();

        // ------------------------------------------------------------ card messages
        void OnCardMessage(Dictionary<string, object> msg)
        {
            msg.TryGetValue("t", out var t);
            switch (t as string)
            {
                case "ready":
                    jsReady = true;
                    core.Push();
                    break;
                case "size":
                    if ((msg.TryGetValue("mode", out var m) ? m as string : null) != core.Mode) break;
                    cssSize = new Size(Convert.ToInt32(msg["w"]), Convert.ToInt32(msg["h"]));
                    ApplySize();
                    if (pendingShow) ShowNow();
                    break;
                default:
                    core.OnMessage(msg);
                    break;
            }
        }

        Size PxSize()
        {
            var s = card.DpiScale;
            return new Size((int)Math.Ceiling(cssSize.Width * s), (int)Math.Ceiling(cssSize.Height * s));
        }

        void ApplySize()
        {
            if (onScreen) card.PlaceOnScreen(PxSize());
            else card.PlaceOffscreen(PxSize());
        }

        void SetFocused(bool on)
        {
            if (on == focused) return;
            focused = on;
            core.FocusChanged();
            if (!on && core.Mode == "home")
            {
                // the home card behaves like a popover: click elsewhere and it goes away
                var t = new Timer { Interval = 200 };
                t.Tick += (_, __) => { t.Stop(); t.Dispose(); if (!focused && core.Mode == "home") core.HideCard(); };
                t.Start();
            }
        }

        // ------------------------------------------------------------ OS events
        void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
        {
            card.BeginInvoke((Action)(() =>
            {
                if (e.Reason == SessionSwitchReason.SessionLock) core.WentAway();
                else if (e.Reason == SessionSwitchReason.SessionUnlock) core.Back();
            }));
        }

        void OnPowerMode(object sender, PowerModeChangedEventArgs e)
        {
            card.BeginInvoke((Action)(() =>
            {
                if (e.Mode == PowerModes.Suspend) core.WentAway();
                else if (e.Mode == PowerModes.Resume) core.Back();
            }));
        }

        void OnPreferences(object sender, UserPreferenceChangedEventArgs e)
        {
            card.BeginInvoke((Action)(() =>
            {
                var theme = Theme;
                if (theme == lastTheme) return;
                lastTheme = theme;
                card.SetBackground(Background(theme));
                core.Push();
            }));
        }

        // ------------------------------------------------------------ tray
        static Icon LoadIcon(string name)
        {
            try
            {
                var p = Path.Combine(BaseDir, "assets", name);
                return File.Exists(p) ? new Icon(p, SystemInformation.SmallIconSize) : null;
            }
            catch (Exception) { return null; }
        }

        ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            miStatus = new ToolStripMenuItem("") { Enabled = false };
            menu.Items.Add(miStatus);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Show Ravi", null, (_, __) => core.OnShow()) { ShortcutKeyDisplayString = "Ctrl+Alt+R" });
            miRun = new ToolStripMenuItem("Pause", null, (_, __) => core.ToggleRun());
            menu.Items.Add(miRun);
            miMeeting = new ToolStripMenuItem("In a meeting", null, (_, __) => core.ToggleMeeting());
            menu.Items.Add(miMeeting);
            menu.Items.Add(new ToolStripMenuItem("Stretch now", null, (_, __) => core.StretchNow()));
            var every = new ToolStripMenuItem("Every");
            foreach (var m in RaviCore.Intervals)
            {
                var it = new ToolStripMenuItem($"{m} minutes", null, (_, __) => core.SetInterval(m));
                every.DropDownItems.Add(it);
                miEvery[m] = it;
            }
            menu.Items.Add(every);
            miSound = new ToolStripMenuItem("Chime", null, (_, __) => core.SetSound(!core.St.settings.sound));
            menu.Items.Add(miSound);
            miLogin = new ToolStripMenuItem("Open at login", null, (_, __) => { AutoStart.Set(!AutoStart.Enabled); UpdateTray(); });
            menu.Items.Add(miLogin);
            menu.Items.Add(new ToolStripSeparator());
            miToday = new ToolStripMenuItem("") { Enabled = false };
            menu.Items.Add(miToday);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit Ravi", null, (_, __) => Quit()));
            menu.Opening += (_, __) => UpdateTray();
            return menu;
        }

        void UpdateTray()
        {
            if (tray == null || quitting) return;
            var line = core.TrayLine();
            var tip = "Ravi · " + line;
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            var icon = core.Due ? iconDue : iconNormal;
            if (tray.Icon != icon) tray.Icon = icon;
            Set(miStatus, line);
            Set(miRun, core.RunLabel);
            Set(miToday, core.TodayLine());
            miMeeting.Checked = core.St.run.meeting;
            miSound.Checked = core.St.settings.sound;
            miLogin.Checked = AutoStart.Enabled;
            foreach (var kv in miEvery) kv.Value.Checked = kv.Key == core.Interval;
        }

        static void Set(ToolStripMenuItem it, string text)
        {
            if (it.Text != text) it.Text = text;
        }

        // ------------------------------------------------------------ quit & log
        void Quit()
        {
            if (quitting) return;
            quitting = true;
            core.Save();
            clock.Stop();
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            SystemEvents.PowerModeChanged -= OnPowerMode;
            SystemEvents.UserPreferenceChanged -= OnPreferences;
            hotkey.Dispose();
            tray.Visible = false;
            tray.Dispose();
            card.CloseForGood();
            ExitThread();
        }

        public static void Log(string text)
        {
            try
            {
                var p = Path.Combine(DataDir, "ravi.log");
                if (File.Exists(p) && new FileInfo(p).Length > 256 * 1024) File.Delete(p);
                File.AppendAllText(p, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + Environment.NewLine);
            }
            catch (Exception) { }
        }
    }

    /// <summary>"Open at login": a value under HKCU\...\Run, which is how Windows starts tray apps for you.</summary>
    static class AutoStart
    {
        const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string Name = "Ravi";

        public static bool Enabled
        {
            get
            {
                try { using (var k = Registry.CurrentUser.OpenSubKey(Key)) return k?.GetValue(Name) != null; }
                catch (Exception) { return false; }
            }
        }

        public static void Set(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(Key))
                {
                    if (on) k.SetValue(Name, "\"" + Application.ExecutablePath + "\" --autostart");
                    else k.DeleteValue(Name, false);
                }
            }
            catch (Exception e) { App.Log("couldn't change Open at login: " + e.Message); }
        }
    }
}
