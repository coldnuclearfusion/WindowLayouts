"""설정 창: 왼쪽에 모니터 구성별 배치 목록, 오른쪽에 배치 편집 또는 일반 설정"""
from __future__ import annotations

import os
import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

from . import applylog, paths  # noqa: E402
from .models import MATCH_LABELS, POLICY_LABELS  # noqa: E402

# 사이드바 열: text, sub, kind(header|empty|layout|general), layout_id, group_id, weight
S_TEXT, S_SUB, S_KIND, S_LAYOUT, S_GROUP, S_WEIGHT = range(6)
# 창 표 열
C_ENABLED, C_APP, C_TITLE, C_URL, C_MATCH, C_MONITOR, C_X, C_Y, C_W, C_H, C_ID = range(11)

AUTOSTART_FILE = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                              "autostart", "windowlayouts.desktop")


def launcher_command(extra: str = "") -> str:
    """자동 시작 항목에 쓸 실행 명령"""
    import shutil
    exe = shutil.which("windowlayouts")
    if exe:
        return f"{exe} {extra}".strip()
    pkg_parent = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return f"sh -c 'PYTHONPATH=\"{pkg_parent}\" \"{sys.executable}\" -m windowlayouts {extra}'"


class MainWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title="창 배치")
        self.app = app
        self.store = app.store
        self.current = None
        self._rebuilding = False
        self.set_default_size(1000, 640)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._on_delete)

        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.add(paned)

        # ---- 사이드바
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        top = Gtk.Box(spacing=6)
        top.set_border_width(8)
        title = Gtk.Label(label="창 배치")
        title.set_xalign(0)
        title.set_markup("<b>창 배치</b>")
        top.pack_start(title, True, True, 0)
        add_btn = Gtk.Button(label="＋ 저장")
        add_btn.set_tooltip_text("현재 열린 창들을 새 배치로 저장")
        add_btn.connect("clicked", lambda _b: self.app.capture_new())
        top.pack_end(add_btn, False, False, 0)
        side.pack_start(top, False, False, 0)

        self.side_model = Gtk.ListStore(str, str, str, str, str, int)
        self.sidebar = Gtk.TreeView(model=self.side_model)
        self.sidebar.set_headers_visible(False)
        r1 = Gtk.CellRendererText()
        r1.set_property("ellipsize", Pango.EllipsizeMode.END)
        col = Gtk.TreeViewColumn("", r1, text=S_TEXT, weight=S_WEIGHT)
        self.sidebar.append_column(col)
        sel = self.sidebar.get_selection()
        sel.set_select_function(self._can_select)
        sel.connect("changed", self._on_sidebar_changed)
        self.sidebar.connect("button-press-event", self._on_sidebar_button)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.add(self.sidebar)
        side.pack_start(scroller, True, True, 0)
        side.set_size_request(250, -1)
        paned.pack1(side, False, False)

        # ---- 오른쪽
        self.right = Gtk.Stack()
        paned.pack2(self.right, True, False)

        self.placeholder = Gtk.Label(label="배치를 선택하세요.\n왼쪽 목록에서 배치를 고르거나, ＋ 저장 버튼으로 현재 창 배치를 저장하세요.")
        self.placeholder.set_justify(Gtk.Justification.CENTER)
        self.placeholder.get_style_context().add_class("dim-label")
        self.right.add_named(self.placeholder, "placeholder")
        self.right.add_named(self._build_detail(), "detail")
        self.right.add_named(self._build_general(), "general")

        self.store.on_change(self._on_store_changed)
        self.app.applier.on_report(self._show_report)
        self.rebuild_sidebar()
        self.show_all()
        self._select_first_layout()

    # ---- 창 닫기 = 숨기기

    def _on_delete(self, *_args) -> bool:
        self.hide()
        return True

    def destroy_window(self) -> None:
        self.store.off_change(self._on_store_changed)
        self.app.applier.off_report(self._show_report)
        self.destroy()

    # ---- 사이드바

    def _can_select(self, selection, model, path, is_selected, *_):
        kind = model[path][S_KIND]
        return kind in ("layout", "general")

    def rebuild_sidebar(self) -> None:
        self._rebuilding = True
        selected_id = self.current.id if self.current else None
        general = self.right.get_visible_child_name() == "general"
        self.side_model.clear()
        for g in self.store.groups(self.app.current_display_config()):
            head = ("현재 모니터 구성" if g.is_current else "다른 모니터 구성") + ": " + g.config_name
            self.side_model.append([head, "", "header", "", g.id, Pango.Weight.BOLD])
            if not g.layouts:
                self.side_model.append(["    저장된 배치가 없습니다", "", "empty", "", g.id, Pango.Weight.NORMAL])
            for l in g.layouts:
                self.side_model.append(["    " + l.name, "", "layout", l.id, g.id, Pango.Weight.NORMAL])
        self.side_model.append(["", "", "header", "", "", Pango.Weight.NORMAL])
        self.side_model.append(["⚙  일반 설정", "", "general", "", "", Pango.Weight.NORMAL])
        self._rebuilding = False
        sel = self.sidebar.get_selection()
        for row in self.side_model:
            if (general and row[S_KIND] == "general") or (not general and selected_id and row[S_LAYOUT] == selected_id):
                sel.select_iter(row.iter)
                return
        if selected_id and not general:
            self._show_placeholder()

    def _select_first_layout(self) -> None:
        sel = self.sidebar.get_selection()
        for row in self.side_model:
            if row[S_KIND] == "layout":
                sel.select_iter(row.iter)
                return
        self._show_placeholder()

    def select_layout(self, lid: str) -> None:
        sel = self.sidebar.get_selection()
        for row in self.side_model:
            if row[S_LAYOUT] == lid:
                sel.select_iter(row.iter)
                return

    def _on_sidebar_changed(self, selection) -> None:
        if self._rebuilding:
            return
        model, it = selection.get_selected()
        if it is None:
            return
        kind = model[it][S_KIND]
        if kind == "general":
            self._show_general()
        elif kind == "layout":
            l = self.store.layout(model[it][S_LAYOUT])
            if l is not None:
                self._show_layout(l)

    def _on_sidebar_button(self, tree, event) -> bool:
        if event.button != 3:
            return False
        hit = tree.get_path_at_pos(int(event.x), int(event.y))
        if hit is None:
            return True
        path = hit[0]
        row = self.side_model[path]
        if row[S_KIND] != "layout":
            return True
        tree.get_selection().select_path(path)
        layout = self.store.layout(row[S_LAYOUT])
        if layout is None:
            return True
        group_ids = [r[S_LAYOUT] for r in self.side_model if r[S_KIND] == "layout" and r[S_GROUP] == row[S_GROUP]]
        menu = Gtk.Menu()

        def item(label, cb):
            mi = Gtk.MenuItem(label=label)
            mi.connect("activate", lambda _i: cb())
            menu.append(mi)

        item("적용", lambda: self.app.apply_layout(layout))
        item("복제", lambda: self._duplicate(layout))
        item("위로", lambda: self.store.move_layout(layout.id, -1, group_ids))
        item("아래로", lambda: self.store.move_layout(layout.id, +1, group_ids))
        menu.append(Gtk.SeparatorMenuItem())
        item("삭제…", lambda: self._delete(layout))
        menu.show_all()
        menu.popup_at_pointer(event)
        return True

    def _duplicate(self, layout) -> None:
        copy = self.store.duplicate(layout.id)
        if copy is not None:
            self.select_layout(copy.id)

    def _delete(self, layout) -> None:
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                buttons=Gtk.ButtonsType.YES_NO, text=f"‘{layout.name}’ 배치를 삭제할까요? 되돌릴 수 없습니다.")
        r = dlg.run()
        dlg.destroy()
        if r != Gtk.ResponseType.YES:
            return
        if self.current is not None and self.current.id == layout.id:
            self._show_placeholder()
        self.store.remove(layout.id)

    def _on_store_changed(self) -> None:
        self.rebuild_sidebar()
        if self.current is not None:
            fresh = self.store.layout(self.current.id)
            if fresh is None:
                self._show_placeholder()
            elif fresh is not self.current:
                self._show_layout(fresh)

    # ---- 상세 패널

    def _build_detail(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(16)

        row = Gtk.Box(spacing=12)
        self.name_entry = Gtk.Entry()
        self.name_entry.set_placeholder_text("배치 이름")
        self.name_entry.connect("changed", self._on_name_changed)
        row.pack_start(self.name_entry, True, True, 0)
        self.apply_button = Gtk.Button(label="▶  지금 적용")
        self.apply_button.connect("clicked", lambda _b: self.current and self.app.apply_layout(self.current))
        row.pack_end(self.apply_button, False, False, 0)
        box.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label="실행 중이 아니거나 창이 없는 앱이 있을 때:"), False, False, 0)
        self.policy_combo = Gtk.ComboBoxText()
        for key, label in POLICY_LABELS.items():
            self.policy_combo.append(key, label)
        self.policy_combo.connect("changed", self._on_policy_changed)
        row.pack_start(self.policy_combo, False, False, 0)
        self.raise_check = Gtk.CheckButton(label="적용할 때 이 창들을 다른 창들 위로 올리기 (표의 위 항목이 가장 앞)")
        self.raise_check.connect("toggled", self._on_raise_toggled)
        row.pack_start(self.raise_check, False, False, 16)
        box.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        self.display_label = Gtk.Label()
        self.display_label.set_xalign(0)
        self.display_label.set_line_wrap(True)
        row.pack_start(self.display_label, True, True, 0)
        change = Gtk.MenuButton(label="변경")
        menu = Gtk.Menu()
        mi = Gtk.MenuItem(label="현재 모니터 구성으로 지정")
        mi.connect("activate", lambda _i: self._set_display_config(self.app.current_display_config()))
        menu.append(mi)
        mi = Gtk.MenuItem(label="구성 무관으로 지정")
        mi.connect("activate", lambda _i: self._set_display_config(None))
        menu.append(mi)
        menu.show_all()
        change.set_popup(menu)
        row.pack_end(change, False, False, 0)
        box.pack_start(row, False, False, 0)

        # 창 표
        self.table_model = Gtk.ListStore(bool, str, str, str, str, str, str, str, str, str, str)
        self.table = Gtk.TreeView(model=self.table_model)
        self.table.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        toggle = Gtk.CellRendererToggle()
        toggle.connect("toggled", self._on_enabled_toggled)
        self.table.append_column(Gtk.TreeViewColumn("", toggle, active=C_ENABLED))
        self.table.append_column(Gtk.TreeViewColumn("앱", Gtk.CellRendererText(), text=C_APP))
        self._text_column("창 제목 (찾을 때 사용)", C_TITLE, expand=True)
        self._text_column("페이지 주소 (브라우저)", C_URL, expand=True)
        combo_model = Gtk.ListStore(str)
        for label in MATCH_LABELS.values():
            combo_model.append([label])
        combo = Gtk.CellRendererCombo(model=combo_model, text_column=0, has_entry=False, editable=True)
        combo.connect("edited", self._on_match_edited)
        self.table.append_column(Gtk.TreeViewColumn("찾기", combo, text=C_MATCH))
        self.table.append_column(Gtk.TreeViewColumn("모니터", Gtk.CellRendererText(), text=C_MONITOR))
        for title, col in (("X", C_X), ("Y", C_Y), ("너비", C_W), ("높이", C_H)):
            self._text_column(title, col)
        scroller = Gtk.ScrolledWindow()
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.add(self.table)
        box.pack_start(scroller, True, True, 0)

        row = Gtk.Box(spacing=8)
        for label, cb, tip in (
            ("＋ 현재 열린 창 추가…", self._add_windows, None),
            ("↻ 현재 위치로 갱신", self._refresh_frames, "저장된 창들을 지금 열린 창에서 찾아 위치와 크기를 다시 읽습니다"),
            ("선택 삭제", self._delete_rows, None),
            ("▲", lambda: self._move_selected(-1), "선택한 창을 한 칸 앞으로"),
            ("▼", lambda: self._move_selected(+1), "선택한 창을 한 칸 뒤로"),
        ):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda _b, f=cb: f())
            if tip:
                b.set_tooltip_text(tip)
            row.pack_start(b, False, False, 0)
        self.count_label = Gtk.Label()
        self.count_label.get_style_context().add_class("dim-label")
        row.pack_start(self.count_label, False, False, 8)
        box.pack_start(row, False, False, 0)

        self.refresh_label = Gtk.Label()
        self.refresh_label.set_xalign(0)
        self.refresh_label.get_style_context().add_class("dim-label")
        box.pack_start(self.refresh_label, False, False, 0)

        self.report_frame = Gtk.Frame()
        rbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        rbox.set_border_width(10)
        self.report_head = Gtk.Label()
        self.report_head.set_xalign(0)
        self.report_head.set_line_wrap(True)
        self.report_lines = Gtk.Label()
        self.report_lines.set_xalign(0)
        self.report_lines.set_line_wrap(True)
        self.report_lines.get_style_context().add_class("dim-label")
        rbox.pack_start(self.report_head, False, False, 0)
        rbox.pack_start(self.report_lines, False, False, 0)
        self.report_frame.add(rbox)
        self.report_frame.set_no_show_all(True)
        box.pack_start(self.report_frame, False, False, 0)
        return box

    def _text_column(self, title: str, col: int, expand: bool = False) -> None:
        r = Gtk.CellRendererText(editable=True)
        r.connect("edited", lambda _r, path, text, c=col: self._on_cell_edited(path, c, text))
        if expand:
            r.set_property("ellipsize", Pango.EllipsizeMode.END)
        column = Gtk.TreeViewColumn(title, r, text=col)
        column.set_expand(expand)
        column.set_resizable(True)
        self.table.append_column(column)

    def _show_placeholder(self) -> None:
        self.current = None
        self.right.set_visible_child_name("placeholder")

    def _show_general(self) -> None:
        self.current = None
        self._refresh_general()
        self.right.set_visible_child_name("general")

    def _show_layout(self, layout) -> None:
        self.current = layout
        self._loading = True
        self.name_entry.set_text(layout.name)
        self.policy_combo.set_active_id(layout.launch_policy)
        self.raise_check.set_active(layout.raise_windows)
        self._loading = False
        self._refresh_display_row()
        self._refresh_table()
        self.refresh_label.set_text("")
        self._show_report()
        self.right.set_visible_child_name("detail")

    def _entry(self, path):
        eid = self.table_model[path][C_ID]
        if self.current is None:
            return None
        return next((w for w in self.current.windows if w.id == eid), None)

    def _refresh_table(self) -> None:
        if self.current is None:
            return
        self.table_model.clear()
        cfg = self.current.display_config
        for w in self.current.windows:
            mon = cfg.display_with_id(w.display_id) if cfg else None
            self.table_model.append([w.enabled, w.app_name, w.title, w.url or "", MATCH_LABELS.get(w.title_match, "자동"),
                                     mon.name if mon else "–", str(int(w.x)), str(int(w.y)), str(int(w.width)),
                                     str(int(w.height)), w.id])
        self.count_label.set_text(f"{len(self.current.windows)}개 창 · 좌표는 루트 화면 왼쪽 위가 (0, 0), 픽셀")

    def _refresh_display_row(self) -> None:
        if self.current is None:
            return
        saved = self.current.display_config
        if saved is None:
            self.display_label.set_text("모니터 구성: 무관 (모든 구성에서 표시, 좌표 그대로 적용)")
            return
        cur = self.app.current_display_config()
        if saved.is_identical(cur):
            status = "현재와 같음"
        elif saved.has_same_displays(cur):
            status = "같은 모니터지만 배열이 달라, 적용할 때 위치를 맞춥니다"
        else:
            status = "현재 구성과 달라, 적용할 때 창이 있던 모니터를 찾아 위치를 맞춥니다"
        self.display_label.set_text(f"모니터 구성: {saved.name}   ·   {status}")

    def _show_report(self) -> None:
        report = self.app.applier.last_report
        if self.current is None or report is None or report.layout_id != self.current.id:
            self.report_frame.hide()
            return
        self.report_head.set_markup("<b>" + _escape(report.headline) + "</b>")
        self.report_lines.set_text("\n".join(report.lines))
        self.report_lines.set_visible(bool(report.lines))
        self.report_frame.show()
        self.report_frame.get_child().show_all()
        self.report_lines.set_visible(bool(report.lines))
        self.apply_button.set_sensitive(not self.app.applier.is_applying)

    # ---- 편집 콜백

    def _on_name_changed(self, entry) -> None:
        if self.current is None or getattr(self, "_loading", False):
            return
        self.current.name = entry.get_text()
        self.store.schedule_save()

    def _on_policy_changed(self, combo) -> None:
        if self.current is None or getattr(self, "_loading", False):
            return
        key = combo.get_active_id()
        if key in POLICY_LABELS:
            self.current.launch_policy = key
            self.store.schedule_save()

    def _on_raise_toggled(self, check) -> None:
        if self.current is None or getattr(self, "_loading", False):
            return
        self.current.raise_windows = check.get_active()
        self.store.schedule_save()

    def _set_display_config(self, config) -> None:
        if self.current is None:
            return
        self.current.display_config = config
        self.store.save()
        self._refresh_display_row()
        self._refresh_table()

    def _on_enabled_toggled(self, renderer, path) -> None:
        e = self._entry(path)
        if e is None:
            return
        e.enabled = not e.enabled
        self.table_model[path][C_ENABLED] = e.enabled
        self.store.schedule_save()

    def _on_match_edited(self, renderer, path, text) -> None:
        e = self._entry(path)
        if e is None:
            return
        key = next((k for k, v in MATCH_LABELS.items() if v == text), None)
        if key:
            e.title_match = key
            self.table_model[path][C_MATCH] = text
            self.store.schedule_save()

    def _on_cell_edited(self, path, col, text) -> None:
        e = self._entry(path)
        if e is None:
            return
        if col == C_TITLE:
            e.title = text
        elif col == C_URL:
            e.url = text.strip() or None
        else:
            try:
                value = float(text)
            except ValueError:
                return
            if col == C_X:
                e.x = round(value)
            elif col == C_Y:
                e.y = round(value)
            elif col == C_W:
                e.width = round(value)
            elif col == C_H:
                e.height = round(value)
            text = str(int(value))
        self.table_model[path][col] = text
        self.store.schedule_save()

    def _selected_entry_ids(self) -> list:
        model, paths_ = self.table.get_selection().get_selected_rows()
        return [model[p][C_ID] for p in paths_]

    def _add_windows(self) -> None:
        if self.current is not None:
            self.app.capture_into(self.current.id)

    def _refresh_frames(self) -> None:
        if self.current is None:
            return
        n = self.app.applier.refresh_frames(self.app.x, self.current)
        self.store.save()
        self._refresh_display_row()
        self._refresh_table()
        self.refresh_label.set_text(f"{n}개 창의 위치를 현재 상태로 갱신하고, 모니터 구성을 현재 것으로 바꿨습니다.")

    def _delete_rows(self) -> None:
        if self.current is None:
            return
        ids = set(self._selected_entry_ids())
        if ids:
            self.store.remove_entries(ids, self.current.id)
            self._refresh_table()

    def _move_selected(self, delta: int) -> None:
        if self.current is None:
            return
        ids = self._selected_entry_ids()
        if len(ids) != 1:
            return
        self.store.move_entry(ids[0], delta, self.current.id)
        self._refresh_table()
        for row in self.table_model:
            if row[C_ID] == ids[0]:
                self.table.get_selection().select_iter(row.iter)

    # ---- 일반 설정

    def _build_general(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_border_width(16)

        def heading(text):
            l = Gtk.Label()
            l.set_markup(f"<b>{text}</b>")
            l.set_xalign(0)
            box.pack_start(l, False, False, 8)

        def note(text):
            l = Gtk.Label(label=text)
            l.set_xalign(0)
            l.set_line_wrap(True)
            l.get_style_context().add_class("dim-label")
            box.pack_start(l, False, False, 0)

        heading("시작")
        self.autostart_check = Gtk.CheckButton(label="로그인할 때 자동으로 실행")
        self.autostart_check.connect("toggled", self._on_autostart_toggled)
        box.pack_start(self.autostart_check, False, False, 0)
        self.autostart_error = Gtk.Label()
        self.autostart_error.set_xalign(0)
        box.pack_start(self.autostart_error, False, False, 0)

        heading("배치 데이터")
        self.file_label = Gtk.Label(label=paths.LAYOUTS_FILE)
        self.file_label.set_xalign(0)
        self.file_label.set_selectable(True)
        box.pack_start(self.file_label, False, False, 0)
        row = Gtk.Box(spacing=8)
        for label, cb in (("파일 열기", lambda: _open(paths.LAYOUTS_FILE)),
                          ("폴더 열기", lambda: _open(paths.CONFIG_DIR)),
                          ("다시 읽기", self.store.reload),
                          ("적용 로그 열기", lambda: _open(paths.LOG_FILE, create=True))):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda _b, f=cb: f())
            row.pack_start(b, False, False, 0)
        box.pack_start(row, False, False, 0)
        note("JSON 파일을 직접 편집해 저장하면 앱이 자동으로 다시 읽습니다. 창 항목의 x, y, width, height, title, url, titleMatch(auto/title/order), enabled 를 고칠 수 있습니다.")
        self.load_error_label = Gtk.Label()
        self.load_error_label.set_xalign(0)
        box.pack_start(self.load_error_label, False, False, 0)
        note("명령줄이나 단축키에서 적용하려면:  windowlayouts --apply \"배치이름\"")

        heading("모니터")
        self.monitors_label = Gtk.Label()
        self.monitors_label.set_xalign(0)
        box.pack_start(self.monitors_label, False, False, 0)
        note("배치는 저장 당시 모니터 구성과 함께 기록됩니다. 메뉴와 목록에서 현재 구성에 맞는 배치가 먼저 나오고, 다른 구성의 배치를 적용하면 창이 있던 모니터를 찾아 위치를 맞춥니다. Wayland 세션에서는 다른 앱의 창을 옮길 수 없어 X11 세션이 필요합니다.")
        return box

    def _refresh_general(self) -> None:
        self._loading = True
        self.autostart_check.set_active(os.path.exists(AUTOSTART_FILE))
        self._loading = False
        self.autostart_error.set_text("")
        self.load_error_label.set_text(self.store.load_error or "")
        cfg = self.app.current_display_config()
        self.monitors_label.set_text("현재 구성: " + cfg.name + "\n" + "\n".join(
            f"{d.name}{' (주 모니터)' if d.is_main else ''} · {d.frame.short()}" for d in cfg.displays))

    def _on_autostart_toggled(self, check) -> None:
        if getattr(self, "_loading", False):
            return
        try:
            if check.get_active():
                os.makedirs(os.path.dirname(AUTOSTART_FILE), exist_ok=True)
                with open(AUTOSTART_FILE, "w", encoding="utf-8") as f:
                    f.write("[Desktop Entry]\nType=Application\nName=WindowLayouts\nComment=창 배치 저장/복원\n"
                            f"Exec={launcher_command('--background')}\nIcon=windowlayouts\nTerminal=false\n"
                            "X-GNOME-Autostart-enabled=true\n")
            elif os.path.exists(AUTOSTART_FILE):
                os.remove(AUTOSTART_FILE)
            self.autostart_error.set_text("")
        except OSError as e:
            self.autostart_error.set_markup(f"<span foreground='red'>설정 실패: {_escape(str(e))}</span>")


def _escape(s: str) -> str:
    from gi.repository import GLib
    return GLib.markup_escape_text(s)


def _open(path: str, create: bool = False) -> None:
    if create and not os.path.exists(path):
        try:
            open(path, "a", encoding="utf-8").close()
        except OSError:
            return
    try:
        subprocess.Popen(["xdg-open", path], start_new_session=True)
    except OSError:
        pass
