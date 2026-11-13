#!/bin/bash
# Rebuild libgogglesxr_capture.so, the GogglesXR capture layer. Needs gcc and the Vulkan
# headers (libvulkan-dev). The built library is committed to the repository so the ISO build
# and Goggles Update don't need a compiler. Rebuild it after changing capture.c.
#
# It is linked against glibc 2.2.5-era symbol versions (see the .symver lines in capture.c), so
# it also loads inside Steam's game containers, which have an older glibc than Goggles OS.
# The check at the end fails the build if anything newer than glibc 2.17 slipped in.
set -euo pipefail
cd "$(dirname "$0")"
out=libgogglesxr_capture.so
gcc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -fPIC -shared -fvisibility=hidden \
  -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
  -Wl,--no-undefined -Wl,--build-id=none -Iinclude \
  -o "$out" capture.c -lvulkan -lm -Wl,--no-as-needed -l:libpthread.so.0
strip "$out"
newest=$(objdump -T "$out" | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -n1)
echo "newest glibc symbol: $newest"
if [ "$(printf '%s\nGLIBC_2.17\n' "$newest" | sort -V | tail -n1)" != GLIBC_2.17 ]; then
  echo "error: $out needs $newest; Steam's containers may not have it" >&2
  objdump -T "$out" | grep "$newest" >&2
  exit 1
fi
ls -l "$out"
