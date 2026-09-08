"""배치 데이터 모델. JSON 형식은 macOS/Windows 버전과 같다."""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from typing import Optional

POLICY_LABELS = {
    "ask": "매번 물어보기",
    "launchMissing": "실행하고 새 창 열기",
    "runningOnly": "지금 있는 창만 배치",
}
MATCH_LABELS = {"auto": "자동", "title": "제목만", "order": "순서만"}


@dataclass
class Frame:
    """화면 좌표계의 사각형 (루트 창 기준 픽셀, 왼쪽 위가 (0,0))."""
    x: float
    y: float
    width: float
    height: float

    @property
    def right(self) -> float:
        return self.x + self.width

    @property
    def bottom(self) -> float:
        return self.y + self.height

    @property
    def mid_x(self) -> float:
        return self.x + self.width / 2

    @property
    def mid_y(self) -> float:
        return self.y + self.height / 2

    def contains(self, px: float, py: float) -> bool:
        return self.x <= px < self.right and self.y <= py < self.bottom

    def approximately_equals(self, other: "Frame", tolerance: float = 2) -> bool:
        return (abs(self.x - other.x) <= tolerance and abs(self.y - other.y) <= tolerance
                and abs(self.width - other.width) <= tolerance and abs(self.height - other.height) <= tolerance)

    def short(self) -> str:
        return f"{int(self.width)}×{int(self.height)} @ ({int(self.x)}, {int(self.y)})"


@dataclass
class DisplayInfo:
    id: str
    name: str
    x: float
    y: float
    width: float
    height: float
    is_main: bool

    @property
    def frame(self) -> Frame:
        return Frame(self.x, self.y, self.width, self.height)

    def same_as(self, o: "DisplayInfo") -> bool:
        return (self.id == o.id and self.name == o.name and self.x == o.x and self.y == o.y
                and self.width == o.width and self.height == o.height and self.is_main == o.is_main)

    def to_json(self) -> dict:
        return {"id": self.id, "name": self.name, "x": self.x, "y": self.y,
                "width": self.width, "height": self.height, "isMain": self.is_main}

    @staticmethod
    def from_json(d: dict) -> "DisplayInfo":
        return DisplayInfo(id=str(d.get("id", "")), name=str(d.get("name", d.get("id", ""))),
                           x=float(d.get("x", 0)), y=float(d.get("y", 0)),
                           width=float(d.get("width", 0)), height=float(d.get("height", 0)),
                           is_main=bool(d.get("isMain", False)))


@dataclass
class DisplayConfig:
    displays: list = field(default_factory=list)

    @property
    def ids(self) -> set:
        return {d.id for d in self.displays}

    @property
    def key(self) -> str:
        return "+".join(sorted(d.id for d in self.displays))

    @property
    def name(self) -> str:
        ordered = sorted(self.displays, key=lambda d: (0 if d.is_main else 1, d.x))
        counts: dict = {}
        order: list = []
        for d in ordered:
            if d.name not in counts:
                order.append(d.name)
                counts[d.name] = 0
            counts[d.name] += 1
        if not order:
            return "모니터 없음"
        return " + ".join(f"{n} ×{counts[n]}" if counts[n] > 1 else n for n in order)

    @property
    def main(self) -> Optional[DisplayInfo]:
        for d in self.displays:
            if d.is_main:
                return d
        return self.displays[0] if self.displays else None

    def display_with_id(self, did: Optional[str]) -> Optional[DisplayInfo]:
        if not did:
            return None
        for d in self.displays:
            if d.id == did:
                return d
        return None

    def display_containing(self, px: float, py: float) -> Optional[DisplayInfo]:
        for d in self.displays:
            if d.frame.contains(px, py):
                return d
        return None

    def has_same_displays(self, other: "DisplayConfig") -> bool:
        return self.ids == other.ids

    def is_identical(self, other: "DisplayConfig") -> bool:
        a = sorted(self.displays, key=lambda d: d.id)
        b = sorted(other.displays, key=lambda d: d.id)
        return len(a) == len(b) and all(x.same_as(y) for x, y in zip(a, b))

    def to_json(self) -> dict:
        return {"displays": [d.to_json() for d in self.displays]}

    @staticmethod
    def from_json(d: Optional[dict]) -> Optional["DisplayConfig"]:
        if not isinstance(d, dict):
            return None
        return DisplayConfig([DisplayInfo.from_json(x) for x in d.get("displays", []) if isinstance(x, dict)])


