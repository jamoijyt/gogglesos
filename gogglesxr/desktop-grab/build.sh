#!/bin/bash
# Rebuild gogglesxr-desktop-grab (the desktop view's picture taker) and gogglesxr-desktop-input
# (its mouse and keyboard). Needs gcc and the GLib/GIO
# headers (libglib2.0-dev). The built program is committed to the repository so the ISO build and
# Goggles Update don't need a compiler. Rebuild it after changing desktop_grab.c.
set -euo pipefail
cd "$(dirname "$0")"
out=gogglesxr-desktop-grab
# shellcheck disable=SC2046
gcc -std=c11 -O2 -Wall -Wextra -Werror -Wl,--build-id=none -o "$out" desktop_grab.c \
  $(pkg-config --cflags --libs gio-unix-2.0) -lpthread
strip "$out"
# The mouse and keyboard side: plain C, no libraries
gcc -std=c11 -O2 -Wall -Wextra -Werror -Wl,--build-id=none -o gogglesxr-desktop-input desktop_input.c
strip gogglesxr-desktop-input
ls -l "$out" gogglesxr-desktop-input
