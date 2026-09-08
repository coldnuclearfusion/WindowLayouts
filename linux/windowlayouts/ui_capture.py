"""현재 열린 창 중 어떤 것을 배치에 넣을지 고르는 대화상자"""
from __future__ import annotations

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from .models import WindowLayout  # noqa: E402
from .store import Prefs  # noqa: E402

COL_SELECTED, COL_INCONSISTENT, COL_TEXT, COL_DETAIL, COL_KEY = range(5)


class CaptureDialog(Gtk.Dialog):
    def __init__(self, parent, store, request):
        self.is_new = request.target_layout_id is None
        super().__init__(title="현재 창 배치 저장" if self.is_new else "현재 열린 창 추가",
                         transient_for=parent, modal=True)
        self.store = store
        self.request = request
        self.new_layout_id = None
        self.set_default_size(660, 560)
        self.add_button("취소", Gtk.ResponseType.CANCEL)
        self.save_button = self.add_button("저장" if self.is_new else "추가", Gtk.ResponseType.OK)
        self.set_default_response(Gtk.ResponseType.OK)

        box = self.get_content_area()
        box.set_spacing(8)
        box.set_border_width(14)

        self.name_entry = Gtk.Entry()
        self.name_entry.set_text(f"배치 {len(store.layouts) + 1}")
        self.name_entry.set_placeholder_text("배치 이름")
        self.name_entry.connect("changed", lambda _e: self._update_footer())
        if self.is_new:
            box.pack_start(self.name_entry, False, False, 0)

        config = Gtk.Label(label="모니터 구성: " + (request.display_config.name if request.display_config else "?"))
        config.set_xalign(0)
        config.get_style_context().add_class("dim-label")
        box.pack_start(config, False, False, 0)

        hint = Gtk.Label(label="포함할 창을 선택하세요. 앱 이름 줄의 체크로 그 앱의 창을 한꺼번에 켜고 끕니다.")
        hint.set_xalign(0)
        hint.get_style_context().add_class("dim-label")
        box.pack_start(hint, False, False, 0)

        self.titles_check = Gtk.CheckButton(label="창 제목도 저장 (같은 앱의 창이 여러 개일 때 구분하는 데 씀. 끄면 순서로만 찾음)")
        self.titles_check.set_active(bool(Prefs.get("saveWindowTitles", True)))
        box.pack_start(self.titles_check, False, False, 0)

        # 앱별로 묶은 트리
        self.model = Gtk.TreeStore(bool, bool, str, str, str)
        self.items: dict = {}
        groups: dict = {}
        order: list = []
        for i, w in enumerate(request.windows):
            if w.app_id not in groups:
                groups[w.app_id] = self.model.append(None, [True, False, w.app_name, "", f"g:{w.app_id}"])
                order.append(w.app_id)
            child = self.model.append(groups[w.app_id], [True, False, w.title or "(제목 없음)", w.frame.short(), f"w:{i}"])
            self.items[f"w:{i}"] = w

        tree = Gtk.TreeView(model=self.model)
        tree.set_headers_visible(False)
        toggle = Gtk.CellRendererToggle()
        toggle.connect("toggled", self._on_toggled)
        col = Gtk.TreeViewColumn("", toggle, active=COL_SELECTED, inconsistent=COL_INCONSISTENT)
        tree.append_column(col)
        text = Gtk.CellRendererText()
        text.set_property("ellipsize", 3)   # END
        col = Gtk.TreeViewColumn("창", text, text=COL_TEXT)
        col.set_expand(True)
        tree.append_column(col)
        detail = Gtk.CellRendererText()
        detail.set_property("foreground", "gray")
        tree.append_column(Gtk.TreeViewColumn("위치", detail, text=COL_DETAIL))
        tree.expand_all()

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        if request.windows:
            scroller.add(tree)
        else:
            empty = Gtk.Label(label="열려 있는 창을 찾지 못했습니다.")
            scroller.add(empty)
        box.pack_start(scroller, True, True, 0)

        self.count_label = Gtk.Label()
        self.count_label.set_xalign(1)
        self.count_label.get_style_context().add_class("dim-label")
        box.pack_start(self.count_label, False, False, 0)

        self.connect("response", self._on_response)
        self._update_footer()
        self.show_all()

    def _selected_items(self) -> list:
        out = []
        for key, w in self.items.items():
            for row in self._iter_children():
                if row[COL_KEY] == key and row[COL_SELECTED]:
                    out.append(w)
        return out

    def _iter_children(self):
        it = self.model.get_iter_first()
        while it is not None:
            child = self.model.iter_children(it)
            while child is not None:
                yield self.model[child]
                child = self.model.iter_next(child)
            it = self.model.iter_next(it)

    def _on_toggled(self, renderer, path) -> None:
        it = self.model.get_iter(path)
        if self.model.iter_has_child(it):
            all_on = all(self.model[c][COL_SELECTED] for c in self._children(it))
            for c in self._children(it):
                self.model[c][COL_SELECTED] = not all_on
        else:
            self.model[it][COL_SELECTED] = not self.model[it][COL_SELECTED]
        self._refresh_groups()
        self._update_footer()

    def _children(self, it) -> list:
        out = []
        c = self.model.iter_children(it)
        while c is not None:
            out.append(c)
            c = self.model.iter_next(c)
        return out

    def _refresh_groups(self) -> None:
        it = self.model.get_iter_first()
        while it is not None:
            states = [self.model[c][COL_SELECTED] for c in self._children(it)]
            self.model[it][COL_SELECTED] = all(states) if states else False
            self.model[it][COL_INCONSISTENT] = any(states) and not all(states)
            it = self.model.iter_next(it)

    def _update_footer(self) -> None:
        n = len(self._selected_items())
        self.count_label.set_text(f"{n}개 창 선택됨")
        ok = n > 0 and (not self.is_new or self.name_entry.get_text().strip() != "")
        self.save_button.set_sensitive(ok)

    def _on_response(self, dlg, response) -> None:
        if response != Gtk.ResponseType.OK:
            return
        titles = self.titles_check.get_active()
        Prefs.set("saveWindowTitles", titles)
        entries = [w.make_entry(include_title=titles, include_url=False) for w in self._selected_items()]
        if self.request.target_layout_id:
            self.store.append_entries(entries, self.request.target_layout_id)
        else:
            layout = WindowLayout(name=self.name_entry.get_text().strip(), display_config=self.request.display_config,
                                  windows=entries)
            self.store.add(layout)
            self.new_layout_id = layout.id
