"""Layout list persistence (~/.config/windowlayouts/layouts.json). Reloads automatically when the file is edited by hand.
Main (GTK) thread only."""
from __future__ import annotations

import json
import os
from typing import Callable, Optional

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import paths, prefs  # noqa: E402
from .l10n import t  # noqa: E402
from .models import DisplayConfig, WindowLayout, dump_file, load_file  # noqa: E402


class LayoutGroup:
    def __init__(self, gid: str, config_name: str, is_current: bool):
        self.id = gid
        self.config_name = config_name
        self.is_current = is_current
        self.layouts: list = []


class LayoutStore:
    def __init__(self) -> None:
        self.layouts: list = []
        self._last_applied_id: Optional[str] = prefs.get("lastAppliedLayoutId", None)
        self.load_error: Optional[str] = None
        self._listeners: list = []
        self._last_written: Optional[str] = None
        self._save_source: Optional[int] = None
        self._reload_source: Optional[int] = None
        if os.path.exists(paths.LAYOUTS_FILE):
            self._load(force=True)
        else:
            self.save()
        try:
            self._monitor = Gio.File.new_for_path(paths.LAYOUTS_FILE).monitor_file(Gio.FileMonitorFlags.NONE, None)
            self._monitor.connect("changed", self._on_file_changed)
        except Exception:
            self._monitor = None

    @property
    def last_applied_id(self) -> Optional[str]:
        """The layout applied last; it is checked in the tray menu. Kept in prefs.json so the check survives restarts."""
        return self._last_applied_id

    @last_applied_id.setter
    def last_applied_id(self, value: Optional[str]) -> None:
        self._last_applied_id = value
        prefs.set("lastAppliedLayoutId", value)

    # ---- notifications

    def on_change(self, cb: Callable[[], None]) -> None:
        self._listeners.append(cb)

    def off_change(self, cb: Callable[[], None]) -> None:
        if cb in self._listeners:
            self._listeners.remove(cb)

    def _notify(self) -> None:
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass

    # ---- queries

    def layout(self, lid: str) -> Optional[WindowLayout]:
        for l in self.layouts:
            if l.id == lid:
                return l
        return None

    def groups(self, current: DisplayConfig) -> list:
        cur = LayoutGroup("current", current.name, True)
        others: list = []
        for l in self.layouts:
            if l.display_config is not None and not l.display_config.has_same_displays(current):
                key = l.display_config.key
                g = next((o for o in others if o.id == key), None)
                if g is None:
                    g = LayoutGroup(key, l.display_config.name, False)
                    others.append(g)
                g.layouts.append(l)
            else:
                cur.layouts.append(l)
        return [cur] + others

    # ---- changes

    def add(self, layout: WindowLayout) -> None:
        self.layouts.append(layout)
        self.save()

    def remove(self, lid: str) -> None:
        self.layouts = [l for l in self.layouts if l.id != lid]
        if self.last_applied_id == lid:
            self.last_applied_id = None
        self.save()

    def duplicate(self, lid: str) -> Optional[WindowLayout]:
        for i, l in enumerate(self.layouts):
            if l.id == lid:
                copy = WindowLayout.from_json(json.loads(json.dumps(l.to_json())))
                copy.id = WindowLayout().id
                copy.name = l.name + t("layout.copy_suffix")
                for w in copy.windows:
                    w.id = WindowLayout().id
                self.layouts.insert(i + 1, copy)
                self.save()
                return copy
        return None

    def move_layout(self, lid: str, delta: int, group_ids: list) -> None:
        if lid not in group_ids:
            return
        i = group_ids.index(lid)
        j = i + delta
        if j < 0 or j >= len(group_ids):
            return
        subset = list(group_ids)
        subset.pop(i)
        subset.insert(j, lid)
        positions = [k for k, l in enumerate(self.layouts) if l.id in group_ids]
        by_id = {l.id: l for l in self.layouts}
        for pos, sid in zip(positions, subset):
            self.layouts[pos] = by_id[sid]
        self.save()

    def append_entries(self, entries: list, lid: str) -> None:
        l = self.layout(lid)
        if l is None:
            return
        l.windows.extend(entries)
        self.save()

    def remove_entries(self, entry_ids: set, lid: str) -> None:
        l = self.layout(lid)
        if l is None:
            return
        l.windows = [w for w in l.windows if w.id not in entry_ids]
        self.save()

    def move_entry(self, entry_id: str, delta: int, lid: str) -> None:
        l = self.layout(lid)
        if l is None:
            return
        idx = next((i for i, w in enumerate(l.windows) if w.id == entry_id), -1)
        j = idx + delta
        if idx < 0 or j < 0 or j >= len(l.windows):
            return
        l.windows[idx], l.windows[j] = l.windows[j], l.windows[idx]
        self.save()

    # ---- save / load

    def reload(self) -> None:
        self._load(force=True)

    def _load(self, force: bool) -> None:
        try:
            with open(paths.LAYOUTS_FILE, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError:
            return
        if not force and text == self._last_written:
            return
        try:
            self.layouts = load_file(text)
            self._last_written = text
            self.load_error = None
        except Exception as e:
            self.load_error = t("store.read_error", error=str(e))
        self._notify()

    def save(self) -> None:
        if self._save_source is not None:
            GLib.source_remove(self._save_source)
            self._save_source = None
        try:
            text = dump_file(self.layouts)
            self._last_written = text
            tmp = paths.LAYOUTS_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, paths.LAYOUTS_FILE)
            self.load_error = None
        except OSError as e:
            self.load_error = t("store.save_error", error=str(e))
        self._notify()

    def schedule_save(self) -> None:
        """Frequent edits are saved once, 0.5 s later."""
        if self._save_source is not None:
            GLib.source_remove(self._save_source)
        self._save_source = GLib.timeout_add(500, self._save_tick)

    def _save_tick(self) -> bool:
        self._save_source = None
        self.save()
        return False

    def _on_file_changed(self, monitor, file, other, event_type) -> None:
        if self._reload_source is not None:
            GLib.source_remove(self._reload_source)
        self._reload_source = GLib.timeout_add(300, self._reload_tick)

    def _reload_tick(self) -> bool:
        self._reload_source = None
        self._load(force=False)
        return False
