"""실행 중이 아니거나 창이 없는 앱이 있을 때 물어보는 대화상자 (메인 스레드)"""
from __future__ import annotations

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402


def ask_missing(parent, names: list, layout_name: str) -> tuple:
    """("launch"|"skip"|"cancel", remember)"""
    dlg = Gtk.Dialog(title="창 배치", transient_for=parent, modal=True)
    dlg.set_keep_above(True)
    dlg.add_button("취소", Gtk.ResponseType.CANCEL)
    dlg.add_button("지금 있는 창만 배치", 1)
    dlg.add_button("실행/창 열고 배치", 2)
    dlg.set_default_response(2)
    box = dlg.get_content_area()
    box.set_spacing(8)
    box.set_border_width(16)
    head = Gtk.Label()
    head.set_markup("<b>실행 중이 아니거나 창이 없는 앱이 있습니다</b>")
    head.set_xalign(0)
    body = Gtk.Label(label=f"‘{layout_name}’ 배치에 포함된 다음 앱을 실행하거나 새 창을 열어야 합니다.\n\n"
                     + "\n".join("• " + n for n in names))
    body.set_xalign(0)
    body.set_line_wrap(True)
    remember = Gtk.CheckButton(label="이 배치에서는 다시 묻지 않기")
    box.pack_start(head, False, False, 0)
    box.pack_start(body, False, False, 0)
    box.pack_start(remember, False, False, 0)
    dlg.show_all()
    response = dlg.run()
    keep = remember.get_active()
    dlg.destroy()
    choice = "launch" if response == 2 else "skip" if response == 1 else "cancel"
    return choice, keep
