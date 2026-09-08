"""설정 창: 왼쪽에 모니터 구성별 배치 목록, 오른쪽에 배치 편집 또는 일반 설정"""
from __future__ import annotations

import os
import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

from . import applylog, l10n, paths  # noqa: E402
from .l10n import t  # noqa: E402
from .models import MATCH_KEYS, POLICY_KEYS, match_label, policy_label  # noqa: E402

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
        super().__init__(title=t("app.name"))
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
        title = Gtk.Label()
        title.set_xalign(0)
        title.set_markup("<b>" + _escape(t("app.name")) + "</b>")
        top.pack_start(title, True, True, 0)
        add_btn = Gtk.Button(label="＋ " + t("common.save"))
        add_btn.set_tooltip_text(t("sidebar.save_tooltip"))
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

        self.placeholder = Gtk.Label(label=t("sidebar.placeholder_title") + "\n" + t("sidebar.placeholder_body"))
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
            head = t("sidebar.current_config_header" if g.is_current else "sidebar.other_config_header") + ": " + g.config_name
            self.side_model.append([head, "", "header", "", g.id, Pango.Weight.BOLD])
            if not g.layouts:
                self.side_model.append(["    " + t("sidebar.no_layouts"), "", "empty", "", g.id, Pango.Weight.NORMAL])
            for l in g.layouts:
                self.side_model.append(["    " + l.name, "", "layout", l.id, g.id, Pango.Weight.NORMAL])
        self.side_model.append(["", "", "header", "", "", Pango.Weight.NORMAL])
        self.side_model.append(["⚙  " + t("sidebar.general"), "", "general", "", "", Pango.Weight.NORMAL])
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

        item(t("context.apply"), lambda: self.app.apply_layout(layout))
        item(t("context.duplicate"), lambda: self._duplicate(layout))
        item(t("context.move_up"), lambda: self.store.move_layout(layout.id, -1, group_ids))
        item(t("context.move_down"), lambda: self.store.move_layout(layout.id, +1, group_ids))
        menu.append(Gtk.SeparatorMenuItem())
        item(t("context.delete"), lambda: self._delete(layout))
        menu.show_all()
        menu.popup_at_pointer(event)
        return True

    def _duplicate(self, layout) -> None:
        copy = self.store.duplicate(layout.id)
        if copy is not None:
            self.select_layout(copy.id)

    def _delete(self, layout) -> None:
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                buttons=Gtk.ButtonsType.YES_NO, text=t("delete.title", name=layout.name) + "\n" + t("delete.message"))
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
        self.name_entry.set_placeholder_text(t("detail.name_placeholder"))
        self.name_entry.connect("changed", self._on_name_changed)
        row.pack_start(self.name_entry, True, True, 0)
        self.apply_button = Gtk.Button(label="▶  " + t("detail.apply_now"))
        self.apply_button.connect("clicked", lambda _b: self.current and self.app.apply_layout(self.current))
        row.pack_end(self.apply_button, False, False, 0)
        box.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label=t("detail.policy_label")), False, False, 0)
        self.policy_combo = Gtk.ComboBoxText()
        for key in POLICY_KEYS:
            self.policy_combo.append(key, policy_label(key))
        self.policy_combo.connect("changed", self._on_policy_changed)
        row.pack_start(self.policy_combo, False, False, 0)
        self.raise_check = Gtk.CheckButton(label=t("detail.raise"))
        self.raise_check.connect("toggled", self._on_raise_toggled)
        row.pack_start(self.raise_check, False, False, 16)
        box.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        self.display_label = Gtk.Label()
        self.display_label.set_xalign(0)
        self.display_label.set_line_wrap(True)
        row.pack_start(self.display_label, True, True, 0)
        change = Gtk.MenuButton(label=t("common.change"))
        menu = Gtk.Menu()
        mi = Gtk.MenuItem(label=t("display.set_current"))
        mi.connect("activate", lambda _i: self._set_display_config(self.app.current_display_config()))
        menu.append(mi)
        mi = Gtk.MenuItem(label=t("display.set_any"))
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
        self.table.append_column(Gtk.TreeViewColumn(t("column.app"), Gtk.CellRendererText(), text=C_APP))
        self._text_column(t("column.title"), C_TITLE, expand=True)
        self._text_column(t("column.url"), C_URL, expand=True)
        combo_model = Gtk.ListStore(str)
        for key in MATCH_KEYS:
            combo_model.append([match_label(key)])
        combo = Gtk.CellRendererCombo(model=combo_model, text_column=0, has_entry=False, editable=True)
        combo.connect("edited", self._on_match_edited)
        self.table.append_column(Gtk.TreeViewColumn(t("column.match"), combo, text=C_MATCH))
        self.table.append_column(Gtk.TreeViewColumn(t("column.monitor"), Gtk.CellRendererText(), text=C_MONITOR))
        for title, col in ((t("column.x"), C_X), (t("column.y"), C_Y), (t("column.width"), C_W), (t("column.height"), C_H)):
            self._text_column(title, col)
        scroller = Gtk.ScrolledWindow()
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.add(self.table)
        box.pack_start(scroller, True, True, 0)

        row = Gtk.Box(spacing=8)
        for label, cb, tip in (
            ("＋ " + t("detail.add_windows"), self._add_windows, None),
            ("↻ " + t("detail.refresh"), self._refresh_frames, t("detail.refresh_help")),
            (t("detail.delete_selected"), self._delete_rows, None),
            ("▲", lambda: self._move_selected(-1), t("detail.move_up_help")),
            ("▼", lambda: self._move_selected(+1), t("detail.move_down_help")),
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
            self.table_model.append([w.enabled, w.app_name, w.title, w.url or "", match_label(w.title_match),
                                     mon.name if mon else "–", str(int(w.x)), str(int(w.y)), str(int(w.width)),
                                     str(int(w.height)), w.id])
        self.count_label.set_text(t("detail.count", count=len(self.current.windows)))

    def _refresh_display_row(self) -> None:
        if self.current is None:
            return
        saved = self.current.display_config
        if saved is None:
            self.display_label.set_text(t("display.any"))
            return
        cur = self.app.current_display_config()
        if saved.is_identical(cur):
            status = t("display.same")
        elif saved.has_same_displays(cur):
            status = t("display.rearranged")
        else:
            status = t("display.different")
        self.display_label.set_text(t("display.config", name=saved.name) + "   ·   " + status)

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
        key = next((k for k in MATCH_KEYS if match_label(k) == text), None)
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
        self.refresh_label.set_text(t("detail.refreshed", count=n))

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

        heading(t("general.language"))
        self.language_combo = Gtk.ComboBoxText()
        self.language_combo.append(l10n.SYSTEM_OPTION, t("general.language_system"))
        for code, name in l10n.languages():
            self.language_combo.append(code, name)
        self.language_combo.connect("changed", self._on_language_changed)
        box.pack_start(self.language_combo, False, False, 0)
        note(t("general.language_note"))

        heading(t("general.startup"))
        self.autostart_check = Gtk.CheckButton(label=t("general.launch_at_login"))
        self.autostart_check.connect("toggled", self._on_autostart_toggled)
        box.pack_start(self.autostart_check, False, False, 0)
        self.autostart_error = Gtk.Label()
        self.autostart_error.set_xalign(0)
        box.pack_start(self.autostart_error, False, False, 0)

        heading(t("general.data"))
        self.file_label = Gtk.Label(label=paths.LAYOUTS_FILE)
        self.file_label.set_xalign(0)
        self.file_label.set_selectable(True)
        box.pack_start(self.file_label, False, False, 0)
        row = Gtk.Box(spacing=8)
        for label, cb in ((t("general.open_file"), lambda: _open(paths.LAYOUTS_FILE)),
                          (t("general.open_folder"), lambda: _open(paths.CONFIG_DIR)),
                          (t("general.reload"), self.store.reload),
                          (t("general.open_log"), lambda: _open(paths.LOG_FILE, create=True))):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda _b, f=cb: f())
            row.pack_start(b, False, False, 0)
        box.pack_start(row, False, False, 0)
        note(t("general.json_hint"))
        self.load_error_label = Gtk.Label()
        self.load_error_label.set_xalign(0)
        box.pack_start(self.load_error_label, False, False, 0)
        note(t("general.cli_hint", command='windowlayouts --apply "NAME"'))

        heading(t("general.monitors"))
        self.monitors_label = Gtk.Label()
        self.monitors_label.set_xalign(0)
        box.pack_start(self.monitors_label, False, False, 0)
        note(t("general.monitors_note") + " " + t("linux.wayland_note"))
        return box

    def show_general(self) -> None:
        """일반 설정 페이지 선택 (언어 변경 뒤 창을 다시 만들 때 사용)"""
        sel = self.sidebar.get_selection()
        for row in self.side_model:
            if row[S_KIND] == "general":
                sel.select_iter(row.iter)
                return

    def _on_language_changed(self, combo) -> None:
        if getattr(self, "_loading", False):
            return
        code = combo.get_active_id()
        if code and code != l10n.setting():
            l10n.set_setting(code)   # App이 이 창을 새 언어로 다시 만든다

    def _refresh_general(self) -> None:
        self._loading = True
        self.autostart_check.set_active(os.path.exists(AUTOSTART_FILE))
        self.language_combo.set_active_id(l10n.setting())
        self._loading = False
        self.autostart_error.set_text("")
        self.load_error_label.set_text(self.store.load_error or "")
        cfg = self.app.current_display_config()
        self.monitors_label.set_text(t("general.current_config") + ": " + cfg.name + "\n" + "\n".join(
            f"{d.name}{t('display.main_suffix') if d.is_main else ''} · {d.frame.short()}" for d in cfg.displays))

    def _on_autostart_toggled(self, check) -> None:
        if getattr(self, "_loading", False):
            return
        try:
            if check.get_active():
                os.makedirs(os.path.dirname(AUTOSTART_FILE), exist_ok=True)
                with open(AUTOSTART_FILE, "w", encoding="utf-8") as f:
                    f.write("[Desktop Entry]\nType=Application\nName=WindowLayouts\nComment=Save and restore window layouts\n"
                            f"Exec={launcher_command('--background')}\nIcon=windowlayouts\nTerminal=false\n"
                            "X-GNOME-Autostart-enabled=true\n")
            elif os.path.exists(AUTOSTART_FILE):
                os.remove(AUTOSTART_FILE)
            self.autostart_error.set_text("")
        except OSError as e:
            self.autostart_error.set_markup(f"<span foreground='red'>{_escape(t('general.login_error', error=str(e)))}</span>")


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
