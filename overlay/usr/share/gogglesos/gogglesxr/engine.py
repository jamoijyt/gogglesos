"""GogglesXR's streaming engines, behind one interface.

The dashboard, the desktop app and the gogglesxr command never talk to the streaming software
directly: they ask the current engine. There are two: WiVRn, and GogglesXR's own link software,
Goggles Link, which is a fork of WiVRn and so shares most of WiVRn's class. Everything an engine reports
uses GogglesXR's own words and units (see Engine.headset), not the engine's.

Engines:
  wivrn        WiVRn (Monado-based), installed as the io.github.wivrn.wivrn Flatpak
  goggleslink  Goggles Link: GogglesXR's own streaming (a fork of WiVRn), installed in /opt/goggles-link
"""
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
SETTINGS_FILE = os.path.join(CONFIG, "gogglesxr", "settings.json")
ACTIVE_RUNTIME = os.path.join(CONFIG, "openxr", "1", "active_runtime.json")


# ------------------------------------------------------------------ the VR runtime (Monado)
# Both engines are Monado-based, so recentring, batteries and the list of running VR apps go
# through Monado's control library (libmonado). Kept as source text so it can also run inside
# the runtime's Flatpak when the library can't be loaded on the desktop side.
MONADO_CODE = r"""
import ctypes, json, sys

class Pose(ctypes.Structure):
    _fields_ = [(n, ctypes.c_float) for n in ("qx", "qy", "qz", "qw", "x", "y", "z")]

LOCAL, STAGE = 1, 3
lib = ctypes.CDLL(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "status"
root = ctypes.c_void_p()
lib.mnd_root_create.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
lib.mnd_root_destroy.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
if lib.mnd_root_create(ctypes.byref(root)) != 0:
    print("NOT-CONNECTED")
    sys.exit(3)
try:
    if mode == "recenter":
        lib.mnd_root_recenter_local_spaces.argtypes = [ctypes.c_void_p]
        # 1. Seated games (the LOCAL space): the runtime puts its centre where the head is now,
        #    facing the way the head faces (turning only around the vertical axis)
        if lib.mnd_root_recenter_local_spaces(root) != 0:
            print("FAILED")
            sys.exit(4)
        # 2. Standing and room-scale games (the STAGE space, which most SteamVR games use): move
        #    the play area's centre to the same place, keeping the floor height
        if hasattr(lib, "mnd_root_set_reference_space_offset"):
            for name in ("mnd_root_get_reference_space_offset", "mnd_root_set_reference_space_offset"):
                getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(Pose)]
            local, stage = Pose(), Pose()
            if (lib.mnd_root_get_reference_space_offset(root, LOCAL, ctypes.byref(local)) == 0 and
                    lib.mnd_root_get_reference_space_offset(root, STAGE, ctypes.byref(stage)) == 0):
                new = Pose(local.qx, local.qy, local.qz, local.qw, local.x, stage.y, local.z)
                print("OK" if lib.mnd_root_set_reference_space_offset(root, STAGE, ctypes.byref(new)) == 0 else "LOCAL-ONLY")
                sys.exit(0)
        print("LOCAL-ONLY")
    else:
        out = {"battery": {}, "apps": []}
        # Batteries of the headset and both controllers, by role
        if hasattr(lib, "mnd_root_get_device_battery_status") and hasattr(lib, "mnd_root_get_device_from_role"):
            lib.mnd_root_get_device_from_role.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32)]
            lib.mnd_root_get_device_battery_status.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_bool),
                                                               ctypes.POINTER(ctypes.c_bool), ctypes.POINTER(ctypes.c_float)]
            for role, name in ((b"head", "head"), (b"left", "left"), (b"right", "right")):
                index = ctypes.c_int32(-1)
                if lib.mnd_root_get_device_from_role(root, role, ctypes.byref(index)) != 0 or index.value < 0:
                    continue
                present, charging, charge = ctypes.c_bool(), ctypes.c_bool(), ctypes.c_float()
                if (lib.mnd_root_get_device_battery_status(root, index.value, ctypes.byref(present), ctypes.byref(charging),
                                                           ctypes.byref(charge)) == 0 and present.value):
                    out["battery"][name] = {"charge": round(max(0.0, min(1.0, charge.value)) * 100), "charging": charging.value}
        # The VR apps connected to the runtime: a game, the dashboard (an overlay)...
        lib.mnd_root_update_client_list.argtypes = [ctypes.c_void_p]
        if lib.mnd_root_update_client_list(root) == 0:
            count = ctypes.c_uint32()
            lib.mnd_root_get_number_clients(root, ctypes.byref(count))
            for i in range(count.value):
                cid, flags, name = ctypes.c_uint32(), ctypes.c_uint32(), ctypes.c_char_p()
                if lib.mnd_root_get_client_id_at_index(root, i, ctypes.byref(cid)) != 0:
                    continue
                lib.mnd_root_get_client_name(root, cid.value, ctypes.byref(name))
                lib.mnd_root_get_client_state(root, cid.value, ctypes.byref(flags))
                f = flags.value
                out["apps"].append({"name": (name.value or b"").decode(errors="replace"), "active": bool(f & 2),
                                    "focused": bool(f & 8), "overlay": bool(f & 16)})
        print(json.dumps(out))
finally:
    lib.mnd_root_destroy(ctypes.byref(root))
"""


