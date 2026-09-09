using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;

namespace WindowLayouts;

/// <summary>
/// The channel through which a second instance (e.g. WindowLayouts.exe --apply "NAME") hands its command to the first one.
/// </summary>
public static class Ipc
{
    private const string PipeName = "WindowLayouts.Commands";

    public static void StartServer(Action<string[]> handler)
    {
        var thread = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1);
                    server.WaitForConnection();
                    using var reader = new StreamReader(server);
                    var text = reader.ReadToEnd();
                    var args = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    var app = System.Windows.Application.Current;
                    app?.Dispatcher.InvokeAsync(() => handler(args));
                }
                catch
                {
                    Thread.Sleep(500);
                }
            }
        })
        { IsBackground = true, Name = "WindowLayouts IPC" };
        thread.Start();
    }

    public static void Send(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(2000);
            using var writer = new StreamWriter(client);
            writer.Write(string.Join("\n", args));
            writer.Flush();
        }
        catch { }
    }
}
