# WindowLayouts

Save window layouts and restore them in one click from the menu bar.

- **Save** the current arrangement of windows, choosing which apps and windows to include.
- **Restore** a layout instantly from the menu bar. A settings window lets you edit every window's title, position and size by hand, or edit the JSON file directly.
- **Per monitor setup.** Each layout remembers the display configuration it was saved on. Layouts for the current setup are listed first; applying a layout from another setup remaps windows to the displays that are present.
- **Multi-window apps.** Several windows of the same app are matched by title, then by order.
- **Missing apps.** When an app in the layout isn't running: ask, launch it, or arrange only what's running (per layout).
- **Raise on apply.** Optionally bring the layout's windows to the front, in the saved order.
- **Browser pages.** A browser window can carry a page address: on apply, the window that has that tab is used (tab activated), or the page is opened in a new window.
- Starts at login and lives in the menu bar, no Dock icon.
- **Scriptable.** `open "windowlayouts://apply?name=Coding"` applies a layout from a terminal, Shortcuts, or a hotkey app.

## Platforms

| Platform | Status | Directory |
|---|---|---|
| macOS 15+ | available | [`macos/`](macos/) |
| Windows 10/11 | draft, not yet built or tested | [`windows/`](windows/) |
| Linux | planned | `linux/` |

Layouts are stored as JSON (`layouts.json`) so the format can be shared across platforms.

## Quick start (macOS)

Requires macOS 15 or later and Xcode or the Command Line Tools.

```bash
git clone https://github.com/coldnuclearfusion/WindowLayouts.git
cd WindowLayouts/macos
./install.sh
```

Then allow the app under System Settings › Privacy & Security › Accessibility. See [`macos/README.md`](macos/README.md) for details: code signing so the permission survives rebuilds, the JSON format, browser page handling, and installing on several Macs.

## License

MIT, see [LICENSE](LICENSE).