def libmonado():
    """The runtime's control library, from the active runtime's manifest:
    (path on the desktop, path inside the runtime's Flatpak or None)."""
    manifest = os.path.realpath(ACTIVE_RUNTIME)
    try:
        with open(manifest, encoding="utf-8") as f:
            lib = json.load(f)["runtime"].get("MND_libmonado_path")
    except (OSError, ValueError, KeyError):
        return None, None
    if not lib:
        return None, None
    lib = os.path.normpath(os.path.join(os.path.dirname(manifest), lib))
    inside = None
    if "/files/" in lib:                   # a Flatpak app's files are at /app inside its sandbox
        inside = "/app/" + lib.split("/files/", 1)[1]
    return lib, inside


def run_monado(mode, flatpak_app=None):
    """Run MONADO_CODE in `mode` ("recenter" or "status"); returns its last line of output, or ""."""
    lib, inside = libmonado()
    if not lib or not os.path.isfile(lib):
        return ""
    answer = ""
    try:                                   # on the desktop side first: quickest
        answer = subprocess.run([sys.executable, "-I", "-c", MONADO_CODE, lib, mode], capture_output=True,
                                text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if not answer and inside and flatpak_app:   # the library needs the runtime's own system libraries
        try:
            answer = subprocess.run(["flatpak", "run", "--command=python3", flatpak_app, "-I", "-c",
                                     MONADO_CODE, inside, mode], capture_output=True, text=True,
                                    timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return answer.splitlines()[-1] if answer else ""


# ------------------------------------------------------------------ helpers
def tcp_link(port):
    """(round-trip time in ms, peer address) of the headset's TCP connection to `port`, from the
    kernel's own measurement (ss). The headset needs no ping reply for this. (None, None) if no
    headset is connected."""
    try:
        out = subprocess.run(["ss", "-tinH", "state", "established", f"( sport = :{port} )"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    return parse_ss(out)


def parse_ss(out):
    best = (None, None)
    peer = None
    for line in out.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():          # "Recv-Q Send-Q Local:Port Peer:Port"
            fields = line.split()
            peer = fields[-1].rsplit(":", 1)[0].strip("[]") if len(fields) >= 4 else None
            if peer and peer.startswith("::ffff:"):     # an IPv4 address on an IPv6 socket
                peer = peer[7:]
            continue
        m = re.search(r"\brtt:([\d.]+)/", line)
        if m and peer is not None:
            rtt = float(m.group(1))
            if best[0] is None or rtt < best[0]:
                best = (rtt, peer)
    return best


def busctl(*args, timeout=3):
    """Run busctl on the user's session bus with JSON output; returns the parsed answer or None."""
    if not shutil.which("busctl"):
        return None
    try:
        result = subprocess.run(["busctl", "--user", "--json=short", *args], capture_output=True, text=True,
                                timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout) if result.stdout.strip() else {}
    except ValueError:
        return None


def read_settings():
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


# ------------------------------------------------------------------ engines
class Engine:
    """What every streaming engine provides. Units and names are GogglesXR's own."""
    id = ""
    name = ""
    description = ""

    def installed(self):
        return False

    def running(self):
        return False

    # ---- where it is installed, for setting up games (gogglesxr on)
    def root(self):
        """The folder Steam's game containers must be able to see, or None if not installed."""
        return None

    def translator(self):
        """The folder of the OpenVR translator (xrizer) that runs SteamVR games, or None."""
        return None

    def container_paths(self):
        """Paths to share with Steam's game containers (PRESSURE_VESSEL_FILESYSTEMS_RW)."""
        return [self.root()] if self.root() else []

    def server_command(self):
        """The command that starts the streaming server in the background."""
        return []

    def window_command(self):
        """The command that opens the engine's own window, if it has one (else the server)."""
        return self.server_command()

    def install_hint(self):
        return ""

    def quit(self):
        """Stop the running server (used when switching engines)."""
        return False

    def headset(self):
        """The connected headset and the link to it:
        {"engine", "engine_name", "running", "connected", "streaming", "name", "refresh_rate",
         "refresh_rates", "codecs", "bitrate_mbps", "hand_tracking", "eye_tracking", "face_tracking",
         "battery": {"head"|"left"|"right": {"charge": 0-100, "charging": bool}},
         "ping_ms", "connection" ("wifi"/"usb"), "address", "pairing": {"enabled", "pin"},
         "apps": [{"name", "active", "focused", "overlay"}]}
        Missing values are None (or empty), never guessed."""
        return {"engine": self.id, "engine_name": self.name, "running": False, "connected": False,
                "streaming": False, "battery": {}, "apps": [], "pairing": {"enabled": False, "pin": ""}}

    def stream_options(self):
        """Settings for the stream: [{"key", "label", "note", "choices": [(value, label)], "value"}]."""
        return []

    def set_stream_option(self, key, value):
        """-> (ok, message)"""
        return False, f"{self.name} has no setting called {key}"

    def known_headsets(self):
        """Headsets paired with this PC: [{"name", "key", "last_seen"}]"""
        return []

    def enable_pairing(self, seconds=120):
        """Let a new headset pair with this PC. Returns the PIN to type in the headset, or ""."""
        return ""

    def disable_pairing(self):
        pass

    def forget_headset(self, key):
        return False

    def disconnect(self):
        return False

    def recenter(self):
        """-> "OK", "LOCAL-ONLY", "NOT-CONNECTED", "FAILED" or "" (couldn't ask the runtime)"""
        return ""


class WiVRn(Engine):
    id = "wivrn"
    name = "WiVRn"
    description = "Streams to Quest and other standalone headsets over Wi-Fi or a USB cable."
    APP = "io.github.wivrn.wivrn"
    BUS = "io.github.wivrn.Server"
    PATH = "/io/github/wivrn/Server"
    PORT = 9757
    ENCODERS = [("auto", "Automatic"), ("nvenc", "NVIDIA (NVENC)"), ("vaapi", "AMD / Intel (VA-API)"),
                ("vulkan", "Vulkan Video"), ("x264", "Processor (x264, slow)")]
    CODECS = [("auto", "Automatic"), ("h264", "H.264"), ("h265", "H.265 (HEVC)"), ("av1", "AV1")]

    def root(self):
        for base in ("/var/lib/flatpak", os.path.join(HOME, ".local/share/flatpak")):
            d = os.path.join(base, "app", self.APP)        # stable across the Flatpak's updates
            if os.path.isdir(os.path.join(d, "current", "active", "files")):
                return d
        return None

    def installed(self):
        return self.root() is not None

    def translator(self):
        d = self.root()
        x = os.path.join(d, "current", "active", "files", "xrizer") if d else None
        return x if x and os.path.isdir(x) else None

    def server_command(self):
        return ["flatpak", "run", "--command=wivrn-server", self.APP]

    def window_command(self):
        return ["flatpak", "run", self.APP]

    def install_hint(self):
        return "Install it: flatpak install flathub " + self.APP

    def quit(self):
        return busctl("call", self.BUS, self.PATH, self.BUS, "Quit") is not None

    def _props(self):
        reply = busctl("call", self.BUS, self.PATH, "org.freedesktop.DBus.Properties", "GetAll", "s", self.BUS)
        if not reply or not isinstance(reply.get("data"), list) or not reply["data"]:
            return None
        return {k: v.get("data") if isinstance(v, dict) else v for k, v in reply["data"][0].items()}

    def running(self):
        return self._props() is not None

    # ---- configuration (WiVRn's config.json, written through the server when it runs)
    def _config_path(self):
        flatpak = os.path.join(HOME, ".var", "app", self.APP, "config", "wivrn", "config.json")
        return flatpak if self.installed() else os.path.join(CONFIG, "wivrn", "config.json")

    def config(self, props=None):
        props = props if props is not None else self._props()
        text = props.get("JsonConfiguration") if props else None
        if not text:
            try:
                with open(self._config_path(), encoding="utf-8") as f:
                    text = f.read()
            except OSError:
                text = ""
        try:
            data = json.loads(text) if text and text.strip() else {}
            return data if isinstance(data, dict) else {}
        except ValueError:
            return {}

    def write_config(self, data):
        text = json.dumps(data, indent=2)
        if self.running():
            if busctl("set-property", self.BUS, self.PATH, self.BUS, "JsonConfiguration", "s", text) is not None:
                return True
        path = self._config_path()
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".new", "w", encoding="utf-8") as f:
                f.write(text + "\n")
            os.replace(path + ".new", path)
            return True
        except OSError:
            return False

    def stream_options(self):
        cfg = self.config()
        enc = cfg.get("encoder")
        encoder = enc if isinstance(enc, str) else (enc.get("encoder") if isinstance(enc, dict) else None)
        codec = enc.get("codec") if isinstance(enc, dict) else None
        return [
            {"key": "encoder", "label": "Video encoder", "choices": self.ENCODERS, "value": encoder or "auto",
             "note": "What turns the game's picture into video for the headset. Automatic picks your graphics card's encoder."},
            {"key": "codec", "label": "Video codec", "choices": self.CODECS, "value": codec or "auto",
             "note": "H.265 and AV1 look better at the same bitrate; H.264 is the most compatible. Quest 1 has no AV1."},
            {"key": "bit_depth", "label": "Colour depth", "choices": [("auto", "Automatic"), ("8", "8-bit"), ("10", "10-bit")],
             "value": str(cfg["bit-depth"]) if "bit-depth" in cfg else "auto",
             "note": "10-bit removes banding in dark scenes. Needs H.265 or AV1 and a hardware encoder."},
            {"key": "connection", "label": "Connection", "choices": [("auto", "Wi-Fi (automatic)"), ("tcp", "Reliable (TCP only)")],
             "value": "tcp" if cfg.get("tcp-only") else "auto",
             "note": "Reliable mode avoids broken frames on a poor connection at the cost of some delay. Also used for USB cable."},
            {"key": "lighthouse", "label": "Lighthouse controllers",
             "choices": [("off", "Off"), ("on", "Use SteamVR's Lighthouse driver")],
             "value": "on" if cfg.get("use-steamvr-lh") else "off",
             "note": "Track Index or Vive controllers and trackers with base stations while you wear a standalone headset."},
        ]

    def set_stream_option(self, key, value):
        cfg = self.config()
        enc = cfg.get("encoder")
        enc = {"encoder": enc} if isinstance(enc, str) else (dict(enc) if isinstance(enc, dict) else {})
        if key in ("encoder", "codec"):
            if value == "auto":
                enc.pop(key, None)
            else:
                enc[key] = value
            if enc:
                cfg["encoder"] = enc
            else:
                cfg.pop("encoder", None)
        elif key == "bit_depth":
            if value == "auto":
                cfg.pop("bit-depth", None)
            else:
                cfg["bit-depth"] = int(value)
        elif key == "connection":
            if value == "tcp":
                cfg["tcp-only"] = True
            else:
                cfg.pop("tcp-only", None)
        elif key == "lighthouse":
            if value == "on":
                cfg["use-steamvr-lh"] = True
            else:
                cfg.pop("use-steamvr-lh", None)
        else:
            return super().set_stream_option(key, value)
        if not self.write_config(cfg):
            return False, "Couldn't save the streaming settings"
        return True, "Saved. Takes effect the next time the headset connects."

    # ---- the headset
    def headset(self):
        info = super().headset()
        props = self._props()
        if props is None:
            return info
        info["running"] = True
        info["connected"] = bool(props.get("HeadsetConnected"))
        info["streaming"] = bool(props.get("SessionRunning"))
        info["pairing"] = {"enabled": bool(props.get("PairingEnabled")), "pin": str(props.get("Pin") or "")}
        if not info["connected"]:
            return info
        name = str(props.get("SystemName") or "")
        info["name"] = name[:-len(" on WiVRn")] if name.endswith(" on WiVRn") else name
        rate = props.get("PreferredRefreshRate")
        info["refresh_rate"] = float(rate) if isinstance(rate, (int, float)) and rate > 0 else None
        info["refresh_rates"] = [float(r) for r in props.get("AvailableRefreshRates") or [] if isinstance(r, (int, float))]
        info["codecs"] = [str(c) for c in props.get("SupportedCodecs") or []]
        bitrate = props.get("Bitrate")
        info["bitrate_mbps"] = round(bitrate / 1e6, 1) if isinstance(bitrate, (int, float)) and bitrate > 0 else None
        for key, prop in (("hand_tracking", "HandTracking"), ("eye_tracking", "EyeGaze"), ("face_tracking", "FaceTracking")):
            info[key] = bool(props.get(prop))
        port = self.config(props).get("port", self.PORT)
        ping, address = tcp_link(port)
        info["ping_ms"] = round(ping, 1) if ping is not None else None
        info["address"] = address
        info["connection"] = None if address is None else ("usb" if address in ("127.0.0.1", "::1") else "wifi")
        status = run_monado("status", self.APP)
        try:
            data = json.loads(status) if status.startswith("{") else {}
        except ValueError:
            data = {}
        info["battery"] = data.get("battery", {})
        info["apps"] = data.get("apps", [])
        return info

    def known_headsets(self):
        props = self._props() or {}
        out = []
        for entry in props.get("KnownKeys") or []:
            if isinstance(entry, list) and len(entry) >= 3:
                out.append({"name": str(entry[0]), "key": str(entry[1]), "last_seen": int(entry[2] or 0)})
        return out

    def enable_pairing(self, seconds=120):
        reply = busctl("call", self.BUS, self.PATH, self.BUS, "EnablePairing", "i", str(int(seconds)))
        data = reply.get("data") if isinstance(reply, dict) else None
        return str(data[0]) if data else ""

    def disable_pairing(self):
        busctl("call", self.BUS, self.PATH, self.BUS, "DisablePairing")

    def forget_headset(self, key):
        return busctl("call", self.BUS, self.PATH, self.BUS, "RevokeKey", "s", key) is not None

    def disconnect(self):
        return busctl("call", self.BUS, self.PATH, self.BUS, "Disconnect") is not None

    def recenter(self):
        return run_monado("recenter", self.APP)


class GogglesLink(WiVRn):
    """Goggles Link: GogglesXR's own link software (github.com/jamoijyt/goggles-link), a fork of
    WiVRn built for Goggles OS and installed without a Flatpak in /opt/goggles-link. Its headset
    app is "Goggles Link". Inside, the server keeps WiVRn's names for now (the wivrn-server
    program, its D-Bus name and its ~/.config/wivrn folder), so everything WiVRn's class does
    over D-Bus works unchanged; only where it lives and how it starts differ."""
    id = "goggleslink"
    name = "Goggles Link"
    description = "GogglesXR's own streaming, built for Goggles OS. Uses the Goggles Link app on the headset."
    APP = None                             # not a Flatpak
    ROOT = os.environ.get("GOGGLES_LINK_ROOT") or "/opt/goggles-link"
    APK = "/usr/share/gogglesos/goggles-link.apk"

    def root(self):
        return self.ROOT if os.access(os.path.join(self.ROOT, "bin", "wivrn-server"), os.X_OK) else None

    def translator(self):
        x = os.path.join(self.ROOT, "xrizer")
        return x if os.path.isdir(x) else None

    def container_paths(self):
        # Not in a Flatpak, so the games' containers also need the runtime's socket
        return [os.path.join(RUNTIME_DIR, "wivrn", "comp_ipc"), self.ROOT] if self.root() else []

    def server_command(self):
        return [os.path.join(self.ROOT, "bin", "wivrn-server")]

    def window_command(self):
        return self.server_command()       # no window of its own: the GogglesXR app is its window

    def install_hint(self):
        return "Goggles Link isn't installed. Update Goggles OS (Goggles Update)."

    def version(self):
        try:
            with open(os.path.join(self.ROOT, "VERSION"), encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return ""

    def _config_path(self):
        return os.path.join(CONFIG, "wivrn", "config.json")


ENGINES = {cls.id: cls for cls in (WiVRn, GogglesLink)}


def current():
    """The engine chosen in the settings ("engine"). If that one isn't installed but another is,
    the installed one is used, so a missing engine never leaves VR without a runtime."""
    if os.environ.get("GOGGLESXR_FAKE_HEADSET"):
        return Fake()
    wanted = ENGINES.get(str(read_settings().get("engine", "wivrn")), WiVRn)()
    if wanted.installed():
        return wanted
    for cls in ENGINES.values():
        if cls().installed():
            return cls()
    return wanted


class Fake(WiVRn):
    """For testing without a headset: GOGGLESXR_FAKE_HEADSET holds the headset() answer as JSON."""

    def headset(self):
        info = Engine.headset(self)
        try:
            info.update(json.loads(os.environ.get("GOGGLESXR_FAKE_HEADSET", "{}")))
        except ValueError:
            pass
        return info

    def running(self):
        return True

    def known_headsets(self):
        return [{"name": "Quest 3", "key": "test-key", "last_seen": 1794580000}]

    def enable_pairing(self, seconds=120):
        return "123456"
