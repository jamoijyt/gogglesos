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
- **Engine:** **Godot 4** is recommended. It has native Linux OpenXR support and is free. Unity's OpenXR plugin doesn't officially support Linux standalone builds, so Unity would be a risk here. StereoKit (C#) is a lighter alternative.
- **Milestones:**
  1. OpenXR "hello room" running under SteamVR on Goggles OS
  2. Game grid from local Steam library + launch
  3. Supervisor: return-to-home after a game exits
  4. Overlay menu (volume, Wi-Fi, recentre, quit to desktop)
  5. Environments and themes (match Glass/Lite)

## Phase 3 — Goggles Link (Quest streaming) 📋

**Goal:** stream SteamVR to Quest headsets over Wi-Fi (and USB), reliably on Goggles OS.

**Feasibility: yes, but it's the biggest item**: months of work for one person. The required pieces:

| Piece | Where | Tech |
|---|---|---|
| Headset client | Quest (Android) | OpenXR, MediaCodec hardware decode, pose sending, reprojection (sideloaded, or via the Meta store) |
| PC driver | SteamVR | OpenVR driver API: exposes a virtual HMD and controllers to SteamVR |
| Encoder | PC | NVENC (NVIDIA; GTX 1080 does H.264/HEVC, no AV1) / VAAPI (AMD) via FFmpeg |
| Transport | both | UDP, forward error correction, adaptive bitrate, clock sync |
| Latency | both | Pose prediction + headset-side timewarp; target < 40 ms motion-to-photon on Wi-Fi 6 |

**Recommended path**
1. **Diagnose first.** Find out exactly why ALVR and WiVRn fail on your setup (logs and errors). Some causes are fixable at the OS level: firewall ports, mDNS/Avahi discovery, missing NVENC libraries, Wayland DRM leasing. Goggles OS can ship those fixes regardless.
2. **Then build Goggles Link.** Starting from ALVR's codebase (MIT licence) saves months over a blank slate. You still own the product, branding and UX.
3. Pair it with Goggles Home so the Quest lands straight in your shell.

## Phase 4 — Legacy headsets: Oculus Rift CV1 📋 ❓

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
- Website and download page; replace the `DISTRO_URL` placeholder in `config.sh`

---

## Open questions

1. Which headsets do you own and test with (Index, Vive, Quest 2/3/Pro, CV1)?
2. What exactly goes wrong with ALVR and WiVRn on your PC (error message or behaviour)?
3. Godot vs Unity for Goggles Home: are you happy to use Godot, given Unity's limited Linux OpenXR support?
4. Wi-Fi setup for Quest streaming (router model, Wi-Fi 5/6/6E, PC wired?)
