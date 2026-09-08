using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace WindowLayouts;

public partial class MainWindow : Window
{
    public sealed class EnumItem<T>
    {
        public T Value { get; }
        public string Label { get; }
        public EnumItem(T value, string label) { Value = value; Label = label; }
    }

    public static IReadOnlyList<EnumItem<TitleMatch>> TitleMatchItems { get; } =
        Enum.GetValues<TitleMatch>().Select(m => new EnumItem<TitleMatch>(m, m.Label())).ToList();

    public static IReadOnlyList<EnumItem<LaunchPolicy>> PolicyItems { get; } =
        Enum.GetValues<LaunchPolicy>().Select(p => new EnumItem<LaunchPolicy>(p, p.Label())).ToList();

    public sealed class SidebarItem
    {
        public string Kind { get; init; } = "layout";   // header | empty | layout | general
        public string Text { get; init; } = "";
        public string Sub { get; init; } = "";
        public Guid? LayoutId { get; init; }
        public string GroupId { get; init; } = "";
        public bool IsSelectable => Kind == "layout" || Kind == "general";
    }

    private readonly ObservableCollection<SidebarItem> _sidebarItems = new();
    private WindowLayout? _current;
    private bool _rebuilding;

    public MainWindow()
    {
        InitializeComponent();
        PolicyCombo.ItemsSource = PolicyItems;
        Sidebar.ItemsSource = _sidebarItems;

        LayoutStore.Shared.Changed += OnStoreChanged;
        LayoutApplier.Shared.ReportChanged += ShowReport;
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        Closed += (s, e) =>
        {
            LayoutStore.Shared.Changed -= OnStoreChanged;
            LayoutApplier.Shared.ReportChanged -= ShowReport;
            SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
        };

        RebuildSidebar();
        if (Sidebar.SelectedItem == null)
        {
            var first = _sidebarItems.FirstOrDefault(i => i.Kind == "layout");
            if (first != null) Sidebar.SelectedItem = first;
            else ShowPlaceholder();
        }
    }

    private void OnStoreChanged() => RebuildSidebar();
    private void OnDisplayChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(() => { RebuildSidebar(); RefreshDisplayRow(); });

    // ---- 사이드바

    private void RebuildSidebar()
    {
        _rebuilding = true;
        var selectedId = _current?.Id;
        bool generalSelected = (Sidebar.SelectedItem as SidebarItem)?.Kind == "general";
        _sidebarItems.Clear();
        foreach (var g in LayoutStore.Shared.Groups(Displays.Current()))
        {
            _sidebarItems.Add(new SidebarItem { Kind = "header", Text = g.IsCurrent ? "현재 모니터 구성" : "다른 모니터 구성", Sub = g.ConfigName, GroupId = g.Id });
            if (g.Layouts.Count == 0)
                _sidebarItems.Add(new SidebarItem { Kind = "empty", Text = "저장된 배치가 없습니다", GroupId = g.Id });
            foreach (var l in g.Layouts)
                _sidebarItems.Add(new SidebarItem { Kind = "layout", Text = l.Name, LayoutId = l.Id, GroupId = g.Id });
        }
        _sidebarItems.Add(new SidebarItem { Kind = "header", Text = "" });
        _sidebarItems.Add(new SidebarItem { Kind = "general", Text = "⚙  일반 설정" });
        _rebuilding = false;

        if (generalSelected) Sidebar.SelectedItem = _sidebarItems.First(i => i.Kind == "general");
        else if (selectedId != null) Sidebar.SelectedItem = _sidebarItems.FirstOrDefault(i => i.LayoutId == selectedId);
        if (Sidebar.SelectedItem == null && _current != null) ShowPlaceholder();
    }

