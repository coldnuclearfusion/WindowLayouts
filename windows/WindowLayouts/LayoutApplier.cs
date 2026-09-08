using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace WindowLayouts;

public sealed class ApplyReport
{
    public Guid LayoutId { get; init; }
    public string LayoutName { get; init; } = "";
    public List<string> Placed { get; } = new();
    public List<string> Unmatched { get; } = new();
    public List<string> Launched { get; } = new();
    public List<string> NotRunning { get; } = new();
    public List<string> Failed { get; } = new();
    public List<string> Mismatched { get; } = new();
    public List<string> Notes { get; } = new();
    public bool Cancelled { get; set; }
    public string? Error { get; set; }

    public string Headline
    {
        get
        {
            if (Error != null) return Error;
            if (Cancelled) return Loc.T("report.cancelled", ("name", LayoutName));
            var s = Loc.T("report.headline", ("name", LayoutName), ("placed", Placed.Count));
            if (Unmatched.Count > 0) s += Loc.T("report.unmatched_suffix", ("count", Unmatched.Count));
            if (Mismatched.Count > 0) s += Loc.T("report.mismatched_suffix", ("count", Mismatched.Count));
            if (Failed.Count > 0) s += Loc.T("report.failed_suffix", ("count", Failed.Count));
            return s;
        }
    }

    public List<string> Lines
    {
        get
        {
            var l = new List<string>(Notes);
            if (Launched.Count > 0) l.Add(Loc.T("report.launched", ("list", string.Join(", ", Launched))));
            if (NotRunning.Count > 0) l.Add(Loc.T("report.not_running", ("list", string.Join(", ", NotRunning))));
            if (Unmatched.Count > 0) l.Add(Loc.T("report.unmatched", ("list", string.Join(", ", Unmatched))));
            if (Failed.Count > 0) l.Add(Loc.T("report.failed", ("list", string.Join(", ", Failed))));
            if (Mismatched.Count > 0) l.Add(Loc.T("report.mismatched", ("list", string.Join(" · ", Mismatched))));
            return l;
        }
    }
}

public enum PlaceKind { Placed, Mismatch, Failed }
public readonly record struct PlaceOutcome(PlaceKind Kind, WinFrame Actual);

public sealed class LayoutApplier
{
    public static LayoutApplier Shared { get; } = new();

    public bool IsApplying { get; private set; }
    public ApplyReport? LastReport { get; private set; }
    public event Action? ReportChanged;

    private enum MissingChoice { Launch, Skip, Cancel }

    /// <summary>UI 스레드에서 호출한다 (대화상자를 띄울 수 있음).</summary>
    public async Task Apply(WindowLayout layout)
    {
        if (IsApplying) return;
        IsApplying = true;
        var report = new ApplyReport { LayoutId = layout.Id, LayoutName = layout.Name };
        ApplyLog.Write(Loc.T("log.start", ("name", layout.Name), ("policy", layout.LaunchPolicy.Key()), ("raise", layout.RaiseWindows)));
        try
        {
            await ApplyCore(layout, report);
        }
        catch (Exception ex)
        {
            report.Error = Loc.T("report.error", ("error", ex.Message));
            ApplyLog.Write("error: " + ex);
        }
        finally
        {
            LastReport = report;
            IsApplying = false;
            ApplyLog.Write(Loc.T("log.end", ("summary", report.Headline + " " + string.Join(" | ", report.Lines))));
            ReportChanged?.Invoke();
        }
    }

