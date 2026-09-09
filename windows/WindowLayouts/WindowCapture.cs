using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace WindowLayouts;

/// <summary>One top-level window on screen</summary>
public sealed class WindowInfo
{
    public IntPtr Hwnd { get; init; }
    public string Title { get; init; } = "";
    public WinFrame Frame { get; init; }
    public uint Pid { get; init; }
    /// <summary>"exe:<path>" or "aumid:…"</summary>
    public string AppId { get; init; } = "";
    public string AppName { get; init; } = "";
    public string? ExePath { get; init; }
    public bool IsMinimized { get; init; }
    public string? DisplayID { get; set; }
    /// <summary>For browser windows, the active tab's address</summary>
    public string? Url { get; set; }

    public WindowEntry MakeEntry(bool includeTitle = true, bool includeUrl = true) => new()
    {
        BundleID = AppId,
        AppName = AppName,
        Title = includeTitle ? Title : "",
        TitleMatch = includeTitle ? TitleMatch.Auto : TitleMatch.Order,
        Frame = Frame,
        DisplayID = DisplayID,
        Url = includeUrl ? Url : null,
    };
}

public sealed class CaptureRequest
{
    public List<WindowInfo> Windows { get; init; } = new();
    /// <summary>null saves a new layout; a value appends the windows to that layout</summary>
    public Guid? TargetLayoutId { get; init; }
    public DisplayConfig DisplayConfig { get; init; } = Displays.Current();
}

/// <summary>Window → app identifier. Executable path for classic apps, AppUserModelId for Store apps.</summary>
public static class AppIdentity
{
    public static (string appId, string appName, string? exePath) Resolve(IntPtr hwnd, uint pid)
    {
        uint realPid = pid;
        string? exe = Native.ProcessPath(pid);
        if (exe != null && Path.GetFileName(exe).Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase))
        {
            // For Store apps ApplicationFrameHost draws the frame; the real app is the process of the CoreWindow child
            var core = Native.FindChildByClass(hwnd, "Windows.UI.Core.CoreWindow");
            if (core != IntPtr.Zero)
            {
                Native.GetWindowThreadProcessId(core, out realPid);
                exe = Native.ProcessPath(realPid) ?? exe;
            }
        }
        var aumid = Native.Aumid(realPid);
        if (aumid != null) return ("aumid:" + aumid, NameFromAumid(aumid), exe);
        if (exe != null) return ("exe:" + exe, NameFromExe(exe), exe);
        return ("pid:" + pid, Loc.T("app.unknown"), null);
    }

    public static string? ExePathOf(string appId) => appId.StartsWith("exe:", StringComparison.Ordinal) ? appId.Substring(4) : null;
    public static string? AumidOf(string appId) => appId.StartsWith("aumid:", StringComparison.Ordinal) ? appId.Substring(6) : null;

    /// <summary>Process IDs running this app</summary>
    public static List<uint> RunningProcessIds(string appId)
    {
        var ids = new List<uint>();
        var exe = ExePathOf(appId);
        var aumid = AumidOf(appId);
        if (exe == null && aumid == null) return ids;
        var exeName = exe != null ? Path.GetFileNameWithoutExtension(exe) : null;
        Process[] processes;
        try { processes = exeName != null ? Process.GetProcessesByName(exeName) : Process.GetProcesses(); }
        catch { return ids; }
        foreach (var p in processes)
        {
            try
            {
                uint pid = (uint)p.Id;
                if (exe != null)
                {
                    var path = Native.ProcessPath(pid);
                    if (path != null && string.Equals(path, exe, StringComparison.OrdinalIgnoreCase)) ids.Add(pid);
                }
                else if (aumid != null)
                {
                    var a = Native.Aumid(pid);
                    if (a != null && string.Equals(a, aumid, StringComparison.OrdinalIgnoreCase)) ids.Add(pid);
                }
            }
            catch { }
            finally { p.Dispose(); }
        }
        return ids;
    }

    /// <summary>Launch the app. A running single-instance app usually shows its window again.</summary>
    public static bool Launch(string appId)
    {
        try
        {
            var exe = ExePathOf(appId);
            if (exe != null && File.Exists(exe))
            {
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(exe) ?? "" });
                return true;
            }
            var aumid = AumidOf(appId);
            if (aumid != null)
            {
                Process.Start(new ProcessStartInfo("explorer.exe", "shell:AppsFolder\\" + aumid) { UseShellExecute = true });
                return true;
            }
        }
        catch { }
        return false;
    }

    private static string NameFromExe(string exe)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(exe);
            if (!string.IsNullOrWhiteSpace(info.FileDescription)) return info.FileDescription!.Trim();
            if (!string.IsNullOrWhiteSpace(info.ProductName)) return info.ProductName!.Trim();
        }
        catch { }
        return Path.GetFileNameWithoutExtension(exe);
    }

    private static string NameFromAumid(string aumid)
    {
        var family = aumid.Split('!')[0];
        var package = family.Split('_')[0];
        var last = package.Split('.').LastOrDefault();
        return string.IsNullOrEmpty(last) ? aumid : last;
    }
}

