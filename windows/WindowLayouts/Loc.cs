using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;

namespace WindowLayouts;

/// <summary>다국어 문자열. 실행 파일에 포함된 strings.json(공통 파일 shared/strings.json)에서 읽는다.</summary>
public static class Loc
{
    public const string SystemOption = "system";

    private static Dictionary<string, Dictionary<string, string>> _table = new();
    private static List<(string code, string name)> _languages = new();
    private static string _resolved = "en";

    public static event Action? Changed;

    public static IReadOnlyList<(string code, string name)> Languages => _languages;
    public static string Resolved => _resolved;

    /// <summary>설정값: "system" 또는 언어 코드</summary>
    public static string Setting
    {
        get => Prefs.GetString("language", SystemOption);
        set
        {
            Prefs.SetString("language", value);
            _resolved = Resolve(value);
            Changed?.Invoke();
        }
    }

    static Loc()
    {
        Load();
        _resolved = Resolve(Setting);
    }

    private static void Load()
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("WindowLayouts.Assets.strings.json");
            if (stream == null) return;
            using var doc = JsonDocument.Parse(stream);
            var root = doc.RootElement;
            var order = new[] { "ko", "en", "ja", "zh-Hans" };
            if (root.TryGetProperty("languages", out var langs))
            {
                _languages = langs.EnumerateObject().Select(p => (p.Name, p.Value.GetString() ?? p.Name))
                    .OrderBy(l => { int i = Array.IndexOf(order, l.Name); return i < 0 ? 99 : i; }).ToList();
            }
            if (root.TryGetProperty("strings", out var strings))
            {
                foreach (var entry in strings.EnumerateObject())
                {
                    var map = new Dictionary<string, string>();
                    foreach (var lang in entry.Value.EnumerateObject()) map[lang.Name] = lang.Value.GetString() ?? "";
                    _table[entry.Name] = map;
                }
            }
        }
        catch { }
    }

    /// <summary>시스템 언어를 지원 언어 중 하나로 맞춘다. 중국어는 간체로 통일.</summary>
    public static string Resolve(string setting)
    {
        var available = _languages.Select(l => l.code).ToList();
        if (setting != SystemOption && available.Contains(setting)) return setting;
        var name = CultureInfo.CurrentUICulture.Name.ToLowerInvariant();
        if (name.StartsWith("ko") && available.Contains("ko")) return "ko";
        if (name.StartsWith("ja") && available.Contains("ja")) return "ja";
        if (name.StartsWith("zh") && available.Contains("zh-Hans")) return "zh-Hans";
        if (available.Contains("en")) return "en";
        return available.FirstOrDefault() ?? "en";
    }

    /// <summary>키에 해당하는 문자열. 인자는 ("name", 값) 쌍으로 {name} 자리에 들어간다.</summary>
    public static string T(string key, params (string name, object? value)[] args)
    {
        string text = key;
        if (_table.TryGetValue(key, out var entry))
        {
            if (!entry.TryGetValue(_resolved, out text!) && !entry.TryGetValue("en", out text!)) text = key;
        }
        foreach (var (name, value) in args) text = text.Replace("{" + name + "}", value?.ToString() ?? "");
        return text;
    }
}
