# GogglesXR desktop view helper

`gogglesxr-desktop-grab` gives the dashboard live pictures of the desktop for its Desktop panel
and big screen. It asks KWin (KDE Plasma's compositor) for a picture through
`org.kde.KWin.ScreenShot2` several times a second, shrinks it to fit (1920 pixels wide at most)
and writes it to a file in the runtime folder, which the dashboard reads (`desktop_view.gd`).

KWin only answers programs listed for that interface in a desktop file:
`overlay/usr/share/applications/org.gogglesos.gogglesxr-desktop-grab.desktop`
(`X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2`). That is why it is a small program
of its own, and why nothing asks for permission while you wear the headset. After the first
install, log out and back in once so Plasma reads the new desktop file.

```bash
./build.sh
```

Needs gcc and the GLib/GIO headers (`libglib2.0-dev`). The built program is committed, so the ISO
build and Goggles Update don't need a compiler.

Try it without the dashboard (writes one picture, then stops):

```bash
./gogglesxr-desktop-grab --out /tmp/desktop.raw --once
```

`--test-pattern` draws moving stripes instead of asking KWin, for testing without Plasma.
