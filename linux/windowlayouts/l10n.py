"""UI strings. Reads the shared strings.json (the copy in the package assets, or ../shared in the checkout)."""
from __future__ import annotations

import json
import locale
import os
from typing import Callable

from . import paths
from . import prefs

SYSTEM_OPTION = "system"
_ORDER = ["ko", "en", "ja", "zh-Hans"]

_table: dict = {}
_languages: list = []       # [(code, name)]
_resolved = "en"
_listeners: list = []


def _candidates() -> list:
    here = os.path.dirname(os.path.abspath(__file__))
    return [os.path.join(here, "assets", "strings.json"),
            os.path.join(here, "..", "..", "shared", "strings.json")]


def _load() -> None:
    global _table, _languages
    for path in _candidates():
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        langs = data.get("languages", {})
        _languages = sorted(langs.items(), key=lambda kv: _ORDER.index(kv[0]) if kv[0] in _ORDER else 99)
        _table = data.get("strings", {})
        return


def languages() -> list:
    return list(_languages)


def resolved() -> str:
    return _resolved


def setting() -> str:
    return str(prefs.get("language", SYSTEM_OPTION))


def set_setting(value: str) -> None:
    global _resolved
    prefs.set("language", value)
    _resolved = resolve(value)
    for cb in list(_listeners):
        try:
            cb()
        except Exception:
            pass


def on_change(cb: Callable[[], None]) -> None:
    _listeners.append(cb)


def resolve(value: str) -> str:
    """Map the system language to one of the supported languages. Chinese maps to Simplified."""
    available = [c for c, _ in _languages]
    if value != SYSTEM_OPTION and value in available:
        return value
    names = []
    for env in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(env)
        if v:
            names.extend(v.split(":"))
    try:
        loc = locale.getlocale()[0]
        if loc:
            names.append(loc)
    except (ValueError, TypeError):
        pass
    for n in names:
        low = n.lower()
        if low.startswith("ko") and "ko" in available:
            return "ko"
        if low.startswith("ja") and "ja" in available:
            return "ja"
        if low.startswith("zh") and "zh-Hans" in available:
            return "zh-Hans"
        if low.startswith("en") and "en" in available:
            return "en"
    return "en" if "en" in available else (available[0] if available else "en")


def t(key: str, **kwargs) -> str:
    entry = _table.get(key, {})
    text = entry.get(_resolved) or entry.get("en") or key
    for k, v in kwargs.items():
        text = text.replace("{" + k + "}", str(v))
    return text


_load()
_resolved = resolve(setting())
