# GogglesXR desktop view and control helpers

`gogglesxr-desktop-grab` gives the dashboard live pictures of the desktop for its Desktop panel
and floating screens. It asks KWin (KDE Plasma's compositor) for a picture through
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

Needs gcc and the GLib/GIO headers (`libglib2.0-dev`; the input helper only needs the kernel headers). The built programs are committed, so the ISO
build and Goggles Update don't need a compiler.

Try it without the dashboard (writes one picture, then stops):

```bash
./gogglesxr-desktop-grab --out /tmp/desktop.raw --once
```

`--test-pattern` draws moving stripes instead of asking KWin, for testing without Plasma.

Pictures identical to the last one aren't written, and while the desktop stays still the helper
asks only five times a second.

## Using the desktop from the headset

`gogglesxr-desktop-input` makes a virtual pointer and keyboard ("GogglesXR pointer", "GogglesXR
keyboard") through the kernel's uinput device, and moves them as the dashboard tells it on
standard input, one command per line:

| Command | Meaning |
|---|---|
| `m X Y` | pointer to X, Y across the whole desktop (0 to 65535 each) |
| `b N D` | button N (0 left, 1 right, 2 middle) down (1) or up (0) |
| `w DY [DX]` | wheel by DY clicks (up is positive), DX sideways |
| `k CODE D` | Linux key code (`linux/input-event-codes.h`) down or up |

It prints `ready`, or `error: ...` and stops. When its input closes, or the dashboard goes away,
it lets go of every key and button and removes the devices. `/dev/uinput` is opened for the
logged-in user by `overlay/etc/udev/rules.d/60-gogglesxr-uinput.rules` (log out and in once after
the first install). `--print` writes the events instead of making devices, for testing:

```bash
printf 'm 32768 32768\nb 0 1\nb 0 0\nk 30 1\nk 30 0\n' | ./gogglesxr-desktop-input --print
```
