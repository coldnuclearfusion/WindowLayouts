"""실행 중이 아니거나 창이 없는 앱이 있을 때 물어보는 대화상자 (메인 스레드)"""
from __future__ import annotations

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from .l10n import t  # noqa: E402


def ask_missing(parent, names: list, layout_name: str) -> tuple:
    """("launch"|"skip"|"cancel", remember)"""
    dlg = Gtk.Dialog(title=t("app.name"), transient_for=parent, modal=True)
    dlg.set_keep_above(True)
    dlg.add_button(t("common.cancel"), Gtk.ResponseType.CANCEL)
    dlg.add_button(t("ask.skip"), 1)
    dlg.add_button(t("ask.launch"), 2)
    dlg.set_default_response(2)
    box = dlg.get_content_area()
    box.set_spacing(8)
    box.set_border_width(16)
    head = Gtk.Label()
    from gi.repository import GLib
    head.set_markup("<b>" + GLib.markup_escape_text(t("ask.title")) + "</b>")
    head.set_xalign(0)
    body = Gtk.Label(label=t("ask.message", name=layout_name) + "\n\n" + "\n".join("• " + n for n in names))
    body.set_xalign(0)
    body.set_line_wrap(True)
    remember = Gtk.CheckButton(label=t("ask.remember"))
    box.pack_start(head, False, False, 0)
    box.pack_start(body, False, False, 0)
    box.pack_start(remember, False, False, 0)
    dlg.show_all()
    response = dlg.run()
    keep = remember.get_active()
    dlg.destroy()
    choice = "launch" if response == 2 else "skip" if response == 1 else "cancel"
    return choice, keep
