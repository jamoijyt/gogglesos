# Goggles OS roadmap

Status key: ✅ done · 🔨 in progress · 📋 planned · ⚠️ limited / needs a workaround · ❓ needs research

---

## Phase 0 — Bootable distro ✅

- Kubuntu 26.04.1 remaster with Secure Boot, live session and Calamares installer
- Branding: boot splash, welcome screen, login, desktop, installer slides, About page
- NVIDIA 580 (GTX 900–RTX 40) + Mesa (AMD/Intel), low-latency kernel options, gaming sysctls
- Steam, OBS, Discord, GameMode, MangoHud, Protontricks, ProtonUp-Qt
- VR basics: Steam and headset udev rules. (The first builds also had a SteamVR setup helper; GogglesXR has replaced it)
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
| VR runtime | ✅ | GogglesXR is preinstalled and set up by the OS (see Phase 2). The earlier SteamVR-based setup (Install SteamVR, Goggles VR Setup) has been removed |

---

## Target headsets

The headsets used for testing, and how each one reaches games.

| Headset | Route | Phase | Status |
|---|---|---|---|
| HTC Vive (Vive wands, Index controllers) | Planned through **GogglesXR** (Monado has a Lighthouse driver). Until then SteamVR can be installed from Steam by hand, with *Send SteamVR games to GogglesXR* switched off | 4 | 📋 ❓ wired headsets are not set up by Goggles OS yet |
| Meta Quest 3 | **GogglesXR** streaming (Goggles Link) | 2 | 📋 |
| Meta Quest 2 | **GogglesXR** streaming (Goggles Link) | 2 | 📋 |
| Oculus Quest 1 | **GogglesXR** streaming, lower-resolution profile | 2 | 📋 Meta has ended Quest 1 updates, so the headset app must stay on toolchain/OpenXR versions that still run on it |
| Steam Frame | Valve's Steam Link today; **GogglesXR** if a client can be installed on it | 2 | ⚠️ Steam Link VR currently crashes on GTX 10-series cards with the NVIDIA 580 driver (see below) |
| Oculus Rift CV1 | Monado driver, through GogglesXR | 4 | 📋 ❓ |

> [!WARNING]
> **Steam Link VR is broken upstream on GTX 10-series cards.** On the test PC (GTX 1080, NVIDIA 580.178.04), SteamVR's compositor crashes as soon as a Quest or Steam Frame connects through Steam Link. Other GTX 1060/1070/1080 owners report the same on other distros: [SteamVR-for-Linux #1005](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/1005), [#1017](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/1017). There is no fix yet. This is the main reason GogglesXR is its own runtime and does not go through SteamVR.

---

## Phase 2 — GogglesXR (Goggles OS's own VR runtime) 📋

**Goal:** Goggles OS has its own OpenXR runtime, **GogglesXR**. It streams to standalone headsets, runs SteamVR games, and has its own dashboard and (later) home space. It does not depend on SteamVR's compositor.

**Feasibility: yes, but it is the biggest item on the roadmap**: many months of work for one person. The plan below keeps it realistic by building on existing open-source pieces.

### Hard requirements

1. **SteamVR games must work.** If WiVRn can run them, so can GogglesXR.
2. **Its own dashboard**, in the Goggles Glass style (below). WiVRn has none of its own.
3. **Its own home application** to launch games from. Later: the dashboard comes first.
4. **Simple.** Preinstalled, nothing to set up on the PC, pair the headset once.

### How it fits together

```
 SteamVR (OpenVR) game ──► OpenVR-to-OpenXR translation ─┐
 OpenXR game ────────────────────────────────────────────┤
 Goggles dashboard / Goggles Home (OpenXR apps) ─────────┤
                                                         ▼
                                    GogglesXR runtime (compositor, tracking)
                                                         │
                             video encode ──► network ──► headset app (Quest)
                             ◄── poses, controller input ◄──
```

