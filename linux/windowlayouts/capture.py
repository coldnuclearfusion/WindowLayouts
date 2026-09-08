"""현재 창 수집 (X11 + 앱 식별 + 모니터)"""
from __future__ import annotations

from . import apps, browser
from .x11 import X11


class CaptureRequest:
    def __init__(self, windows: list, target_layout_id=None, display_config=None):
        self.windows = windows
        self.target_layout_id = target_layout_id
        self.display_config = display_config


def _identify(w) -> None:
    w.app_id, w.app_name = apps.identify(w.pid, w.wm_class)


def current_windows(x: X11) -> list:
    """저장용: 지금 데스크톱에 보이는 창들 (최소화 제외), 앞→뒤 순서"""
    config = x.monitors()
    result = []
    for w in x.list_windows(include_minimized=False, current_desktop_only=True):
        _identify(w)
        d = config.display_containing(w.frame.mid_x, w.frame.mid_y) or config.display_containing(w.frame.x, w.frame.y)
        w.display_id = d.id if d else None
        w.url = None   # Linux에서는 활성 탭 주소를 읽을 표준 방법이 없다
        result.append(w)
    return result


def windows_of(x: X11, app_id: str) -> list:
    """적용용: 이 앱의 창들 (최소화·다른 데스크톱 포함)"""
    result = []
    for w in x.list_windows(include_minimized=True, current_desktop_only=False):
        _identify(w)
        if w.app_id == app_id:
            result.append(w)
    return result


def make_request(x: X11, target_layout_id=None) -> CaptureRequest:
    return CaptureRequest(current_windows(x), target_layout_id, x.monitors())
