#!/bin/bash
# Boot an ISO in QEMU (UEFI) and save a screenshot every minute.
# Usage: sudo ./test-iso.sh path/to.iso [minutes=20] [shots-dir=./test-shots]
# Env:
#   SHOW=1     open a visible QEMU window (via WSLg on Windows) you can click and type in
#   SHOW=web   show the VM in a browser at http://localhost:6080/vnc.html (noVNC)
#   RAM_MB     guest memory (default 3584; keep it well under WSL's limit)
# Uses KVM when available, otherwise slow software emulation.
set -euo pipefail
ISO="$1"; MINUTES="${2:-20}"; SHOTS="${3:-./test-shots}"
RAM_MB="${RAM_MB:-3584}"
mkdir -p "$SHOTS"
# UEFI firmware as pflash (code read-only + a writable copy of the vars store)
VARS=$(mktemp /tmp/ovmf-vars.XXXX.fd)
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
FW=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
    -drive if=pflash,format=raw,file="$VARS")
# QEMU tries KVM first and falls back to software emulation if KVM is unusable
ACCEL=(-accel kvm -accel tcg,thread=multi -cpu max)
DISP=(-display none)
if [ "${SHOW:-0}" = 1 ]; then
  # WSLg provides DISPLAY/WAYLAND_DISPLAY to user sessions; make sure root sees them too
  export DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
  # WSLg: GTK over Wayland/GL can draw a blank window; X11 without GL is reliable
  export GDK_BACKEND=x11
  DISP=(-display gtk,gl=off,zoom-to-fit=on,show-menubar=on -name "Goggles OS test VM")
elif [ "${SHOW:-0}" = web ]; then
  # VNC on localhost, served to a browser by noVNC: open http://localhost:6080/vnc.html
  DISP=(-display none -vnc 127.0.0.1:0)
  websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/tmp/websockify.log 2>&1 &
  WSPID=$!
  echo "VM screen: http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
fi
SOCK=$(mktemp -u /tmp/qemu-mon.XXXX)

qemu-system-x86_64 "${ACCEL[@]}" -smp 4 -m "$RAM_MB" -machine q35 \
  "${FW[@]}" -cdrom "$ISO" -boot d \
  -vga none -device virtio-vga,xres=1280,yres=800 "${DISP[@]}" -monitor unix:"$SOCK",server,nowait \
  -usb -device usb-tablet \
  -nic user,model=virtio-net-pci &
QPID=$!
trap 'kill $QPID ${WSPID:-} 2>/dev/null || true; rm -f "$SOCK" "$VARS"' EXIT

end=$(( $(date +%s) + MINUTES*60 )); n=0
while [ "$(date +%s)" -lt "$end" ] && kill -0 $QPID 2>/dev/null; do
  sleep 60; n=$((n+1))
  f="$SHOTS/shot-$(printf %02d $n)"
  echo "screendump $f.ppm" | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1 || true
  sleep 2; [ -f "$f.ppm" ] && convert "$f.ppm" "$f.png" && rm -f "$f.ppm" && echo "saved $f.png"
done
echo "test finished"
