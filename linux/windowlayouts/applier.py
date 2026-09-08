"""배치 적용: 실행 정책, 브라우저 페이지, 검증하는 배치, 앞으로 올리기. 작업 스레드에서 돈다."""
from __future__ import annotations

import threading
import time
from typing import Callable, Optional

from gi.repository import GLib

from . import applylog, apps, browser, capture, matcher
from .l10n import t
from .models import DisplayConfig, Frame, WindowEntry, WindowLayout
from .x11 import X11


class ApplyReport:
    def __init__(self, layout: WindowLayout):
        self.layout_id = layout.id
        self.layout_name = layout.name
        self.placed: list = []
        self.unmatched: list = []
        self.launched: list = []
        self.not_running: list = []
        self.failed: list = []
        self.mismatched: list = []
        self.notes: list = []
        self.cancelled = False
        self.error: Optional[str] = None

    @property
    def headline(self) -> str:
        if self.error:
            return self.error
        if self.cancelled:
            return t("report.cancelled", name=self.layout_name)
        s = t("report.headline", name=self.layout_name, placed=len(self.placed))
        if self.unmatched:
            s += t("report.unmatched_suffix", count=len(self.unmatched))
        if self.mismatched:
            s += t("report.mismatched_suffix", count=len(self.mismatched))
        if self.failed:
            s += t("report.failed_suffix", count=len(self.failed))
        return s

    @property
    def lines(self) -> list:
        l = list(self.notes)
        if self.launched:
            l.append(t("report.launched", list=", ".join(self.launched)))
        if self.not_running:
            l.append(t("report.not_running", list=", ".join(self.not_running)))
        if self.unmatched:
            l.append(t("report.unmatched", list=", ".join(self.unmatched)))
        if self.failed:
            l.append(t("report.failed", list=", ".join(self.failed)))
        if self.mismatched:
            l.append(t("report.mismatched", list=" · ".join(self.mismatched)))
        return l


def target_frame(entry: WindowEntry, saved: Optional[DisplayConfig], current: DisplayConfig) -> Frame:
    """모니터 구성이 저장 당시와 다르면 창이 있던 모니터 기준 상대 위치로 옮기고, 없으면 주 모니터에 놓는다."""
    if saved is None or saved.is_identical(current) or current.main is None:
        return entry.frame
    sd = saved.display_with_id(entry.display_id) or saved.display_containing(entry.frame.mid_x, entry.frame.mid_y) or saved.main
    if sd is None:
        return entry.frame
    target = current.display_with_id(sd.id) or current.main
    x = target.x + (entry.x - sd.x)
    y = target.y + (entry.y - sd.y)
    w = min(entry.width, target.width)
    h = min(entry.height, target.height)
    x = max(target.x, min(x, target.frame.right - w))
    y = max(target.y, min(y, target.frame.bottom - h))
    return Frame(x, y, w, h)


