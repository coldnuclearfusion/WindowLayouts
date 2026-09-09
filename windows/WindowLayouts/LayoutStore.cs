using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows.Threading;

namespace WindowLayouts;

public sealed class LayoutGroup
{
    public string Id { get; init; } = "";
    public string ConfigName { get; init; } = "";
    public bool IsCurrent { get; init; }
    public List<WindowLayout> Layouts { get; init; } = new();
}

/// <summary>
/// Holds the layout list and saves it to %LOCALAPPDATA%\WindowLayouts\layouts.json.
/// Reloads automatically when the file is edited by hand. UI thread only.
/// </summary>
public sealed class LayoutStore
{
    public static LayoutStore Shared { get; } = new();

    public ObservableCollection<WindowLayout> Layouts { get; } = new();
    public Guid? LastAppliedId { get; set; }
    public string? LoadError { get; private set; }
    public string DirectoryPath { get; }
    public string FilePath { get; }

    /// <summary>Raised when the list or its contents change (tray menu and sidebar refresh)</summary>
    public event Action? Changed;

    private string? _lastWrittenText;
    private FileSystemWatcher? _watcher;
    private DispatcherTimer? _saveTimer;
    private DispatcherTimer? _reloadTimer;
    private readonly HashSet<object> _wired = new(ReferenceEqualityComparer.Instance);

    private LayoutStore()
    {
        DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WindowLayouts");
        Directory.CreateDirectory(DirectoryPath);
        FilePath = Path.Combine(DirectoryPath, "layouts.json");
        if (File.Exists(FilePath)) Load(force: true); else Save();
        StartWatching();
    }

    // ---- queries

    public WindowLayout? Layout(Guid id) => Layouts.FirstOrDefault(l => l.Id == id);

    public int IndexOf(Guid id)
    {
        for (int i = 0; i < Layouts.Count; i++) if (Layouts[i].Id == id) return i;
        return -1;
    }

    /// <summary>Layouts for the current monitor setup (including "any setup" layouts) form the first group; the rest are grouped per setup.</summary>
    public List<LayoutGroup> Groups(DisplayConfig current)
    {
        var currentLayouts = new List<WindowLayout>();
        var others = new List<LayoutGroup>();
        foreach (var l in Layouts)
        {
            if (l.DisplayConfig != null && !l.DisplayConfig.HasSameDisplays(current))
            {
                var key = l.DisplayConfig.Key;
                var g = others.FirstOrDefault(o => o.Id == key);
                if (g == null)
                {
                    g = new LayoutGroup { Id = key, ConfigName = l.DisplayConfig.Name, IsCurrent = false };
                    others.Add(g);
                }
                g.Layouts.Add(l);
            }
            else
            {
                currentLayouts.Add(l);
            }
        }
        var result = new List<LayoutGroup>
        {
            new() { Id = "current", ConfigName = current.Name, IsCurrent = true, Layouts = currentLayouts },
        };
        result.AddRange(others);
        return result;
    }

    // ---- changes

    public void Add(WindowLayout layout)
    {
        Wire(layout);
        Layouts.Add(layout);
        Save();
    }

    public void Remove(Guid id)
    {
        int i = IndexOf(id);
        if (i < 0) return;
        Layouts.RemoveAt(i);
        if (LastAppliedId == id) LastAppliedId = null;
        Save();
    }

    public WindowLayout? Duplicate(Guid id)
    {
        int i = IndexOf(id);
        if (i < 0) return null;
        var src = Layouts[i];
        var copy = JsonSerializer.Deserialize<WindowLayout>(JsonSerializer.Serialize(src, Json.Options), Json.Options);
        if (copy == null) return null;
        copy.Id = Guid.NewGuid();
        copy.Name = src.Name + Loc.T("layout.copy_suffix");
        foreach (var w in copy.Windows) w.Id = Guid.NewGuid();
        Wire(copy);
        Layouts.Insert(i + 1, copy);
        Save();
        return copy;
    }

    /// <summary>Move one layout by delta within its group (ids); the full list order follows.</summary>
    public void MoveLayout(Guid id, int delta, List<Guid> groupIds)
    {
        int from = groupIds.IndexOf(id);
        int to = from + delta;
        if (from < 0 || to < 0 || to >= groupIds.Count) return;
        var subset = groupIds.ToList();
        subset.RemoveAt(from);
        subset.Insert(to, id);
        var positions = new List<int>();
        for (int i = 0; i < Layouts.Count; i++) if (groupIds.Contains(Layouts[i].Id)) positions.Add(i);
        var byId = Layouts.ToDictionary(l => l.Id);
        for (int k = 0; k < positions.Count && k < subset.Count; k++)
        {
            if (!ReferenceEquals(Layouts[positions[k]], byId[subset[k]])) Layouts[positions[k]] = byId[subset[k]];
        }
        Save();
    }

