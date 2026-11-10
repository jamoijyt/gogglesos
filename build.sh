#!/bin/bash
# Goggles OS ISO builder.
# Remasters the official Kubuntu LTS ISO: unpacks its live filesystem, customizes it
# in a chroot (chroot/customize.sh), repacks it and writes a new bootable ISO that
# keeps Kubuntu's Secure Boot chain.
#
# Run as root on Ubuntu (WSL2 works):   sudo ./build.sh
# Options (env vars):
#   GPU_VARIANT=nvidia|amd     (default nvidia; see config.sh)
#   REUSE_ROOTFS=1             skip unpacking and customizing; just repack the existing rootfs
#   RESUME=1                   skip unpacking; re-run customization on the existing rootfs
#   KEEP_ROOTFS=1              keep the unpacked rootfs after the build (default: keep)
set -eEuo pipefail
trap 'echo "BUILD FAILED (line $LINENO, exit $?)" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./build.sh)"
for t in xorriso unsquashfs mksquashfs convert; do command -v $t >/dev/null || die "missing $t (apt install xorriso squashfs-tools imagemagick)"; done

ISO_IN="$CACHE_DIR/$(basename "$BASE_ISO_URL")"
ROOTFS="$WORK_DIR/rootfs"
STAGE="$WORK_DIR/stage"
ISO_OUT="$OUTPUT_DIR/${DISTRO_ID}-${DISTRO_VERSION}-${GPU_VARIANT}-amd64.iso"
SQUASH_OUT="$OUTPUT_DIR/work/filesystem.squashfs"
mkdir -p "$CACHE_DIR" "$OUTPUT_DIR/work" "$WORK_DIR"

# ---------------------------------------------------------------- base ISO
if [ ! -f "$ISO_IN" ]; then
  log "Downloading base ISO"
  wget -c -O "$ISO_IN.part" "$BASE_ISO_URL" && mv "$ISO_IN.part" "$ISO_IN"
fi
if [ ! -f "$ISO_IN.verified" ] || [ "$ISO_IN" -nt "$ISO_IN.verified" ]; then
  log "Verifying base ISO checksum"
  echo "$BASE_ISO_SHA256  $ISO_IN" | sha256sum -c - || die "checksum mismatch: delete $ISO_IN and retry"
  touch "$ISO_IN.verified"
fi

# ---------------------------------------------------------------- chroot helpers
MOUNTS=()
mount_chroot() {
  for d in dev dev/pts proc sys run; do mkdir -p "$ROOTFS/$d"; done
  mount --bind /dev "$ROOTFS/dev";           MOUNTS+=("$ROOTFS/dev")
  mount -t devpts devpts "$ROOTFS/dev/pts";  MOUNTS+=("$ROOTFS/dev/pts")
  mount -t proc proc "$ROOTFS/proc";         MOUNTS+=("$ROOTFS/proc")
  mount -t sysfs sysfs "$ROOTFS/sys";        MOUNTS+=("$ROOTFS/sys")
  mount -t tmpfs tmpfs "$ROOTFS/run";        MOUNTS+=("$ROOTFS/run")
}
cleanup() {
  for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount -l "${MOUNTS[$i]}" 2>/dev/null || true; done
  MOUNTS=()
}
trap cleanup EXIT

