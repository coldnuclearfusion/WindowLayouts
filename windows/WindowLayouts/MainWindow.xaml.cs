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

    // The window is recreated when the language changes, so these are rebuilt on every access to pick up the new labels
    public static IReadOnlyList<EnumItem<TitleMatch>> TitleMatchItems =>
        Enum.GetValues<TitleMatch>().Select(m => new EnumItem<TitleMatch>(m, m.Label())).ToList();

    public static IReadOnlyList<EnumItem<LaunchPolicy>> PolicyItems =>
        Enum.GetValues<LaunchPolicy>().Select(p => new EnumItem<LaunchPolicy>(p, p.Label())).ToList();

    public sealed class LanguageItem
    {
        public string Code { get; init; } = "";
        public string Name { get; init; } = "";
    }

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
    private bool _loadingGeneral;

    public MainWindow()
    {
        InitializeComponent();
        ApplyStrings();
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

    /// <summary>Fill the fixed texts of the window in the current language</summary>
    private void ApplyStrings()
    {
        Title = Loc.T("app.name");
        SidebarTitle.Text = Loc.T("app.name");
        CaptureButton.Content = "＋ " + Loc.T("common.save");
        CaptureButton.ToolTip = Loc.T("sidebar.save_tooltip");
        Placeholder.Text = Loc.T("sidebar.placeholder_title") + "\n" + Loc.T("sidebar.placeholder_body");
        ApplyButton.Content = "▶  " + Loc.T("detail.apply_now");
        PolicyLabel.Text = Loc.T("detail.policy_label");
        RaiseCheck.Content = Loc.T("detail.raise");
        ChangeButton.Content = Loc.T("common.change");
        ColApp.Header = Loc.T("column.app");
        ColTitle.Header = Loc.T("column.title");
        ColUrl.Header = Loc.T("column.url");
        ColMatch.Header = Loc.T("column.match");
        ColMonitor.Header = Loc.T("column.monitor");
        ColX.Header = Loc.T("column.x");
        ColY.Header = Loc.T("column.y");
        ColW.Header = Loc.T("column.width");
        ColH.Header = Loc.T("column.height");
        AddWindowsButton.Content = "＋ " + Loc.T("detail.add_windows");
        RefreshButton.Content = "↻ " + Loc.T("detail.refresh");
        RefreshButton.ToolTip = Loc.T("detail.refresh_help");
        DeleteRowsButton.Content = Loc.T("detail.delete_selected");
        UpButton.ToolTip = Loc.T("detail.move_up_help");
        DownButton.ToolTip = Loc.T("detail.move_down_help");
        LanguageHeading.Text = Loc.T("general.language");
        LanguageNote.Text = Loc.T("general.language_note");
        StartupHeading.Text = Loc.T("general.startup");
        StartupBox.Content = Loc.T("general.launch_at_login");
        DataHeading.Text = Loc.T("general.data");
        OpenFileButton.Content = Loc.T("general.open_file");
        OpenFolderButton.Content = Loc.T("general.open_folder");
        ReloadButton.Content = Loc.T("general.reload");
        OpenLogButton.Content = Loc.T("general.open_log");
        JsonHint.Text = Loc.T("general.json_hint");
        CliHint.Text = Loc.T("general.cli_hint", ("command", "WindowLayouts.exe --apply \"NAME\""));
        MonitorsHeading.Text = Loc.T("general.monitors");
        MonitorsNote.Text = Loc.T("general.monitors_note");
    }

    /// <summary>Open the general settings page (used when the window is recreated after a language change)</summary>
    public void ShowGeneral()
    {
        var item = _sidebarItems.FirstOrDefault(i => i.Kind == "general");
        if (item != null) Sidebar.SelectedItem = item;
    }
    private void OnDisplayChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(() => { RebuildSidebar(); RefreshDisplayRow(); });

    // ---- sidebar

    private void RebuildSidebar()
    {
        _rebuilding = true;
        var selectedId = _current?.Id;
        bool generalSelected = (Sidebar.SelectedItem as SidebarItem)?.Kind == "general";
        _sidebarItems.Clear();
        foreach (var g in LayoutStore.Shared.Groups(Displays.Current()))
        {
            _sidebarItems.Add(new SidebarItem { Kind = "header", Text = Loc.T(g.IsCurrent ? "sidebar.current_config_header" : "sidebar.other_config_header"), Sub = g.ConfigName, GroupId = g.Id });
            if (g.Layouts.Count == 0)
                _sidebarItems.Add(new SidebarItem { Kind = "empty", Text = Loc.T("sidebar.no_layouts"), GroupId = g.Id });
            foreach (var l in g.Layouts)
                _sidebarItems.Add(new SidebarItem { Kind = "layout", Text = l.Name, LayoutId = l.Id, GroupId = g.Id });
        }
        _sidebarItems.Add(new SidebarItem { Kind = "header", Text = "" });
        _sidebarItems.Add(new SidebarItem { Kind = "general", Text = "⚙  " + Loc.T("sidebar.general") });
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
        // Select the right-clicked item first so the context menu targets that layout
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

        var apply = new MenuItem { Header = Loc.T("context.apply") };
        apply.Click += async (s, a) => await LayoutApplier.Shared.Apply(layout);
        var duplicate = new MenuItem { Header = Loc.T("context.duplicate") };
        duplicate.Click += (s, a) =>
        {
            var copy = LayoutStore.Shared.Duplicate(layout.Id);
            if (copy != null) Sidebar.SelectedItem = _sidebarItems.FirstOrDefault(i => i.LayoutId == copy.Id);
        };
        var up = new MenuItem { Header = Loc.T("context.move_up") };
        up.Click += (s, a) => LayoutStore.Shared.MoveLayout(layout.Id, -1, groupIds);
        var down = new MenuItem { Header = Loc.T("context.move_down") };
        down.Click += (s, a) => LayoutStore.Shared.MoveLayout(layout.Id, +1, groupIds);
        var delete = new MenuItem { Header = Loc.T("context.delete") };
        delete.Click += (s, a) =>
        {
            if (MessageBox.Show(this, Loc.T("delete.title", ("name", layout.Name)) + "\n" + Loc.T("delete.message"), Loc.T("app.name"),
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

    // ---- switching panels

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
        _loadingGeneral = true;
        var languages = new List<LanguageItem> { new() { Code = Loc.SystemOption, Name = Loc.T("general.language_system") } };
        languages.AddRange(Loc.Languages.Select(l => new LanguageItem { Code = l.code, Name = l.name }));
        LanguageCombo.ItemsSource = languages;
        LanguageCombo.SelectedValue = Loc.Setting;
        _loadingGeneral = false;
        StartupBox.IsChecked = StartupRegistration.IsEnabled();
        StartupError.Text = "";
        FilePathText.Text = LayoutStore.Shared.FilePath;
        LoadErrorText.Text = LayoutStore.Shared.LoadError ?? "";
        var config = Displays.Current();
        MonitorsText.Text = Loc.T("general.current_config") + ": " + config.Name + "\n" + string.Join("\n",
            config.Displays.Select(d => $"{d.Name}{(d.IsMain ? Loc.T("display.main_suffix") : "")} · {d.Frame.ShortDescription}"));
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
            DisplayText.Text = Loc.T("display.any");
            DisplayText.Foreground = Brushes.Black;
            return;
        }
        string status;
        bool warn = false;
        if (saved.IsIdentical(current)) status = Loc.T("display.same");
        else if (saved.HasSameDisplays(current)) { status = Loc.T("display.rearranged"); warn = true; }
        else { status = Loc.T("display.different"); warn = true; }
        DisplayText.Text = Loc.T("display.config", ("name", saved.Name)) + "   ·   " + status;
        DisplayText.Foreground = warn ? Brushes.DarkOrange : Brushes.Black;
    }

    private void UpdateCount()
    {
        if (_current == null) return;
        CountText.Text = Loc.T("detail.count", ("count", _current.Windows.Count));
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

    // ---- detail panel actions

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
        var toCurrent = new MenuItem { Header = Loc.T("display.set_current") };
        toCurrent.Click += (s, a) => { LayoutStore.Shared.SetDisplayConfig(Displays.Current(), layout.Id); RefreshMonitorNames(); RefreshDisplayRow(); };
        var any = new MenuItem { Header = Loc.T("display.set_any") };
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
        RefreshText.Text = Loc.T("detail.refreshed", ("count", updated));
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

    // ---- general settings

    private void Startup_Click(object sender, RoutedEventArgs e)
    {
        var error = StartupRegistration.SetEnabled(StartupBox.IsChecked == true);
        StartupError.Text = error == null ? "" : Loc.T("general.login_error", ("error", error));
        StartupBox.IsChecked = StartupRegistration.IsEnabled();
    }

    private void Language_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingGeneral || LanguageCombo.SelectedValue is not string code || code == Loc.Setting) return;
        Loc.Setting = code;   // App handles Loc.Changed and recreates this window in the new language
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
