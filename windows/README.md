# WindowLayouts for Windows

The Windows version of [WindowLayouts](../README.md): a tray app that saves window layouts and restores them in one click.

> **Status: draft, not yet built or tested.** This port was written on a Mac without a Windows toolchain, mirroring the macOS app file by file. Expect compile errors and rough edges on first build; the structure, data format and behavior are meant to match the macOS version.

## What it does

Same feature set as the macOS app, the same UI languages (Korean, English, Japanese, Simplified Chinese, following the system language by default and selectable under *General*) and the same `layouts.json` format:

- **Save the current layout** from the tray menu (*현재 창 배치 저장…*) or the **＋ 저장** button in the settings window. Pick windows per app, name the layout, optionally keep window titles and, for browsers, the page address of the active tab.
- **Restore in one click** from the tray menu (left or right click). Windows are restored from minimized/maximized state, moved and resized, and raised in the saved order.
- **Edit by hand** in the settings window (title, page address, matching mode, position, size, order) or in the JSON file, which is reloaded when it changes.
- **Per monitor setup.** Each layout records the monitor configuration it was saved on (stable device paths from `EnumDisplayDevices`). Layouts for the current setup come first; applying one from another setup remaps windows to the monitor they were on and clamps them to the screen.
- **Multiple windows per app**, matched by exact title, then word overlap (ignoring words shared by all windows of the app), then order.
- **Apps that aren't running, or have no visible window** (tray-resident apps): per-layout policy *ask / launch / only existing*. Launching runs the executable again (or `shell:AppsFolder\<AUMID>` for Store apps), which makes single-instance apps show a window.
- **Browser pages.** A browser row can carry a page address. The app reads each window's address bar through UI Automation to find a window showing that page; otherwise it opens the page with `--new-window`. Background tabs cannot be inspected on Windows, so a page that is open in a non-active tab gets a new window.
- **Starts at login** (HKCU Run key), lives in the notification area.
- **Command line:** `WindowLayouts.exe --apply "NAME"` (or a layout id) applies a layout; `--settings` opens the window. A second instance forwards the command to the running one through a named pipe.
- **Languages.** Strings come from `..\..\shared\strings.json`, embedded into the executable by the project file. Changing the language in *General* recreates the settings window in the new language; the tray menu is rebuilt on every open.

## Build and install

Requires Windows 10/11 x64 and the .NET 8 SDK.

```powershell
.\install.ps1     # publish → %LOCALAPPDATA%\Programs\WindowLayouts → launch
```

Or `dotnet build -c Release` inside `WindowLayouts\` for a plain build. No signing is needed; nothing here requires administrator rights.

## How windows are placed

Coordinates are physical pixels in the virtual screen (main monitor's top-left is (0,0)). The app is declared per-monitor-DPI-aware (v2) so `GetWindowRect` and monitor rectangles are consistent across monitors with different scaling. Frames are the *visible* frame from `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`; the invisible resize borders are compensated when calling `SetWindowPos`. After each move the frame is read back and, if it differs, the move is retried up to three times — moving a window to a monitor with a different DPI makes many apps resize themselves once, which the second attempt corrects. Frames that still differ are reported as "요청과 다르게 놓임".

Every apply is logged to `%LOCALAPPDATA%\WindowLayouts\apply.log` (*일반 설정 › 적용 로그 열기*).

## Data file

`%LOCALAPPDATA%\WindowLayouts\layouts.json`, same schema as macOS (see [`../macos/README.md`](../macos/README.md)). Differences:

- `bundleID` holds `exe:<full path>` for classic apps or `aumid:<AppUserModelId>` for Store apps.
- `displayConfig.displays[].id` is the monitor's device interface path; `name` is the monitor's PnP name.
- Coordinates are physical pixels.

## Layout of the source

```
WindowLayouts/
  WindowLayouts.csproj    .NET 8, WPF + WinForms (tray icon), win-x64
  app.manifest            per-monitor DPI awareness
  App.xaml(.cs)           startup, single instance, tray, command line
  Models.cs               WindowLayout, WindowEntry, DisplayConfig, policies, JSON options
  Loc.cs                  loads the embedded strings.json, resolves the language, Loc.T("key") lookup
  LayoutStore.cs          JSON persistence, file watching, grouping by monitor setup
  Native.cs               Win32 bindings
  Displays.cs             current monitor configuration
  WindowCapture.cs        enumerate top-level windows, app identity, launching
  WindowMatcher.cs        matching algorithm (same as macOS)
  BrowserSupport.cs       browser detection, URL matching, address bar via UI Automation, new windows
  LayoutApplier.cs        apply: policies, browser pages, verified placement, raising
  ApplyLog.cs             apply.log
  Ipc.cs                  named pipe for --apply from a second instance
  StartupRegistration.cs  Run key
  TrayIcon.cs             notification area icon and menu
  MainWindow.xaml(.cs)    settings window (sidebar + layout editor + general settings)
  CaptureWindow.xaml(.cs) choose windows to save
  AskMissingDialog.xaml   launch / only existing / cancel
  Assets/app.ico          icon (same artwork as macOS)
install.ps1               publish and install
```
