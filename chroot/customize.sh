#!/bin/bash
# Runs INSIDE the Kubuntu live filesystem chroot. Called by build.sh.
set -euo pipefail
G=/tmp/goggles
A=$G/assets
# shellcheck source=../config.sh
source $G/config.sh
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
log()  { printf '\n\033[1;36m--> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ chroot setup
log "Preparing chroot"
# (resolv.conf is restored to the Ubuntu default symlink at the end)
rm -f /etc/resolv.conf; cp $G/resolv.conf /etc/resolv.conf
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
dpkg-divert --local --rename --add /usr/bin/ischroot >/dev/null 2>&1 || true
ln -sf /bin/true /usr/bin/ischroot
# The live system lists the install medium (file:/cdrom) as a source for the installer;
# it doesn't exist in the chroot, so park it and restore it at the end.
CDROM_SRC=/etc/apt/sources.list.d/cdrom.sources
[ -f $CDROM_SRC ] && mv $CDROM_SRC /etc/apt/cdrom.sources.parked

# ------------------------------------------------------------------ packages
log "Updating base system"
dpkg --add-architecture i386
apt-get update
"${APT[@]}" full-upgrade

log "Installing gaming / VR packages"
"${APT[@]}" install "${APT_PACKAGES[@]}"

if [ "$GPU_VARIANT" = nvidia ]; then
  log "Installing NVIDIA driver $NVIDIA_BRANCH (prebuilt, Secure Boot signed modules)"
  B=$NVIDIA_BRANCH
  # Match the installed kernel metapackage, e.g. linux-generic-hwe-26.04 -> generic-hwe-26.04
  KFLAVOUR=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-generic*' 2>/dev/null \
             | awk '$1=="ii"{print $2}' | sort | tail -1 | sed 's/^linux-//')
  KFLAVOUR=${KFLAVOUR:-generic}
  "${APT[@]}" install "nvidia-driver-$B" "linux-modules-nvidia-$B-$KFLAVOUR" "libnvidia-gl-${B%-open}:i386"
  # Required for SteamVR direct mode / Wayland on NVIDIA
  echo "options nvidia-drm modeset=1 fbdev=1" > /etc/modprobe.d/gogglesos-nvidia.conf
fi

log "Installing Discord"
if wget -q -O /tmp/discord.deb "$DISCORD_DEB_URL"; then
  "${APT[@]}" install /tmp/discord.deb || warn "Discord install failed"
  rm -f /tmp/discord.deb
else
  warn "Discord download failed"
fi

log "Installing Flatpaks"
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
for fp in "${FLATPAKS[@]}"; do
  flatpak install --system -y --noninteractive flathub "$fp" || warn "flatpak $fp failed"
done

log "Removing old kernels"
KNEW=$(ls /lib/modules | sort -V | tail -1)
for k in $(ls /lib/modules); do
  [ "$k" = "$KNEW" ] && continue
  OLD=$(dpkg-query -W -f='${Package}\n' | grep -E -- "-${k}\$" || true)
  [ -n "$OLD" ] && "${APT[@]}" purge $OLD
  rm -rf "/lib/modules/$k"
done
"${APT[@]}" autoremove --purge

# ------------------------------------------------------------------ system files
# Overlay, branding, themes, start menu, login and boot splash. Shared with Goggles Update
# (/usr/bin/goggles-update), so installed systems get the same changes without a new ISO.
G="$G" A="$A" APPLY_MODE=build SOURCE_COMMIT="${SOURCE_COMMIT:-unknown}" bash "$G/chroot/apply-system.sh"

log "Branding: installer (Calamares)"
CB=/etc/calamares/branding
if [ -d $CB/kubuntu ]; then
  rm -rf "${CB:?}/${DISTRO_ID:?}"; cp -a $CB/kubuntu $CB/$DISTRO_ID
  rm -f $CB/$DISTRO_ID/0*.png
  install -m644 $A/icons/256.png        $CB/$DISTRO_ID/icon.png
  install -m644 $A/calamares-logo.png   $CB/$DISTRO_ID/logo.png
  install -m644 $A/welcome.png          $CB/$DISTRO_ID/welcome.png
  install -m644 $A/welcome.png          $CB/$DISTRO_ID/welcome-oem.png
  install -m644 $A/slide-*.png          $CB/$DISTRO_ID/
  install -m644 $G/chroot/calamares-show.qml $CB/$DISTRO_ID/show.qml
  D=$CB/$DISTRO_ID/branding.desc
  sed -i -e "s/^componentName:.*/componentName: $DISTRO_ID/" \
         -e "s/^\( *productName: *\).*/\1$DISTRO_NAME/" \
         -e "s/^\( *shortProductName: *\).*/\1$DISTRO_NAME/" \
         -e "s/^\( *shortVersion: *\).*/\1$DISTRO_CODENAME/" \
         -e "s/^\( *versionedName: *\).*/\1$DISTRO_NAME $DISTRO_VERSION LTS/" \
         -e "s/^\( *shortVersionedName: *\).*/\1$DISTRO_NAME $DISTRO_VERSION/" \
         -e "s#^\( *productUrl: *\).*#\1$DISTRO_URL#" \
         -e "s#^\( *supportUrl: *\).*#\1$DISTRO_BUG_URL#" \
         -e 's/^\( *SidebarBackground: *\).*/\1"#0a2a26"/' \
         -e 's/^\( *SidebarTextCurrent: *\).*/\1"#3ddc84"/' "$D"
  sed -i "s/^branding: .*/branding: $DISTRO_ID/" /etc/calamares/settings.conf
  sed -i "s#^showDonateUrl:.*#showDonateUrl: false#" /etc/calamares/modules/welcome.conf 2>/dev/null || true
  # Root partition label shown in the installer summary (kubuntu_boot is left as-is)
  sed -i 's/"kubuntu_2604"/"gogglesos"/' /etc/calamares/modules/partition.conf
  # Appearance page (Glass / Lite) + the step that applies it in the installed system
  install -m644 $G/chroot/calamares/packagechooser_appearance.conf  /etc/calamares/modules/
  install -m644 $G/chroot/calamares/contextualprocess_appearance.conf /etc/calamares/modules/
  S=/etc/calamares/settings.conf
  if ! grep -q 'packagechooser_appearance.conf' $S; then
    sed -i '/^instances:/a - id: appearance\n  module: packagechooser\n  config: packagechooser_appearance.conf\n- id: appearance_apply\n  module: contextualprocess\n  config: contextualprocess_appearance.conf' $S
    sed -i '0,/^  - pkgselect$/s//  - pkgselect\n  - packagechooser@appearance/' $S
    sed -i 's/^  - contextualprocess@pkgselect_snap_action$/&\n  - contextualprocess@appearance_apply/' $S
  fi
  grep -q 'packagechooser@appearance' $S && grep -q 'contextualprocess@appearance_apply' $S \
    || warn "could not add the Appearance page to $S"
  # Installer launcher name
  for f in /usr/share/applications/kubuntu-calamares.desktop; do
    [ -f "$f" ] && sed -i -e "s/Kubuntu/$DISTRO_NAME/g" "$f"
  done
else
  warn "Calamares kubuntu branding not found"
fi

# ------------------------------------------------------------------ finish
log "Regenerating initramfs"
# Package scripts that use `uname -r` see the build host's kernel (e.g. WSL); drop those leftovers.
HOSTK=$(uname -r)
if [ ! -d "/usr/lib/modules/$HOSTK/kernel" ]; then
  rm -rf "/boot/initrd.img-$HOSTK" "/var/lib/initramfs-tools/$HOSTK" "/usr/lib/modules/$HOSTK"
fi
update-initramfs -u -k "$(ls /lib/modules | sort -V | tail -1)"

log "Cleaning up"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*.deb /var/tmp/* /root/.cache
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /usr/bin/ischroot; dpkg-divert --local --rename --remove /usr/bin/ischroot >/dev/null 2>&1 || true
rm -f /usr/sbin/policy-rc.d
[ -f /etc/apt/cdrom.sources.parked ] && mv /etc/apt/cdrom.sources.parked $CDROM_SRC
rm -f /etc/resolv.conf
ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
log "Chroot customization complete"