| Piece | Plan |
|---|---|
| Runtime core | Build on **Monado**, the open-source OpenXR runtime (Boost licence). It already provides the OpenXR API, compositor and driver framework. WiVRn is built the same way. Writing a runtime from nothing would add years |
| SteamVR games | An **OpenVR-to-OpenXR translation layer** (xrizer or OpenComposite), the same approach WiVRn uses. Goggles OS registers it as the system's OpenVR runtime, and exposes the runtime inside Steam's game containers, so games launched from Steam find it without any setup |
| Streaming ("Goggles Link") | GogglesXR's streaming part: video encode on the PC (NVENC on NVIDIA, VAAPI on AMD), UDP transport with error correction and adaptive bitrate, and a headset app that decodes, sends poses and reprojects. WiVRn (GPL-3.0, compatible with this repo) and ALVR (MIT) are references and possible code sources |
| Headset app | Native Android app for Quest 1/2/3 (OpenXR, hardware decode). Installed from the PC over USB with one button; pairing happens in the same step |
| Dashboard | An overlay drawn by the runtime on top of the running game. Design below |
| Goggles Home | The space you land in when no game is running. Godot 4 (OpenXR app). After the dashboard |
| PC app | Small Qt/KDE app: status, *Install to headset*, connection check, quality |

### Experience rules

1. **Nothing to install or set up on the PC.** GogglesXR ships with Goggles OS: runtime registered for OpenXR and OpenVR, encoder libraries present, firewall rules in place.
2. **Headset app installed from the PC.** Plug the Quest in once and press *Install to headset*.
3. **Pair once, then automatic.** After that the headset finds the PC and connects on its own.
4. **Can't break itself.** GogglesXR checks its own setup on start and repairs it. PC and headset apps update together through Goggles Update.
5. **Errors in plain words**, with the fix. USB mode as a fallback.
6. **Per-headset profiles**, picked automatically.

### Dashboard design: five panels

Pressing the dashboard button brings up one glass panel in front of you, with a status strip under it. There are five panels, laid out like a plus sign with the current game in the middle:

```
                 ┌────────────────┐
                 │ Quick Settings │
┌───────────────┬┴────────────────┴┬───────────────┐
│ Full Settings │   Current Game   │    Library    │
└───────────────┴┬────────────────┬┴───────────────┘
                 │    Desktop     │
                 └────────────────┘
```

- **Moving between panels:** hold **grip** and swipe the panel like a card. The card follows your hand, so sliding it down reveals the panel above, and sliding it left reveals the panel on the right. Every move goes through the centre. Example, Desktop to Library: slide top to bottom (Current Game appears), then slide right to left (Library appears).
- **Using a panel:** like any dashboard. Point with the laser, click with the trigger, scroll with the stick or trackpad.
- **Finding your way:** small labels on the panel's edges name the panel in each direction, and a five-dot map in the status strip shows where you are.
- **Status strip (under the panel):** time and date, the panel map, headset and controller batteries, stream bitrate and latency, frame rate.
- **Look:** Goggles Glass. Translucent dark panel, the visor line along the top, green accent, lens-style toggles.

| Panel | Contents |
|---|---|
| **Current Game** (centre) | Game art and name, time running, Resume, Recentre, Screenshot, Record clip, Quit game, and live FPS / frame time / GPU load |
| **Quick Settings** (top) | Volume, brightness and render-scale sliders; toggles for mic mute, passthrough, boundary, do not disturb, motion smoothing, stats overlay, night tint; recentre |
| **Desktop** (bottom) | Live view of the PC desktop with the laser as the mouse; screen picker, keyboard, window list, pin a window in the game world |
| **Library** (right) | Grid of installed games (SteamVR and OpenXR) with filters; select one to launch it |
| **Full Settings** (left) | Sections: Display, Streaming, Audio, Controllers, Play area, Appearance, System |

