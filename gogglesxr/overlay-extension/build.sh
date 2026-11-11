#!/bin/bash
# Rebuild gogglesxr/dashboard/bin/libgogglesxr_overlay.linux.x86_64.so. Needs only gcc.
# The built library is committed to the repository so the ISO build and Goggles Update
# don't need a compiler. Rebuild it after changing overlay.c.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../dashboard/bin
gcc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -Wno-cast-function-type -fPIC -shared -fvisibility=hidden \
  -Wl,--no-undefined -Wl,--build-id=none -Iinclude \
  -o ../dashboard/bin/libgogglesxr_overlay.linux.x86_64.so overlay.c
strip ../dashboard/bin/libgogglesxr_overlay.linux.x86_64.so
ls -l ../dashboard/bin/
