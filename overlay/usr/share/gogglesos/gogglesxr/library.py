"""GogglesXR game library: what is installed, which games can run in VR, their cover art,
and the per-game choices the user made (favourite, hidden, treat as VR or not).

Used by the gogglesxr command, the GogglesXR desktop app and (through a cache file) the
in-headset dashboard. Everything is read from Steam's own files; no Steam API key is needed.
"""
import glob
import json
import os
import re
import struct

HOME = os.path.expanduser("~")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "gogglesxr")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "gogglesxr")
PROPS_FILE = os.path.join(CONFIG, "library.json")
SCAN_FILE = os.path.join(CACHE, "vr-scan.json")
LIST_FILE = os.path.join(CACHE, "library.json")          # read by the dashboard
LAUNCH_FILE = os.path.join(CACHE, "launches.json")       # when each game was last started from GogglesXR
STEAM_ROOTS = [".steam/debian-installation", ".steam/steam", ".local/share/Steam"]
NOT_GAMES = ("Proton", "Steam Linux Runtime", "Steamworks Common", "SteamVR", "Steam Controller")

# Files that show which VR interface a game was built for
VR_FILES = (
    ("openxr", ("openxr_loader", "unityopenxr", "libopenxr_loader")),
    ("steamvr", ("openvr_api", "libopenvr_api")),
    ("oculus", ("ovrplugin", "libovr", "oculusxrplugin")),
)
VR_LABELS = {
    "openxr": "VR (OpenXR)",
    "steamvr": "VR (SteamVR game)",
    "oculus": "Oculus only: can't run in VR on Linux",
    "none": "Not a VR game",
    "unknown": "Unknown",
}
PROP_DEFAULTS = {"favourite": False, "hidden": False, "vr": "auto", "name": ""}


# ------------------------------------------------------------------ Steam folders
def steam_roots():
    seen, out = set(), []
    for rel in STEAM_ROOTS:
        root = os.path.realpath(os.path.join(HOME, rel))
        if os.path.isdir(os.path.join(root, "steamapps")) and root not in seen:
            seen.add(root)
            out.append(root)
    return out


def library_folders():
    """Every steamapps folder: the main one and extra libraries on other drives."""
    seen, out = set(), []

    def add(path):
        real = os.path.realpath(path)
        if os.path.isdir(real) and real not in seen:
            seen.add(real)
            out.append(real)

    for root in steam_roots():
        apps = os.path.join(root, "steamapps")
        add(apps)
        try:
            with open(os.path.join(apps, "libraryfolders.vdf"), encoding="utf-8", errors="replace") as f:
                for path in re.findall(r'"path"\s+"([^"]+)"', f.read()):
                    add(os.path.join(path.replace("\\\\", "\\"), "steamapps"))
        except OSError:
            pass
    return out


# ------------------------------------------------------------------ cover art
def cover_art(app_id, shortcut_grids=()):
    """Path of the best cover picture Steam has cached for a game, or None."""
    names = ("library_600x900.jpg", "library_600x900.png", "library_capsule.jpg", "header.jpg", "library_header.jpg")
    for root in steam_roots():
        cache = os.path.join(root, "appcache", "librarycache")
        for name in names:
            flat = os.path.join(cache, f"{app_id}_{name}")
            if os.path.isfile(flat):
                return flat
            hits = glob.glob(os.path.join(cache, str(app_id), name)) + glob.glob(os.path.join(cache, str(app_id), "*", name))
            if hits:
                return hits[0]
    for grid in shortcut_grids:           # non-Steam games: artwork the user set in Steam
        for suffix in ("p.png", "p.jpg", ".png", ".jpg"):
            path = os.path.join(grid, f"{app_id}{suffix}")
            if os.path.isfile(path):
                return path
    return None


# ------------------------------------------------------------------ which VR interface
def _load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def detect_vr(folder, max_depth=6):
    """'openxr', 'steamvr', 'oculus', 'none', or 'unknown' if the folder can't be read."""
    if not folder or not os.path.isdir(folder):
        return "unknown"
    found = set()
    base_depth = folder.rstrip(os.sep).count(os.sep)
    for path, dirs, files in os.walk(folder):
        if path.count(os.sep) - base_depth >= max_depth:
            dirs[:] = []
        for name in files:
            low = name.lower()
            for kind, prefixes in VR_FILES:
                if low.startswith(prefixes):
                    found.add(kind)
    for kind in ("openxr", "steamvr", "oculus"):
        if kind in found:
            return kind
    return "none"


def _scan(game, scans):
    """detect_vr with a cache: a game is only rescanned when its folder changes."""
    folder = game.get("folder") or ""
    try:
        stamp = int(os.path.getmtime(folder))
    except OSError:
        return "unknown"
    entry = scans.get(game["id"])
    if not (isinstance(entry, dict) and entry.get("folder") == folder and entry.get("stamp") == stamp):
        entry = {"folder": folder, "stamp": stamp, "vr": detect_vr(folder)}
        scans[game["id"]] = entry
    return entry["vr"]


# ------------------------------------------------------------------ installed games
def _steam_games():
    games, seen = [], set()
    field = re.compile(r'"(appid|name|installdir|LastPlayed)"\s+"([^"]*)"')
    for apps in library_folders():
        for manifest in sorted(glob.glob(os.path.join(apps, "appmanifest_*.acf"))):
            try:
                with open(manifest, encoding="utf-8", errors="replace") as f:
                    info = {}
                    for key, value in field.findall(f.read()):
                        info.setdefault(key, value)
            except OSError:
                continue
            app_id, name = info.get("appid", ""), info.get("name", "")
            if not app_id or not name or app_id in seen or name.startswith(NOT_GAMES):
                continue
            seen.add(app_id)
            games.append({"id": app_id, "name": name, "source": "steam", "played": _number(info.get("LastPlayed")),
                          "folder": os.path.join(apps, "common", info.get("installdir", "")),
                          "launch": "steam://rungameid/" + app_id})
    return games


