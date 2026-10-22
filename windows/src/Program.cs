// Ravi.exe [--focus | --show | --stretch | --toggle | --meeting | --quit]
// One Ravi per user: a second launch passes its command to the running one and exits.
using System;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace Ravi
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            var command = args.FirstOrDefault(a => a.StartsWith("--", StringComparison.Ordinal)) ?? "";
            using (var mutex = new Mutex(true, @"Local\RaviTheRavioli", out bool first))
            {
                if (!first)
                {
                    Ipc.Send(command == "" ? "--show" : command);
                    return 0;
                }
                if (command == "--quit") return 0;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (_, e) => App.Log("error: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (_, e) => App.Log("fatal: " + e.ExceptionObject);
                Application.Run(new App(command));
                GC.KeepAlive(mutex);
            }
            return 0;
        }
    }
}