    private async Task ApplyCore(WindowLayout layout, ApplyReport report)
    {
        var entries = layout.Windows.Where(w => w.Enabled).ToList();
        var appIds = layout.EnabledAppIds;
        var currentConfig = Displays.Current();
        ApplyLog.Write(Loc.T("log.monitors", ("list", string.Join(" / ",
            currentConfig.Displays.Select(d => $"{d.Name} {d.Frame.ShortDescription}{(d.IsMain ? Loc.T("log.main_suffix") : "")}")))));
        if (layout.DisplayConfig != null && !layout.DisplayConfig.IsIdentical(currentConfig))
            report.Notes.Add(Loc.T("report.config_differs", ("saved", layout.DisplayConfig.Name), ("current", currentConfig.Name)));

        var missing = appIds.Where(id => AppIdentity.RunningProcessIds(id).Count == 0).ToList();
        // 프로세스는 살아 있지만(트레이 상주 등) 보이는 창이 하나도 없는 앱
        var windowless = appIds.Where(id =>
        {
            if (missing.Contains(id)) return false;
            var appEntries = entries.Where(e => e.BundleID == id).ToList();
            if (BrowserSupport.IsBrowser(id) && appEntries.All(e => e.HasUrl)) return false; // 주소로 새 창을 열 것
            return WindowCapture.WindowsOf(id).Count == 0;
        }).ToList();
        var needsOpen = missing.Concat(windowless).ToList();
        var skipped = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool allowNewWindows = layout.LaunchPolicy != LaunchPolicy.RunningOnly;

        string Label(string id) => layout.AppName(id) + (windowless.Contains(id) ? Loc.T("report.windowless_suffix") : "");

        if (needsOpen.Count > 0)
        {
            var policy = layout.LaunchPolicy;
            if (policy == LaunchPolicy.Ask)
            {
                var (choice, remember) = AskAboutMissing(needsOpen.Select(Label).ToList(), layout.Name);
                switch (choice)
                {
                    case MissingChoice.Launch:
                        policy = LaunchPolicy.LaunchMissing;
                        if (remember) LayoutStore.Shared.SetLaunchPolicy(policy, layout.Id);
                        break;
                    case MissingChoice.Skip:
                        policy = LaunchPolicy.RunningOnly;
                        if (remember) LayoutStore.Shared.SetLaunchPolicy(policy, layout.Id);
                        break;
                    default:
                        report.Cancelled = true;
                        return;
                }
            }

            if (policy == LaunchPolicy.LaunchMissing)
            {
                var toWait = new Dictionary<string, int>();
                foreach (var id in needsOpen)
                {
                    bool reopen = windowless.Contains(id);
                    if (AppIdentity.Launch(id))
                    {
                        report.Launched.Add(layout.AppName(id) + (reopen ? Loc.T("report.new_window_suffix") : ""));
                        toWait[id] = entries.Count(e => e.BundleID == id);
                    }
                    else
                    {
                        report.Failed.Add(Loc.T("report.app_not_found", ("app", layout.AppName(id))));
                        skipped.Add(id);
                    }
                }
                await WaitForWindows(toWait);
            }
            else
            {
                allowNewWindows = false;
                foreach (var id in needsOpen)
                {
                    skipped.Add(id);
                    report.NotRunning.Add(Label(id));
                }
            }
        }

        // 앱별로 창을 짝지어 옮기기
        var placed = new List<(WindowEntry entry, WindowInfo window)>();
        foreach (var id in appIds)
        {
            if (skipped.Contains(id)) continue;
            var windows = WindowCapture.WindowsOf(id);
            var appEntries = entries.Where(e => e.BundleID == id).ToList();
            var matches = new List<(WindowEntry entry, WindowInfo? window)>();

            // 브라우저: 주소가 지정된 항목은 그 페이지를 보여주는 창을 먼저 찾고, 없으면 새 창으로 연다
            if (BrowserSupport.IsBrowser(id))
            {
                foreach (var entry in appEntries.Where(e => e.HasUrl).ToList())
                {
                    var (window, note) = await ResolveBrowserWindow(entry, id, windows, allowNewWindows);
                    if (note != null && !report.Notes.Contains(note)) report.Notes.Add(note);
                    if (window != null)
                    {
                        matches.Add((entry, window));
                        windows.RemoveAll(w => w.Hwnd == window.Hwnd);
                        appEntries.Remove(entry);
                    }
                }
            }
            matches.AddRange(WindowMatcher.Match(appEntries, windows));

            foreach (var (entry, window) in matches)
            {
                if (window == null)
                {
                    report.Unmatched.Add(entry.DisplayName);
                    ApplyLog.Write(Loc.T("log.no_match", ("window", entry.DisplayName), ("count", windows.Count)));
                    continue;
                }
                var frame = TargetFrame(entry, layout.DisplayConfig, currentConfig);
                ApplyLog.Write(Loc.T("log.assigned", ("window", entry.DisplayName), ("title", window.Title)));
                var outcome = await Place(window.Hwnd, frame, s => ApplyLog.Write($"[{entry.DisplayName}] {s}"));
                switch (outcome.Kind)
                {
                    case PlaceKind.Placed:
                        report.Placed.Add(entry.DisplayName);
                        placed.Add((entry, window));
                        break;
                    case PlaceKind.Mismatch:
                        report.Placed.Add(entry.DisplayName);
                        report.Mismatched.Add(Loc.T("report.mismatch_item", ("window", entry.DisplayName), ("requested", frame.ShortDescription), ("actual", outcome.Actual.ShortDescription)));
                        placed.Add((entry, window));
                        break;
                    default:
                        report.Failed.Add(entry.DisplayName);
                        break;
                }
            }
        }

        if (layout.RaiseWindows && placed.Count > 0)
        {
            int failures = await Raise(placed, layout.Windows.Select(w => w.Id).ToList());
            if (failures > 0) report.Notes.Add(Loc.T("report.raise_failed", ("count", failures)));
        }

        LayoutStore.Shared.LastAppliedId = layout.Id;
    }

