using System;
using Microsoft.Win32;

namespace WindowLayouts;

/// <summary>로그인할 때 자동 실행 (HKCU\...\Run)</summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WindowLayouts";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) != null;
        }
        catch { return false; }
    }

    public static string? SetEnabled(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key == null) return "레지스트리를 열 수 없습니다.";
            if (on)
            {
                var exe = Environment.ProcessPath ?? "";
                key.SetValue(ValueName, $"\"{exe}\" --background");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return null;
        }
        catch (Exception ex) { return ex.Message; }
    }
}
