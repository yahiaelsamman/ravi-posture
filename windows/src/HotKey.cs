using System;
using System.Windows.Forms;

namespace Ravi
{
    /// <summary>A system-wide shortcut (RegisterHotKey) that works whichever app is in front.</summary>
    sealed class HotKey : NativeWindow, IDisposable
    {
        const int Id = 0x5241;   // "RA"
        readonly Action pressed;
        public bool Registered { get; }

        public HotKey(uint modifiers, Keys key, Action pressed)
        {
            this.pressed = pressed;
            CreateHandle(new CreateParams());
            Registered = Native.RegisterHotKey(Handle, Id, modifiers | Native.MOD_NOREPEAT, (uint)key);
            if (!Registered) App.Log("Ctrl+Alt+R is already registered by another app");
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == Id)
            {
                pressed();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Registered) Native.UnregisterHotKey(Handle, Id);
            DestroyHandle();
        }
    }
}
