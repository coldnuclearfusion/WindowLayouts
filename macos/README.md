# WindowLayouts for macOS

The macOS version of [WindowLayouts](../README.md): a menu bar app that saves window layouts and restores them in one click.

## What it does

- **Save the current layout.** Menu bar › *Save current windows…* (or the **+** button in the settings window) lists every open window grouped by app. Pick the windows to include, name the layout, save. Options: store window titles (used to tell apart several windows of one app) and, for browsers, the page address of the active tab.
- **Restore in one click.** Layouts are listed at the top of the menu bar menu. Clicking one moves and resizes the windows, unminimizes them, and by default raises them in the saved order (top row of the table ends up in front).
- **Edit by hand.** The settings window (*Settings…*) has a table per layout. The switch at the start of each row decides whether that window takes part when the layout is applied; a switched-off row is dimmed but kept. Title, page address, matching mode, position and size are edited in place, rows can be reordered, and positions can be re-read from the live windows. *Edit* turns on edit mode, which adds a check column for choosing rows to delete and the button for adding currently open windows; in that sheet, apps that are already in the layout start unchecked (so only new windows get added), and so does Finder, which is always running in the background. The JSON file can also be edited directly; the app reloads it when it changes.
- **Per monitor setup.** Every layout records the display configuration it was saved on. The menu and the sidebar show layouts for the current setup first; layouts from other setups sit in a *Other setup* submenu. Applying one of those remaps each window to the display it was on (by display id) and clamps it to the screen when that display is missing. A layout can also be marked *any setup*.
- **Multiple windows per app.** Windows are matched by exact title, then by word overlap after removing words shared by all windows of that app (for example a browser suffix), then by order. Per row you can force *title only* or *order only*.
- **Apps that aren't running, or have no window.** macOS keeps apps alive after the last window is closed. Both cases are handled by the layout's policy: *ask every time*, *launch and open windows*, or *only place existing windows*. Launching sends the app a reopen event, which makes it create a window, and the app waits for it before placing.
- **Browser pages.** A browser row can carry a page address. On apply, the app looks for a window that has a tab with that address, activates the tab and places that window; if there is none, it opens the page in a new window and places it. Safari and Chromium browsers (Chrome, Edge, Brave, Vivaldi) expose all tabs through AppleScript, so tabs hidden behind other tabs are found too — macOS asks once for Automation permission. The same lookup is used for browser rows that have a title but no address: when no window title matches, a tab whose title matches is activated and its window is used. Firefox and others only expose the active tab of each window through the Accessibility API, so background tabs are not detected there and a new window is opened instead. New windows are opened with the browser's `--new-window` flag (Safari: AppleScript). Every tab lookup (tabs listed, tab chosen, AppleScript errors) is written to the apply log.
- **Starts at login, lives in the menu bar.** No Dock icon. Toggle *Launch at login* under *General*.
- **Automation.** `open "windowlayouts://apply?name=Coding"` (or `?id=<layout UUID>`) applies a layout from a terminal, Shortcuts, or a hotkey app.
- **Languages.** Korean, English, Japanese and Simplified Chinese. *General › Language* offers *Follow system language* (default) or a fixed language; the change applies immediately to the menu and the open windows. The app's display name and permission prompts are localized through `Resources/*.lproj/InfoPlist.strings`.

## How windows are placed

Each window is resized first, then moved, then resized again, and the resulting frame is read back. If it differs from the request, the app retries twice with the other order and, if it still differs, reports the actual frame in the result ("Placed differently than requested"). The size-before-move order matters: Chromium-based apps (Chrome, Discord, Electron apps) ignore a resize that arrives right after the window has been moved to a display with a different backing scale (for example from a 1x external monitor to the 2x built-in display), which left windows too wide. Fullscreen windows are skipped; minimized windows are restored first.

Every apply is logged to `~/Library/Application Support/WindowLayouts/apply.log` (*General › Open apply log*): which window was matched to each row, each placement attempt with the frame read back, launches, and browser tab lookups. Check it first when a layout does not come out as expected.

## Build and install

Requires macOS 15 or later and Xcode. Recent Command Line Tools (Swift 6.4, macOS 26 SDK) no longer include the SwiftUI macro plugin and fail with `plugin for module 'SwiftUIMacros' not found`; `build.sh` picks Xcode's toolchain automatically when Xcode is installed (or set `DEVELOPER_DIR` yourself).

```bash
./install.sh     # build → /Applications/WindowLayouts.app → launch
```

`./build.sh` only builds; the bundle lands in `build/WindowLayouts.app`. It copies `../shared/strings.json` (the UI strings for all languages) and the `*.lproj` folders into the bundle. The icon is regenerated with `tools/make-icon.sh` from `tools/makeicon.swift`.

On first launch the app asks for **Accessibility** permission (System Settings › Privacy & Security › Accessibility). Without it the app can neither read nor move windows.

