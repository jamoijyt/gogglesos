"""GogglesXR desktop app: status, game library and settings in one window, plus a tray icon
that keeps VR ready in the background.

Started by `gogglesxr app` (menu entry) and, with --background, at login.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys

import math
import queue
import threading
import time

from PyQt6.QtCore import QEasingCurve, QProcess, QPropertyAnimation, QSize, Qt, QTimer
from PyQt6.QtGui import QAction, QBrush, QColor, QFont, QIcon, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PyQt6.QtWidgets import (QApplication, QButtonGroup, QCheckBox, QComboBox, QFileDialog, QFrame, QGraphicsOpacityEffect,
                             QGridLayout, QHBoxLayout, QLabel, QLineEdit, QListView, QListWidget, QListWidgetItem,
                             QMainWindow, QMenu, QPushButton, QScrollArea, QSlider, QStackedWidget, QSystemTrayIcon,
                             QVBoxLayout, QWidget)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import library  # noqa: E402
import engine as engines  # noqa: E402

TOOL = os.environ.get("GOGGLESXR_TOOL") or "/usr/bin/gogglesxr"
SETTINGS_FILE = os.path.join(library.CONFIG, "settings.json")
AUTOSTART_SYSTEM = "/etc/xdg/autostart/gogglesxr.desktop"
AUTOSTART_USER = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(library.HOME, ".config"),
                              "autostart", "gogglesxr.desktop")
DEFAULTS = {"keep_ready": True, "auto_dashboard": True, "show_all_games": False, "animations": True,
            "pointer_smoothing": 60, "engine": "wivrn", "environment": "goggles", "environment_image": "",
            "desktop_screen": "all", "desktop_fps": 15}
# Recording and screenshot options: (setting, label, [(value, label)], note). The values match
# CAPTURE_CHOICES in the gogglesxr command, which reads them when a recording starts.
CAPTURE_OPTIONS = [
    ("record_aspect", "Shape", [("16:9", "16:9 widescreen"), ("9:16", "9:16 upright (phones, Shorts, TikTok)"),
                                ("1:1", "1:1 square"), ("4:3", "4:3")], ""),
    ("record_resolution", "Resolution", [(1080, "1080p"), (720, "720p"), (1440, "1440p")], "The short side of the video."),
    ("record_fps", "Frame rate", [(30, "30 fps"), (60, "60 fps"), (72, "72 fps"), (90, "90 fps")], ""),
    ("record_bitrate", "Quality", [(0, "Automatic (constant quality)"), (8, "8 Mbit/s"), (15, "15 Mbit/s"),
                                   (30, "30 Mbit/s"), (50, "50 Mbit/s"), (80, "80 Mbit/s")],
     "A fixed bitrate keeps file sizes predictable; automatic keeps quality even."),
    ("record_encoder", "Encoder", [("auto", "Automatic (graphics card if possible)"), ("nvidia", "NVIDIA graphics card"),
                                   ("amd_intel", "AMD / Intel graphics card"), ("cpu", "Processor")],
     "The graphics card records with almost no cost to the game. Falls back to the processor if it can't."),
    ("record_codec", "Video format", [("h264", "H.264 (plays everywhere)"), ("h265", "H.265 / HEVC (smaller files)")], ""),
    ("record_audio", "Sound", [("game", "Game sound"), ("game_mic", "Game sound and microphone"), ("none", "No sound")], ""),
    ("record_view", "View", [("wide", "Wide (everything the eye sees)"), ("normal", "Normal"), ("narrow", "Narrow (less distortion)")],
     "Headsets see a very wide view; a narrower crop looks more natural on a flat screen."),
    ("screenshot_area", "Screenshots", [("eye", "The whole view"), ("crop", "Framed like recordings")], ""),
]
for _key, _label, _choices, _note in CAPTURE_OPTIONS:
    DEFAULTS[_key] = _choices[0][0]
ACCENT, ACCENT_2, INK, MUTED = "#3ddc84", "#f1ff9c", "#e6f3ee", "#9fbfb4"
COVER = QSize(150, 225)

STYLE = f"""
* {{ color: {INK}; font-size: 14px; }}
QMainWindow, #root {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 #0d2e28, stop:1 #04100e); }}
#side {{ background: rgba(0, 0, 0, 0.28); border-right: 1px solid rgba(255, 255, 255, 0.07); }}
#brand {{ font-size: 20px; font-weight: 600; padding: 4px 6px 14px 6px; }}
#nav {{ text-align: left; padding: 11px 14px; border-radius: 10px; border: 1px solid transparent; color: {MUTED}; font-size: 15px; }}
#nav:hover {{ background: rgba(255, 255, 255, 0.06); color: {INK}; }}
#nav:checked {{ background: rgba(61, 220, 132, 0.16); border: 1px solid rgba(61, 220, 132, 0.4); color: {INK}; }}
#title {{ font-size: 26px; font-weight: 600; }}
#eyebrow {{ color: {ACCENT}; font-size: 11px; font-weight: 600; letter-spacing: 2px; }}
#muted, QCheckBox#muted {{ color: {MUTED}; }}
#card {{ background: rgba(12, 38, 33, 0.74); border: 1px solid rgba(61, 220, 132, 0.26); border-radius: 18px; }}
#visor {{ background: {ACCENT}; border-radius: 1px; max-height: 2px; min-height: 2px; }}
#headline {{ font-size: 22px; font-weight: 600; }}
#row {{ border-bottom: 1px solid rgba(255, 255, 255, 0.07); padding: 9px 2px; }}
QPushButton {{ background: rgba(255, 255, 255, 0.06); border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 10px; padding: 9px 16px; font-weight: 600; }}
QPushButton:hover {{ border-color: {ACCENT}; background: rgba(61, 220, 132, 0.12); }}
QPushButton:disabled {{ color: rgba(230, 243, 238, 0.35); }}
QPushButton#primary {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 {ACCENT}, stop:1 #8ff0a4); color: #052012; border: none; }}
QPushButton#primary:hover {{ background: #8ff0a4; }}
QPushButton#chip {{ border-radius: 14px; padding: 5px 13px; font-weight: 500; color: {MUTED}; }}
QPushButton#chip:checked {{ background: {ACCENT}; color: #052012; border-color: {ACCENT}; }}
QLineEdit, QComboBox {{ background: rgba(0, 0, 0, 0.35); border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 10px; padding: 8px 12px; selection-background-color: {ACCENT}; selection-color: #052012; }}
QLineEdit:focus, QComboBox:focus {{ border-color: {ACCENT}; }}
QComboBox QAbstractItemView {{ background: #0b201c; border: 1px solid rgba(61, 220, 132, 0.4); selection-background-color: rgba(61, 220, 132, 0.3); }}
QListWidget {{ background: transparent; border: none; outline: none; }}
QListWidget::item {{ border-radius: 12px; padding: 6px; color: {INK}; }}
QListWidget::item:hover {{ background: rgba(255, 255, 255, 0.06); }}
QListWidget::item:selected {{ background: rgba(61, 220, 132, 0.2); border: 1px solid {ACCENT}; }}
QCheckBox {{ spacing: 10px; padding: 6px 0; }}
QCheckBox::indicator {{ width: 38px; height: 20px; border-radius: 10px; background: rgba(255, 255, 255, 0.14); border: 1px solid rgba(255, 255, 255, 0.2); }}
QCheckBox::indicator:checked {{ background: {ACCENT}; border-color: {ACCENT}; }}
QSlider::groove:horizontal {{ height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.14); }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 3px; }}
QSlider::handle:horizontal {{ width: 16px; height: 16px; margin: -6px 0; border-radius: 9px; background: {INK}; border: 3px solid {ACCENT}; }}
#info {{ color: {MUTED}; font-size: 12px; }}
#value {{ font-size: 14px; font-weight: 600; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: rgba(61, 220, 132, 0.4); border-radius: 5px; min-height: 30px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QScrollArea {{ background: transparent; border: none; }}
QMenu {{ background: #0b201c; border: 1px solid rgba(61, 220, 132, 0.4); padding: 6px; }}
QMenu::item {{ padding: 6px 18px; border-radius: 6px; }}
QMenu::item:selected {{ background: rgba(61, 220, 132, 0.25); }}
"""


def load_tool():
    """The gogglesxr command, loaded as a module so its checks and actions can be called directly."""
    loader = importlib.machinery.SourceFileLoader("gogglesxr_tool", TOOL)
    spec = importlib.util.spec_from_loader("gogglesxr_tool", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def load_settings():
    data = dict(DEFAULTS)
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            data.update({k: v for k, v in json.load(f).items() if k in DEFAULTS})
    except (OSError, ValueError):
        pass
    return data


def save_settings(data):
    # Merge with what is on disk: the dashboard in the headset writes to this file too
    merged = {}
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            merged = json.load(f)
    except (OSError, ValueError):
        pass
    merged.update(data)
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(merged, f, indent=1)


def describe_headset(info):
    """Rows for the Home page from the engine's headset() answer: [(label, text)]."""
    rows = []
    if info.get("name"):
        rows.append(("Headset", info["name"]))
    names = {"head": "Headset battery", "left": "Left controller", "right": "Right controller"}
    for key in ("head", "left", "right"):
        battery = info.get("battery", {}).get(key)
        if battery:
            rows.append((names[key], f'{battery["charge"]}%' + (" · charging" if battery.get("charging") else "")))
    if info.get("ping_ms") is not None:
        rows.append(("Ping", f'{info["ping_ms"]:.0f} ms' + (" · USB" if info.get("connection") == "usb" else "")))
    if info.get("bitrate_mbps"):
        rows.append(("Stream", f'{info["bitrate_mbps"]:g} Mbit/s'))
    if info.get("refresh_rate"):
        rows.append(("Refresh rate", f'{info["refresh_rate"]:g} Hz'))
    elif info.get("refresh_rates"):
        rows.append(("Refresh rates", ", ".join(f"{r:g}" for r in info["refresh_rates"]) + " Hz"))
    if info.get("codecs"):
        rows.append(("Video", ", ".join(str(c).upper() for c in info["codecs"])))
    tracking = [text for key, text in (("hand_tracking", "hands"), ("eye_tracking", "eyes"), ("face_tracking", "face"))
                if info.get(key)]
    if tracking:
        rows.append(("Tracks", ", ".join(tracking)))
    return rows


def autostart_enabled():
    """Starts at login unless the user's own autostart entry switches it off."""
    try:
        with open(AUTOSTART_USER, encoding="utf-8") as f:
            return "Hidden=true" not in f.read()
    except OSError:
        return os.path.exists(AUTOSTART_SYSTEM)


def set_autostart(on):
    if on:
        try:
            os.remove(AUTOSTART_USER)
        except OSError:
            pass
    else:
        os.makedirs(os.path.dirname(AUTOSTART_USER), exist_ok=True)
        with open(AUTOSTART_USER, "w", encoding="utf-8") as f:
            f.write("[Desktop Entry]\nType=Application\nName=GogglesXR\nHidden=true\n")


def logo_pixmap(size):
    """The two lenses of the Goggles logo, drawn so the app needs no image files."""
    pix = QPixmap(size, size)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    grad = QLinearGradient(0, size, size, 0)
    grad.setColorAt(0, QColor(ACCENT_2))
    grad.setColorAt(0.45, QColor(ACCENT))
    grad.setColorAt(1, QColor("#0a2a26"))
    path = QPainterPath()
    path.addRoundedRect(size * 0.04, size * 0.16, size * 0.92, size * 0.68, size * 0.14, size * 0.14)
    p.fillPath(path, QBrush(grad))
    p.setPen(QPen(QColor("#06120c"), size * 0.06))
    p.setBrush(QColor(0, 0, 0, 60))
    for cx in (0.3, 0.7):
        p.drawEllipse(int(size * (cx - 0.13)), int(size * 0.37), int(size * 0.26), int(size * 0.26))
    p.end()
    return pix


def cover_pixmap(game):
    """Steam's cover art, or a tinted card with the game's initials when Steam has none."""
    pix = QPixmap(COVER)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    clip = QPainterPath()
    clip.addRoundedRect(0, 0, COVER.width(), COVER.height(), 12, 12)
    p.setClipPath(clip)
    art = QPixmap(game["art"]) if game.get("art") else QPixmap()
    if not art.isNull():
        art = art.scaled(COVER, Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
        p.drawPixmap((COVER.width() - art.width()) // 2, (COVER.height() - art.height()) // 2, art)
    else:
        hue = sum(ord(c) for c in game["title"]) % 360
        grad = QLinearGradient(0, 0, COVER.width(), COVER.height())
        grad.setColorAt(0, QColor.fromHsv(hue, 150, 110))
        grad.setColorAt(1, QColor.fromHsv((hue + 50) % 360, 170, 60))
        p.fillRect(pix.rect(), QBrush(grad))
        initials = "".join(w[0] for w in game["title"].replace(":", " ").split()[:3]).upper()
        font = QFont()
        font.setPixelSize(44)
        font.setBold(True)
        p.setFont(font)
        p.setPen(QColor(255, 255, 255, 220))
        p.drawText(pix.rect(), Qt.AlignmentFlag.AlignCenter, initials)
    if not game["is_vr"]:
        p.fillRect(pix.rect(), QColor(4, 16, 14, 150))
    if game["favourite"]:
        p.setClipping(False)
        p.setBrush(QColor(ACCENT))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(COVER.width() - 30, 8, 22, 22)
        p.setPen(QColor("#052012"))
        font = QFont()
        font.setPixelSize(14)
        p.setFont(font)
        p.drawText(COVER.width() - 30, 8, 22, 22, Qt.AlignmentFlag.AlignCenter, "★")
    p.end()
    return pix


def label(text, name=None, wrap=False):
    w = QLabel(text)
    if name:
        w.setObjectName(name)
    w.setWordWrap(wrap)
    return w


def card():
    frame = QFrame()
    frame.setObjectName("card")
    box = QVBoxLayout(frame)
    box.setContentsMargins(22, 0, 22, 20)
    box.setSpacing(10)
    visor = QFrame()
    visor.setObjectName("visor")
    box.addWidget(visor)
    box.addSpacing(8)
    return frame, box


class Lenses(QWidget):
    """The two lenses as a status light: breathing while waiting, lit when a headset is
    connected, dim when something needs fixing."""

    def __init__(self):
        super().__init__()
        self.state = "waiting"
        self.animated = True
        self.setFixedSize(132, 84)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update)
        self.timer.start(40)

    def set_state(self, state, animated):
        self.state, self.animated = state, animated
        (self.timer.start if animated and state == "waiting" else self.timer.stop)()
        self.update()

    def paintEvent(self, _event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        breath = 0.5 + 0.5 * math.sin(time.monotonic() * 2.4) if self.animated else 0.6
        ring = {"connected": QColor(ACCENT), "problem": QColor("#ff9c8a")}.get(self.state, QColor(ACCENT))
        if self.state == "waiting":
            ring.setAlphaF(0.35 + 0.5 * breath)
        for index, cx in enumerate((38, 94)):
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setPen(QPen(ring, 4))
            p.drawEllipse(cx - 28, 14, 56, 56)
            if self.state == "connected":
                grad = QLinearGradient(cx, 24, cx, 60)
                grad.setColorAt(0, QColor(ACCENT_2))
                grad.setColorAt(1, QColor(ACCENT))
                p.setBrush(QBrush(grad))
                p.setPen(Qt.PenStyle.NoPen)
                p.drawEllipse(cx - 17, 25, 34, 34)
            elif self.state == "waiting":
                dot = QColor(ACCENT)
                dot.setAlphaF(0.15 + 0.35 * (breath if index == 0 else 1 - breath))
                p.setBrush(dot)
                p.setPen(Qt.PenStyle.NoPen)
                p.drawEllipse(cx - 12, 30, 24, 24)
        p.end()


class Window(QMainWindow):
    def __init__(self, tool):
        super().__init__()
        self.tool = tool
        self.settings = load_settings()
        self.games = []
        self.selected = None
        self.dashboard = None
        self.server = None
        self.dashboard_retry = 0
        self.engine = engines.current()
        self.headset = {}                  # the engine's last headset() answer
        self.headset_polling = False
        self.headset_due = 0.0
        self.pairing_until = 0.0
        self.jobs = queue.Queue()          # (callback, result) from work done on other threads
        self.job_timer = QTimer(self)
        self.job_timer.timeout.connect(self.collect_jobs)
        self.job_timer.start(100)
        self.setWindowTitle("GogglesXR")
        self.setWindowIcon(QIcon(logo_pixmap(128)))
        self.resize(1040, 680)

        root = QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        row = QHBoxLayout(root)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)

        side = QFrame()
        side.setObjectName("side")
        side.setFixedWidth(210)
        side_box = QVBoxLayout(side)
        side_box.setContentsMargins(14, 18, 14, 14)
        brand = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(logo_pixmap(34))
        brand.addWidget(icon)
        brand.addWidget(label("GogglesXR", "brand"), 1)
        side_box.addLayout(brand)
        self.pages = QStackedWidget()
        self.nav = QButtonGroup(self)
        for index, (name, builder) in enumerate((("Home", self.build_home), ("Library", self.build_library),
                                                 ("VR settings", self.build_vr_settings), ("Settings", self.build_settings))):
            button = QPushButton(name)
            button.setObjectName("nav")
            button.setCheckable(True)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            self.nav.addButton(button, index)
            side_box.addWidget(button)
            self.pages.addWidget(builder())
        side_box.addStretch(1)
        self.side_note = label("", "muted", True)
        side_box.addWidget(self.side_note)
        self.nav.idClicked.connect(self.show_page)
        row.addWidget(side)
        row.addWidget(self.pages, 1)
        self.show_page(0)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(3000)
        self.tick()

    # -------------------------------------------------------------- pages
    def page(self, eyebrow, title):
        widget = QWidget()
        box = QVBoxLayout(widget)
        box.setContentsMargins(30, 24, 30, 24)
        box.setSpacing(14)
        box.addWidget(label(eyebrow.upper(), "eyebrow"))
        box.addWidget(label(title, "title"))
        return widget, box

    def show_page(self, index):
        self.nav.button(index).setChecked(True)
        changed = self.pages.currentIndex() != index
        self.pages.setCurrentIndex(index)
        if index == 0:
            self.refresh_quick()
        if index == 1:
            self.reload_library()
        if changed and self.settings["animations"] and self.isVisible():
            self.fade_in(self.pages.currentWidget())

    def fade_in(self, widget):
        """A short fade when changing page. The effect is removed afterwards so it costs nothing."""
        effect = QGraphicsOpacityEffect(widget)
        widget.setGraphicsEffect(effect)
        self.page_fade = QPropertyAnimation(effect, b"opacity", self)
        self.page_fade.setDuration(190)
        self.page_fade.setStartValue(0.0)
        self.page_fade.setEndValue(1.0)
        self.page_fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.page_fade.finished.connect(lambda: widget.setGraphicsEffect(None))
        self.page_fade.start()

    def build_home(self):
        widget, box = self.page("GogglesXR", "VR on Goggles OS")

        # Headset: status light, headline, what the headset reports, and the main buttons
        hero, hero_box = card()
        top = QHBoxLayout()
        top.setSpacing(20)
        self.lenses = Lenses()
        top.addWidget(self.lenses, 0, Qt.AlignmentFlag.AlignTop)
        text = QVBoxLayout()
        text.setSpacing(4)
        text.addWidget(label("HEADSET", "eyebrow"))
        self.headline = label("", "headline")
        self.subline = label("", "muted", True)
        text.addWidget(self.headline)
        text.addWidget(self.subline)
        top.addLayout(text, 1)
        hero_box.addLayout(top)
        self.info_grid = QGridLayout()
        self.info_grid.setHorizontalSpacing(28)
        self.info_grid.setVerticalSpacing(2)
        hero_box.addLayout(self.info_grid)
        buttons = QHBoxLayout()
        self.connect_button = QPushButton("Connect a headset")
        self.connect_button.setObjectName("primary")
        self.connect_button.clicked.connect(lambda: self.tool.start())
        self.dashboard_button = QPushButton("Open dashboard")
        self.dashboard_button.clicked.connect(lambda: self.start_dashboard(manual=True))
        self.setup_button = QPushButton("Set up / repair")
        self.setup_button.clicked.connect(self.repair)
        for b in (self.connect_button, self.dashboard_button, self.setup_button):
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            buttons.addWidget(b)
        buttons.addStretch(1)
        hero_box.addLayout(buttons)
        box.addWidget(hero)

        # Quick launch: the VR game played most recently
        quick, quick_box = card()
        row = QHBoxLayout()
        row.setSpacing(18)
        self.quick_cover = QLabel()
        self.quick_cover.setFixedSize(80, 120)
        row.addWidget(self.quick_cover)
        words = QVBoxLayout()
        words.setSpacing(4)
        words.addWidget(label("QUICK LAUNCH", "eyebrow"))
        self.quick_name = label("", "headline", True)
        self.quick_note = label("", "muted", True)
        words.addWidget(self.quick_name)
        words.addWidget(self.quick_note)
        words.addStretch(1)
        row.addLayout(words, 1)
        self.quick_button = QPushButton("Play")
        self.quick_button.setObjectName("primary")
        self.quick_button.setCursor(Qt.CursorShape.PointingHandCursor)
        self.quick_button.setMinimumWidth(130)
        self.quick_button.clicked.connect(self.quick_launch)
        row.addWidget(self.quick_button, 0, Qt.AlignmentFlag.AlignVCenter)
        quick_box.addLayout(row)
        box.addWidget(quick)
        self.quick_game = None
        self.refresh_quick()

        # Checks: listed in full only while something needs fixing
        checks, self.checks_box = card()
        self.checks_title = label("CHECKS", "eyebrow")
        self.checks_box.addWidget(self.checks_title)
        self.check_rows = QVBoxLayout()
        self.check_rows.setSpacing(0)
        self.checks_box.addLayout(self.check_rows)
        box.addWidget(checks)
        box.addStretch(1)
        return widget

    def refresh_quick(self):
        try:
            game = library.last_played()
        except Exception:
            game = None
        self.quick_game = game
        self.quick_button.setEnabled(game is not None)
        if game is None:
            self.quick_cover.setPixmap(QPixmap())
            self.quick_name.setText("Nothing played yet")
            self.quick_note.setText("Start a VR game from the Library page and it will appear here.")
            return
        self.quick_cover.setPixmap(cover_pixmap(game).scaled(self.quick_cover.size(), Qt.AspectRatioMode.KeepAspectRatio,
                                                             Qt.TransformationMode.SmoothTransformation))
        self.quick_name.setText(game["title"])
        when = time.strftime("%-d %B", time.localtime(game["played"]))
        self.quick_note.setText(f'Last played {when} · {game["vr_label"]}')

    def quick_launch(self):
        if self.quick_game:
            self.play(self.quick_game)

    def play(self, game):
        library.note_launch(game["id"])
        subprocess.Popen(["steam", game["launch"]], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.refresh_quick()

    def build_library(self):
        widget, box = self.page("Library", "Your games")
        top = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search games")
        self.search.textChanged.connect(self.fill_library)
        top.addWidget(self.search, 1)
        self.filters = QButtonGroup(self)
        for index, name in enumerate(("VR games", "All games", "Hidden")):
            chip = QPushButton(name)
            chip.setObjectName("chip")
            chip.setCheckable(True)
            chip.setChecked(index == 0)
            chip.setCursor(Qt.CursorShape.PointingHandCursor)
            self.filters.addButton(chip, index)
            top.addWidget(chip)
        self.filters.idClicked.connect(lambda _: self.fill_library())
        box.addLayout(top)

        row = QHBoxLayout()
        row.setSpacing(18)
        self.grid = QListWidget()
        self.grid.setViewMode(QListView.ViewMode.IconMode)
        self.grid.setIconSize(COVER)
        self.grid.setResizeMode(QListView.ResizeMode.Adjust)
        self.grid.setMovement(QListView.Movement.Static)
        self.grid.setSpacing(8)
        self.grid.setWordWrap(True)
        self.grid.setUniformItemSizes(True)
        self.grid.currentItemChanged.connect(self.select_game)
        self.grid.itemDoubleClicked.connect(lambda _: self.launch())
        row.addWidget(self.grid, 1)

        panel, p = card()
        panel.setFixedWidth(280)
        self.p_cover = QLabel()
        self.p_cover.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.p_name = label("", "headline", True)
        self.p_type = label("", "muted", True)
        self.p_launch = QPushButton("Play")
        self.p_launch.setObjectName("primary")
        self.p_launch.clicked.connect(self.launch)
        self.p_fav = QCheckBox("Favourite (listed first)")
        self.p_fav.toggled.connect(lambda on: self.set_prop("favourite", on))
        self.p_hidden = QCheckBox("Hide from the library")
        self.p_hidden.toggled.connect(lambda on: self.set_prop("hidden", on))
        self.p_vr = QComboBox()
        self.p_vr.addItems(["Detect automatically", "Always show as a VR game", "Never show as a VR game"])
        self.p_vr.activated.connect(lambda i: self.set_prop("vr", ("auto", "yes", "no")[i]))
        self.p_rename = QLineEdit()
        self.p_rename.setPlaceholderText("Display name (optional)")
        self.p_rename.editingFinished.connect(lambda: self.set_prop("name", self.p_rename.text().strip()))
        self.p_folder = QPushButton("Open game folder")
        self.p_folder.clicked.connect(self.open_folder)
        for w in (self.p_cover, self.p_name, self.p_type, self.p_launch, self.p_fav, self.p_hidden,
                  label("In the headset's library", "muted"), self.p_vr, self.p_rename, self.p_folder):
            p.addWidget(w)
        p.addStretch(1)
        self.panel = panel
        row.addWidget(panel)
        box.addLayout(row, 1)
        self.select_game(None)
        return widget

    def scroll_page(self, eyebrow, title):
        """A page whose cards scroll: returns (page widget, add-a-card function)."""
        widget, box = self.page(eyebrow, title)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        inner = QWidget()
        inner.setObjectName("scrollinner")       # a style without a name would reach every button inside
        inner.setStyleSheet("#scrollinner { background: transparent; }")
        inner_box = QVBoxLayout(inner)
        inner_box.setContentsMargins(0, 0, 8, 0)
        inner_box.setSpacing(14)
        scroll.setWidget(inner)
        box.addWidget(scroll, 1)

        def group(title, note=""):
            frame, f = card()
            f.addWidget(label(title.upper(), "eyebrow"))
            if note:
                f.addWidget(label(note, "muted", True))
            inner_box.addWidget(frame)
            return f
        return widget, group, inner_box

    def choice(self, f, text, choices, value, changed, note=""):
        """A labelled drop-down. `choices`: [(value, label)]; calls changed(value)."""
        row = QHBoxLayout()
        name = label(text)
        name.setFixedWidth(170)
        row.addWidget(name)
        combo = QComboBox()
        for v, text_ in choices:
            combo.addItem(text_, v)
        index = next((i for i, (v, _) in enumerate(choices) if v == value or
                      (isinstance(v, (int, float)) and isinstance(value, (int, float)) and float(v) == float(value))), 0)
        combo.setCurrentIndex(index)
        combo.activated.connect(lambda i: changed(combo.itemData(i)))
        row.addWidget(combo, 1)
        f.addLayout(row)
        if note:
            hint = label(note, "muted", True)
            hint.setContentsMargins(178, 0, 0, 6)
            f.addWidget(hint)
        return combo

    def build_vr_settings(self):
        widget, group, inner_box = self.scroll_page("VR settings", "Headset and dashboard")

        # The streaming engine: today WiVRn; Goggles Link (GogglesXR's own) when it is ready
        f = group("Streaming engine", "What streams the game to the headset. Each engine has its own app on the headset: "
                                      "Goggles Link for Goggles Link, WiVRn for WiVRn. After changing it, quit "
                                      "Steam completely and open it again.")
        combo = self.choice(f, "Engine", [(cls.id, cls.name + ("" if cls().installed() else " (not installed)"))
                                          for cls in engines.ENGINES.values()], self.engine.id, self.change_engine)
        for index, cls in enumerate(engines.ENGINES.values()):
            if not cls().installed():           # listed, but can't be chosen
                combo.model().item(index).setEnabled(False)
        self.engine_note = label(self.engine.description, "muted", True)
        self.engine_note.setContentsMargins(178, 0, 0, 6)
        f.addWidget(self.engine_note)

        f = group("Stream", "Applied the next time the headset connects. Bitrate, resolution and foveation are set in "
                            "the headset's own app while WiVRn is the engine.")
        self.stream_box = f
        self.stream_note = label("", "muted", True)
        for option in self.engine.stream_options():
            self.choice(f, option["label"], option["choices"], option["value"],
                        lambda v, key=option["key"]: self.set_stream_option(key, v), option["note"])
        f.addWidget(self.stream_note)

        f = group("Headsets", "Headsets that have connected to this PC. A new headset needs a PIN the first time.")
        row = QHBoxLayout()
        self.pair_button = QPushButton("Pair a new headset")
        self.pair_button.setObjectName("primary")
        self.pair_button.clicked.connect(self.pair)
        row.addWidget(self.pair_button)
        self.disconnect_button = QPushButton("Disconnect headset")
        self.disconnect_button.clicked.connect(lambda: self.run_bg(self.engine.disconnect, lambda _: self.poll_headset(True)))
        row.addWidget(self.disconnect_button)
        row.addStretch(1)
        f.addLayout(row)
        self.pin_label = label("", "headline", True)
        self.pin_label.hide()
        f.addWidget(self.pin_label)
        self.known_box = QVBoxLayout()
        self.known_box.setSpacing(0)
        f.addLayout(self.known_box)
        self.refresh_known()

        f = group("In the headset")
        toggle = self.toggle
        self.s_dash = toggle(f, "Open the dashboard in the headset automatically",
                             "Starts the dashboard on top of your game when a headset connects. The menu button shows and hides it.",
                             self.settings["auto_dashboard"], lambda on: self.change("auto_dashboard", on))
        self.s_all = toggle(f, "Show non-VR games in the headset's library",
                            "By default the headset only lists games that can run in VR.",
                            self.settings["show_all_games"], lambda on: self.change("show_all_games", on))
        row = QHBoxLayout()
        row.addWidget(label("Pointer smoothing"))
        self.s_smooth = QSlider(Qt.Orientation.Horizontal)
        self.s_smooth.setRange(0, 100)
        self.s_smooth.setValue(int(self.settings["pointer_smoothing"]))
        self.s_smooth_value = label(str(self.s_smooth.value()), "muted")
        self.s_smooth_value.setFixedWidth(34)
        self.s_smooth.valueChanged.connect(lambda v: self.s_smooth_value.setText(str(v)))
        self.s_smooth.sliderReleased.connect(lambda: self.change("pointer_smoothing", self.s_smooth.value()))
        row.addWidget(self.s_smooth, 1)
        row.addWidget(self.s_smooth_value)
        f.addLayout(row)
        f.addWidget(label("Steadies the laser on the dashboard. 0 follows your hand exactly; higher holds the pointer stiller "
                          "on small buttons. Takes effect the next time the dashboard opens.", "muted", True))

        f = group("Home environment", "What you see around you in the headset while no game is running.")
        self.env_combo = self.choice(f, "Surroundings", [("goggles", "Goggles night (built in)"), ("custom", "My 360° picture"), ("none", "Black")],
                    self.settings["environment"], lambda v: self.change("environment", v))
        row = QHBoxLayout()
        row.addSpacing(178)
        self.env_pick = QPushButton("Choose a 360° picture…")
        self.env_pick.clicked.connect(self.choose_environment)
        row.addWidget(self.env_pick)
        self.env_name = label(os.path.basename(self.settings["environment_image"]) or "No picture chosen", "muted")
        row.addWidget(self.env_name, 1)
        f.addLayout(row)
        hint = label("Use an equirectangular picture (twice as wide as it is tall), like those from 360° cameras. "
                     "The dashboard picks up changes the next time it opens.", "muted", True)
        hint.setContentsMargins(178, 0, 0, 6)
        f.addWidget(hint)

        f = group("Recordings and screenshots", "Clips and pictures of what the headset shows, from the dashboard's "
                                                "Current Game panel. Saved to Videos/GogglesXR and Pictures/GogglesXR.")
        for key, text, choices, note in CAPTURE_OPTIONS:
            self.choice(f, text, choices, self.settings[key], lambda v, k=key: self.change(k, v), note)

        f = group("Desktop view", "The dashboard's Desktop panel and big screen show this PC's desktop in the headset.")
        self.choice(f, "Screen", [("all", "All screens"), ("active", "The screen with the mouse")],
                    self.settings["desktop_screen"], lambda v: self.change("desktop_screen", v))
        self.choice(f, "Frame rate", [(15, "15 fps"), (10, "10 fps (lighter)"), (30, "30 fps (smoother)")],
                    self.settings["desktop_fps"], lambda v: self.change("desktop_fps", v))
        inner_box.addStretch(1)
        return widget

    def toggle(self, f, text, note, value, changed):
        check = QCheckBox(text)
        check.setChecked(value)
        check.toggled.connect(changed)
        f.addWidget(check)
        hint = label(note, "muted", True)
        hint.setContentsMargins(48, 0, 0, 8)
        f.addWidget(hint)
        return check

    def build_settings(self):
        widget, group, inner_box = self.scroll_page("Settings", "Settings")
        toggle = self.toggle

        f = group("Starting up")
        self.s_autostart = toggle(f, "Start GogglesXR when I log in",
                                  "Sits in the system tray and gets VR ready. Turn this off to start it yourself from the app menu.",
                                  autostart_enabled(), set_autostart)
        self.s_ready = toggle(f, "Keep the VR runtime running in the background",
                              "The headset can connect at any time without opening anything on the PC first.",
                              self.settings["keep_ready"], lambda on: self.change("keep_ready", on))

        f = group("Look and feel")
        self.s_anim = toggle(f, "Animations",
                             "Page fades and the status light here, and the dashboard's open and close animation in the headset.",
                             self.settings["animations"], lambda on: self.change("animations", on))

        f = group("Games")
        self.s_on = toggle(f, "Send SteamVR games to GogglesXR",
                           "Turn this off to hand VR back to SteamVR, for a wired headset. Restart Steam after changing it.",
                           self.tool.is_on(), self.switch)
        inner_box.addStretch(1)
        return widget

    # -------------------------------------------------------------- home
    def tick(self):
        # The command-line hints, reworded for the buttons in this window
        reword = lambda t: (t.replace("Run: gogglesxr on", "Press Set up / repair.")
                             .replace("Open GogglesXR (run: gogglesxr start) and connect the headset.", "Press Connect a headset."))
        checks = [(ok, title, reword(todo)) for ok, title, todo in self.tool.checks()]
        failed = [c for c in checks if c[0] is False]
        self.poll_headset()
        info = self.headset
        connected = bool(info.get("connected")) if info.get("running") else os.path.exists(self.tool.IPC_SOCKET)
        animated = self.settings["animations"]
        if failed:
            self.headline.setText("GogglesXR needs setting up")
            self.subline.setText(failed[0][2] or failed[0][1])
            self.lenses.set_state("problem", animated)
        elif connected:
            self.headline.setText(f'{info["name"]} connected' if info.get("name") else "Headset connected")
            self.subline.setText("Start a VR game from Steam, the Library page, or the dashboard in the headset.")
            self.lenses.set_state("connected", animated)
        else:
            self.headline.setText("Ready for a headset")
            self.subline.setText("Put the headset on and open the GogglesXR streaming app in it. This PC will show up there.")
            self.lenses.set_state("waiting", animated)
        self.setup_button.setVisible(bool(failed))
        self.dashboard_button.setEnabled(not failed)
        self.connect_button.setVisible(not connected)

        # What the headset reports (only while it is connected)
        rows = [r for r in describe_headset(info) if r[0] != "Headset"] if connected and not failed else []
        if connected and not failed and not rows:
            rows = [("Status", "Streaming to this PC")]
        while self.info_grid.count():
            self.info_grid.takeAt(0).widget().deleteLater()
        per_row = 4
        for index, (name, value) in enumerate(rows):
            r, c = divmod(index, per_row)
            title = label(name.upper(), "info")
            if r:
                title.setContentsMargins(0, 10, 0, 0)
            self.info_grid.addWidget(title, r * 2, c)
            value_label = label(value, "value")
            if name in ("Headset battery", "Left controller", "Right controller") and value.endswith("%") \
                    and int(value[:-1]) <= 20:
                value_label.setStyleSheet("color: #ff9c8a;")
            self.info_grid.addWidget(value_label, r * 2 + 1, c)
        if rows:
            self.info_grid.setColumnStretch(min(len(rows), per_row), 1)
        self.disconnect_button.setEnabled(connected)

        while self.check_rows.count():
            self.check_rows.takeAt(0).widget().deleteLater()
        self.checks_title.setText("CHECKS" if failed else "CHECKS  ·  ALL GOOD")
        for ok, title, todo in checks if failed else []:
            mark = {True: ("✓", ACCENT), False: ("✗", "#ff9c8a"), None: ("…", MUTED)}[ok]
            text = f'<span style="color:{mark[1]}; font-weight:600">{mark[0]}</span>&nbsp;&nbsp;{title}'
            if todo and ok is not True:
                text += f'<br><span style="color:{MUTED}">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;{todo}</span>'
            line = label(text, "row", True)
            line.setTextFormat(Qt.TextFormat.RichText)
            self.check_rows.addWidget(line)
        self.side_note.setText("Headset connected" if connected else "Waiting for a headset")
        self.background(connected, bool(failed))

    # -------------------------------------------------------------- engine (on other threads)
    def run_bg(self, work, done=None):
        """Run work() on another thread; done(result) runs back on this one."""
        def run():
            try:
                result = work()
            except Exception as e:             # report, never take the app down
                result = e
            self.jobs.put((done, result))
        threading.Thread(target=run, daemon=True).start()

    def collect_jobs(self):
        while True:
            try:
                done, result = self.jobs.get_nowait()
            except queue.Empty:
                return
            if done:
                done(result)

    def poll_headset(self, now=False):
        """Ask the engine about the headset every few seconds, without holding up the window."""
        if self.headset_polling or (not now and time.monotonic() < self.headset_due):
            return
        self.headset_polling = True
        self.headset_due = time.monotonic() + 4

        def got(info):
            self.headset_polling = False
            if isinstance(info, dict):
                changed = info != self.headset
                self.headset = info
                if changed:
                    self.tick()
                if self.pairing_until and (time.monotonic() > self.pairing_until or not info.get("pairing", {}).get("enabled")):
                    self.pairing_until = 0.0
                    self.pin_label.setText("")
                    self.pin_label.hide()
                    self.pair_button.setEnabled(True)
                    self.refresh_known()
        self.run_bg(self.engine.headset, got)

    def set_stream_option(self, key, value):
        self.stream_note.setText("Saving…")
        self.run_bg(lambda: self.engine.set_stream_option(key, value),
                    lambda result: self.stream_note.setText(result[1] if isinstance(result, tuple) else str(result)))

    def pair(self):
        self.pair_button.setEnabled(False)
        self.pin_label.setText("Starting pairing…")
        self.pin_label.show()

        def got(pin):
            if isinstance(pin, str) and pin:
                self.pairing_until = time.monotonic() + 120
                self.pin_label.setText(f"Type this PIN in the headset:  {pin}")
            else:
                self.pin_label.setText("Couldn't start pairing: is the VR runtime running? Press Connect a headset on Home first.")
                self.pair_button.setEnabled(True)
        self.run_bg(lambda: self.engine.enable_pairing(120), got)

    def refresh_known(self):
        def got(known):
            while self.known_box.count():
                item = self.known_box.takeAt(0)
                if item.widget():
                    item.widget().deleteLater()
            if not isinstance(known, list) or not known:
                self.known_box.addWidget(label("No headsets paired yet (or the VR runtime isn't running).", "muted"))
                return
            for entry in known:
                row = QWidget()
                line = QHBoxLayout(row)
                line.setContentsMargins(0, 4, 0, 4)
                seen = time.strftime("%-d %B %Y", time.localtime(entry["last_seen"])) if entry["last_seen"] else "never"
                line.addWidget(label(f'{entry["name"]}   <span style="color:{MUTED}">last connected {seen}</span>'), 1)
                forget = QPushButton("Forget")
                forget.clicked.connect(lambda _=False, key=entry["key"]: self.run_bg(
                    lambda: self.engine.forget_headset(key), lambda _: self.refresh_known()))
                line.addWidget(forget)
                self.known_box.addWidget(row)
        self.run_bg(self.engine.known_headsets, got)

    def change_engine(self, engine_id):
        cls = engines.ENGINES.get(engine_id)
        if cls is None or not cls().installed() or engine_id == self.engine.id:
            return
        old = self.engine
        self.change("engine", engine_id)
        self.engine = engines.current()
        self.engine_note.setText(self.engine.description)
        self.headset = {}

        def switched(_):
            # games must now find the new engine: its translator and its folder in Steam's containers
            if self.tool.is_on():
                self.tool.turn_on()
            if self.server is not None and self.server.state() != QProcess.ProcessState.NotRunning:
                self.server.terminate()
            self.refresh_known()
            self.tick()
        self.run_bg(old.quit, switched)

    def choose_environment(self):
        path, _ = QFileDialog.getOpenFileName(self, "Choose a 360° picture", os.path.expanduser("~/Pictures"),
                                              "Pictures (*.jpg *.jpeg *.png *.webp)")
        if path:
            self.change("environment_image", path)
            self.change("environment", "custom")
            self.env_combo.setCurrentIndex(1)
            self.env_name.setText(os.path.basename(path))

    def repair(self):
        self.tool.turn_on()
        self.s_on.blockSignals(True)
        self.s_on.setChecked(self.tool.is_on())
        self.s_on.blockSignals(False)
        self.tick()

    def switch(self, on):
        (self.tool.turn_on if on else self.tool.turn_off)()
        self.tick()

    def change(self, key, value):
        self.settings[key] = value
        save_settings({key: value})
        if key == "show_all_games":
            library.write_dashboard_list(value)
        if key == "animations":
            self.tick()

    # -------------------------------------------------------------- background work
    def background(self, connected, broken):
        """Keep the runtime up, and the dashboard open in the headset, as the settings ask."""
        if os.environ.get("GOGGLESXR_APP_NO_BACKGROUND"):
            return
        if self.settings["keep_ready"] and not broken and not connected and not self.tool.running("wivrn-server"):
            if self.server is None or self.server.state() == QProcess.ProcessState.NotRunning:
                self.server = QProcess(self)
                command = self.engine.server_command()
                self.server.start(command[0], command[1:])
        running = self.dashboard is not None and self.dashboard.state() != QProcess.ProcessState.NotRunning
        if connected and self.settings["auto_dashboard"] and not broken and not running:
            if self.dashboard_retry <= 0:
                self.start_dashboard()
                self.dashboard_retry = 5          # if it exits straight away, wait a few ticks before retrying
            else:
                self.dashboard_retry -= 1
        elif not connected:
            self.dashboard_retry = 0
            if running and self.dashboard.property("auto"):
                self.dashboard.terminate()

    def start_dashboard(self, manual=False):
        if self.dashboard is not None and self.dashboard.state() != QProcess.ProcessState.NotRunning:
            return
        library.write_dashboard_list(self.settings["show_all_games"])
        connected = os.path.exists(self.tool.IPC_SOCKET)
        self.dashboard = QProcess(self)
        self.dashboard.setProperty("auto", not manual)
        self.dashboard.setProcessChannelMode(QProcess.ProcessChannelMode.ForwardedChannels)
        self.dashboard.start(sys.executable, [TOOL, "dashboard"] + (["--overlay"] if connected else []))

    # -------------------------------------------------------------- library
    def reload_library(self):
        self.games = library.games()
        self.fill_library()

    def fill_library(self, *_):
        keep = self.selected["id"] if self.selected else None
        mode = self.filters.checkedId()
        needle = self.search.text().strip().lower()
        self.grid.blockSignals(True)
        self.grid.clear()
        for game in self.games:
            if needle and needle not in game["title"].lower():
                continue
            if mode == 2 and not game["hidden"]:
                continue
            if mode != 2 and game["hidden"]:
                continue
            if mode == 0 and not game["is_vr"]:
                continue
            item = QListWidgetItem(QIcon(cover_pixmap(game)), game["title"])
            item.setData(Qt.ItemDataRole.UserRole, game["id"])
            item.setSizeHint(QSize(COVER.width() + 22, COVER.height() + 52))
            item.setTextAlignment(Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop)
            item.setToolTip(f'{game["title"]}\n{game["vr_label"]}')
            self.grid.addItem(item)
            if game["id"] == keep:
                self.grid.setCurrentItem(item)
        self.grid.blockSignals(False)
        if self.grid.currentItem() is None and self.grid.count():
            self.grid.setCurrentRow(0)
        self.select_game(self.grid.currentItem())

    def select_game(self, item, *_):
        game = next((g for g in self.games if item is not None and g["id"] == item.data(Qt.ItemDataRole.UserRole)), None)
        self.selected = game
        for w in (self.p_launch, self.p_fav, self.p_hidden, self.p_vr, self.p_rename, self.p_folder):
            w.setEnabled(game is not None)
            w.blockSignals(True)
        if game is None:
            self.p_cover.setPixmap(QPixmap())
            self.p_name.setText("No game selected")
            self.p_type.setText("Games you install in Steam appear here, with non-Steam games you added to Steam.")
        else:
            self.p_cover.setPixmap(cover_pixmap(game).scaled(QSize(120, 180), Qt.AspectRatioMode.KeepAspectRatio,
                                                             Qt.TransformationMode.SmoothTransformation))
            self.p_name.setText(game["title"])
            self.p_type.setText(game["vr_label"] + ("" if game["source"] == "steam" else " · non-Steam game"))
            self.p_fav.setChecked(game["favourite"])
            self.p_hidden.setChecked(game["hidden"])
            self.p_vr.setCurrentIndex(("auto", "yes", "no").index(game["vr"]))
            self.p_rename.setText(game["custom_name"])
        for w in (self.p_launch, self.p_fav, self.p_hidden, self.p_vr, self.p_rename, self.p_folder):
            w.blockSignals(False)

    def set_prop(self, key, value):
        if self.selected is None or self.selected.get({"name": "custom_name"}.get(key, key)) == value:
            return
        library.set_prop(self.selected["id"], key, value)
        library.write_dashboard_list(self.settings["show_all_games"])
        self.reload_library()

    def launch(self):
        if self.selected:
            self.play(self.selected)

    def open_folder(self):
        if self.selected and os.path.isdir(self.selected["folder"]):
            subprocess.Popen(["xdg-open", self.selected["folder"]], start_new_session=True)

    # -------------------------------------------------------------- window
    def closeEvent(self, event):
        # With a tray icon, closing the window keeps GogglesXR running in the background
        if getattr(self, "tray", None) is not None and self.tray.isVisible():
            event.ignore()
            self.hide()
        else:
            event.accept()

    def quit(self):
        for process in (self.dashboard, self.server):
            if process is not None and process.state() != QProcess.ProcessState.NotRunning:
                process.terminate()
        QApplication.quit()


def main(argv):
    background = "--background" in argv
    app = QApplication(sys.argv[:1])
    app.setApplicationName("GogglesXR")
    app.setDesktopFileName("gogglesxr")
    app.setStyleSheet(STYLE)
    app.setQuitOnLastWindowClosed(False)
    tool = load_tool()
    if tool.is_on():
        tool.ensure_layer()           # screenshots and recordings of the headset view (games started from now on)
    window = Window(tool)

    window.tray = None
    if QSystemTrayIcon.isSystemTrayAvailable():
        tray = QSystemTrayIcon(QIcon(logo_pixmap(64)), app)
        tray.setToolTip("GogglesXR")
        menu = QMenu()
        for text, action in (("Open GogglesXR", window.showNormal), ("Open dashboard", lambda: window.start_dashboard(True)),
                             ("Quit", window.quit)):
            entry = QAction(text, menu)
            entry.triggered.connect(action)
            menu.addAction(entry)
        tray.setContextMenu(menu)
        tray.activated.connect(lambda reason: window.showNormal() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        tray.show()
        window.tray = tray
        window.tray_menu = menu
    else:
        app.setQuitOnLastWindowClosed(True)
        background = False            # no tray to live in, so show the window

    page = {"home": 0, "library": 1, "vr": 2, "settings": 3}.get(os.environ.get("GOGGLESXR_APP_PAGE", ""), 0)
    window.show_page(page)
    if not background:
        window.show()
    shot = os.environ.get("GOGGLESXR_APP_SHOT")
    if shot:                           # testing: save a picture of the window and quit
        window.show()
        QTimer.singleShot(900, lambda: (window.grab().save(shot), app.quit()))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