class Applier:
    """ask_fn(names, layout_name) -> ("launch"|"skip"|"cancel", remember). 메인 스레드에서 대화상자를 띄우는 함수."""

    def __init__(self, store, ask_fn: Callable) -> None:
        self.store = store
        self.ask_fn = ask_fn
        self.is_applying = False
        self.last_report: Optional[ApplyReport] = None
        self._listeners: list = []

    def on_report(self, cb: Callable[[], None]) -> None:
        self._listeners.append(cb)

    def off_report(self, cb) -> None:
        if cb in self._listeners:
            self._listeners.remove(cb)

    def apply_async(self, layout: WindowLayout) -> None:
        if self.is_applying:
            return
        self.is_applying = True
        threading.Thread(target=self._run, args=(layout,), daemon=True, name="apply").start()

    def _run(self, layout: WindowLayout) -> None:
        report = ApplyReport(layout)
        applylog.write(t("log.start", name=layout.name, policy=layout.launch_policy).replace("{raise}", str(layout.raise_windows)))
        x = None
        try:
            x = X11()
            self._apply(x, layout, report)
        except Exception as e:   # noqa: BLE001
            report.error = t("report.error", error=str(e))
            applylog.write(f"error: {e!r}")
        finally:
            if x is not None:
                x.close()
            self.last_report = report
            self.is_applying = False
            applylog.write(t("log.end", summary=report.headline + " " + " | ".join(report.lines)))
            GLib.idle_add(self._notify)

    def _notify(self) -> bool:
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass
        return False

    def _apply(self, x: X11, layout: WindowLayout, report: ApplyReport) -> None:
        entries = [w for w in layout.windows if w.enabled]
        app_ids = layout.enabled_app_ids
        current = x.monitors()
        applylog.write(t("log.monitors", list=" / ".join(f"{d.name} {d.frame.short()}{t('log.main_suffix') if d.is_main else ''}" for d in current.displays)))
        if layout.display_config is not None and not layout.display_config.is_identical(current):
            report.notes.append(t("report.config_differs", saved=layout.display_config.name, current=current.name))

        missing = [a for a in app_ids if not apps.running_pids(a)]

        def windowless_check(a: str) -> bool:
            if a in missing:
                return False
            app_entries = [e for e in entries if e.bundle_id == a]
            if browser.is_browser(a) and all(e.has_url for e in app_entries):
                return False
            return not capture.windows_of(x, a)

        windowless = [a for a in app_ids if windowless_check(a)]
        needs_open = missing + windowless
        skipped: set = set()
        allow_new_windows = layout.launch_policy != "runningOnly"

        def label(a: str) -> str:
            return layout.app_name(a) + (t("report.windowless_suffix") if a in windowless else "")

        if needs_open:
            policy = layout.launch_policy
            if policy == "ask":
                choice, remember = self.ask_fn([label(a) for a in needs_open], layout.name)
                if choice == "launch":
                    policy = "launchMissing"
                elif choice == "skip":
                    policy = "runningOnly"
                else:
                    report.cancelled = True
                    return
                if remember:
                    GLib.idle_add(self._remember_policy, layout.id, policy)
            if policy == "launchMissing":
                to_wait: dict = {}
                for a in needs_open:
                    reopen = a in windowless
                    if apps.launch(a):
                        report.launched.append(layout.app_name(a) + (t("report.new_window_suffix") if reopen else ""))
                        to_wait[a] = sum(1 for e in entries if e.bundle_id == a)
                    else:
                        report.failed.append(t("report.app_not_found", app=layout.app_name(a)))
                        skipped.add(a)
                self._wait_for_windows(x, to_wait)
            else:
                allow_new_windows = False
                for a in needs_open:
                    skipped.add(a)
                    report.not_running.append(label(a))

        placed: list = []
        for a in app_ids:
            if a in skipped:
                continue
            windows = capture.windows_of(x, a)
            app_entries = [e for e in entries if e.bundle_id == a]
            matches: list = []

            if browser.is_browser(a):
                for entry in [e for e in app_entries if e.has_url]:
                    win, note = self._resolve_browser_window(x, entry, a, windows, allow_new_windows)
                    if note and note not in report.notes:
                        report.notes.append(note)
                    if win is not None:
                        matches.append((entry, win))
                        windows = [w for w in windows if w.wid != win.wid]
                        app_entries.remove(entry)
            matches.extend(matcher.match(app_entries, windows))

            for entry, win in matches:
                if win is None:
                    report.unmatched.append(entry.display_name)
                    applylog.write(t("log.no_match", window=entry.display_name, count=len(windows)))
                    continue
                frame = target_frame(entry, layout.display_config, current)
                applylog.write(t("log.assigned", window=entry.display_name, title=win.title))
                kind, actual = x.place(win.wid, frame, lambda s, e=entry: applylog.write(f"[{e.display_name}] {s}"))
                if kind == "failed":
                    report.failed.append(entry.display_name)
                    continue
                report.placed.append(entry.display_name)
                placed.append((entry, win))
                if kind == "mismatch" and actual is not None:
                    report.mismatched.append(t("report.mismatch_item", window=entry.display_name, requested=frame.short(), actual=actual.short()))

        if layout.raise_windows and placed:
            self._raise(x, placed, [w.id for w in layout.windows])

        self.store.last_applied_id = layout.id

    def _remember_policy(self, lid: str, policy: str) -> bool:
        l = self.store.layout(lid)
        if l is not None:
            l.launch_policy = policy
            self.store.save()
        return False

    def refresh_frames(self, x: X11, layout: WindowLayout) -> int:
        """저장된 항목의 위치/크기를 지금 실제 창 위치로 갱신하고 모니터 구성도 현재 것으로 바꾼다."""
        updated = 0
        config = x.monitors()
        layout.display_config = config
        by_app: dict = {}
        for w in layout.windows:
            by_app.setdefault(w.bundle_id, []).append(w)
        for app_id, group in by_app.items():
            windows = capture.windows_of(x, app_id)
            for entry, win in matcher.match(group, windows):
                if win is None:
                    continue
                entry.frame = win.frame
                d = config.display_containing(win.frame.mid_x, win.frame.mid_y)
                entry.display_id = d.id if d else None
                updated += 1
        return updated

    # ---- 실행 대기

    @staticmethod
    def _wait_for_windows(x: X11, needed: dict) -> None:
        if not needed:
            return
        pending = set(needed)
        deadline = time.time() + 20
        while pending and time.time() < deadline:
            time.sleep(0.4)
            for a in list(pending):
                if capture.windows_of(x, a):
                    pending.discard(a)
        few = {a for a, n in needed.items() if n > 1}
        deadline = time.time() + 4
        while few and time.time() < deadline:
            time.sleep(0.4)
            for a in list(few):
                if len(capture.windows_of(x, a)) >= needed[a]:
                    few.discard(a)
        time.sleep(0.5)

    # ---- 브라우저

    @staticmethod
    def _resolve_browser_window(x: X11, entry: WindowEntry, app_id: str, windows: list, allow_new: bool) -> tuple:
        url = (entry.url or "").strip()
        for w in windows:
            if browser.title_hints(url, w.title):
                return w, None
        if not allow_new:
            return None, None
        before = {w.wid for w in capture.windows_of(x, app_id)}
        if not browser.open_in_new_window(app_id, url):
            return None, t("report.new_window_failed", app=entry.app_name, url=url)
        deadline = time.time() + 10
        while time.time() < deadline:
            time.sleep(0.3)
            fresh = next((w for w in capture.windows_of(x, app_id) if w.wid not in before), None)
            if fresh is not None:
                time.sleep(0.3)
                return fresh, t("report.opened_new_window", app=entry.app_name, url=url, reason=t("report.reason_linux_tabs"))
        return None, t("report.new_window_timeout", app=entry.app_name, url=url)

    # ---- 앞으로 올리기

    @staticmethod
    def _raise(x: X11, placed: list, order: list) -> None:
        position = {lid: i for i, lid in enumerate(order)}
        ordered = sorted(placed, key=lambda p: position.get(p[0].id, 0))
        groups: list = []
        for entry, win in ordered:
            g = next((g for g in groups if g[0] == entry.bundle_id), None)
            if g is None:
                g = (entry.bundle_id, [])
                groups.append(g)
            g[1].append((entry, win))
        for _, items in reversed(groups):
            for entry, win in reversed(items):
                x.activate(win.wid)
                time.sleep(0.05)
        if ordered:
            x.activate(ordered[0][1].wid)
