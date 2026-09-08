"""앱 전체를 묶는 객체: 저장소, 적용기, 트레이, 설정 창, 명령 처리"""
from __future__ import annotations

import threading

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import applylog, capture  # noqa: E402
from .applier import Applier  # noqa: E402
from .store import LayoutStore  # noqa: E402
from .tray import Tray  # noqa: E402
from .ui_ask import ask_missing  # noqa: E402
from .ui_capture import CaptureDialog  # noqa: E402
from .ui_main import MainWindow  # noqa: E402
from .x11 import X11  # noqa: E402


class App:
    def __init__(self) -> None:
        self.store = LayoutStore()
        self.x = X11()                       # 메인 스레드용 X 연결
        self.applier = Applier(self.store, self._ask_on_main)
        self.main_window = None
        self.tray = Tray(self)
        self.store.on_change(lambda: self.tray.rebuild())
        self.applier.on_report(lambda: self.tray.rebuild())
        self._last_monitor_key = self.current_display_config().key
        GLib.timeout_add_seconds(5, self._poll_monitors)
        applylog.write("앱 시작")

    # ---- 상태

    def current_display_config(self):
        return self.x.monitors()

    def _poll_monitors(self) -> bool:
        key = self.current_display_config().key
        if key != self._last_monitor_key:
            self._last_monitor_key = key
            self.tray.rebuild()
            if self.main_window is not None:
                self.main_window.rebuild_sidebar()
        return True

    # ---- 동작

    def apply_layout(self, layout) -> None:
        self.applier.apply_async(layout)
        self.tray.rebuild()

    def _ask_on_main(self, names, layout_name):
        """작업 스레드에서 호출: 메인 스레드에서 대화상자를 띄우고 답을 기다린다"""
        result: dict = {}
        done = threading.Event()

        def run():
            try:
                result["v"] = ask_missing(self.main_window if self.main_window and self.main_window.get_visible() else None,
                                          names, layout_name)
            finally:
                done.set()
            return False

        GLib.idle_add(run)
        done.wait()
        return result.get("v", ("cancel", False))

    def show_settings(self) -> None:
        if self.main_window is None:
            self.main_window = MainWindow(self)
        self.main_window.show_all()
        self.main_window.present()

    def capture_new(self) -> None:
        request = capture.make_request(self.x)      # 메뉴를 누른 순간의 창 상태
        self.show_settings()
        self._run_capture(request)

    def capture_into(self, layout_id: str) -> None:
        request = capture.make_request(self.x, layout_id)
        self._run_capture(request)

    def _run_capture(self, request) -> None:
        dlg = CaptureDialog(self.main_window, self.store, request)
        dlg.run()
        new_id = dlg.new_layout_id
        dlg.destroy()
        if new_id and self.main_window is not None:
            self.main_window.select_layout(new_id)

    def handle_args(self, args: list) -> None:
        i = 0
        while i < len(args):
            a = args[i]
            if a == "--apply" and i + 1 < len(args):
                key = args[i + 1]
                i += 1
                layout = next((l for l in self.store.layouts if l.name == key or l.id.lower() == key.lower()), None)
                if layout is not None:
                    self.apply_layout(layout)
                else:
                    applylog.write("명령줄로 요청한 배치를 찾지 못함: " + key)
            elif a == "--settings":
                self.show_settings()
            i += 1

    def quit(self) -> None:
        applylog.write("앱 종료")
        Gtk.main_quit()
