"""파일 위치"""
import os

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "windowlayouts")
os.makedirs(CONFIG_DIR, exist_ok=True)
LAYOUTS_FILE = os.path.join(CONFIG_DIR, "layouts.json")
LOG_FILE = os.path.join(CONFIG_DIR, "apply.log")
PREFS_FILE = os.path.join(CONFIG_DIR, "prefs.json")
ASSETS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")
ICON_FILE = os.path.join(ASSETS_DIR, "windowlayouts.png")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/windowlayouts-{os.getuid()}"
SOCKET_FILE = os.path.join(RUNTIME_DIR, "windowlayouts.sock")
