# WindowLayouts

**English** · [한국어](README.ko.md) · [日本語](README.ja.md) · [中文（简体）](README.zh-Hans.md)

Save window layouts and restore them in one click from the menu bar.

- **Save** the current arrangement of windows, choosing which apps and windows to include.
- **Restore** a layout instantly from the menu bar. The menu checks the layout that is in place: moving, resizing, minimizing or closing one of its windows removes the check, and putting the window back brings it back.
- **Edit by hand.** A settings window lets you edit every window's title, position and size, switch single windows off without deleting them, or edit the JSON file directly.
- **Per monitor setup.** Each layout remembers the display configuration it was saved on. Layouts for the current setup are listed first; applying a layout from another setup remaps windows to the displays that are present.
- **Multi-window apps.** Several windows of the same app are matched by title, then by order.
- **Missing apps.** When an app in the layout isn't running: ask, launch it, or arrange only what's running (per layout).
- **Raise on apply.** Optionally bring the layout's windows to the front, in the saved order.
- **Browser pages.** A browser window can carry a page address. On apply, the window that has the page open is used, even when the page is in a tab behind other tabs (Safari and Chromium browsers), and each layout decides whether that tab is brought to the front; if no window has it, the page opens in a new window.
- **Chrome profiles.** A Chrome window can remember the profile it belongs to: applying then uses only windows of that profile, and opens one in that profile when needed.
- **Clean uninstall.** General settings can remove the app: it turns off launch at login, removes its permission entries, and moves the app, its settings and, unless you keep them, the saved layouts to the Trash. A second button cleans up what older versions left behind.
- Starts at login and lives in the menu bar, no Dock icon.
- **Scriptable.** `open "windowlayouts://apply?name=Coding"` applies a layout from a terminal, Shortcuts, or a hotkey app.
- **Languages.** Korean, English, Japanese and Simplified Chinese, following the system language by default; selectable under General settings. All three apps share one string table, [`shared/strings.json`](shared/strings.json).

## Platforms

| Platform | Status | Directory |
|---|---|---|
| macOS 15+ | available | [`macos/`](macos/) |
| Windows 10/11 | draft, not yet built or tested | [`windows/`](windows/) |
| Linux (X11) | draft, not yet run or tested | [`linux/`](linux/) |

Layouts are stored as JSON (`layouts.json`) so the format can be shared across platforms; the Linux models have been verified to read the macOS file unchanged. The Windows and Linux ports were written on a Mac, mirroring the macOS app module by module, and have not been built or run yet. They check the layout applied last instead of watching whether its windows stay in place, and they have no search of tabs behind other tabs, no Chrome profiles and no uninstall; each platform's README lists the differences.

## Languages

The UI is available in Korean, English, Japanese and Simplified Chinese. By default each app follows the system language (Traditional Chinese systems get Simplified Chinese); a fixed language can be chosen under *General* in the settings window. Every user-visible string lives in [`shared/strings.json`](shared/strings.json), keyed by a stable identifier with `{placeholder}` substitution, and each platform copies that file into its build (macOS `build.sh`, the Windows project file, Linux `install.sh`). To add a language, add its code to `languages` and to every entry.

## Quick start (macOS)

Requires macOS 15 or later and Xcode (recent Command Line Tools lack the SwiftUI macro plugin; see [macos/README.md](macos/README.md)).

```bash
git clone https://github.com/coldnuclearfusion/WindowLayouts.git
cd WindowLayouts/macos
./install.sh
```

Then allow the app under System Settings › Privacy & Security › Accessibility. See [`macos/README.md`](macos/README.md) for details: code signing so the permission survives rebuilds, the JSON format, browser page and Chrome profile handling, the menu check, diagnostics, uninstalling, and installing on several Macs.

## License

MIT, see [LICENSE](LICENSE).
