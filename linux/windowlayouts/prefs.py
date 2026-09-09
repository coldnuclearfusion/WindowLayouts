"""Small settings (language, capture options): ~/.config/windowlayouts/prefs.json"""
from __future__ import annotations

import json

from . import paths


def _read() -> dict:
    try:
        with open(paths.PREFS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def get(key: str, default):
    return _read().get(key, default)


def set(key: str, value) -> None:   # noqa: A001
    data = _read()
    data[key] = value
    try:
        with open(paths.PREFS_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except OSError:
        pass
