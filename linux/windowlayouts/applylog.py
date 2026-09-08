"""배치 적용 과정을 파일에 남긴다: ~/.config/windowlayouts/apply.log"""
from __future__ import annotations

import datetime
import os
import threading

from . import paths

_lock = threading.Lock()
MAX_BYTES = 512 * 1024


def write(line: str) -> None:
    with _lock:
        try:
            p = paths.LOG_FILE
            if os.path.exists(p) and os.path.getsize(p) > MAX_BYTES:
                os.remove(p)
            with open(p, "a", encoding="utf-8") as f:
                f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S.%f}"[:-3] + " " + line + "\n")
        except OSError:
            pass
