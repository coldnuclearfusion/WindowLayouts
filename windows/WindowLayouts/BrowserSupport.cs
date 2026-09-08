using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows.Automation;

namespace WindowLayouts;

/// <summary>
/// 브라우저 창을 페이지 주소로 찾거나 새 창으로 여는 기능.
/// Windows에서는 UI 자동화(UIA)로 주소창 값을 읽어 각 창의 활성 탭 주소만 알 수 있다.
/// 뒤에 숨은 탭의 주소는 볼 수 없으므로, 없으면 새 창을 연다.
/// </summary>
public static class BrowserSupport
{
    private static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome.exe", "msedge.exe", "brave.exe", "vivaldi.exe", "opera.exe", "opera_gx.exe", "arc.exe",
        "firefox.exe", "floorp.exe", "zen.exe", "librewolf.exe", "waterfox.exe",
    };

    public static bool IsBrowser(string appId)
    {
        var exe = AppIdentity.ExePathOf(appId);
        return exe != null && Browsers.Contains(Path.GetFileName(exe));
    }

    // ---- 주소 비교

    /// <summary>비교용 정규화: 소문자 호스트, www. 제거, 끝의 / 와 #조각 제거, 스킴 제거</summary>
    public static string Normalize(string raw)
    {
        var s = raw.Trim();
        int hash = s.IndexOf('#');
        if (hash >= 0) s = s.Substring(0, hash);
        if (s.Length == 0) return "";
        if (!s.Contains("://")) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
            return s.ToLowerInvariant().Trim('/');
        var host = uri.Host.ToLowerInvariant();
        if (host.StartsWith("www.", StringComparison.Ordinal)) host = host.Substring(4);
        var path = uri.AbsolutePath;
        while (path.EndsWith("/", StringComparison.Ordinal)) path = path.Substring(0, path.Length - 1);
        return host + path + uri.Query;
    }

    /// <summary>저장된 주소가 열린 탭 주소의 앞부분과 같으면 같은 페이지로 본다. 예: "youtube.com" ↔ "https://www.youtube.com/watch?v=…"</summary>
    public static bool Matches(string saved, string candidate)
    {
        var a = Normalize(saved);
        var b = Normalize(candidate);
        if (a.Length == 0 || b.Length == 0) return false;
        if (a == b) return true;
        if (!b.StartsWith(a, StringComparison.Ordinal)) return false;
        char next = b[a.Length];
        return next == '/' || next == '?' || next == '&';
    }

    // ---- 활성 탭 주소 (UI 자동화)

    /// <summary>창의 주소창에서 현재 탭의 주소를 읽는다. 못 읽으면 null.</summary>
    public static string? ActiveTabUrl(IntPtr hwnd)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                new PropertyCondition(AutomationElement.IsValuePatternAvailableProperty, true));
            var edits = root.FindAll(TreeScope.Descendants, condition);
            foreach (AutomationElement edit in edits)
            {
                if (!edit.TryGetCurrentPattern(ValuePattern.Pattern, out object patternObj)) continue;
                var value = ((ValuePattern)patternObj).Current.Value?.Trim();
                if (LooksLikeUrl(value)) return value;
            }
        }
        catch { }
        return null;
    }

    private static bool LooksLikeUrl(string? v)
    {
        if (string.IsNullOrEmpty(v) || v.Contains(' ')) return false;
        return v.Contains("://") || v.StartsWith("about:", StringComparison.OrdinalIgnoreCase)
            || (v.Contains('.') && !v.EndsWith(".", StringComparison.Ordinal));
    }

    // ---- 새 창으로 열기

    /// <summary>새 창에 URL을 연다. 창이 생기는 건 호출한 쪽에서 기다린다.</summary>
    public static bool OpenInNewWindow(string appId, string url)
    {
        var exe = AppIdentity.ExePathOf(appId);
        if (exe == null || !File.Exists(exe)) return false;
        try
        {
            var safeUrl = url.Replace("\"", "%22");
            Process.Start(new ProcessStartInfo(exe)
            {
                Arguments = "--new-window \"" + safeUrl + "\"",
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(exe) ?? "",
            });
            return true;
        }
        catch { return false; }
    }
}