    /// <summary>
    /// 모니터 구성이 저장 당시와 다르면, 창이 있던 모니터를 찾아 그 모니터 기준 상대 위치로 옮기고
    /// 그 모니터가 없으면 주 모니터에 놓는다. 화면 밖으로 나가지 않게 잘라 맞춘다.
    /// </summary>
    public static WinFrame TargetFrame(WindowEntry entry, DisplayConfig? saved, DisplayConfig current)
    {
        if (saved == null || saved.IsIdentical(current) || current.Main == null) return entry.Frame;
        var savedDisplay = saved.DisplayWithId(entry.DisplayID)
            ?? saved.DisplayContaining(entry.Frame.MidX, entry.Frame.MidY)
            ?? saved.Main;
        if (savedDisplay == null) return entry.Frame;
        var target = current.DisplayWithId(savedDisplay.Id) ?? current.Main!;
        double x = target.X + (entry.X - savedDisplay.X);
        double y = target.Y + (entry.Y - savedDisplay.Y);
        double w = Math.Min(entry.Width, target.Width);
        double h = Math.Min(entry.Height, target.Height);
        x = Math.Max(target.X, Math.Min(x, target.Frame.Right - w));
        y = Math.Max(target.Y, Math.Min(y, target.Frame.Bottom - h));
        return new WinFrame(x, y, w, h);
    }

