"""Window → app identity, launching, running check. Uses the .desktop entry when one can be matched, otherwise the executable path."""
from __future__ import annotations

import os
import subprocess
from typing import Optional

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402

_desktop_cache: Optional[list] = None


def _desktop_infos() -> list:
    global _desktop_cache
    if _desktop_cache is None:
        _desktop_cache = [a for a in Gio.AppInfo.get_all() if isinstance(a, Gio.DesktopAppInfo)]
    return _desktop_cache


def exe_of_pid(pid: Optional[int]) -> Optional[str]:
    if not pid:
        return None
    try:
        return os.path.realpath(f"/proc/{pid}/exe")
    except OSError:
        return None


def _exe_basename(info) -> str:
    exe = info.get_executable() or ""
    return os.path.basename(exe)


def find_desktop(wm_class: tuple, exe: Optional[str]):
    instance, cls = (wm_class + ("", ""))[:2]
    cls_l, inst_l = cls.lower(), instance.lower()
    exe_base = os.path.basename(exe).lower() if exe else ""
    best = None
    for info in _desktop_infos():
        swc = (info.get_string("StartupWMClass") or "").lower()
        if swc and swc in (cls_l, inst_l):
            return info
        base = _exe_basename(info).lower()
        if base and base in (cls_l, inst_l, exe_base) and best is None:
            best = info
    if best is None and cls_l:
        for info in _desktop_infos():
            if (info.get_id() or "").lower().startswith(cls_l + ".") and best is None:
                best = info
    return best


def identify(pid: Optional[int], wm_class: tuple) -> tuple:
    """(app_id, app_name). app_id is 'desktop:<file>.desktop' | 'exe:<path>' | 'class:<WM_CLASS>'"""
    exe = exe_of_pid(pid)
    info = find_desktop(wm_class, exe)
    if info is not None:
        return "desktop:" + (info.get_id() or ""), info.get_display_name() or wm_class[1] or "app"
    if exe:
        return "exe:" + exe, os.path.basename(exe)
    cls = wm_class[1] if len(wm_class) > 1 else ""
    from .l10n import t
    return "class:" + cls, cls or t("app.unknown")


def desktop_info(app_id: str):
    if app_id.startswith("desktop:"):
        try:
            return Gio.DesktopAppInfo.new(app_id[8:])
        except Exception:
            return None
    return None


def executable_of(app_id: str) -> Optional[str]:
    if app_id.startswith("exe:"):
        return app_id[4:]
    info = desktop_info(app_id)
    if info is not None:
        exe = info.get_executable()
        if exe:
            import shutil
            return shutil.which(exe) or exe
    return None


def launch(app_id: str) -> bool:
    try:
        info = desktop_info(app_id)
        if info is not None:
            return bool(info.launch([], None))
        exe = executable_of(app_id)
        if exe:
            subprocess.Popen([exe], start_new_session=True)
            return True
    except Exception:
        pass
    return False


def running_pids(app_id: str) -> list:
    """Process IDs running this app (scans /proc)."""
    target = executable_of(app_id)
    if not target:
        return []
    target_real = os.path.realpath(target)
    target_base = os.path.basename(target_real)
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            exe = os.path.realpath(f"/proc/{entry}/exe")
        except OSError:
            continue
        if exe == target_real or os.path.basename(exe) == target_base:
            pids.append(int(entry))
    return pids
