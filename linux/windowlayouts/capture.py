"""Collect the current windows (X11 + app identity + monitors)."""
from __future__ import annotations

from . import apps, browser
from .x11 import X11


class CaptureRequest:
    def __init__(self, windows: list, target_layout_id=None, display_config=None):
        self.windows = windows
        self.target_layout_id = target_layout_id
        self.display_config = display_config


def _identify(w) -> None:
    w.app_id, w.app_name = apps.identify(w.pid, w.wm_class)


def current_windows(x: X11) -> list:
    """For saving: windows visible on the current desktop (minimized excluded), front to back."""
    config = x.monitors()
    result = []
    for w in x.list_windows(include_minimized=False, current_desktop_only=True):
        _identify(w)
        d = config.display_containing(w.frame.mid_x, w.frame.mid_y) or config.display_containing(w.frame.x, w.frame.y)
        w.display_id = d.id if d else None
        w.url = None   # Linux has no standard way to read the active tab's address
        result.append(w)
    return result


def windows_of(x: X11, app_id: str) -> list:
    """For applying: this app's windows (including minimized ones and other desktops)."""
    result = []
    for w in x.list_windows(include_minimized=True, current_desktop_only=False):
        _identify(w)
        if w.app_id == app_id:
            result.append(w)
    return result


def make_request(x: X11, target_layout_id=None) -> CaptureRequest:
    return CaptureRequest(current_windows(x), target_layout_id, x.monitors())
