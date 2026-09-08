# WindowLayouts for macOS

The macOS version of [WindowLayouts](../README.md): a menu bar app that saves window layouts and restores them in one click.

## What it does

- **Save the current layout.** Menu bar › *Save current windows…* (or the **+** button in the settings window) lists every open window grouped by app. Pick the windows to include, name the layout, save. Options: store window titles (used to tell apart several windows of one app) and, for browsers, the page address of the active tab.
- **Restore in one click.** Layouts are listed at the top of the menu bar menu. Clicking one moves and resizes the windows, unminimizes them, and by default raises them in the saved order (top row of the table ends up in front).
- **Edit by hand.** The settings window (*Settings…*) has a table per layout: enable/disable a window, edit its title, page address, matching mode, monitor, position and size, reorder rows, add currently open windows, or re-read positions from the live windows. The JSON file can also be edited directly; the app reloads it when it changes.
- **Per monitor setup.** Every layout records the display configuration it was saved on. The menu and the sidebar show layouts for the current setup first; layouts from other setups sit in a *Other setup* submenu. Applying one of those remaps each window to the display it was on (by display id) and clamps it to the screen when that display is missing. A layout can also be marked *any setup*.
- **Multiple windows per app.** Windows are matched by exact title, then by word overlap after removing words shared by all windows of that app (for example a browser suffix), then by order. Per row you can force *title only* or *order only*.
- **Apps that aren't running, or have no window.** macOS keeps apps alive after the last window is closed. Both cases are handled by the layout's policy: *ask every time*, *launch and open windows*, or *only place existing windows*. Launching sends the app a reopen event, which makes it create a window, and the app waits for it before placing.
- **Browser pages.** A browser row can carry a page address. On apply, the app looks for a window that has a tab with that address, activates the tab and places that window; if there is none, it opens the page in a new window and places it. Safari and Chromium browsers (Chrome, Edge, Brave, Vivaldi) expose all tabs through AppleScript, so tabs hidden behind other tabs are found too — macOS asks once for Automation permission. Firefox and others only expose the active tab of each window through the Accessibility API, so background tabs are not detected there and a new window is opened instead. New windows are opened with the browser's `--new-window` flag (Safari: AppleScript).
- **Starts at login, lives in the menu bar.** No Dock icon. Toggle *Launch at login* under *General*.

## Build and install

Requires macOS 15 or later and either Xcode or the Command Line Tools (`swift`, `codesign`, `iconutil`).

```bash
./install.sh     # build → /Applications/WindowLayouts.app → launch
```

`./build.sh` only builds; the bundle lands in `build/WindowLayouts.app`. The icon is regenerated with `tools/make-icon.sh` from `tools/makeicon.swift`.

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
Resources/Info.plist    LSUIElement (menu bar only), icon, usage descriptions
Resources/AppIcon.icns  app icon (tools/make-icon.sh)
Sources/WindowLayouts/
  App.swift             MenuBarExtra + settings window scene
  Models.swift          WindowLayout, WindowEntry, DisplayConfig, policies
  LayoutStore.swift     JSON persistence, file watching, grouping by monitor setup
  SystemMonitor.swift   Accessibility permission and display change monitoring
  AX.swift              Accessibility API: list windows, move/resize, page URL of a browser window
  WindowCapture.swift   collect open windows front to back
  LayoutApplier.swift   matching, launching/reopening apps, browser page resolution, raising
  BrowserSupport.swift  browser detection, URL matching, AppleScript tab search, new windows
  Views/                menu, main window, layout editor, capture sheet, general settings
build.sh / install.sh   build the .app bundle and sign it / install to /Applications
make-signing-cert.sh    optional local self-signed certificate
```

The UI strings are currently Korean.
