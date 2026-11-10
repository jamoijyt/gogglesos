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
| Steam Frame | Valve's own streaming through the **Steam Frame wireless adapter** | 1 | ❓ verify the adapter and pairing work out of the box on Goggles OS; ship any needed udev rules or firmware |
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

Both tools find the PC with **local discovery** (multicast/broadcast: mDNS, UDP broadcast). The test network is a **5 GHz Wi-Fi 5 range extender**, with the PC wired to it by Ethernet and the headset on its Wi-Fi. Many extenders rewrite client MAC addresses and filter or drop multicast traffic, which silently breaks that discovery. The same setup works on Windows with Air Link / Virtual Desktop, which find the PC through the user's account rather than local multicast. **This is the leading theory, not confirmed.** The Goggles Link network check (below) will confirm or rule it out.

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

Design for the **current setup**: Wi-Fi 5 on 5 GHz, extender in the same room, PC wired to it. Plan on about 100–150 Mbps of video bitrate on that link, with a latency target under 50 ms motion-to-photon. Wi-Fi 6/6E is a bonus, not a requirement. Quest 1 and Quest 2 can't use 6 GHz anyway; Quest 3 can.

❓ **Steam Frame wireless adapter:** research whether Linux sees it as a normal Wi-Fi device and whether it can host a link for Quest 3. If it's locked to the Steam Frame, Goggles Link stays on the extender.

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
| Wi-Fi | 5 GHz Wi-Fi 5 extender in the play room, PC wired to it by Ethernet (works fine with Air Link / Virtual Desktop on Windows). Steam Frame wireless adapter also available |

## Open questions

1. What model is the Wi-Fi extender, and is it in *repeater* or *access point* mode? Some extenders have an access point mode that stops them rewriting MAC addresses and passes multicast through.
2. Does the Steam Frame already stream on Goggles OS (or any Linux distro) through its wireless adapter?
