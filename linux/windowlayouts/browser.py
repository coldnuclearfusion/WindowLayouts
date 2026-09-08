"""브라우저 창을 페이지 주소로 다루기. Linux에서는 활성 탭 주소를 읽을 표준 방법이 없어서
제목에 사이트 이름이 들어 있는지로 추정하고, 없으면 새 창을 연다."""
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
    """제목에 사이트 이름(호스트의 첫 라벨)이 들어 있으면 그 페이지로 본다. 약한 추정."""
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
