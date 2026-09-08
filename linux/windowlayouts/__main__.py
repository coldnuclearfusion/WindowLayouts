"""진입점: windowlayouts [--apply 이름|ID] [--settings] [--background]"""
from __future__ import annotations

import os
import socket
import sys
import threading

from . import paths


def _try_forward(args: list) -> bool:
    """이미 실행 중인 인스턴스가 있으면 명령을 넘기고 True"""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(paths.SOCKET_FILE)
        s.sendall("\n".join(args if args else ["--settings"]).encode("utf-8"))
        s.close()
        return True
    except OSError:
        return False


def _serve(app) -> None:
    from gi.repository import GLib
    os.makedirs(paths.RUNTIME_DIR, exist_ok=True)
    try:
        os.remove(paths.SOCKET_FILE)
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(paths.SOCKET_FILE)
    server.listen(2)

    def loop():
        while True:
            try:
                conn, _ = server.accept()
                data = conn.recv(65536).decode("utf-8", "replace")
                conn.close()
                args = [a for a in data.split("\n") if a]
                GLib.idle_add(lambda a=args: (app.handle_args(a), False)[1])
            except OSError:
                break

    threading.Thread(target=loop, daemon=True, name="ipc").start()


def main() -> int:
    args = sys.argv[1:]
    if "--help" in args or "-h" in args:
        print("windowlayouts [--apply 배치이름|ID] [--settings] [--background]")
        return 0
    if _try_forward(args):
        return 0

    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk

    from .app import App

    app = App()
    _serve(app)
    app.handle_args(args)
    if not app.store.layouts and "--background" not in args:
        app.show_settings()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