@dataclass
class WindowEntry:
    bundle_id: str
    app_name: str = ""
    title: str = ""
    title_match: str = "auto"       # auto | title | order
    x: float = 0
    y: float = 0
    width: float = 800
    height: float = 600
    enabled: bool = True
    display_id: Optional[str] = None
    url: Optional[str] = None
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())

    @property
    def frame(self) -> Frame:
        return Frame(self.x, self.y, self.width, self.height)

    @frame.setter
    def frame(self, f: Frame) -> None:
        self.x, self.y, self.width, self.height = round(f.x), round(f.y), round(f.width), round(f.height)

    @property
    def display_name(self) -> str:
        detail = self.title or (self.url or "")
        return f"{self.app_name} – {detail}" if detail else self.app_name

    @property
    def has_url(self) -> bool:
        return bool((self.url or "").strip())

    def to_json(self) -> dict:
        return {"id": self.id, "bundleID": self.bundle_id, "appName": self.app_name, "title": self.title,
                "titleMatch": self.title_match, "x": self.x, "y": self.y, "width": self.width,
                "height": self.height, "enabled": self.enabled, "displayID": self.display_id, "url": self.url}

    @staticmethod
    def from_json(d: dict) -> "WindowEntry":
        e = WindowEntry(bundle_id=str(d.get("bundleID", "")))
        e.id = str(d.get("id") or e.id)
        e.app_name = str(d.get("appName") or e.bundle_id)
        e.title = str(d.get("title") or "")
        e.title_match = d.get("titleMatch") if d.get("titleMatch") in MATCH_LABELS else "auto"
        e.x = float(d.get("x", 0))
        e.y = float(d.get("y", 0))
        e.width = float(d.get("width", 800))
        e.height = float(d.get("height", 600))
        e.enabled = bool(d.get("enabled", True))
        e.display_id = d.get("displayID") or None
        url = d.get("url")
        e.url = str(url).strip() if url else None
        return e


@dataclass
class WindowLayout:
    name: str = "이름 없음"
    launch_policy: str = "ask"      # ask | launchMissing | runningOnly
    raise_windows: bool = True
    display_config: Optional[DisplayConfig] = None
    windows: list = field(default_factory=list)
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())

    @property
    def enabled_app_ids(self) -> list:
        seen: set = set()
        out: list = []
        for w in self.windows:
            if w.enabled and w.bundle_id not in seen:
                seen.add(w.bundle_id)
                out.append(w.bundle_id)
        return out

    def app_name(self, app_id: str) -> str:
        for w in self.windows:
            if w.bundle_id == app_id:
                return w.app_name
        return app_id

    def to_json(self) -> dict:
        return {"id": self.id, "name": self.name, "launchPolicy": self.launch_policy,
                "raiseWindows": self.raise_windows,
                "displayConfig": self.display_config.to_json() if self.display_config else None,
                "windows": [w.to_json() for w in self.windows]}

    @staticmethod
    def from_json(d: dict) -> "WindowLayout":
        l = WindowLayout()
        l.id = str(d.get("id") or l.id)
        l.name = str(d.get("name") or "이름 없음")
        l.launch_policy = d.get("launchPolicy") if d.get("launchPolicy") in POLICY_LABELS else "ask"
        l.raise_windows = bool(d.get("raiseWindows", True))
        l.display_config = DisplayConfig.from_json(d.get("displayConfig"))
        l.windows = [WindowEntry.from_json(w) for w in d.get("windows", []) if isinstance(w, dict)]
        return l


def load_file(text: str) -> list:
    data = json.loads(text)
    return [WindowLayout.from_json(x) for x in data.get("layouts", []) if isinstance(x, dict)]


def dump_file(layouts: list) -> str:
    return json.dumps({"version": 1, "layouts": [l.to_json() for l in layouts]},
                      ensure_ascii=False, indent=2, sort_keys=True) + "\n"
