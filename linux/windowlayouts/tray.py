"""트레이 아이콘과 메뉴. AppIndicator가 있으면 그것을, 없으면 Gtk.StatusIcon을 쓴다."""
from __future__ import annotations

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from . import paths  # noqa: E402

AppIndicator = None
for _ns in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(_ns, "0.1")
        AppIndicator = getattr(__import__("gi.repository", fromlist=[_ns]), _ns)
        break
    except (ValueError, ImportError, AttributeError):
        continue


class Tray:
    def __init__(self, app) -> None:
        self.app = app
        self.menu = Gtk.Menu()
        self.indicator = None
        self.status_icon = None
        if AppIndicator is not None:
            self.indicator = AppIndicator.Indicator.new("windowlayouts", "windowlayouts",
                                                        AppIndicator.IndicatorCategory.APPLICATION_STATUS)
            try:
                self.indicator.set_icon_full(paths.ICON_FILE, "창 배치")
            except Exception:
                pass
            self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
            self.indicator.set_title("창 배치")
            self.rebuild()
        else:
            self.status_icon = Gtk.StatusIcon.new_from_file(paths.ICON_FILE)
            self.status_icon.set_tooltip_text("창 배치")
            self.status_icon.connect("popup-menu", self._on_popup)
            self.status_icon.connect("activate", self._on_popup_left)

    def _on_popup(self, icon, button, activate_time) -> None:
        self.rebuild()
        self.menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, activate_time)

    def _on_popup_left(self, icon) -> None:
        self.rebuild()
        self.menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, 1, Gtk.get_current_event_time())

    def rebuild(self) -> None:
        menu = Gtk.Menu()
        store = self.app.store
        for g in store.groups(self.app.current_display_config()):
            if g.is_current:
                header = Gtk.MenuItem(label="현재 모니터 구성: " + g.config_name)
                header.set_sensitive(False)
                menu.append(header)
                if not g.layouts:
                    empty = Gtk.MenuItem(label="이 구성에 저장된 배치가 없습니다")
                    empty.set_sensitive(False)
                    menu.append(empty)
                for l in g.layouts:
                    menu.append(self._layout_item(l))
            else:
                sub_item = Gtk.MenuItem(label="다른 구성: " + g.config_name)
                sub = Gtk.Menu()
                for l in g.layouts:
                    sub.append(self._layout_item(l))
                sub_item.set_submenu(sub)
                menu.append(sub_item)
        menu.append(Gtk.SeparatorMenuItem())
        save = Gtk.MenuItem(label="현재 창 배치 저장…")
        save.connect("activate", lambda _i: self.app.capture_new())
        menu.append(save)
        settings = Gtk.MenuItem(label="상세 설정…")
        settings.connect("activate", lambda _i: self.app.show_settings())
        menu.append(settings)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="종료")
        quit_item.connect("activate", lambda _i: self.app.quit())
        menu.append(quit_item)
        menu.show_all()
        self.menu = menu
        if self.indicator is not None:
            self.indicator.set_menu(menu)

    def _layout_item(self, layout) -> Gtk.MenuItem:
        applied = self.app.store.last_applied_id == layout.id
        item = Gtk.CheckMenuItem(label=layout.name) if applied else Gtk.MenuItem(label=layout.name)
        if applied:
            item.set_active(True)
        item.set_sensitive(not self.app.applier.is_applying)
        item.connect("activate", lambda _i, l=layout: self.app.apply_layout(l))
        return item