## Code signing (keeping the permission across rebuilds)

macOS ties the Accessibility permission to the app's code signature. With an ad-hoc signature every rebuild looks like a new app and the permission has to be granted again. `build.sh` picks the first signing identity it finds, in this order:

1. `WindowLayouts Dev` — a local self-signed certificate created by `./make-signing-cert.sh` (no Apple account, but one certificate per Mac).
2. `Apple Development: …` — from Xcode with a free Apple ID (recommended when using several Macs; the identity is the team, so it stays valid on every Mac where the same Apple ID is added).
3. `Developer ID Application: …`
4. Otherwise ad-hoc.

Override with `CODESIGN_IDENTITY="…" ./build.sh`.

If `security find-identity -v -p codesigning` shows `0 valid identities` even though Xcode created the certificate, the intermediate certificate is probably missing. Download `AppleWWDRCAG3.cer` from https://www.apple.com/certificateauthority/ and import it:

```bash
security import ~/Downloads/AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
```

A paid Apple Developer Program membership is only needed to distribute to other people (Developer ID and notarization).

## Installing on several Macs

On each Mac, once:

1. Install Xcode, launch it once, and add your Apple ID under Xcode › Settings › Accounts (a free "Personal Team" appears).
2. Select the team › *Manage Certificates…* › `+` › *Apple Development*.
3. Clone and install:

   ```bash
   git clone https://github.com/coldnuclearfusion/WindowLayouts.git ~/WindowLayouts
   ~/WindowLayouts/macos/install.sh
   ```

4. Grant Accessibility once. Later updates: `git pull`, then `install.sh` again.

Don't copy a built `.app` to another Mac over AirDrop or the like: the Apple Development signature is not notarized, and Gatekeeper blocks quarantined apps. Build from source on each Mac instead, or strip the quarantine attribute after copying (`xattr -dr com.apple.quarantine /Applications/WindowLayouts.app`).

## Data file

`~/Library/Application Support/WindowLayouts/layouts.json`

```json
{
  "version": 1,
  "layouts": [
    {
      "id": "…",
      "name": "Coding",
      "launchPolicy": "ask",
      "raiseWindows": true,
      "displayConfig": {
        "displays": [
          { "id": "…", "name": "Built-in Retina Display", "x": 0, "y": 0, "width": 1512, "height": 982, "isMain": true }
        ]
      },
      "windows": [
        {
          "bundleID": "com.apple.Terminal",
          "appName": "Terminal",
          "title": "zsh",
          "titleMatch": "auto",
          "url": null,
          "x": 0, "y": 25, "width": 960, "height": 1055,
          "displayID": "…",
          "enabled": true
        }
      ]
    }
  ]
}
```

- Coordinates: the top-left corner of the main display is (0, 0), y grows downward, other displays are relative to it.
- `launchPolicy`: `ask` / `launchMissing` / `runningOnly`.
- `raiseWindows`: raise the layout's windows after placing; earlier entries in `windows` end up in front.
- `displayConfig`: the monitor setup the layout was saved on. Remove it to make the layout show under every setup with coordinates applied as-is.
- `titleMatch`: `auto` (title first, then order) / `title` (title only, skip if none) / `order` (ignore title).
- `url`: page address for browser windows (see above). A bare host such as `youtube.com` matches any page on that host.
- `id`, `appName`, `titleMatch`, `enabled` and other fields may be omitted; defaults are filled in. The app reloads the file whenever it is saved.

## Layout of the source

```
Package.swift           Swift package, macOS 15+
Resources/Info.plist    LSUIElement (menu bar only), icon, usage descriptions, windowlayouts:// URL scheme
Resources/AppIcon.icns  app icon (tools/make-icon.sh)
Resources/*.lproj       localized display name and usage descriptions
../shared/strings.json  UI strings (ko/en/ja/zh-Hans), copied into the bundle by build.sh
Sources/WindowLayouts/
  App.swift             MenuBarExtra + settings window scene
  L10n.swift            loads strings.json, resolves the language, L("key") lookup
  Models.swift          WindowLayout, WindowEntry, DisplayConfig, policies
  LayoutStore.swift     JSON persistence, file watching, grouping by monitor setup
  SystemMonitor.swift   Accessibility permission and display change monitoring
  AX.swift              Accessibility API: list windows, verified move/resize with retries, page URL of a browser window
  ApplyLog.swift        apply.log writer
  WindowCapture.swift   collect open windows front to back
  LayoutApplier.swift   matching, launching/reopening apps, browser page resolution, raising
  BrowserSupport.swift  browser detection, URL matching, AppleScript tab search, new windows
  Views/                menu, main window, layout editor, capture sheet, general settings
build.sh / install.sh   build the .app bundle and sign it / install to /Applications
make-signing-cert.sh    optional local self-signed certificate
```