# ---------------------------------------------------------------- unpack
if [ "${REUSE_ROOTFS:-0}" != 1 ]; then
 if [ "${RESUME:-0}" = 1 ] && [ -d "$ROOTFS/usr" ]; then
  log "RESUME=1: re-running customization on the existing rootfs"
 else
  log "Unpacking live filesystem"
  rm -rf "$ROOTFS" "$STAGE"
  mkdir -p "$STAGE"
  xorriso -osirrox on -indev "$ISO_IN" \
    -extract /casper/filesystem.squashfs "$WORK_DIR/base.squashfs" \
    -extract /boot/grub/grub.cfg "$STAGE/grub.cfg.orig" \
    -extract /boot/grub/loopback.cfg "$STAGE/loopback.cfg.orig" \
    -extract /md5sum.txt "$STAGE/md5sum.txt.orig" \
    -extract /.disk/info "$STAGE/info.orig" 2>/dev/null
  unsquashfs -s "$WORK_DIR/base.squashfs" > "$STAGE/squashfs-info.txt"
  unsquashfs -d "$ROOTFS" "$WORK_DIR/base.squashfs"
  rm -f "$WORK_DIR/base.squashfs"
 fi

  # -------------------------------------------------------------- customize
  log "Preparing branding assets"
  G="$ROOTFS/tmp/goggles"
  rm -rf "$G"; mkdir -p "$G"
  # Copy WITHOUT preserving modes/owners: files on a Windows drive show up as 0777 and
  # owned by the WSL user, which must never leak into the image.
  cp -r --no-preserve=mode,ownership "$HERE/config.sh" "$HERE/chroot" "$HERE/overlay" "$HERE/third_party" "$HERE/gogglesxr" "$G/"
  chown -R root:root "$G"
  find "$G" -type d -exec chmod 755 {} +
  find "$G" -type f -exec chmod 644 {} +
  find "$G" -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.qml' -o -path '*/overlay/*' \) -exec sed -i 's/\r$//' {} +
  bash "$HERE/branding/make-assets.sh" "$G/assets"

  # Commit the image is built from, so Goggles Update knows what the installed system has.
  # "-dirty" marks uncommitted changes (the next update then re-applies everything).
  SOURCE_COMMIT=unknown
  if command -v git >/dev/null && SOURCE_COMMIT=$(git -c safe.directory="$HERE" -C "$HERE" rev-parse HEAD 2>/dev/null); then
    [ -z "$(git -c safe.directory="$HERE" -C "$HERE" status --porcelain 2>/dev/null)" ] || SOURCE_COMMIT="$SOURCE_COMMIT-dirty"
  else
    SOURCE_COMMIT=unknown
  fi

  log "Customizing in chroot (GPU_VARIANT=$GPU_VARIANT, source $SOURCE_COMMIT)"
  cp -L /etc/resolv.conf "$ROOTFS/tmp/goggles/resolv.conf"
  mount_chroot
  chroot "$ROOTFS" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    GPU_VARIANT="$GPU_VARIANT" NVIDIA_BRANCH="$NVIDIA_BRANCH" SOURCE_COMMIT="$SOURCE_COMMIT" \
    bash /tmp/goggles/chroot/customize.sh
  cleanup
  rm -rf "$ROOTFS/tmp/goggles"
fi
[ -d "$ROOTFS/usr" ] || die "no rootfs at $ROOTFS (run without REUSE_ROOTFS=1)"

# ---------------------------------------------------------------- permissions audit
# Repair every path the overlay touches (dirs root:root 755, files 644, bin scripts 755),
# then refuse to build if anything outside /home is owned by the build user or world-writable.
log "Checking file ownership and permissions"
( cd "$HERE/overlay" && find . -mindepth 0 ) | while IFS= read -r p; do
  t="$ROOTFS/${p#./}"; [ -e "$t" ] || continue
  chown root:root "$t"
  if [ -d "$t" ]; then chmod 755 "$t"
  else case "$p" in ./usr/bin/*|./usr/local/bin/*|./usr/libexec/gogglesos/*) chmod 755 "$t";; *) chmod 644 "$t";; esac; fi
done
BUILD_UID=$(stat -c %u "$HERE/build.sh")
BAD_OWN=$(find "$ROOTFS" -xdev \( -uid "$BUILD_UID" -o -gid "$BUILD_UID" \) -not -path "$ROOTFS/home/*" 2>/dev/null | head -20)
[ "$BUILD_UID" = 0 ] && BAD_OWN=""
BAD_DIRS=$(find "$ROOTFS" -xdev -type d -perm -0002 -not -perm -1000 -not -path "$ROOTFS/proc/*" 2>/dev/null | head -20)
if [ -n "$BAD_OWN$BAD_DIRS" ]; then
  printf 'owned by build user (uid %s):\n%s\nworld-writable dirs without sticky bit:\n%s\n' "$BUILD_UID" "$BAD_OWN" "$BAD_DIRS" >&2
  die "unsafe permissions in the image (see above)"
fi

# ---------------------------------------------------------------- live welcome screen
# Kubuntu's "Try or Install" app has its branding compiled in; rebuild it from source.
KIP_VER=$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' kubuntu-installer-prompt 2>/dev/null || true)
if [ -n "$KIP_VER" ]; then
  log "Rebranding live welcome screen (kubuntu-installer-prompt $KIP_VER)"
  KIP_BIN="$WORK_DIR/kubuntu-installer-prompt"
  if [ "$(cat "$KIP_BIN.version" 2>/dev/null)" != "$KIP_VER" ] || [ "${REBUILD_PROMPT:-0}" = 1 ]; then
    bash "$HERE/branding/make-assets.sh" "$WORK_DIR/assets" >/dev/null
    bash "$HERE/branding/build-installer-prompt.sh" "$KIP_VER" "$WORK_DIR/assets" "$KIP_BIN"
    echo "$KIP_VER" > "$KIP_BIN.version"
  else
    echo "reusing $KIP_BIN (set REBUILD_PROMPT=1 after changing artwork)"
  fi
  chroot "$ROOTFS" dpkg-divert --local --rename --add /usr/bin/kubuntu-installer-prompt >/dev/null
  install -m755 "$WORK_DIR/kubuntu-installer-prompt" "$ROOTFS/usr/bin/kubuntu-installer-prompt"
fi

KVER=$(ls "$ROOTFS/lib/modules" | sort -V | tail -1)

# Drop initrds for kernels that aren't installed (e.g. the WSL host kernel picked up via `uname -r`)
for f in "$ROOTFS"/boot/initrd.img-*; do
  v=${f##*/initrd.img-}
  [ -d "$ROOTFS/lib/modules/$v/kernel" ] || { echo "removing stray $f"; rm -f "$f"; rm -rf "$ROOTFS/var/lib/initramfs-tools/$v"; }
