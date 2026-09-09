using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowLayouts;

/// <summary>What to do when an app in the layout isn't running or has no window</summary>
public enum LaunchPolicy { Ask, LaunchMissing, RunningOnly }

/// <summary>How to find which of an app's several windows an entry refers to</summary>
public enum TitleMatch { Auto, Title, Order }

public static class EnumLabels
{
    public static string Key(this LaunchPolicy p) => p switch
    {
        LaunchPolicy.Ask => "ask",
        LaunchPolicy.LaunchMissing => "launchMissing",
        LaunchPolicy.RunningOnly => "runningOnly",
        _ => p.ToString(),
    };

    public static string Key(this TitleMatch m) => m switch
    {
        TitleMatch.Auto => "auto",
        TitleMatch.Title => "title",
        TitleMatch.Order => "order",
        _ => m.ToString(),
    };

    public static string Label(this LaunchPolicy p) => Loc.T("policy." + p.Key());
    public static string Label(this TitleMatch m) => Loc.T("match." + m.Key());
}

/// <summary>A rectangle in screen coordinates (virtual screen, main monitor's top-left is (0,0), physical pixels)</summary>
public readonly record struct WinFrame(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;

    public bool Contains(double px, double py) => px >= X && px < Right && py >= Y && py < Bottom;

    public bool ApproximatelyEquals(WinFrame other, double tolerance = 2) =>
        Math.Abs(X - other.X) <= tolerance && Math.Abs(Y - other.Y) <= tolerance &&
        Math.Abs(Width - other.Width) <= tolerance && Math.Abs(Height - other.Height) <= tolerance;

    public string ShortDescription => $"{(int)Width}×{(int)Height} @ ({(int)X}, {(int)Y})";
}

public abstract class NotifyBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>One monitor</summary>
public sealed class DisplayInfo
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("x")] public double X { get; set; }
    [JsonPropertyName("y")] public double Y { get; set; }
    [JsonPropertyName("width")] public double Width { get; set; }
    [JsonPropertyName("height")] public double Height { get; set; }
    [JsonPropertyName("isMain")] public bool IsMain { get; set; }

    [JsonIgnore] public WinFrame Frame => new(X, Y, Width, Height);

    public bool SameAs(DisplayInfo o) =>
        Id == o.Id && Name == o.Name && X == o.X && Y == o.Y && Width == o.Width && Height == o.Height && IsMain == o.IsMain;
}

/// <summary>Which monitors are connected and how they are arranged</summary>
public sealed class DisplayConfig
{
    [JsonPropertyName("displays")] public List<DisplayInfo> Displays { get; set; } = new();

    [JsonIgnore] public HashSet<string> Ids => Displays.Select(d => d.Id).ToHashSet(StringComparer.Ordinal);

    /// <summary>Key for the set of connected monitors (arrangement ignored)</summary>
    [JsonIgnore] public string Key => string.Join("+", Displays.Select(d => d.Id).OrderBy(s => s, StringComparer.Ordinal));

    /// <summary>Display name such as "Built-in + LG"</summary>
    [JsonIgnore]
    public string Name
    {
        get
        {
            var ordered = Displays.OrderBy(d => d.IsMain ? 0 : 1).ThenBy(d => d.X).ToList();
            var counts = new Dictionary<string, int>();
            var order = new List<string>();
            foreach (var d in ordered)
            {
                if (!counts.ContainsKey(d.Name)) { order.Add(d.Name); counts[d.Name] = 0; }
                counts[d.Name]++;
            }
            if (order.Count == 0) return Loc.T("display.none");
            return string.Join(" + ", order.Select(n => counts[n] > 1 ? $"{n} ×{counts[n]}" : n));
        }
    }

    [JsonIgnore] public DisplayInfo? Main => Displays.FirstOrDefault(d => d.IsMain) ?? Displays.FirstOrDefault();

    public DisplayInfo? DisplayWithId(string? id) => id == null ? null : Displays.FirstOrDefault(d => d.Id == id);

    public DisplayInfo? DisplayContaining(double x, double y) => Displays.FirstOrDefault(d => d.Frame.Contains(x, y));

    /// <summary>Same set of monitors (the arrangement may differ)</summary>
    public bool HasSameDisplays(DisplayConfig other) => Ids.SetEquals(other.Ids);

    /// <summary>Same monitors and the same arrangement</summary>
    public bool IsIdentical(DisplayConfig other)
    {
        var a = Displays.OrderBy(d => d.Id, StringComparer.Ordinal).ToList();
        var b = other.Displays.OrderBy(d => d.Id, StringComparer.Ordinal).ToList();
        if (a.Count != b.Count) return false;
        for (int i = 0; i < a.Count; i++) if (!a[i].SameAs(b[i])) return false;
        return true;
    }
}

