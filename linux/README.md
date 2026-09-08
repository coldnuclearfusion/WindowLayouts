# WindowLayouts for Linux (X11)

The Linux version of [WindowLayouts](../README.md): a tray app that saves window layouts and restores them in one click.

> **Status: draft, not yet run or tested.** Written on a Mac without a Linux desktop at hand, mirroring the macOS app module by module. It is plain Python, so there is no compile step, but expect runtime errors and rough edges on the first run; the structure, data format and behavior are meant to match the macOS version. What has been verified on the Mac: every module compiles, and the pure logic (reading the real macOS `layouts.json`, matching, URL matching, EDID parsing, string lookup in all four languages) passes its tests.

## Requirements and limits

- **X11 session (Xorg).** Windows are read and moved through the EWMH window-manager protocol (`_NET_CLIENT_LIST_STACKING`, `_NET_MOVERESIZE_WINDOW`, `_NET_ACTIVE_WINDOW`, …), which every mainstream X11 window manager supports. **Wayland sessions are not supported**: Wayland has no protocol that lets one application position another application's windows. On a Wayland session only XWayland windows may partially work.
- Python 3.8+, PyGObject with GTK 3, python-xlib. AppIndicator (Ayatana) is used for the tray icon when available, otherwise `Gtk.StatusIcon`. GNOME needs an AppIndicator extension to show tray icons.

```bash
# Debian / Ubuntu
sudo apt install python3-gi gir1.2-gtk-3.0 python3-xlib gir1.2-ayatanaappindicator3-0.1
# Fedora
sudo dnf install python3-gobject gtk3 python3-xlib libappindicator-gtk3
# Arch
sudo pacman -S python-gobject gtk3 python-xlib libappindicator-gtk3
```

## Install

```bash
./install.sh      # copies the package to ~/.local/share/windowlayouts, creates ~/.local/bin/windowlayouts and a menu entry, starts it
```

Or run from the checkout without installing: `python3 -m windowlayouts` inside `linux/`.

## What it does

Same feature set as the macOS app, the same UI languages (Korean, English, Japanese, Simplified Chinese, following `LANGUAGE`/`LC_ALL`/`LANG` by default and selectable under *General*) and the same `layouts.json` format:

- **Save the current layout** from the tray menu or the settings window, choosing windows per app; optionally keep window titles.
- **Restore in one click** from the tray menu. Windows are unmaximized/unminimized, moved and resized, and raised in the saved order (the first row ends up in front and focused).
- **Edit by hand** in the settings window or in the JSON file, which is reloaded when it changes.
- **Per monitor setup** via RandR: each layout records the monitor configuration it was saved on (output name plus EDID vendor/model/serial when readable). Layouts for the current setup come first; applying one from another setup remaps windows to the monitor they were on.
- **Multiple windows per app**, matched by exact title, then word overlap, then order.
- **Apps that aren't running, or have no window:** per-layout policy *ask / launch / only existing*. Apps are identified by their `.desktop` entry when one can be matched from `WM_CLASS` (falling back to the executable path) and launched through it.
- **Browser pages.** A browser row can carry a page address. Linux has no standard way to read a browser's current tab address, so the app only checks whether the site name appears in a window title; otherwise it opens the page with `--new-window` and places that window.
- **Starts at login** via `~/.config/autostart`, lives in the tray.
- **Command line:** `windowlayouts --apply "NAME"` applies a layout (a second instance forwards the command to the running one over a Unix socket); `--settings` opens the window; `--background` starts without opening the window.
- **Languages.** Strings come from `../shared/strings.json`; `install.sh` copies it into the package as `assets/strings.json`, and running from the checkout reads the shared file directly. Changing the language in *General* rebuilds the tray menu and reopens the settings window in the new language.

## How windows are placed

Coordinates are root-window pixels. Frames include the window-manager decorations (`_NET_FRAME_EXTENTS`). Placement sends `_NET_MOVERESIZE_WINDOW` with north-west gravity, reads the resulting frame back and, if it differs, sends a corrected request offset by the difference (window managers interpret the reference point slightly differently), up to three times. Frames that still differ are reported as "요청과 다르게 놓임". Every apply is logged to `~/.config/windowlayouts/apply.log`.

## Data

`~/.config/windowlayouts/layouts.json`, same schema as macOS (see [`../macos/README.md`](../macos/README.md)). Differences:

- `bundleID` holds `desktop:<id>.desktop`, `exe:<path>` or `class:<WM_CLASS>`.
- `displayConfig.displays[].id` is `<output name>|<EDID vendor-model-serial>` when EDID is readable, otherwise the output name.

## Layout of the source

```
windowlayouts/
  __main__.py     entry point, single instance over a Unix socket
  app.py          wires store, applier, tray, windows; handles --apply
  models.py       WindowLayout, WindowEntry, DisplayConfig (same JSON as other platforms)
  l10n.py         loads strings.json, resolves the language, t("key") lookup
  prefs.py        small settings (language, capture options) in prefs.json
  store.py        JSON persistence, file monitoring, grouping by monitor setup
  x11.py          EWMH: list windows, frames, move/resize with verification, activate, RandR monitors, EDID
  apps.py         WM_CLASS → .desktop entry / executable, launch, running check
  capture.py      collect current windows
  matcher.py      matching algorithm
  browser.py      browser detection, URL matching, --new-window
  applier.py      apply in a worker thread: policies, browser pages, placement, raising
  applylog.py     apply.log
  tray.py         AppIndicator or StatusIcon menu
  ui_main.py      settings window
  ui_capture.py   choose windows to save
  ui_ask.py       launch / only existing / cancel dialog
  assets/         icon
install.sh        install to ~/.local
```