done
for l in "$ROOTFS"/boot/vmlinuz.old "$ROOTFS"/boot/initrd.img.old; do [ -e "$l" ] || rm -f "$l"; done

# ---------------------------------------------------------------- live initrd
# The installed system's initrd boots from disk. The live medium needs one generated with
# CASPER_GENERATE_UUID=1, which adds BOOT=casper and a medium UUID (matched by .disk/casper-uuid-*).
log "Building live (casper) initrd for $KVER"
mount_chroot
chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin CASPER_GENERATE_UUID=1 \
  mkinitramfs -o /tmp/live-initrd "$KVER"
rm -rf "$ROOTFS/tmp/live-initrd-x"
chroot "$ROOTFS" unmkinitramfs /tmp/live-initrd /tmp/live-initrd-x
cleanup
UUIDF=$(find "$ROOTFS/tmp/live-initrd-x" -path '*/conf/uuid.conf' | head -1)
[ -n "$UUIDF" ] && grep -q 'BOOT=casper' "$(dirname "$UUIDF")/conf.d/default-boot-to-casper.conf" \
  || die "live initrd is missing casper boot config"
cp "$UUIDF" "$STAGE/casper-uuid"
mv "$ROOTFS/tmp/live-initrd" "$STAGE/initrd"
rm -rf "$ROOTFS/tmp/live-initrd-x"
CASPER_UUID_PATH=$(xorriso -indev "$ISO_IN" -find /.disk -name 'casper-uuid-*' 2>/dev/null | tr -d "'" | head -1)
CASPER_UUID_PATH=${CASPER_UUID_PATH:-/.disk/casper-uuid-generic}
echo "live medium UUID $(cat "$STAGE/casper-uuid") -> $CASPER_UUID_PATH"

