# Goggles OS roadmap

Status key: ✅ done · 🔨 in progress · 📋 planned · ⚠️ limited / needs a workaround · ❓ needs research

---

## Phase 0 — Bootable distro ✅

- Kubuntu 26.04.1 remaster with Secure Boot, live session and Calamares installer
- Branding: boot splash, welcome screen, login, desktop, installer slides, About page
- NVIDIA 580 (GTX 900–RTX 40) + Mesa (AMD/Intel), low-latency kernel options, gaming sysctls
- Steam, OBS, Discord, GameMode, MangoHud, Protontricks, ProtonUp-Qt
- Goggles VR Setup (SteamVR async-reprojection fix)
- Test tooling: Hyper-V VM script, QEMU script

## Phase 1 — Look & feel + VR setup 🔨 (current build)

| Item | Status | Notes |
|---|---|---|
| **Glass** mode (default) | 🔨 | Kvantum "GogglesGlass" theme: translucent, blurred windows and menus; KWin blur, background contrast and translucency effects; floating translucent panel; green accent |
| **Lite** mode | 🔨 | Breeze, opaque windows and panel, no blur, quicker animations |
| Glass/Lite choice in the installer | 🔨 | New "Appearance" page in Calamares; switch later with **Goggles Appearance** (`goggles-theme glass\|lite`) |
| Rounded corners | 🔨 | KDE-Rounded-Corners from its author's PPA (14 px corners, soft green outline on the active window). The PPA is rebuilt for each KWin update, so installed systems keep working |
| Animations | 🔨 | Scale open/close, Magic Lamp minimise, sliding popups, 0.85× duration (Lite: 0.6×) |
| Remove Kubuntu desktop links | 🔨 | |
| SteamVR pre-installed | ⚠️ | **Not possible on the ISO.** SteamVR is only distributed through Steam and needs a Steam login. Instead: an **Install SteamVR** app and a prompt in Goggles VR Setup open Steam's installer (`steam://install/250820`) |

---

## Target headsets

The headsets used for testing. Each one has a supported route into SteamVR, so Goggles Home and games behave the same on all of them.

| Headset | Route into SteamVR | Phase | Status |
|---|---|---|---|
| HTC Vive (Vive wands, Index controllers) | Native SteamVR Lighthouse driver; udev rules from `steam-devices` | 0–1 | ✅ expected to work, needs a test pass on Goggles OS |
| Steam Frame | Valve's **Steam Link** over local Wi-Fi (main route). The Steam Frame wireless adapter is optional; its Linux setup is still unreliable | 1 | ❓ verify Steam Link streaming to the Frame works out of the box on Goggles OS; the adapter is a later extra |
| Meta Quest 3 | **Goggles Link** | 3 | 📋 |
| Meta Quest 2 | **Goggles Link** | 3 | 📋 |
| Oculus Quest 1 | **Goggles Link** (lower-resolution profile) | 3 | 📋 Meta has ended Quest 1 updates, so the client must stay on toolchain/OpenXR versions that still run on it |
| Oculus Rift CV1 | Monado + its SteamVR driver plugin | 4 | 📋 ❓ |

---

## Phase 2 — Goggles Home (custom VR shell) 📋

**Goal:** a Goggles home space you land in when the headset starts. Launching a game hands over to it; quitting the game brings you back to Goggles Home.

**Feasibility: yes, with one limit.**
- You **can** replace the *SteamVR Home environment* (SteamVR lets you disable its Home and run your own scene app). You can also add your own in-VR menu as a dashboard overlay.
- You **can't** fully remove *SteamVR's own system dashboard* (the system/menu button). It's part of SteamVR's compositor. Goggles Home sits alongside it, the same way OVR Toolkit and XSOverlay do.

**How it works**

```
goggles-vr-session (supervisor service)
  ├─ starts SteamVR with SteamVR Home disabled
  ├─ launches Goggles Home (OpenXR scene app)
  ├─ user picks a game → steam://rungameid/<id> → SteamVR switches scene app
  └─ watches the scene app; when the game exits → relaunches Goggles Home
```

