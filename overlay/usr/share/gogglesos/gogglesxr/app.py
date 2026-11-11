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
import time

from PyQt6.QtCore import QEasingCurve, QProcess, QPropertyAnimation, QSize, Qt, QTimer
from PyQt6.QtGui import QAction, QBrush, QColor, QFont, QIcon, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PyQt6.QtWidgets import (QApplication, QButtonGroup, QCheckBox, QComboBox, QFrame, QGraphicsOpacityEffect,
                             QGridLayout, QHBoxLayout, QLabel, QLineEdit, QListView, QListWidget, QListWidgetItem,
                             QMainWindow, QMenu, QPushButton, QScrollArea, QSlider, QStackedWidget, QSystemTrayIcon,
                             QVBoxLayout, QWidget)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import library  # noqa: E402

TOOL = os.environ.get("GOGGLESXR_TOOL") or "/usr/bin/gogglesxr"
SETTINGS_FILE = os.path.join(library.CONFIG, "settings.json")
AUTOSTART_SYSTEM = "/etc/xdg/autostart/gogglesxr.desktop"
AUTOSTART_USER = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(library.HOME, ".config"),
                              "autostart", "gogglesxr.desktop")
DEFAULTS = {"keep_ready": True, "auto_dashboard": True, "show_all_games": False, "animations": True,
            "pointer_smoothing": 60}
ENGINE_BUS = "io.github.wivrn.Server"          # the streaming engine's D-Bus name
ENGINE_PATH = "/io/github/wivrn/Server"
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


def headset_info():
    """What the streaming engine reports about the headset, as {property name: value}.

    Read over D-Bus from the engine (WiVRn's server). Returns {} when it isn't running or
    doesn't answer; the caller shows only the properties that are present.
    """
    fake = os.environ.get("GOGGLESXR_FAKE_HEADSET")
    if fake:
        return json.loads(fake)
    try:
        from PyQt6.QtDBus import QDBusConnection, QDBusInterface, QDBusMessage
        bus = QDBusConnection.sessionBus()
        if not bus.isConnected() or not bus.interface().isServiceRegistered(ENGINE_BUS).value():
            return {}
        engine = QDBusInterface(ENGINE_BUS, ENGINE_PATH, "org.freedesktop.DBus.Properties", bus)
        engine.setTimeout(500)
        reply = engine.call("GetAll", ENGINE_BUS)
        if reply.type() != QDBusMessage.MessageType.ReplyMessage or not reply.arguments():
            return {}
        return dict(reply.arguments()[0])
    except Exception:
        return {}


def describe_headset(info):
    """Rows for the Home page from headset_info(): [(label, text)]. Unknown shapes are skipped."""
    lowered = {str(k).lower(): v for k, v in info.items()}

    def get(*names):
        for name in names:
            if name in lowered:
                return lowered[name]
        return None

    def numbers(value):
        try:
            return [float(v) for v in value]
        except (TypeError, ValueError):
            return []

    rows = []
    size = numbers(get("recommendedeyesize", "eyesize"))
    if len(size) == 2:
        rows.append(("Resolution per eye", "%d × %d" % (size[0], size[1])))
    rate = get("preferredrefreshrate", "refreshrate")
    rates = numbers(get("availablerefreshrates"))
    try:
        rate = float(rate)
    except (TypeError, ValueError):
        rate = 0.0
    if rate > 0:
        rows.append(("Refresh rate", "%g Hz" % rate))
    elif rates:
        rows.append(("Refresh rates", ", ".join("%g" % r for r in rates) + " Hz"))
    codecs = get("supportedcodecs", "codecs")
    if isinstance(codecs, (list, tuple)) and codecs:
        rows.append(("Video", ", ".join(str(c).upper() for c in codecs)))
    for names, text in ((("handtracking",), "Hand tracking"), (("eyegaze", "eyetracking"), "Eye tracking"),
                        (("facetracking",), "Face tracking")):
        value = get(*names)
        if isinstance(value, bool):
            rows.append((text, "Yes" if value else "No"))
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
                                                 ("Settings", self.build_settings))):
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

    def build_settings(self):
        widget, box = self.page("Settings", "Settings")
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        inner = QWidget()
        inner.setStyleSheet("background: transparent;")
        inner_box = QVBoxLayout(inner)
        inner_box.setContentsMargins(0, 0, 8, 0)
        inner_box.setSpacing(14)
        scroll.setWidget(inner)
        box.addWidget(scroll, 1)

        def group(title):
            frame, f = card()
            f.addWidget(label(title.upper(), "eyebrow"))
            inner_box.addWidget(frame)
            return f

        def toggle(f, text, note, value, changed):
            check = QCheckBox(text)
            check.setChecked(value)
            check.toggled.connect(changed)
            f.addWidget(check)
            hint = label(note, "muted", True)
            hint.setContentsMargins(48, 0, 0, 8)
            f.addWidget(hint)
            return check

        f = group("Starting up")
        self.s_autostart = toggle(f, "Start GogglesXR when I log in",
                                  "Sits in the system tray and gets VR ready. Turn this off to start it yourself from the app menu.",
                                  autostart_enabled(), set_autostart)
        self.s_ready = toggle(f, "Keep the VR runtime running in the background",
                              "The headset can connect at any time without opening anything on the PC first.",
                              self.settings["keep_ready"], lambda on: self.change("keep_ready", on))

        f = group("In the headset")
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
        info = headset_info()
        reported = {str(k).lower(): v for k, v in info.items()}.get("headsetconnected")
        connected = reported if isinstance(reported, bool) else os.path.exists(self.tool.IPC_SOCKET)
        animated = self.settings["animations"]
        if failed:
            self.headline.setText("GogglesXR needs setting up")
            self.subline.setText(failed[0][2] or failed[0][1])
            self.lenses.set_state("problem", animated)
        elif connected:
            self.headline.setText("Headset connected")
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
        rows = [("Status", "Streaming to this PC")] + describe_headset(info) if connected and not failed else []
        while self.info_grid.count():
            self.info_grid.takeAt(0).widget().deleteLater()
        for index, (name, value) in enumerate(rows):
            self.info_grid.addWidget(label(name.upper(), "info"), 0, index)
            self.info_grid.addWidget(label(value, "value"), 1, index)
        if rows:
            self.info_grid.setColumnStretch(len(rows), 1)

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
                self.server.start("flatpak", ["run", "--command=wivrn-server", self.tool.ENGINE_APP])
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
    window = Window(load_tool())

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

    page = {"home": 0, "library": 1, "settings": 2}.get(os.environ.get("GOGGLESXR_APP_PAGE", ""), 0)
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