# ---------------------------------------------------------------- repack squashfs
COMP=$(awk '/^Compression/{print $2}' "$STAGE/squashfs-info.txt"); COMP=${COMP:-xz}
BS=$(awk '/^Block size/{print $3}' "$STAGE/squashfs-info.txt"); BS=${BS:-1048576}
log "Compressing filesystem ($COMP, block $BS) - this takes a while"
rm -f "$SQUASH_OUT"
# Limit threads/buffers: on a 16 GB PC running WSL, the default can exhaust memory
mksquashfs "$ROOTFS" "$SQUASH_OUT" -noappend -comp "$COMP" -b "$BS" -wildcards \
  -processors "${SQUASH_CPUS:-6}" -mem "${SQUASH_MEM:-1G}" \
  -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/cache/apt/archives/*.deb'

# ---------------------------------------------------------------- boot files
log "Preparing boot files"
cp -L "$ROOTFS/boot/vmlinuz-$KVER" "$STAGE/vmlinuz"

brand_grub() {
  # Rename menu entries; add the low-latency options to every kernel line (before "---" if present)
  sed -e "s/Kubuntu/${DISTRO_NAME}/g" \
      -e "/\/casper\/vmlinuz/{ / ---/!s/\$/ ${KERNEL_CMDLINE_EXTRA}/; s/ ---/ ${KERNEL_CMDLINE_EXTRA} ---/; }" \
      "$1" > "$2"
}
brand_grub "$STAGE/grub.cfg.orig" "$STAGE/grub.cfg"
brand_grub "$STAGE/loopback.cfg.orig" "$STAGE/loopback.cfg"
printf '%s %s LTS "Resolute Raccoon" - PCVR Edition (%s) amd64 (%s)\n' \
  "$DISTRO_NAME" "$DISTRO_VERSION" "$GPU_VARIANT" "$(date +%Y%m%d)" > "$STAGE/info"

# md5sum.txt: keep entries for unchanged files, recompute changed ones
declare -A NEWFILES=(
  [./casper/filesystem.squashfs]="$SQUASH_OUT"
  [./casper/vmlinuz]="$STAGE/vmlinuz"
  [./casper/initrd]="$STAGE/initrd"
  [./boot/grub/grub.cfg]="$STAGE/grub.cfg"
  [./boot/grub/loopback.cfg]="$STAGE/loopback.cfg"
  [./.disk/info]="$STAGE/info"
  [."$CASPER_UUID_PATH"]="$STAGE/casper-uuid"
)
log "Updating md5sum.txt"
cp "$STAGE/md5sum.txt.orig" "$STAGE/md5sum.txt"
for k in "${!NEWFILES[@]}"; do
  sum=$(md5sum "${NEWFILES[$k]}" | cut -d' ' -f1)
  grep -vF "  $k" "$STAGE/md5sum.txt" > "$STAGE/md5.tmp" || true
  echo "$sum  $k" >> "$STAGE/md5.tmp"
  mv "$STAGE/md5.tmp" "$STAGE/md5sum.txt"
done

# ---------------------------------------------------------------- write ISO
log "Writing $ISO_OUT"
rm -f "$ISO_OUT"
MAPS=()
for k in "${!NEWFILES[@]}"; do MAPS+=(-map "${NEWFILES[$k]}" "${k#.}"); done
xorriso -indev "$ISO_IN" -outdev "$ISO_OUT" \
  -volid "$ISO_VOLID" \
  "${MAPS[@]}" \
  -map "$STAGE/md5sum.txt" /md5sum.txt \
  -boot_image any replay

( cd "$OUTPUT_DIR" && sha256sum "$(basename "$ISO_OUT")" > "$(basename "$ISO_OUT").sha256" )
log "Done: $ISO_OUT ($(du -h "$ISO_OUT" | cut -f1))"