def _number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _read_binary_vdf(data, pos=0):
    """Steam's binary key/value format (used by shortcuts.vdf). Returns (dict, next position)."""
    out = {}
    while pos < len(data):
        kind = data[pos]
        pos += 1
        if kind == 0x08:
            break
        end = data.index(b"\0", pos)
        key = data[pos:end].decode("utf-8", "replace")
        pos = end + 1
        if kind == 0x00:
            out[key], pos = _read_binary_vdf(data, pos)
        elif kind == 0x01:
            end = data.index(b"\0", pos)
            out[key] = data[pos:end].decode("utf-8", "replace")
            pos = end + 1
        elif kind == 0x02:
            out[key] = struct.unpack_from("<I", data, pos)[0]
            pos += 4
        else:
            raise ValueError(f"unknown field type {kind}")
    return out, pos


def _shortcut_games():
    """Non-Steam games the user added to Steam (for example a game from itch.io)."""
    games, grids = [], []
    for root in steam_roots():
        for config in glob.glob(os.path.join(root, "userdata", "*", "config")):
            grids.append(os.path.join(config, "grid"))
            try:
                with open(os.path.join(config, "shortcuts.vdf"), "rb") as f:
                    tree, _ = _read_binary_vdf(f.read())
            except (OSError, ValueError, struct.error):
                continue
            for item in (tree.get("shortcuts") or {}).values():
                if not isinstance(item, dict):
                    continue
                lowered = {k.lower(): v for k, v in item.items()}
                name, app_id = lowered.get("appname", ""), lowered.get("appid")
                if not name or not isinstance(app_id, int):
                    continue
                exe = str(lowered.get("exe", "")).strip('"')
                folder = str(lowered.get("startdir", "")).strip('"') or os.path.dirname(exe)
                games.append({"id": str(app_id), "name": name, "source": "shortcut", "folder": folder,
                              "played": _number(lowered.get("lastplaytime")),
                              # Steam's "game id" for a shortcut: its app id in the top half
                              "launch": "steam://rungameid/%d" % ((app_id << 32) | 0x02000000)})
    return games, grids


def load_props():
    return _load_json(PROPS_FILE, {})


def set_prop(app_id, key, value):
    if key not in PROP_DEFAULTS:
        raise KeyError(key)
    if key == "vr" and value not in ("auto", "yes", "no"):
        raise ValueError("vr must be auto, yes or no")
    props = load_props()
    entry = dict(props.get(str(app_id)) or {})
    entry[key] = value
    # keep the file to what differs from the defaults
    entry = {k: v for k, v in entry.items() if k in PROP_DEFAULTS and v != PROP_DEFAULTS[k]}
    if entry:
        props[str(app_id)] = entry
    else:
        props.pop(str(app_id), None)
    _save_json(PROPS_FILE, props)


def games():
    """Every installed game with its cover art, VR interface and the user's choices."""
    scans = _load_json(SCAN_FILE, {})
    before = json.dumps(scans, sort_keys=True)
    props = load_props()
    launches = _load_json(LAUNCH_FILE, {})
    shortcuts, grids = _shortcut_games()
    out = []
    for game in _steam_games() + shortcuts:
        chosen = dict(PROP_DEFAULTS, **(props.get(game["id"]) or {}))
        detected = _scan(game, scans)
        game.update({k: chosen[k] for k in ("favourite", "hidden", "vr")})
        game["custom_name"] = chosen["name"]
        game["title"] = chosen["name"] or game["name"]
        game["detected"] = detected
        game["art"] = cover_art(game["id"], grids)
        # Steam's own record, or the last start from GogglesXR if that is newer
        game["played"] = max(game.get("played", 0), _number(launches.get(game["id"])))
        game["is_vr"] = chosen["vr"] == "yes" or (chosen["vr"] == "auto" and detected in ("openxr", "steamvr"))
        game["vr_label"] = {"yes": "VR (set by you)", "no": "Not VR (set by you)"}.get(chosen["vr"], VR_LABELS[detected])
        out.append(game)
    if json.dumps(scans, sort_keys=True) != before:
        try:
            _save_json(SCAN_FILE, scans)
        except OSError:
            pass
    out.sort(key=lambda g: (not g["favourite"], g["title"].lower()))
    return out


def note_launch(app_id):
    """Remember that a game was just started from GogglesXR (Steam records it later)."""
    import time
    launches = _load_json(LAUNCH_FILE, {})
    launches[str(app_id)] = int(time.time())
    try:
        _save_json(LAUNCH_FILE, launches)
    except OSError:
        pass


def last_played(all_games=None):
    """The VR game played most recently, or None if nothing has been played yet."""
    candidates = [g for g in (all_games if all_games is not None else games())
                  if g["is_vr"] and not g["hidden"] and g["played"] > 0]
    return max(candidates, key=lambda g: g["played"]) if candidates else None


def dashboard_list(show_all=False):
    """What the in-headset Library shows: VR games that aren't hidden, favourites first."""
    return [g for g in games() if not g["hidden"] and (show_all or g["is_vr"])]


def write_dashboard_list(show_all=False):
    items = [{"id": g["id"], "name": g["title"], "launch": g["launch"], "art": g["art"] or "",
              "favourite": g["favourite"], "vr": g["vr_label"]} for g in dashboard_list(show_all)]
    try:
        _save_json(LIST_FILE, {"version": 1, "games": items})
    except OSError:
        pass
    return items
