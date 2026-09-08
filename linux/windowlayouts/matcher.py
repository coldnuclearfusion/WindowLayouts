"""저장된 배치의 창 항목들을 실제 창에 짝지어 준다 (macOS/Windows와 같은 규칙)."""
from __future__ import annotations

import re

_SPLIT = re.compile(r"[^\w]+", re.UNICODE)


def tokens(s: str) -> set:
    return {t for t in _SPLIT.split(s.lower()) if t}


def common_tokens(titles: list) -> set:
    if len(titles) < 2:
        return set()
    common = tokens(titles[0])
    for t in titles[1:]:
        common &= tokens(t)
    return common


def similarity(a: str, b: str, boilerplate: set = frozenset()) -> float:
    la, lb = a.lower(), b.lower()
    if la == lb:
        return 1.0
    ta, tb = tokens(la) - boilerplate, tokens(lb) - boilerplate
    if not ta or not tb:
        return 0.0
    if lb in la or la in lb:
        return 0.9
    return len(ta & tb) / min(len(ta), len(tb))


def match(entries: list, windows: list) -> list:
    """[(entry, window 또는 None)]"""
    available = list(windows)
    assigned: dict = {}

    # 1) 제목이 정확히 같은 창
    for e in entries:
        if e.title_match == "order" or not e.title:
            continue
        for i, w in enumerate(available):
            if w.title == e.title:
                assigned[e.id] = available.pop(i)
                break

    # 2) 비슷한 제목: 공통 접미사를 뺀 단어 겹침, 점수 높은 짝부터
    boiler = common_tokens([w.title for w in available])
    candidates = []
    for ei, e in enumerate(entries):
        if e.id in assigned or e.title_match == "order" or not e.title:
            continue
        for wi, w in enumerate(available):
            s = similarity(e.title, w.title, boiler)
            if s >= 0.3:
                candidates.append((s, ei, wi))
    candidates.sort(key=lambda c: -c[0])
    used_e: set = set()
    used_w: set = set()
    for s, ei, wi in candidates:
        if ei in used_e or wi in used_w:
            continue
        assigned[entries[ei].id] = available[wi]
        used_e.add(ei)
        used_w.add(wi)
    available = [w for i, w in enumerate(available) if i not in used_w]

    # 3) 남은 항목은 남은 창에 순서대로
    for e in entries:
        if e.id in assigned:
            continue
        if e.title_match == "title" and e.title:
            continue
        if available:
            assigned[e.id] = available.pop(0)

    return [(e, assigned.get(e.id)) for e in entries]
