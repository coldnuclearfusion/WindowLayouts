using System;
using System.Linq;
using System.Threading;
using System.Windows;

namespace WindowLayouts;

public partial class App : Application
{
    private static Mutex? _mutex;
    private TrayIcon? _tray;

    public static MainWindow? Main { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Single instance: a second instance forwards its command to the first one and exits.
        _mutex = new Mutex(true, "Local\\WindowLayouts.SingleInstance", out bool createdNew);
        if (!createdNew)
        {
            Ipc.Send(e.Args.Length > 0 ? e.Args : new[] { "--settings" });
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var store = LayoutStore.Shared;
        ApplyLog.Write(Loc.T("log.app_start"));
        _tray = new TrayIcon();
        // Recreate the open settings window in the new language when it changes
        Loc.Changed += () =>
        {
            if (Main == null) return;
            var old = Main;
            Main = null;
            old.Close();
            ShowMainWindow();
            Main?.ShowGeneral();
        };
        Ipc.StartServer(HandleArgs);
        HandleArgs(e.Args);

        // Open the settings window only on the first launch, when no layouts are saved yet
        if (store.Layouts.Count == 0 && !e.Args.Contains("--background")) ShowMainWindow();
    }

    /// <summary>--apply "NAME"  /  --apply UUID  /  --settings</summary>
    private static void HandleArgs(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--apply" && i + 1 < args.Length)
            {
                var key = args[++i];
                var layout = LayoutStore.Shared.Layouts.FirstOrDefault(l =>
                    l.Name == key || string.Equals(l.Id.ToString(), key, StringComparison.OrdinalIgnoreCase));
                if (layout != null) _ = LayoutApplier.Shared.Apply(layout);
                else ApplyLog.Write(Loc.T("log.cli_not_found", ("name", key)));
            }
            else if (args[i] == "--settings")
            {
                ShowMainWindow();
            }
        }
    }

    public static void ShowMainWindow(CaptureRequest? capture = null)
    {
        if (Main == null)
        {
            Main = new MainWindow();
            Main.Closed += (s, e) => Main = null;
        }
        Main.Show();
        if (Main.WindowState == WindowState.Minimized) Main.WindowState = WindowState.Normal;
        Main.Activate();
        if (capture != null) Main.BeginCapture(capture);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        try { _mutex?.ReleaseMutex(); } catch { }
        base.OnExit(e);
    }
}