public sealed class WindowEntry : NotifyBase
{
    private Guid _id = Guid.NewGuid();
    private string _bundleID = "";
    private string _appName = "";
    private string _title = "";
    private TitleMatch _titleMatch = TitleMatch.Auto;
    private double _x, _y, _width = 800, _height = 600;
    private bool _enabled = true;
    private string? _displayID;
    private string? _url;
    private string _monitorName = "";

    [JsonPropertyName("id")] public Guid Id { get => _id; set => Set(ref _id, value); }
    /// <summary>App identifier. On Windows "exe:<full path>" or "aumid:…" for Store apps (the macOS bundle ID equivalent)</summary>
    [JsonPropertyName("bundleID")] public string BundleID { get => _bundleID; set => Set(ref _bundleID, value); }
    [JsonPropertyName("appName")] public string AppName { get => _appName; set => Set(ref _appName, value); }
    [JsonPropertyName("title")] public string Title { get => _title; set => Set(ref _title, value ?? ""); }
    [JsonPropertyName("titleMatch")] public TitleMatch TitleMatch { get => _titleMatch; set => Set(ref _titleMatch, value); }
    [JsonPropertyName("x")] public double X { get => _x; set => Set(ref _x, Math.Round(value)); }
    [JsonPropertyName("y")] public double Y { get => _y; set => Set(ref _y, Math.Round(value)); }
    [JsonPropertyName("width")] public double Width { get => _width; set => Set(ref _width, Math.Round(value)); }
    [JsonPropertyName("height")] public double Height { get => _height; set => Set(ref _height, Math.Round(value)); }
    [JsonPropertyName("enabled")] public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }
    /// <summary>The monitor this window was on when saved (DisplayInfo.Id)</summary>
    [JsonPropertyName("displayID")] public string? DisplayID { get => _displayID; set => Set(ref _displayID, value); }
    /// <summary>For browser windows: the page to show here</summary>
    [JsonPropertyName("url")]
    public string? Url
    {
        get => _url;
        set
        {
            var trimmed = value?.Trim();
            Set(ref _url, string.IsNullOrEmpty(trimmed) ? null : trimmed);
        }
    }

    /// <summary>Display-only (not saved): the name of the monitor this window was on</summary>
    [JsonIgnore] public string MonitorName { get => _monitorName; set => Set(ref _monitorName, value); }

    [JsonIgnore]
    public WinFrame Frame
    {
        get => new(X, Y, Width, Height);
        set { X = value.X; Y = value.Y; Width = value.Width; Height = value.Height; }
    }

    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            var detail = string.IsNullOrEmpty(Title) ? (Url ?? "") : Title;
            return string.IsNullOrEmpty(detail) ? AppName : $"{AppName} – {detail}";
        }
    }

    [JsonIgnore] public bool HasUrl => !string.IsNullOrWhiteSpace(Url);

    public WindowEntry Clone()
    {
        return new WindowEntry
        {
            Id = Guid.NewGuid(), BundleID = BundleID, AppName = AppName, Title = Title, TitleMatch = TitleMatch,
            X = X, Y = Y, Width = Width, Height = Height, Enabled = Enabled, DisplayID = DisplayID, Url = Url,
        };
    }
}

public sealed class WindowLayout : NotifyBase
{
    private Guid _id = Guid.NewGuid();
    private string _name = Loc.T("layout.untitled");
    private LaunchPolicy _launchPolicy = LaunchPolicy.Ask;
    private bool _raiseWindows = true;
    private DisplayConfig? _displayConfig;

    [JsonPropertyName("id")] public Guid Id { get => _id; set => Set(ref _id, value); }
    [JsonPropertyName("name")] public string Name { get => _name; set => Set(ref _name, value ?? ""); }
    [JsonPropertyName("launchPolicy")] public LaunchPolicy LaunchPolicy { get => _launchPolicy; set => Set(ref _launchPolicy, value); }
    /// <summary>Whether to raise the layout's windows above the others when applying (earlier entries end up higher)</summary>
    [JsonPropertyName("raiseWindows")] public bool RaiseWindows { get => _raiseWindows; set => Set(ref _raiseWindows, value); }
    /// <summary>Monitor setup at save time. null means an "any setup" layout that shows under every setup</summary>
    [JsonPropertyName("displayConfig")] public DisplayConfig? DisplayConfig { get => _displayConfig; set => Set(ref _displayConfig, value); }
    [JsonPropertyName("windows")] public ObservableCollection<WindowEntry> Windows { get; set; } = new();

    /// <summary>App IDs in order of appearance (enabled windows only)</summary>
    [JsonIgnore]
    public List<string> EnabledAppIds
    {
        get
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var result = new List<string>();
            foreach (var w in Windows) if (w.Enabled && seen.Add(w.BundleID)) result.Add(w.BundleID);
            return result;
        }
    }

    public string AppName(string appId) => Windows.FirstOrDefault(w => w.BundleID == appId)?.AppName ?? appId;
}

public sealed class LayoutFile
{
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("layouts")] public List<WindowLayout> Layouts { get; set; } = new();
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}
