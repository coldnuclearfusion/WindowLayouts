using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

namespace WindowLayouts;

/// <summary>Notification area (tray) icon and menu</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly ContextMenuStrip _menu = new();

    public TrayIcon()
    {
        _icon = new NotifyIcon { Icon = LoadIcon(), Text = Loc.T("app.name"), Visible = true, ContextMenuStrip = _menu };
        Loc.Changed += () => _icon.Text = Loc.T("app.name");
        _menu.Opening += (s, e) => Rebuild();
        _icon.MouseUp += (s, e) => { if (e.Button == MouseButtons.Left) ShowMenu(); };
        _icon.DoubleClick += (s, e) => App.ShowMainWindow();
    }

    private void ShowMenu()
    {
        // Show the same menu on left click (a private NotifyIcon method)
        var method = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
        method?.Invoke(_icon, null);
    }

    private static Icon LoadIcon()
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("WindowLayouts.Assets.app.ico");
            if (stream != null) return new Icon(stream);
        }
        catch { }
        return SystemIcons.Application;
    }

    private void Rebuild()
    {
        _menu.Items.Clear();
        var store = LayoutStore.Shared;
        foreach (var group in store.Groups(Displays.Current()))
        {
            if (group.IsCurrent)
            {
                _menu.Items.Add(new ToolStripMenuItem(Loc.T("menu.current_config", ("name", group.ConfigName))) { Enabled = false });
                if (group.Layouts.Count == 0)
                    _menu.Items.Add(new ToolStripMenuItem(Loc.T("menu.no_layouts_in_config")) { Enabled = false });
                foreach (var layout in group.Layouts) _menu.Items.Add(LayoutItem(layout));
            }
            else
            {
                var sub = new ToolStripMenuItem(Loc.T("menu.other_config", ("name", group.ConfigName)));
                foreach (var layout in group.Layouts) sub.DropDownItems.Add(LayoutItem(layout));
                _menu.Items.Add(sub);
            }
        }
        _menu.Items.Add(new ToolStripSeparator());

        var save = new ToolStripMenuItem(Loc.T("menu.save_current"));
        // Capture the window state at the moment the menu was clicked, then open the window
        save.Click += (s, e) => App.ShowMainWindow(new CaptureRequest { Windows = WindowCapture.CurrentWindows() });
        _menu.Items.Add(save);

        var settings = new ToolStripMenuItem(Loc.T("menu.settings"));
        settings.Click += (s, e) => App.ShowMainWindow();
        _menu.Items.Add(settings);

        _menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem(Loc.T("menu.quit"));
        quit.Click += (s, e) => System.Windows.Application.Current.Shutdown();
        _menu.Items.Add(quit);
    }

    private static ToolStripMenuItem LayoutItem(WindowLayout layout)
    {
        var item = new ToolStripMenuItem(layout.Name)
        {
            Checked = LayoutStore.Shared.LastAppliedId == layout.Id,
            Enabled = !LayoutApplier.Shared.IsApplying,
        };
        item.Click += async (s, e) => await LayoutApplier.Shared.Apply(layout);
        return item;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }
}
