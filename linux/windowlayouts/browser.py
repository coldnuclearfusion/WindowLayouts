"""Browser windows and page addresses. Linux has no standard way to read the active tab's address,
so a window is matched by whether the site name appears in its title; otherwise a new window is opened."""
from __future__ import annotations

import os
import subprocess
from urllib.parse import urlsplit

from . import apps

BROWSER_EXES = {
    "firefox", "firefox-bin", "firefox-esr", "librewolf", "floorp", "zen", "waterfox",
    "chrome", "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
    "brave", "brave-browser", "vivaldi", "vivaldi-stable", "opera", "microsoft-edge", "msedge",
}


def is_browser(app_id: str) -> bool:
    exe = apps.executable_of(app_id)
    if not exe:
        return False
    base = os.path.basename(os.path.realpath(exe)).lower()
    return base in BROWSER_EXES


def normalize(raw: str) -> str:
    s = raw.strip()
    if "#" in s:
        s = s.split("#", 1)[0]
    if not s:
        return ""
    if "://" not in s:
        s = "https://" + s
    try:
        u = urlsplit(s)
    except ValueError:
        return s.lower().strip("/")
    host = (u.hostname or "").lower()
    if not host:
        return s.lower().strip("/")
    if host.startswith("www."):
        host = host[4:]
    path = u.path.rstrip("/")
    query = ("?" + u.query) if u.query else ""
    return host + path + query


def matches(saved: str, candidate: str) -> bool:
    a, b = normalize(saved), normalize(candidate)
    if not a or not b:
        return False
    if a == b:
        return True
    if not b.startswith(a):
        return False
    return b[len(a)] in "/?&"


def title_hints(saved_url: str, title: str) -> bool:
    """Treat the window as showing the page if the site name (first host label) appears in the title. A weak heuristic."""
    host = normalize(saved_url).split("/")[0].split("?")[0]
    label = host.split(".")[0] if host else ""
    return len(label) >= 3 and label.lower() in (title or "").lower()


def open_in_new_window(app_id: str, url: str) -> bool:
    exe = apps.executable_of(app_id)
    if not exe:
        return False
    try:
        subprocess.Popen([exe, "--new-window", url], start_new_session=True)
        return True
    except Exception:
        return False