    private void Sidebar_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuilding) return;
        if (Sidebar.SelectedItem is not SidebarItem item) { ShowPlaceholder(); return; }
        if (item.Kind == "general") { ShowGeneral(); return; }
        if (item.LayoutId is Guid id && LayoutStore.Shared.Layout(id) is WindowLayout layout) ShowLayout(layout);
        else ShowPlaceholder();
    }

    private void Sidebar_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        // 오른쪽 클릭한 항목을 먼저 선택해서 컨텍스트 메뉴가 그 배치를 대상으로 하게 한다
        var element = e.OriginalSource as DependencyObject;
        while (element != null && element is not ListBoxItem) element = VisualTreeHelper.GetParent(element);
        if (element is ListBoxItem container && container.DataContext is SidebarItem item && item.Kind == "layout")
            Sidebar.SelectedItem = item;
    }

    private void Sidebar_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = Sidebar.ContextMenu;
        if (menu == null) return;
        menu.Items.Clear();
        if (Sidebar.SelectedItem is not SidebarItem item || item.Kind != "layout" || item.LayoutId is not Guid id
            || LayoutStore.Shared.Layout(id) is not WindowLayout layout)
        {
            e.Handled = true;
            return;
        }
        var groupIds = _sidebarItems.Where(i => i.Kind == "layout" && i.GroupId == item.GroupId).Select(i => i.LayoutId!.Value).ToList();

        var apply = new MenuItem { Header = "적용" };
        apply.Click += async (s, a) => await LayoutApplier.Shared.Apply(layout);
        var duplicate = new MenuItem { Header = "복제" };
        duplicate.Click += (s, a) =>
        {
            var copy = LayoutStore.Shared.Duplicate(layout.Id);
            if (copy != null) Sidebar.SelectedItem = _sidebarItems.FirstOrDefault(i => i.LayoutId == copy.Id);
        };
        var up = new MenuItem { Header = "위로" };
        up.Click += (s, a) => LayoutStore.Shared.MoveLayout(layout.Id, -1, groupIds);
        var down = new MenuItem { Header = "아래로" };
        down.Click += (s, a) => LayoutStore.Shared.MoveLayout(layout.Id, +1, groupIds);
        var delete = new MenuItem { Header = "삭제…" };
        delete.Click += (s, a) =>
        {
            if (MessageBox.Show(this, $"‘{layout.Name}’ 배치를 삭제할까요? 되돌릴 수 없습니다.", "창 배치",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            if (_current?.Id == layout.Id) { _current = null; ShowPlaceholder(); }
            LayoutStore.Shared.Remove(layout.Id);
        };
        menu.Items.Add(apply);
        menu.Items.Add(duplicate);
        menu.Items.Add(up);
        menu.Items.Add(down);
        menu.Items.Add(new Separator());
        menu.Items.Add(delete);
    }

    // ---- 패널 전환

    private void ShowPlaceholder()
    {
        _current = null;
        DetailPanel.Visibility = Visibility.Collapsed;
        GeneralPanel.Visibility = Visibility.Collapsed;
        Placeholder.Visibility = Visibility.Visible;
    }

    private void ShowGeneral()
    {
        _current = null;
        DetailPanel.Visibility = Visibility.Collapsed;
        Placeholder.Visibility = Visibility.Collapsed;
        GeneralPanel.Visibility = Visibility.Visible;
        StartupBox.IsChecked = StartupRegistration.IsEnabled();
        StartupError.Text = "";
        FilePathText.Text = LayoutStore.Shared.FilePath;
        LoadErrorText.Text = LayoutStore.Shared.LoadError ?? "";
        var config = Displays.Current();
        MonitorsText.Text = "현재 구성: " + config.Name + "\n" + string.Join("\n",
            config.Displays.Select(d => $"{d.Name}{(d.IsMain ? " (주 모니터)" : "")} · {d.Frame.ShortDescription}"));
    }

    private void ShowLayout(WindowLayout layout)
    {
        _current = layout;
        DetailPanel.DataContext = layout;
        Placeholder.Visibility = Visibility.Collapsed;
        GeneralPanel.Visibility = Visibility.Collapsed;
        DetailPanel.Visibility = Visibility.Visible;
        RefreshText.Text = "";
        RefreshMonitorNames();
        RefreshDisplayRow();
        UpdateCount();
        ShowReport();
    }

    private void RefreshMonitorNames()
    {
        if (_current == null) return;
        foreach (var entry in _current.Windows)
            entry.MonitorName = _current.DisplayConfig?.DisplayWithId(entry.DisplayID)?.Name ?? "–";
    }

    private void RefreshDisplayRow()
    {
        if (_current == null) return;
        var current = Displays.Current();
        var saved = _current.DisplayConfig;
        if (saved == null)
        {
            DisplayText.Text = "모니터 구성: 무관 (모든 구성에서 표시, 좌표 그대로 적용)";
            DisplayText.Foreground = Brushes.Black;
            return;
        }
        string status;
        bool warn = false;
        if (saved.IsIdentical(current)) status = "현재와 같음";
        else if (saved.HasSameDisplays(current)) { status = "같은 모니터지만 배열이 달라, 적용할 때 위치를 맞춥니다"; warn = true; }
        else { status = "현재 구성과 달라, 적용할 때 창이 있던 모니터를 찾아 위치를 맞춥니다"; warn = true; }
        DisplayText.Text = $"모니터 구성: {saved.Name}   ·   {status}";
        DisplayText.Foreground = warn ? Brushes.DarkOrange : Brushes.Black;
    }

    private void UpdateCount()
    {
        if (_current == null) return;
        CountText.Text = $"{_current.Windows.Count}개 창 · 좌표는 주 모니터 왼쪽 위가 (0, 0), 물리 픽셀";
    }

    private void ShowReport()
    {
        var report = LayoutApplier.Shared.LastReport;
        if (_current == null || report == null || report.LayoutId != _current.Id)
        {
            ReportBox.Visibility = Visibility.Collapsed;
            return;
        }
        ReportHeadline.Text = report.Headline;
        ReportLines.Text = string.Join("\n", report.Lines);
        ReportLines.Visibility = report.Lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ReportBox.Visibility = Visibility.Visible;
    }

    // ---- 상세 패널 동작

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        ApplyButton.IsEnabled = false;
        try { await LayoutApplier.Shared.Apply(_current); }
        finally { ApplyButton.IsEnabled = true; }
        ShowReport();
    }

    private void DisplayChange_Click(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        var layout = _current;
        var menu = new ContextMenu();
        var toCurrent = new MenuItem { Header = "현재 모니터 구성으로 지정" };
        toCurrent.Click += (s, a) => { LayoutStore.Shared.SetDisplayConfig(Displays.Current(), layout.Id); RefreshMonitorNames(); RefreshDisplayRow(); };
        var any = new MenuItem { Header = "구성 무관으로 지정" };
        any.Click += (s, a) => { LayoutStore.Shared.SetDisplayConfig(null, layout.Id); RefreshMonitorNames(); RefreshDisplayRow(); };
        menu.Items.Add(toCurrent);
        menu.Items.Add(any);
        menu.PlacementTarget = (UIElement)sender;
        menu.IsOpen = true;
    }

    private void Capture_Click(object sender, RoutedEventArgs e)
    {
        BeginCapture(new CaptureRequest { Windows = WindowCapture.CurrentWindows() });
    }

    private void AddWindows_Click(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        BeginCapture(new CaptureRequest { Windows = WindowCapture.CurrentWindows(), TargetLayoutId = _current.Id });
    }

    public void BeginCapture(CaptureRequest request)
    {
        var dialog = new CaptureWindow(request) { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            if (dialog.NewLayoutId is Guid id)
                Sidebar.SelectedItem = _sidebarItems.FirstOrDefault(i => i.LayoutId == id);
            else if (_current != null)
            {
                RefreshMonitorNames();
                UpdateCount();
            }
        }
    }

    private void Refresh_Click(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        int updated = LayoutApplier.Shared.RefreshFrames(_current);
        LayoutStore.Shared.Save();
        RefreshMonitorNames();
        RefreshDisplayRow();
        RefreshText.Text = $"{updated}개 창의 위치를 현재 상태로 갱신하고, 모니터 구성을 현재 것으로 바꿨습니다.";
    }

    private void DeleteRows_Click(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        var ids = WindowsGrid.SelectedItems.OfType<WindowEntry>().Select(w => w.Id).ToList();
        if (ids.Count == 0) return;
        LayoutStore.Shared.RemoveEntries(ids, _current.Id);
        UpdateCount();
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => MoveSelected(-1);
    private void MoveDown_Click(object sender, RoutedEventArgs e) => MoveSelected(+1);

    private void MoveSelected(int delta)
    {
        if (_current == null || WindowsGrid.SelectedItem is not WindowEntry entry) return;
        LayoutStore.Shared.MoveEntry(entry.Id, delta, _current.Id);
        WindowsGrid.SelectedItem = entry;
    }

    // ---- 일반 설정

    private void Startup_Click(object sender, RoutedEventArgs e)
    {
        var error = StartupRegistration.SetEnabled(StartupBox.IsChecked == true);
        StartupError.Text = error == null ? "" : "설정 실패: " + error;
        StartupBox.IsChecked = StartupRegistration.IsEnabled();
    }

    private void OpenFile_Click(object sender, RoutedEventArgs e) => OpenPath(LayoutStore.Shared.FilePath);
    private void OpenLog_Click(object sender, RoutedEventArgs e) => OpenPath(ApplyLog.FilePath);
    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        LayoutStore.Shared.Reload();
        LoadErrorText.Text = LayoutStore.Shared.LoadError ?? "";
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{LayoutStore.Shared.FilePath}\"") { UseShellExecute = true }); }
        catch { }
    }

    private static void OpenPath(string path)
    {
        try
        {
            if (!System.IO.File.Exists(path)) System.IO.File.WriteAllText(path, "");
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch { }
    }
}