    /// <summary>
    /// 창을 옮기고 실제로 그렇게 됐는지 읽어서 확인한다. 안 맞으면 최대 3번 시도한다.
    /// DPI가 다른 모니터로 옮기면 앱이 WM_DPICHANGED를 받아 크기를 다시 잡으므로 두 번째 시도에서 맞는 경우가 많다.
    /// 좌표는 보이는 테두리 기준이라, 투명 테두리만큼 보정해서 SetWindowPos에 넘긴다.
    /// </summary>
    public static async Task<PlaceOutcome> Place(IntPtr hwnd, WinFrame target, Action<string>? log = null)
    {
        if (!Native.IsWindow(hwnd)) return new PlaceOutcome(PlaceKind.Failed, default);
        if (Native.IsIconic(hwnd) || Native.IsZoomed(hwnd))
        {
            Native.ShowWindow(hwnd, Native.SW_RESTORE);
            await Task.Delay(150);
        }
        log?.Invoke(Loc.T("log.place_start", ("from", Native.GetExtendedFrame(hwnd).ShortDescription), ("to", target.ShortDescription)));

        bool any = false;
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            if (attempt > 1) await Task.Delay(attempt == 2 ? 150 : 300);
            if (!Native.GetWindowRect(hwnd, out var wr)) break;
            Native.TryGetExtendedFrame(hwnd, out var eb);
            int dl = eb.Left - wr.Left, dt = eb.Top - wr.Top, dr = wr.Right - eb.Right, db = wr.Bottom - eb.Bottom;
            int x = (int)Math.Round(target.X) - dl;
            int y = (int)Math.Round(target.Y) - dt;
            int w = (int)Math.Round(target.Width) + dl + dr;
            int h = (int)Math.Round(target.Height) + dt + db;
            any |= Native.SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
            await Task.Delay(attempt == 1 ? 80 : 150);
            var now = Native.GetExtendedFrame(hwnd);
            bool match = now.ApproximatelyEquals(target, 2);
            log?.Invoke(Loc.T("log.place_attempt", ("attempt", attempt), ("result", now.ShortDescription)) + (match ? " ✓" : ""));
            if (match) return new PlaceOutcome(PlaceKind.Placed, now);
        }
        if (!any) return new PlaceOutcome(PlaceKind.Failed, default);
        return new PlaceOutcome(PlaceKind.Mismatch, Native.GetExtendedFrame(hwnd));
    }

    /// <summary>저장된 항목의 위치/크기를 지금 실제 창 위치로 갱신하고, 모니터 구성도 현재 것으로 바꾼다. 갱신된 창 수를 돌려준다.</summary>
    public int RefreshFrames(WindowLayout layout)
    {
        int updated = 0;
        var config = Displays.Current();
        layout.DisplayConfig = config;
        foreach (var group in layout.Windows.GroupBy(w => w.BundleID))
        {
            var windows = WindowCapture.WindowsOf(group.Key);
            foreach (var (entry, window) in WindowMatcher.Match(group.ToList(), windows))
            {
                if (window == null) continue;
                entry.Frame = window.Frame;
                entry.DisplayID = config.DisplayContaining(window.Frame.MidX, window.Frame.MidY)?.Id;
                updated++;
            }
        }
        return updated;
    }

    // ---- 실행 대기

    private static async Task WaitForWindows(Dictionary<string, int> needed)
    {
        if (needed.Count == 0) return;
        var pending = new HashSet<string>(needed.Keys);
        var deadline = DateTime.Now.AddSeconds(20);
        while (pending.Count > 0 && DateTime.Now < deadline)
        {
            await Task.Delay(400);
            foreach (var id in pending.ToList())
                if (WindowCapture.WindowsOf(id).Count > 0) pending.Remove(id);
        }
        var extraDeadline = DateTime.Now.AddSeconds(4);
        var few = needed.Where(kv => kv.Value > 1).Select(kv => kv.Key).ToHashSet();
        while (few.Count > 0 && DateTime.Now < extraDeadline)
        {
            await Task.Delay(400);
            foreach (var id in few.ToList())
                if (WindowCapture.WindowsOf(id).Count >= needed[id]) few.Remove(id);
        }
        await Task.Delay(500);
    }

    // ---- 브라우저

    private static async Task<(WindowInfo? window, string? note)> ResolveBrowserWindow(
        WindowEntry entry, string appId, List<WindowInfo> windows, bool allowNewWindow)
    {
        var url = (entry.Url ?? "").Trim();
        foreach (var w in windows)
        {
            var current = BrowserSupport.ActiveTabUrl(w.Hwnd);
            if (current != null && BrowserSupport.Matches(url, current)) return (w, null);
        }
        if (!allowNewWindow) return (null, null);

        var before = WindowCapture.WindowsOf(appId).Select(w => w.Hwnd).ToHashSet();
        if (!BrowserSupport.OpenInNewWindow(appId, url))
            return (null, Loc.T("report.new_window_failed", ("app", entry.AppName), ("url", url)));
        var deadline = DateTime.Now.AddSeconds(10);
        while (DateTime.Now < deadline)
        {
            await Task.Delay(300);
            var fresh = WindowCapture.WindowsOf(appId).FirstOrDefault(w => !before.Contains(w.Hwnd));
            if (fresh != null)
            {
                await Task.Delay(300);
                return (fresh, Loc.T("report.opened_new_window", ("app", entry.AppName), ("url", url), ("reason", Loc.T("report.reason_windows_tabs"))));
            }
        }
        return (null, Loc.T("report.new_window_timeout", ("app", entry.AppName), ("url", url)));
    }

    // ---- 앞으로 올리기

    /// <summary>앱 단위로 뒤에서부터 창을 올려서, 마지막에 첫 항목이 맨 앞에 오게 한다.</summary>
    private static async Task<int> Raise(List<(WindowEntry entry, WindowInfo window)> placed, List<Guid> order)
    {
        var position = new Dictionary<Guid, int>();
        for (int i = 0; i < order.Count; i++) position[order[i]] = i;
        var sorted = placed.OrderBy(p => position.TryGetValue(p.entry.Id, out var i) ? i : 0).ToList();

        var groups = new List<(string appId, List<(WindowEntry entry, WindowInfo window)> items)>();
        foreach (var item in sorted)
        {
            int g = groups.FindIndex(x => string.Equals(x.appId, item.entry.BundleID, StringComparison.OrdinalIgnoreCase));
            if (g >= 0) groups[g].items.Add(item);
            else groups.Add((item.entry.BundleID, new List<(WindowEntry entry, WindowInfo window)> { item }));
        }

        int failures = 0;
        for (int gi = groups.Count - 1; gi >= 0; gi--)
        {
            var items = groups[gi].items;
            for (int k = items.Count - 1; k >= 0; k--)
            {
                var hwnd = items[k].window.Hwnd;
                if (!Native.SetWindowPos(hwnd, Native.HWND_TOP, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE)) failures++;
                await Task.Delay(30);
            }
        }
        if (sorted.Count > 0) ForceForeground(sorted[0].window.Hwnd);
        return failures;
    }

    /// <summary>다른 프로세스 창에 포커스를 주기 위한 관용구 (포그라운드 잠금 우회)</summary>
    private static void ForceForeground(IntPtr hwnd)
    {
        try
        {
            var fg = Native.GetForegroundWindow();
            uint fgThread = fg != IntPtr.Zero ? Native.GetWindowThreadProcessId(fg, out _) : 0;
            uint me = Native.GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != me && Native.AttachThreadInput(fgThread, me, true);
            Native.keybd_event(Native.VK_MENU, 0, 0, UIntPtr.Zero);
            Native.keybd_event(Native.VK_MENU, 0, Native.KEYEVENTF_KEYUP, UIntPtr.Zero);
            Native.BringWindowToTop(hwnd);
            Native.SetForegroundWindow(hwnd);
            if (attached) Native.AttachThreadInput(fgThread, me, false);
        }
        catch { }
    }

    // ---- 물어보기

    private static (MissingChoice choice, bool remember) AskAboutMissing(List<string> names, string layoutName)
    {
        var dialog = new AskMissingDialog(names, layoutName);
        var owner = App.Main;
        if (owner != null && owner.IsVisible) dialog.Owner = owner;
        dialog.ShowDialog();
        var choice = dialog.Choice switch
        {
            AskMissingDialog.Result.Launch => MissingChoice.Launch,
            AskMissingDialog.Result.Skip => MissingChoice.Skip,
            _ => MissingChoice.Cancel,
        };
        return (choice, dialog.Remember);
    }
}
