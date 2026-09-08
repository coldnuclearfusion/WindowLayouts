using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace WindowLayouts;

/// <summary>화면에 있는 최상위 창 하나</summary>
public sealed class WindowInfo
{
    public IntPtr Hwnd { get; init; }
    public string Title { get; init; } = "";
    public WinFrame Frame { get; init; }
    public uint Pid { get; init; }
    /// <summary>"exe:경로" 또는 "aumid:…"</summary>
    public string AppId { get; init; } = "";
    public string AppName { get; init; } = "";
    public string? ExePath { get; init; }
    public bool IsMinimized { get; init; }
    public string? DisplayID { get; set; }
    /// <summary>브라우저 창이면 활성 탭의 주소</summary>
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
    /// <summary>null이면 새 배치로 저장, 값이 있으면 그 배치에 창 추가</summary>
    public Guid? TargetLayoutId { get; init; }
    public DisplayConfig DisplayConfig { get; init; } = Displays.Current();
}

/// <summary>창 → 앱 식별자. 일반 앱은 실행 파일 경로, 스토어 앱은 AppUserModelId.</summary>
public static class AppIdentity
{
    public static (string appId, string appName, string? exePath) Resolve(IntPtr hwnd, uint pid)
    {
        uint realPid = pid;
        string? exe = Native.ProcessPath(pid);
        if (exe != null && Path.GetFileName(exe).Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase))
        {
            // 스토어 앱은 ApplicationFrameHost가 창틀을 그리고, 실제 앱은 CoreWindow 자식 창의 프로세스
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

    /// <summary>이 앱으로 실행 중인 프로세스 ID들</summary>
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

    /// <summary>앱을 실행한다. 이미 실행 중인 단일 인스턴스 앱이면 보통 창을 다시 보여 준다.</summary>
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

    /// <summary>최상위 창 목록. EnumWindows는 앞→뒤(z-order) 순서로 돌려준다.</summary>
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

    /// <summary>저장용: 지금 보이는 창들 (최소화 제외) + 모니터 + 브라우저 주소</summary>
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

    /// <summary>적용용: 이 앱의 창들 (최소화 포함)</summary>
    public static List<WindowInfo> WindowsOf(string appId) =>
        TopLevelWindows(includeMinimized: true)
            .Where(w => string.Equals(w.AppId, appId, StringComparison.OrdinalIgnoreCase))
            .ToList();
}
