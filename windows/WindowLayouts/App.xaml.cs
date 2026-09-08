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

        // 한 번에 하나만 실행. 두 번째 실행은 명령을 첫 인스턴스에 넘기고 끝낸다.
        _mutex = new Mutex(true, "Local\\WindowLayouts.SingleInstance", out bool createdNew);
        if (!createdNew)
        {
            Ipc.Send(e.Args.Length > 0 ? e.Args : new[] { "--settings" });
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var store = LayoutStore.Shared;
        ApplyLog.Write("앱 시작");
        _tray = new TrayIcon();
        Ipc.StartServer(HandleArgs);
        HandleArgs(e.Args);

        // 저장된 배치가 하나도 없는 첫 실행에만 설정 창을 연다
        if (store.Layouts.Count == 0 && !e.Args.Contains("--background")) ShowMainWindow();
    }

    /// <summary>--apply "배치이름"  /  --apply UUID  /  --settings</summary>
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
                else ApplyLog.Write("명령줄로 요청한 배치를 찾지 못함: " + key);
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