**Try it:** an interactive prototype of the panels and the swipe navigation is on the website at [`/dashboard/`](https://jamoijyt.github.io/gogglesos/dashboard/) (source: `docs/dashboard/index.html`). Drag the panel with the mouse in place of grip + swipe.

### Milestones

1. ✅ **Proof on the test PC.** Done on 10 November 2026: WiVRn (Monado) streamed a VR game to a Quest on the GTX 1080 with head tracking and a stable frame rate, with no sign of the crash that hits Steam Link. See "What the proof showed" below.
2. ✅ **SteamVR games through translation.** Grab VR and Gorilla Tag both ran from Steam on the test PC with working controllers and buttons.
3. ✅ **Seamless setup (GogglesXR v0).** Tested on the test PC on 10 November 2026: games reach the headset with no launch options.
    The `gogglesxr` tool does automatically what took manual troubleshooting in the proof: it keeps the translator first for SteamVR games, lets Steam's game containers see the runtime for the whole session (no launch options), repairs itself when SteamVR changes the file, and reports each link of the chain in plain words. This version uses **WiVRn as its engine**, preinstalled with Goggles OS.
4. **GogglesXR's own runtime build.** Prepared for: the app, the dashboard and the `gogglesxr` command talk to the streaming software only through an engine interface (`engine.py`: headset status, batteries, ping, stream settings, pairing, recentring). WiVRn is the one engine today; **Goggles Link** is listed in VR settings as coming later and only needs the same methods to drop in.
    A Monado-based runtime packaged for Goggles OS under its own name, replacing the WiVRn Flatpak, with its own headset app.
5. 🔨 **Dashboard v1 and desktop app.** The dashboard is built in Godot (`gogglesxr/dashboard`), in two stages:
   - **5a, as a normal VR app (in progress).** The five panels on a floating screen, lasers, trigger to click, stick to scroll, grip + swipe between panels, status strip. Working for real: Library (reads the installed Steam games and launches them), volume, recentre, dashboard size. Hold grip on the status bar to move the dashboard; while holding, the stick sends it further away (bigger) or closer (smaller), and its place is remembered. It runs when no game is running. First headset test on the test PC passed (10 November 2026).
   - **5b, on top of a running game (in progress).** Godot has no overlay support, so a small C extension (`gogglesxr/overlay-extension`) asks the runtime for an overlay session (`XR_EXTX_overlay`). Tested on Monado: the dashboard is drawn over another VR app with that app visible around it. The left controller's menu button shows and hides it. Needs its first test in the headset over a real game. Tested in the headset over real games (11 November 2026). The Current Game panel shows the running game with its cover art and time running, and Resume hides the dashboard. The laser is smoothed (adjustable), and the dashboard animates open and closed. Quit game is connected and tested. Screenshot and Record clip capture **what the headset shows**, not the desktop: a small OpenXR API layer (`gogglesxr/capture-layer`) that VR games load copies the game's own left-eye image on the GPU as the game hands it to the runtime. Screenshots are the full eye image (PNG in Pictures/GogglesXR); recordings are a 16:9 crop around where you look, 1080p at 30 fps with the desktop's sound, encoded by ffmpeg (MP4 in Videos/GogglesXR). It only does work while a capture is asked for, never touches the dashboard, and works for Vulkan games (including Proton and SteamVR games through the translator); games started before GogglesXR set it up need one restart. Recentre counts down 3-2-1 with the dashboard out of the way, then has the runtime move both the seated and the standing/room-scale spaces (the one most SteamVR games use) to where you stand and face, and returns you to the game. Your controllers are drawn with their real models (Quest 1, 2, 3/3S and Pro, Rift CV1, Index, Vive wands; a generic model otherwise) from the WebXR Input Profiles project, with buttons, trigger and stick moving as you press them; the models are downloaded from a pinned, checksum-checked release when the system is installed or updated. Capture, recentring and the controller models were confirmed in the headset on the test PC (13 November 2026). Recordings now have options: shape (16:9, 9:16 upright, 1:1, 4:3), resolution (720p to 1440p), frame rate (30 to 90 fps), quality (automatic or a fixed bitrate), encoder (the graphics card through NVENC or VA-API, tested once per login, with the processor as fallback), H.264 or H.265, sound (game, game and microphone, or none) and how wide a view to keep; screenshots can be the whole view or framed like recordings. The **Desktop panel** shows the PC's desktop live (from KWin's screenshot interface through a small helper, `gogglesxr/desktop-grab`, which KWin allows through a desktop file, so there is no prompt), with a **big screen** that floats a large copy in front of you, also during a game; it is view-only for now. A **home environment** (a 360° picture: Goggles OS's own night scene, your own picture, or black) surrounds you while no game is running and steps aside as soon as one starts drawing. The status strip shows the headset's and both controllers' batteries and the ping. Settings on the dashboard (Recording, Home, Desktop, Streaming) are shared with the desktop app. Tested on Monado and with stand-ins for KWin and WiVRn in the test container; the new parts need their first headset test. Still to do: stop the game also receiving the buttons while the dashboard is open; capture for OpenGL games; using the desktop with the lasers.
   - **Desktop app (in progress).** `gogglesxr app`: status and one-press repair, a game library with Steam cover art and per-game choices (favourite, hide, treat as VR or not, display name), and settings. The Home page shows the connected headset (name, battery of the headset and each controller, ping, stream bitrate, refresh rate, video formats, tracking) and a quick-launch button for the VR game played last. A **VR settings** page has the streaming engine and its options (encoder, codec, colour depth, reliable TCP mode, Lighthouse controllers through SteamVR's driver), pairing a new headset with a PIN and forgetting old ones, the dashboard's options, the home environment (with your own 360° picture), recording options and the desktop view. It starts at login in the system tray (can be switched off), keeps the runtime ready and opens the dashboard when a headset connects. Tested on the test PC. The library detects each game's VR interface from its files and includes non-Steam games added to Steam.
6. **Wi-Fi streaming** with pairing and automatic reconnect; the PC app with *Install to headset*.
7. **Per-headset profiles, adaptive bitrate.**
8. **Goggles Home.**

### What the proof showed

Test on 10 November 2026: GTX 1080, NVIDIA 580.178.04, Quest connected through WiVRn (Flatpak) with the regular `.deb` Steam.

- **Result:** a VR game (Tricky Taggers, a non-Steam game added to Steam) ran in the headset with full head tracking and a stable frame rate. Two Steam games, Grab VR and Gorilla Tag, then ran with working controllers and buttons.
- **It took three manual steps**, which the `gogglesxr` tool now does automatically:
  1. **Put the translation layer first in the OpenVR paths file** (`~/.config/openvr/openvrpaths.vrpath`). SteamVR was listed first, so games went to SteamVR.
  2. **Add launch options to every game** so Steam's game container can see the runtime: `PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1` and `PRESSURE_VESSEL_FILESYSTEMS_RW=<runtime path>`.
  3. **Keep SteamVR from running**, since it can put itself back on top of that file.
- **Not every game can work.** Games that only ship the Oculus interface (`OVRPlugin.dll` and nothing else) never ask for VR through SteamVR or OpenXR, so they stay flat on any Linux runtime. The Library panel should mark these.
- **Desktop Chrome is not a test.** WebXR found no headset in Chrome on Linux even with the runtime working.

### Network baseline

Design for the **current setup**: a TP-Link RE200 (AC750) extender on 5 GHz Wi-Fi 5 (single stream, 433 Mbps link rate, usually about 200 Mbps of real throughput) in the same room, PC wired to it. It already handles VR streaming on Windows. Plan on about 100–150 Mbps of video bitrate, with a latency target under 50 ms motion-to-photon. Wi-Fi 6/6E is a bonus, not a requirement.

### Why not ALVR or WiVRn as they are

ALVR and WiVRn are impressive open-source projects, and plenty of people use them happily. **What follows is my own personal experience** on my own PC, headsets and network, not a verdict on either project. Results depend a lot on hardware and setup.

- **ALVR** works for me on Windows over the same Wi-Fi, but I find it clunky and hard to set up. On Linux I've never got it working. It is also a SteamVR driver, so it goes through the compositor that currently crashes on my card.
- **WiVRn** has been fragile for me. It has broken itself during install or after small changes. It has no dashboard or home of its own.

GogglesXR's aim is the same technology with the setup, updates and interface handled by the OS.

## Phase 3 — Goggles Home 📋

**Goal:** a Goggles home space you land in when the headset connects and no game is running. Launching a game hands over to it; quitting brings you back.

- An OpenXR app running on GogglesXR, built with **Godot 4** (native Linux OpenXR support).
- **Library:** reads installed games straight from Steam's `appmanifest_*.acf` files and cached artwork. No Steam API key is needed. Shares this code with the dashboard's Library panel.
- **Milestones:**
  1. OpenXR "hello room" running on GogglesXR
  2. Game grid and launch (reusing the dashboard's library)
  3. Return to home after a game exits
  4. Environments and themes (match Glass/Lite)

## Phase 4 — Legacy headsets: Oculus Rift CV1 📋 ❓

A CV1 is available for testing.

**Feasibility: partly.** Meta's Rift runtime is Windows-only and discontinued, so Linux support comes from community drivers:

- **OpenHMD / Monado** drive the CV1 display and IMU. Rotation-only (3DoF) is the dependable part.
- **Full 6DoF** (constellation camera tracking + Touch controllers) relies on Jan Schmidt's reverse-engineering work. **Its current maturity needs checking** before committing.
- **Route into games:** GogglesXR is built on Monado, so a CV1 driven by Monado's driver would use the same runtime, dashboard and SteamVR-game translation as every other headset.
- **Display:** the kernel already treats the CV1 as a "non-desktop" HMD, so DRM leasing works.

## Phase 5 — Everyday apps 📋

| App | Native Linux? | Plan |
|---|---|---|
| Claude | Claude Desktop isn't on Linux; Claude Code (CLI) is | Ship a **claude.ai web app** (installable, own window and icon) plus Claude Code. Unofficial repackages of the Windows app can't be bundled (licence) |
| CapCut | No (Windows/macOS only); Wine is unreliable | Ship the **CapCut web editor** as a web app; suggest **Kdenlive** (installed on request) or **DaVinci Resolve** (works well on NVIDIA) |
| Others | — | Same rule: **ship launchers or installers that fetch from the official source**, never redistribute closed binaries in the ISO |

## Phase 6 — Distro infrastructure 📋

- 🔨 **Goggles Update** (`goggles-update`): installed systems get Goggles OS changes from GitHub without a new ISO. Runs the same configuration step as the build (`chroot/apply-system.sh`); `stable` (releases) and `main` channels; daily check with a popup; rollback. Needs a first test on real hardware
- **Package Goggles tools as .debs in a Goggles PPA** (theme, VR setup, GogglesXR, Home), once they're larger apps. Goggles Update covers the desktop setup and small tools until then
- Separate ISOs: `nvidia` (580, GTX 900–RTX 40), `nvidia-open` (RTX 50), `amd` (smaller)
- Automated builds (GitHub Actions or a build box) + Hyper-V smoke test
- ✅ Website and download page (GitHub Pages, `docs/`); `DISTRO_URL` in `config.sh` points to it

---

## Decisions

| Question | Answer |
|---|---|
| Test headsets | Rift CV1, HTC Vive (Vive wands + Index controllers), Quest 1, Quest 2, Quest 3, Steam Frame |
| ALVR / WiVRn | From my own experience only: ALVR works for me on Windows but I find it clunky and hard to set up, and I've never got it working on Linux. WiVRn has broken itself for me during install or after small changes. For me the problem is the software and experience, not the network. Streaming becomes part of **GogglesXR**, Goggles OS's own runtime |
| VR runtime | Goggles OS has its own OpenXR runtime, **GogglesXR**, built on Monado. It must run SteamVR games (OpenVR-to-OpenXR translation, as WiVRn does) |
| Dashboard | Five panels on a plus-shaped layout (Current Game in the centre; Quick Settings above, Desktop below, Library right, Full Settings left), moved by grip + swipe. Dashboard first, Goggles Home later |
| Dashboard and Goggles Home engine | Godot 4. Ubuntu packages only Godot 3, so `gogglesxr dashboard` fetches the official Godot 4 build once (checksum pinned) until the dashboard ships as a built app |
| Wi-Fi | TP-Link RE200 (AC750) extender on 5 GHz in the play room, PC wired to it by Ethernet. Works fine for VR streaming, including ALVR on Windows |
| Screenshots and recordings | Taken from inside the game's own frames by GogglesXR's capture layer (an OpenXR API layer), so they show the headset view. The desktop window of a VR game often shows nothing useful, and the runtime's compositor isn't ours to change while the engine is WiVRn |
| Desktop view | KWin's screenshot interface (`org.kde.KWin.ScreenShot2`), allowed for one small helper through a desktop file, so nothing asks for permission while you are in the headset. The screen-sharing portal would ask on the desktop every time |
| Link software | Everything goes through one engine interface, so GogglesXR's own link software can replace WiVRn without changing the app or the dashboard |
| Controller models | The WebXR Input Profiles models (MIT licence), the same set browsers use for WebXR. Downloaded from a pinned release with checksums instead of kept in the repository (about 25 MB) |
| Steam Frame | Streams with Steam Link over the same local Wi-Fi. The wireless adapter works but its Linux setup is unreliable, so it's optional |

## Open questions

1. Can a third-party streaming client be installed on the Steam Frame?
2. For the dashboard to show over a game: how does the runtime hand controller input to an overlay app while a game has focus? WayVR (wlx-overlay-s) does this on Monado and is the reference.