    public void Append(IEnumerable<WindowEntry> entries, Guid layoutId)
    {
        var l = Layout(layoutId);
        if (l == null) return;
        foreach (var e in entries) l.Windows.Add(e);
        Save();
    }

    public void RemoveEntries(IEnumerable<Guid> entryIds, Guid layoutId)
    {
        var l = Layout(layoutId);
        if (l == null) return;
        var ids = entryIds.ToHashSet();
        for (int i = l.Windows.Count - 1; i >= 0; i--) if (ids.Contains(l.Windows[i].Id)) l.Windows.RemoveAt(i);
        Save();
    }

    /// <summary>Move one window entry up (-1) or down (+1). Array order = stacking order</summary>
    public void MoveEntry(Guid entryId, int delta, Guid layoutId)
    {
        var l = Layout(layoutId);
        if (l == null) return;
        int i = -1;
        for (int k = 0; k < l.Windows.Count; k++) if (l.Windows[k].Id == entryId) { i = k; break; }
        int target = i + delta;
        if (i < 0 || target < 0 || target >= l.Windows.Count) return;
        l.Windows.Move(i, target);
        Save();
    }

    public void SetLaunchPolicy(LaunchPolicy policy, Guid layoutId)
    {
        var l = Layout(layoutId);
        if (l == null) return;
        l.LaunchPolicy = policy;
        Save();
    }

    public void SetDisplayConfig(DisplayConfig? config, Guid layoutId)
    {
        var l = Layout(layoutId);
        if (l == null) return;
        l.DisplayConfig = config;
        Save();
    }

    /// <summary>Replace a layout wholesale (used by "update from current positions")</summary>
    public void Replace(WindowLayout updated)
    {
        int i = IndexOf(updated.Id);
        if (i < 0) return;
        Wire(updated);
        Layouts[i] = updated;
        Save();
    }

    // ---- save / load

    public void Reload() => Load(force: true);

    private void Load(bool force)
    {
        string text;
        try { text = File.ReadAllText(FilePath); }
        catch { return; }
        if (!force && text == _lastWrittenText) return;
        try
        {
            var file = JsonSerializer.Deserialize<LayoutFile>(text, Json.Options) ?? new LayoutFile();
            Layouts.Clear();
            foreach (var l in file.Layouts)
            {
                Wire(l);
                Layouts.Add(l);
            }
            _lastWrittenText = text;
            LoadError = null;
        }
        catch (Exception ex)
        {
            LoadError = Loc.T("store.read_error", ("error", ex.Message));
        }
        Changed?.Invoke();
    }

    public void Save()
    {
        _saveTimer?.Stop();
        try
        {
            var text = JsonSerializer.Serialize(new LayoutFile { Layouts = Layouts.ToList() }, Json.Options);
            _lastWrittenText = text;
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, FilePath, overwrite: true);
            LoadError = null;
        }
        catch (Exception ex)
        {
            LoadError = Loc.T("store.save_error", ("error", ex.Message));
        }
        Changed?.Invoke();
    }

    /// <summary>Frequent changes such as text edits are saved once, 0.5 s later</summary>
    public void ScheduleSave()
    {
        if (_saveTimer == null)
        {
            _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            _saveTimer.Tick += (s, e) => { _saveTimer.Stop(); Save(); };
        }
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    // ---- change tracking (save automatically when a property changes)

    private void Wire(WindowLayout layout)
    {
        if (_wired.Add(layout))
        {
            layout.PropertyChanged += OnItemChanged;
            layout.Windows.CollectionChanged += OnWindowsChanged;
        }
        foreach (var e in layout.Windows) WireEntry(e);
    }

    private void WireEntry(WindowEntry entry)
    {
        if (_wired.Add(entry)) entry.PropertyChanged += OnItemChanged;
    }

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(WindowEntry.MonitorName)) return; // display-only value
        ScheduleSave();
    }

    private void OnWindowsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null) foreach (WindowEntry w in e.NewItems) WireEntry(w);
        ScheduleSave();
    }

    // ---- file watching

    private void StartWatching()
    {
        try
        {
            _watcher = new FileSystemWatcher(DirectoryPath, "layouts.json")
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
            };
            _watcher.Changed += OnFileChanged;
            _watcher.Created += OnFileChanged;
            _watcher.Renamed += OnFileChanged;
            _watcher.EnableRaisingEvents = true;
        }
        catch { }
    }

    private void OnFileChanged(object sender, FileSystemEventArgs e)
    {
        var app = System.Windows.Application.Current;
        if (app == null) return;
        app.Dispatcher.InvokeAsync(() =>
        {
            if (_reloadTimer == null)
            {
                _reloadTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
                _reloadTimer.Tick += (s, a) => { _reloadTimer.Stop(); Load(force: false); };
            }
            _reloadTimer.Stop();
            _reloadTimer.Start();
        });
    }
}
