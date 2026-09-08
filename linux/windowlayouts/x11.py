"""X11(EWMH)로 창을 읽고 옮기는 부분. 스레드마다 별도의 X11 객체를 만들어 쓴다."""
from __future__ import annotations

import time
from typing import Optional

from Xlib import X, Xatom, display, error, protocol
from Xlib.ext import randr

from .models import DisplayConfig, DisplayInfo, Frame


class WindowInfo:
    def __init__(self, wid: int, title: str, frame: Frame, pid: Optional[int], wm_class: tuple,
                 minimized: bool, desktop: Optional[int]):
        self.wid = wid
        self.title = title
        self.frame = frame
        self.pid = pid
        self.wm_class = wm_class          # (instance, class)
        self.minimized = minimized
        self.desktop = desktop
        self.app_id = ""
        self.app_name = ""
        self.display_id: Optional[str] = None
        self.url: Optional[str] = None

    def make_entry(self, include_title: bool = True, include_url: bool = True):
        from .models import WindowEntry
        e = WindowEntry(bundle_id=self.app_id, app_name=self.app_name,
                        title=self.title if include_title else "",
                        title_match="auto" if include_title else "order",
                        display_id=self.display_id, url=self.url if include_url else None)
        e.frame = self.frame
        return e


class X11:
    def __init__(self) -> None:
        self.d = display.Display()
        self.root = self.d.screen().root
        self._atoms: dict = {}

    def close(self) -> None:
        try:
            self.d.close()
        except Exception:
            pass

    def atom(self, name: str) -> int:
        if name not in self._atoms:
            self._atoms[name] = self.d.intern_atom(name)
        return self._atoms[name]

    def _prop(self, win, name: str, ptype=X.AnyPropertyType):
        try:
            p = win.get_full_property(self.atom(name), ptype)
            return p.value if p is not None else None
        except error.XError:
            return None

    def window(self, wid: int):
        return self.d.create_resource_object("window", wid)

    # ---- 창 목록

    def stacking(self) -> list:
        """아래→위 순서의 창 ID 목록"""
        v = self._prop(self.root, "_NET_CLIENT_LIST_STACKING", Xatom.WINDOW)
        return list(v) if v is not None else []

    def current_desktop(self) -> Optional[int]:
        v = self._prop(self.root, "_NET_CURRENT_DESKTOP", Xatom.CARDINAL)
        return int(v[0]) if v else None

    def is_window(self, wid: int) -> bool:
        try:
            self.window(wid).get_attributes()
            return True
        except error.XError:
            return False

    def list_windows(self, include_minimized: bool, current_desktop_only: bool) -> list:
        """앞→뒤 순서의 일반 창 목록"""
        result = []
        cur = self.current_desktop() if current_desktop_only else None
        for wid in reversed(self.stacking()):
            info = self.describe(wid)
            if info is None:
                continue
            if not include_minimized and info.minimized:
                continue
            if cur is not None and info.desktop is not None and info.desktop != cur and info.desktop != 0xFFFFFFFF:
                continue
            result.append(info)
        return result

    def describe(self, wid: int) -> Optional[WindowInfo]:
        w = self.window(wid)
        try:
            types = self._prop(w, "_NET_WM_WINDOW_TYPE", Xatom.ATOM)
            if types is not None and len(types) > 0:
                normal = self.atom("_NET_WM_WINDOW_TYPE_NORMAL")
                if normal not in list(types):
                    return None
            states = list(self._prop(w, "_NET_WM_STATE", Xatom.ATOM) or [])
            if self.atom("_NET_WM_STATE_SKIP_TASKBAR") in states:
                return None
            minimized = self.atom("_NET_WM_STATE_HIDDEN") in states
            title = self.title(w)
            if not title:
                return None
            pid_v = self._prop(w, "_NET_WM_PID", Xatom.CARDINAL)
            pid = int(pid_v[0]) if pid_v else None
            wm_class = w.get_wm_class() or ("", "")
            desk_v = self._prop(w, "_NET_WM_DESKTOP", Xatom.CARDINAL)
            desktop = int(desk_v[0]) if desk_v else None
            frame = self.frame(wid)
            if frame is None:
                return None
            return WindowInfo(wid, title, frame, pid, tuple(wm_class), minimized, desktop)
        except error.XError:
            return None

    def title(self, w) -> str:
        v = self._prop(w, "_NET_WM_NAME", self.atom("UTF8_STRING"))
        if v:
            return v.decode("utf-8", "replace") if isinstance(v, bytes) else str(v)
        try:
            return w.get_wm_name() or ""
        except error.XError:
            return ""

    def extents(self, w) -> tuple:
        v = self._prop(w, "_NET_FRAME_EXTENTS", Xatom.CARDINAL)
        if v is not None and len(v) >= 4:
            return int(v[0]), int(v[1]), int(v[2]), int(v[3])   # left, right, top, bottom
        return 0, 0, 0, 0

    def frame(self, wid: int) -> Optional[Frame]:
        """창틀(장식) 포함 사각형"""
        w = self.window(wid)
        try:
            g = w.get_geometry()
            p = self.root.translate_coords(w, 0, 0)
            l, r, t, b = self.extents(w)
            return Frame(p.x - l, p.y - t, g.width + l + r, g.height + t + b)
        except error.XError:
            return None

    # ---- 창 조작

    def _send(self, wid: int, name: str, data: list) -> None:
        w = self.window(wid)
        payload = (list(data) + [0] * 5)[:5]
        ev = protocol.event.ClientMessage(window=w, client_type=self.atom(name), data=(32, payload))
        self.root.send_event(ev, event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask)
        self.d.flush()

    def unmaximize(self, wid: int) -> None:
        self._send(wid, "_NET_WM_STATE", [0, self.atom("_NET_WM_STATE_MAXIMIZED_VERT"),
                                           self.atom("_NET_WM_STATE_MAXIMIZED_HORZ"), 2])

    def is_fullscreen(self, wid: int) -> bool:
        states = list(self._prop(self.window(wid), "_NET_WM_STATE", Xatom.ATOM) or [])
        return self.atom("_NET_WM_STATE_FULLSCREEN") in states

    def is_minimized(self, wid: int) -> bool:
        states = list(self._prop(self.window(wid), "_NET_WM_STATE", Xatom.ATOM) or [])
        return self.atom("_NET_WM_STATE_HIDDEN") in states

    def activate(self, wid: int) -> None:
        """앞으로 올리고 포커스 (최소화도 풀린다)"""
        self._send(wid, "_NET_ACTIVE_WINDOW", [2, X.CurrentTime, 0])

    def move_resize(self, wid: int, frame: Frame) -> None:
        """창틀 왼쪽 위를 (x, y)에, 창틀 포함 크기가 (w, h)가 되도록 요청 (NorthWest 중력)"""
        w = self.window(wid)
        l, r, t, b = self.extents(w)
        cw = max(1, int(round(frame.width)) - l - r)
        ch = max(1, int(round(frame.height)) - t - b)
        flags = 1 | 0x100 | 0x200 | 0x400 | 0x800 | 0x2000   # gravity NorthWest, x y w h, source=pager
        self._send(wid, "_NET_MOVERESIZE_WINDOW", [flags, int(round(frame.x)), int(round(frame.y)), cw, ch])

    def place(self, wid: int, target: Frame, log=None) -> tuple:
        """창을 옮기고 실제 결과를 읽어 확인한다. 어긋나면 그 차이만큼 보정해 다시 요청한다.
        반환: ("placed"|"mismatch"|"failed", 실제 Frame 또는 None)"""
        if not self.is_window(wid):
            return "failed", None
        if self.is_fullscreen(wid):
            if log:
                from .l10n import t
                log(t("log.fullscreen_skip"))
            return "failed", None
        if self.is_minimized(wid):
            self.activate(wid)
            time.sleep(0.2)
        self.unmaximize(wid)
        time.sleep(0.05)
        before = self.frame(wid)
        if before is None:
            return "failed", None
        if log:
            from .l10n import t
            log(t("log.place_start").replace("{from}", before.short()).replace("{to}", target.short()))
        request = Frame(target.x, target.y, target.width, target.height)
        now = before
        for attempt in (1, 2, 3):
            self.move_resize(wid, request)
            time.sleep(0.15 if attempt == 1 else 0.3)
            now = self.frame(wid)
            if now is None:
                return "failed", None
            ok = now.approximately_equals(target, 2)
            if log:
                from .l10n import t
                log(t("log.place_attempt", attempt=attempt, result=now.short()) + (" ✓" if ok else ""))
            if ok:
                return "placed", now
            # 창 관리자가 좌표를 해석하는 방식이 달라 어긋났으면 그 차이만큼 보정
            request = Frame(request.x - (now.x - target.x), request.y - (now.y - target.y),
                            request.width - (now.width - target.width), request.height - (now.height - target.height))
        return "mismatch", now

    # ---- 모니터

    def monitors(self) -> DisplayConfig:
        displays = []
        try:
            res = randr.get_monitors(self.root, True)
            for m in res.monitors:
                out_name = self.d.get_atom_name(m.name)
                mid, name = out_name, out_name
                try:
                    outputs = list(getattr(m, "crtcs", []) or [])
                    if outputs:
                        edid = randr.get_output_property(self.d, outputs[0], self.atom("EDID"), X.AnyPropertyType, 0, 64, False, False)
                        raw = bytes(edid._data["value"]) if hasattr(edid, "_data") else b""
                        parsed = parse_edid(raw)
                        if parsed:
                            mid = f"{out_name}|{parsed[0]}"
                            name = parsed[1] or out_name
                except Exception:
                    pass
                displays.append(DisplayInfo(id=mid, name=name, x=float(m.x), y=float(m.y),
                                            width=float(m.width_in_pixels), height=float(m.height_in_pixels),
                                            is_main=bool(m.primary)))
        except Exception:
            pass
        if not displays:
            g = self.root.get_geometry()
            displays.append(DisplayInfo(id="screen", name="Screen", x=0, y=0, width=float(g.width), height=float(g.height), is_main=True))
        if not any(d.is_main for d in displays):
            displays[0].is_main = True
        return DisplayConfig(displays)


def parse_edid(raw: bytes):
    """EDID에서 (제조사-모델-일련번호, 모니터 이름)을 뽑는다. 실패하면 None."""
    if len(raw) < 128 or raw[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
        return None
    v = (raw[8] << 8) | raw[9]
    vendor = "".join(chr(64 + ((v >> s) & 0x1F)) for s in (10, 5, 0))
    model = raw[10] | (raw[11] << 8)
    serial = raw[12] | (raw[13] << 8) | (raw[14] << 16) | (raw[15] << 24)
    name = ""
    for i in range(4):
        blk = raw[54 + 18 * i: 54 + 18 * (i + 1)]
        if len(blk) == 18 and blk[0] == 0 and blk[1] == 0 and blk[3] == 0xFC:
            name = blk[5:18].decode("ascii", "replace").strip()
            break
    return f"{vendor}-{model:04X}-{serial:08X}", name