- **Library:** read installed games straight from Steam's `appmanifest_*.acf` files and cached artwork. No Steam API key is needed.
- **Engine: Godot 4 (decided).** It has native Linux OpenXR support and is free. Unity's OpenXR plugin doesn't officially support Linux standalone builds.
- **Milestones:**
  1. OpenXR "hello room" running under SteamVR on Goggles OS
  2. Game grid from local Steam library + launch
  3. Supervisor: return-to-home after a game exits
  4. Overlay menu (volume, Wi-Fi, recentre, quit to desktop)
  5. Environments and themes (match Glass/Lite)

## Phase 3 — Goggles Link (Quest streaming) 📋

**Goal:** stream SteamVR to Quest 1, 2 and 3 over Wi-Fi (and USB). It has to connect every time and need almost no setup. Goggles Link is a **new app built for Goggles OS**, not a rebrand of ALVR or WiVRn. Both of those fail to connect to these headsets on every distro tried, and they're clunky to set up.

**Feasibility: yes, but it's the biggest item**: months of work for one person.

### Why ALVR and WiVRn probably fail here

Both tools find the PC with **local discovery** (multicast/broadcast: mDNS, UDP broadcast). The test network is a **TP-Link RE200 (AC750) range extender** on 5 GHz Wi-Fi 5, with the PC wired to its Ethernet port and the headset on its Wi-Fi. The link itself is fine: it carries VR streaming without trouble. But in *range extender* (repeater) mode, extenders like this rewrite client MAC addresses and often filter or drop multicast traffic, which silently breaks that discovery. The same setup works on Windows with Air Link / Virtual Desktop, which find the PC through the user's account rather than local multicast. **This is the leading theory, not confirmed.** The Goggles Link network check (below) will confirm or rule it out.