public static class WindowCapture
{
    private static readonly HashSet<string> ExcludedClasses = new(StringComparer.Ordinal)
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow",
        "NotifyIconOverflowWindow", "Xaml_WindowedPopupClass", "DV2ControlHost",
    };

    /// <summary>Top-level windows. EnumWindows returns them front to back (z-order).</summary>
    public static List<WindowInfo> TopLevelWindows(bool includeMinimized)
    {
        var result = new List<WindowInfo>();
        uint myPid = (uint)Environment.ProcessId;
        Native.EnumWindowsProc callback = (hwnd, l) =>
        {
            var w = Describe(hwnd, myPid);
            if (w != null && (includeMinimized || !w.IsMinimized)) result.Add(w);
            return true;
        };
        Native.EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return result;
    }

    private static WindowInfo? Describe(IntPtr hwnd, uint myPid)
    {
        if (!Native.IsWindowVisible(hwnd)) return null;
        if (Native.GetWindow(hwnd, Native.GW_OWNER) != IntPtr.Zero) return null;
        long ex = Native.GetWindowLongPtrW(hwnd, Native.GWL_EXSTYLE).ToInt64();
        if ((ex & Native.WS_EX_TOOLWINDOW) != 0) return null;
        if (Native.IsCloaked(hwnd)) return null;
        if (ExcludedClasses.Contains(Native.GetClassName(hwnd))) return null;
        var title = Native.GetWindowText(hwnd);
        if (title.Length == 0) return null;
        Native.GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == myPid) return null;
        var (appId, appName, exe) = AppIdentity.Resolve(hwnd, pid);
        bool minimized = Native.IsIconic(hwnd);
        var frame = Native.GetExtendedFrame(hwnd);
        if (!minimized && (frame.Width < 2 || frame.Height < 2)) return null;
        return new WindowInfo
        {
            Hwnd = hwnd, Title = title, Frame = frame, Pid = pid,
            AppId = appId, AppName = appName, ExePath = exe, IsMinimized = minimized,
        };
    }

    /// <summary>For saving: the windows visible now (minimized excluded) + monitor + browser address</summary>
    public static List<WindowInfo> CurrentWindows()
    {
        var config = Displays.Current();
        var list = TopLevelWindows(includeMinimized: false);
        foreach (var w in list)
        {
            var d = config.DisplayContaining(w.Frame.MidX, w.Frame.MidY) ?? config.DisplayContaining(w.Frame.X, w.Frame.Y);
            w.DisplayID = d?.Id;
            if (BrowserSupport.IsBrowser(w.AppId)) w.Url = BrowserSupport.ActiveTabUrl(w.Hwnd);
        }
        return list;
    }

    /// <summary>For applying: this app's windows (including minimized ones)</summary>
    public static List<WindowInfo> WindowsOf(string appId) =>
        TopLevelWindows(includeMinimized: true)
            .Where(w => string.Equals(w.AppId, appId, StringComparison.OrdinalIgnoreCase))
            .ToList();
}
