using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace WindowLayouts;

/// <summary>Per-app settings (HKCU\Software\WindowLayouts)</summary>
public static class Prefs
{
    private const string Key = @"Software\WindowLayouts";

    public static bool GetBool(string name, bool fallback)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(name) is int v ? v != 0 : fallback;
        }
        catch { return fallback; }
    }

    public static string GetString(string name, string fallback)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(name) as string ?? fallback;
        }
        catch { return fallback; }
    }

    public static void SetString(string name, string value)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k?.SetValue(name, value, RegistryValueKind.String);
        }
        catch { }
    }

    public static void SetBool(string name, bool value)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k?.SetValue(name, value ? 1 : 0, RegistryValueKind.DWord);
        }
        catch { }
    }
}

/// <summary>Window for choosing which open windows to put into a layout</summary>
public partial class CaptureWindow : Window
{
    public sealed class Item : NotifyBase
    {
        private bool _selected = true;
        public WindowInfo Info { get; }
        public Item(WindowInfo info) { Info = info; }
        public bool Selected { get => _selected; set => Set(ref _selected, value); }
        public string Title => string.IsNullOrEmpty(Info.Title) ? Loc.T("capture.untitled_window") : Info.Title;
        public string Detail => (Info.Url != null ? Info.Url + "   ·   " : "") + Info.Frame.ShortDescription;
    }

    public sealed class Group : NotifyBase
    {
        public string Name { get; init; } = "";
        public List<Item> Windows { get; init; } = new();
        public int SelectedCount => Windows.Count(w => w.Selected);
        public bool AllSelected => SelectedCount == Windows.Count;
        public string HeaderText
        {
            get
            {
                var mark = AllSelected ? "☑" : (SelectedCount == 0 ? "☐" : "▣");
                return $"{mark}  {Name}   {SelectedCount}/{Windows.Count}";
            }
        }
        public void Refresh() => Raise(nameof(HeaderText));
        public void ToggleAll()
        {
            bool target = !AllSelected;
            foreach (var w in Windows) w.Selected = target;
        }
    }

    private readonly CaptureRequest _request;
    private readonly List<Group> _groups = new();
    private bool IsNewLayout => _request.TargetLayoutId == null;

    /// <summary>The id of the layout when a new one was saved</summary>
    public Guid? NewLayoutId { get; private set; }

    public CaptureWindow(CaptureRequest request)
    {
        InitializeComponent();
        _request = request;

        Title = IsNewLayout ? Loc.T("capture.title_new") : Loc.T("capture.title_add");
        Heading.Text = Title;
        SaveButton.Content = IsNewLayout ? Loc.T("common.save") : Loc.T("common.add");
        CancelButton.Content = Loc.T("common.cancel");
        HintText.Text = Loc.T("capture.hint");
        TitlesBox.Content = Loc.T("capture.save_titles");
        UrlsBox.Content = Loc.T("capture.save_urls");
        EmptyText.Text = Loc.T("capture.no_windows");
        NameBox.Visibility = IsNewLayout ? Visibility.Visible : Visibility.Collapsed;
        NameBox.Text = Loc.T("layout.default_name", ("n", LayoutStore.Shared.Layouts.Count + 1));
        ConfigText.Text = Loc.T("capture.config", ("name", request.DisplayConfig.Name));
        TitlesBox.IsChecked = Prefs.GetBool("saveWindowTitles", true);
        UrlsBox.IsChecked = Prefs.GetBool("saveWindowURLs", true);

        // group by app, keeping order of appearance
        foreach (var w in request.Windows)
        {
            var g = _groups.FirstOrDefault(x => x.Name == w.AppName && x.Windows.Count > 0 && x.Windows[0].Info.AppId == w.AppId);
            if (g == null)
            {
                g = new Group { Name = w.AppName };
                _groups.Add(g);
            }
            var item = new Item(w);
            var group = g;
            item.PropertyChanged += (s, e) => { group.Refresh(); UpdateFooter(); };
            g.Windows.Add(item);
        }
        GroupsList.ItemsSource = _groups;
        EmptyText.Visibility = request.Windows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateFooter();
    }

    private int SelectedCount => _groups.Sum(g => g.SelectedCount);

    private void UpdateFooter()
    {
        CountText.Text = Loc.T("capture.selected_count", ("count", SelectedCount));
        SaveButton.IsEnabled = SelectedCount > 0 && (!IsNewLayout || NameBox.Text.Trim().Length > 0);
    }

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateFooter();

    private void GroupHeader_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.DataContext is Group g) g.ToggleAll();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        bool titles = TitlesBox.IsChecked == true;
        bool urls = UrlsBox.IsChecked == true;
        Prefs.SetBool("saveWindowTitles", titles);
        Prefs.SetBool("saveWindowURLs", urls);

        var entries = _groups.SelectMany(g => g.Windows).Where(i => i.Selected)
            .Select(i => i.Info.MakeEntry(includeTitle: titles, includeUrl: urls)).ToList();
        var store = LayoutStore.Shared;
        if (_request.TargetLayoutId is Guid target)
        {
            store.Append(entries, target);
        }
        else
        {
            var layout = new WindowLayout { Name = NameBox.Text.Trim(), DisplayConfig = _request.DisplayConfig };
            foreach (var en in entries) layout.Windows.Add(en);
            store.Add(layout);
            NewLayoutId = layout.Id;
        }
        DialogResult = true;
    }
}