Quick checks before any code is written:
- **Extender mode:** open the RE200's web page and look at *Operation Mode*. If it's in Range Extender mode and offers Access Point mode, try ALVR once in Access Point mode (the extender's Ethernet cable must then go to the router, not to the PC). If ALVR suddenly connects, the theory is confirmed.
- **Steam Link to the Steam Frame:** if it streams fine on Goggles OS over the same extender, Linux and the network can carry VR streaming, which narrows the ALVR/WiVRn problem down to discovery and pairing.

### Design rules

1. **Never depend on multicast.** Pair once over **USB** (adb) or by **QR code / PIN**; the headset then remembers the PC's address and connects with direct (unicast) packets. mDNS is only a convenience, never the only path.
2. **Built-in network check.** One button reports what's in the way: discovery, firewall, Wi-Fi band and link speed, packet loss, jitter. It says the fix in plain words.
3. **USB mode** as a fallback that always works (adb port forwarding over the Quest cable).
4. **Per-headset profiles**, picked automatically: Quest 1 (Snapdragon 835, lower resolution and bitrate), Quest 2, Quest 3.
5. **OS-level fixes ship with Goggles OS**: firewall rules, NVENC/VAAPI libraries, the SteamVR driver pre-registered, and a tuned Wi-Fi power-save setting.

### Pieces

| Piece | Where | Tech |
|---|---|---|
| Headset client | Quest (Android) | Native C++: OpenXR, MediaCodec hardware decode, pose sending, timewarp. Sideloaded at first (developer mode) |
| PC driver | SteamVR | OpenVR driver API: exposes a virtual HMD and controllers to SteamVR |
| Encoder | PC | NVENC (NVIDIA; GTX 1080 does H.264/HEVC, no AV1) / VAAPI (AMD) via FFmpeg |
| Transport | both | UDP, forward error correction, adaptive bitrate, clock sync |
| Pairing | both | USB (adb) and QR/PIN pairing, remembered PC address, unicast reconnect |
| Latency | both | Pose prediction + headset-side timewarp |

### Network baseline

Design for the **current setup**: the RE200's 5 GHz Wi-Fi 5 radio (single stream, 433 Mbps link rate, usually about 200 Mbps of real throughput), extender in the same room, PC wired to it. Plan on about 100–150 Mbps of video bitrate on that link, with a latency target under 50 ms motion-to-photon. Wi-Fi 6/6E is a bonus, not a requirement. Quest 1 and Quest 2 can't use 6 GHz anyway; Quest 3 can.

Goggles Link targets the extender. The Steam Frame wireless adapter is not part of the plan: its Linux setup is still unreliable, and the Frame streams fine over normal Wi-Fi with Steam Link anyway.

### Milestones

1. **Network check tool first.** Run it on the current setup to confirm why ALVR/WiVRn can't connect.
2. USB mode: video + tracking working over the cable on Quest 2/3.
3. Wi-Fi with USB/QR pairing and unicast reconnect.
4. Adaptive bitrate, FEC, per-headset profiles (including Quest 1).
5. Hand off to Goggles Home so the Quest lands straight in the shell.

ALVR's code (MIT licence) can still be reused piece by piece (for example the SteamVR driver or encoder setup) where it saves time, but the product, pairing flow and UX are Goggles Link's own.

## Phase 4 — Legacy headsets: Oculus Rift CV1 📋 ❓

A CV1 is available for testing.

**Feasibility: partly.** Meta's Rift runtime is Windows-only and discontinued, so Linux support comes from community drivers:

- **OpenHMD / Monado** drive the CV1 display and IMU. Rotation-only (3DoF) is the dependable part.
- **Full 6DoF** (constellation camera tracking + Touch controllers) relies on Jan Schmidt's reverse-engineering work. **Its current maturity needs checking** before committing.
- **Route into SteamVR:** Monado's SteamVR driver plugin exposes Monado devices to SteamVR, so CV1 games and Goggles Home use the same path as every other headset.
- **Display:** the kernel already treats the CV1 as a "non-desktop" HMD, so DRM leasing works.

## Phase 5 — Everyday apps 📋

| App | Native Linux? | Plan |
|---|---|---|
| Claude | Claude Desktop isn't on Linux; Claude Code (CLI) is | Ship a **claude.ai web app** (installable, own window and icon) plus Claude Code. Unofficial repackages of the Windows app can't be bundled (licence) |
| CapCut | No (Windows/macOS only); Wine is unreliable | Ship the **CapCut web editor** as a web app; suggest **Kdenlive** (installed on request) or **DaVinci Resolve** (works well on NVIDIA) |
| Others | — | Same rule: **ship launchers or installers that fetch from the official source**, never redistribute closed binaries in the ISO |

## Phase 6 — Distro infrastructure 📋

- **Package Goggles tools as .debs in a Goggles PPA** (theme, VR setup, Home, Link). Installed systems then get updates through normal system updates, instead of only from new ISOs
- Separate ISOs: `nvidia` (580, GTX 900–RTX 40), `nvidia-open` (RTX 50), `amd` (smaller)
- Automated builds (GitHub Actions or a build box) + Hyper-V smoke test
- ✅ Website and download page (GitHub Pages, `docs/`); `DISTRO_URL` in `config.sh` points to it

---

## Decisions

| Question | Answer |
|---|---|
| Test headsets | Rift CV1, HTC Vive (Vive wands + Index controllers), Quest 1, Quest 2, Quest 3, Steam Frame |
| ALVR / WiVRn | They don't connect to these headsets on any distro tried, and work only briefly when they do. They're also clunky to set up. Build **Goggles Link** as Goggles OS's own app |
| Goggles Home engine | Godot 4 |
| Wi-Fi | TP-Link RE200 (AC750) extender on 5 GHz in the play room, PC wired to it by Ethernet. Works fine for VR streaming (Air Link / Virtual Desktop on Windows) |
| Steam Frame | Streams with Steam Link over the same local Wi-Fi. The wireless adapter works but its Linux setup is unreliable, so it's optional |

## Open questions

1. Is the RE200 in *Range Extender* or *Access Point* mode? It's shown under *Operation Mode* on the extender's web page. See the quick checks under Phase 3.
