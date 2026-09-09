using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows.Automation;

namespace WindowLayouts;

/// <summary>
/// Finding a browser window by page address, or opening the page in a new window.
/// On Windows only the active tab's address of each window is available, read from the address bar through UI Automation.
/// Background tabs cannot be inspected, so a new window is opened when no window shows the page.
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

    // ---- address comparison

    /// <summary>Normalization for comparison: lowercase host, strip www., trailing / and the #fragment, drop the scheme</summary>
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

    /// <summary>The saved address matches an open tab when it is a prefix of the tab's address. Example: "youtube.com" ↔ "https://www.youtube.com/watch?v=…"</summary>
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

    // ---- active tab address (UI Automation)

    /// <summary>Read the current tab's address from the window's address bar. Null when it cannot be read.</summary>
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

    // ---- opening a new window

    /// <summary>Open the URL in a new window. The caller waits for the window to appear.</summary>
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
