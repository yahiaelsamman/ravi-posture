using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;

namespace Ravi
{
    /// <summary>Lets a second "Ravi.exe --stretch" (or a click on the Start menu entry) talk to the running Ravi.</summary>
    static class Ipc
    {
        static string PipeName => "RaviTheRavioli-" + Environment.UserName;

        public static void Listen(Action<string> onCommand)
        {
            var t = new Thread(() =>
            {
                while (true)
                {
                    try
                    {
                        using (var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1))
                        {
                            server.WaitForConnection();
                            using (var reader = new StreamReader(server))
                            {
                                var line = reader.ReadLine();
                                if (!string.IsNullOrEmpty(line)) onCommand(line.Trim());
                            }
                        }
                    }
                    catch (Exception e)
                    {
                        App.Log("pipe: " + e.Message);
                        Thread.Sleep(1000);
                    }
                }
            }) { IsBackground = true, Name = "ravi-ipc" };
            t.Start();
        }

        public static bool Send(string command)
        {
            try
            {
                Native.AllowSetForegroundWindow(Native.ASFW_ANY);   // so the running Ravi may bring its card forward
                using (var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
                {
                    client.Connect(3000);
                    using (var writer = new StreamWriter(client)) writer.WriteLine(command);
                }
                return true;
            }
            catch (Exception) { return false; }
        }
    }
}
