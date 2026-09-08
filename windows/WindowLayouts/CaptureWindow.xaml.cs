using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace WindowLayouts;

/// <summary>앱별 저장 설정 (HKCU\Software\WindowLayouts)</summary>
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

/// <summary>현재 열린 창 중 어떤 것을 배치에 넣을지 고르는 창</summary>
public partial class CaptureWindow : Window
{
    public sealed class Item : NotifyBase
    {
        private bool _selected = true;
        public WindowInfo Info { get; }
        public Item(WindowInfo info) { Info = info; }
        public bool Selected { get => _selected; set => Set(ref _selected, value); }
        public string Title => string.IsNullOrEmpty(Info.Title) ? "(제목 없음)" : Info.Title;
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

    /// <summary>새 배치로 저장했을 때 그 배치의 ID</summary>
    public Guid? NewLayoutId { get; private set; }

    public CaptureWindow(CaptureRequest request)
    {
        InitializeComponent();
        _request = request;

        Heading.Text = IsNewLayout ? "현재 창 배치 저장" : "현재 열린 창 추가";
        SaveButton.Content = IsNewLayout ? "저장" : "추가";
        NameBox.Visibility = IsNewLayout ? Visibility.Visible : Visibility.Collapsed;
        NameBox.Text = $"배치 {LayoutStore.Shared.Layouts.Count + 1}";
        ConfigText.Text = "모니터 구성: " + request.DisplayConfig.Name;
        TitlesBox.IsChecked = Prefs.GetBool("saveWindowTitles", true);
        UrlsBox.IsChecked = Prefs.GetBool("saveWindowURLs", true);

        // 앱별로 묶기 (등장 순서 유지)
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
        CountText.Text = $"{SelectedCount}개 창 선택됨";
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
