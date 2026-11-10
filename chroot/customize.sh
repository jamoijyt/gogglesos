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
log "Applying system overlay"
# Install file by file so existing system directories keep their own owner and mode
(cd $G/overlay && find . -type f -print0) | while IFS= read -r -d '' f; do
  case "$f" in ./usr/bin/*|./usr/local/bin/*|./usr/libexec/gogglesos/*) m=755;; *) m=644;; esac
  install -D -o root -g root -m $m "$G/overlay/$f" "/${f#./}"
done
sed -i "s|@KERNEL_CMDLINE_EXTRA@|$KERNEL_CMDLINE_EXTRA|" /etc/default/grub.d/90-gogglesos.cfg
sed -i "s|@DISTRO_URL@|$DISTRO_URL|" /etc/xdg/kcm-about-distrorc
chmod 755 /usr/local/bin/goggles-vr-setup

log "Branding: os-release / lsb-release"
for f in /usr/lib/os-release /etc/lsb-release; do
  dpkg-divert --local --rename --add "$f" >/dev/null 2>&1 || true
done
cat > /usr/lib/os-release <<EOF
PRETTY_NAME="$DISTRO_NAME $DISTRO_VERSION LTS"
NAME="$DISTRO_NAME"
VERSION_ID="$DISTRO_VERSION"
VERSION="$DISTRO_VERSION LTS (Resolute Raccoon)"
VERSION_CODENAME=$DISTRO_CODENAME
ID=ubuntu
ID_LIKE=debian
VARIANT="PCVR Edition"
VARIANT_ID=$DISTRO_ID
HOME_URL="$DISTRO_URL"
SUPPORT_URL="$DISTRO_BUG_URL"
BUG_REPORT_URL="$DISTRO_BUG_URL"
UBUNTU_CODENAME=$DISTRO_CODENAME
LOGO=$DISTRO_ID
EOF
ln -sf ../usr/lib/os-release /etc/os-release
cat > /etc/lsb-release <<EOF
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=$DISTRO_VERSION
DISTRIB_CODENAME=$DISTRO_CODENAME
DISTRIB_DESCRIPTION="$DISTRO_NAME $DISTRO_VERSION LTS"
EOF
printf '%s %s LTS \\n \\l\n\n' "$DISTRO_NAME" "$DISTRO_VERSION" > /etc/issue
printf '%s %s LTS\n' "$DISTRO_NAME" "$DISTRO_VERSION" > /etc/issue.net

log "Branding: icons and wallpaper"
for s in 16 22 24 32 48 64 96 128 256 512; do
  install -D -m644 $A/icons/$s.png /usr/share/icons/hicolor/${s}x${s}/apps/$DISTRO_ID.png
done
install -D -m644 $A/gogglesos-logo.png /usr/share/pixmaps/gogglesos-logo.png
install -D -m644 $A/icons/256.png /usr/share/pixmaps/$DISTRO_ID.png
install -D -m644 $A/logo-light.png /usr/share/$DISTRO_ID/logo-light.png
install -D -m644 $A/logo-dark.png /usr/share/$DISTRO_ID/logo-dark.png
gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true

WP=/usr/share/wallpapers/GogglesOS
install -D -m644 $A/wallpaper-1920x1080.png $WP/contents/images/1920x1080.png
install -D -m644 $A/wallpaper-preview.png  $WP/contents/screenshot.png
cat > $WP/metadata.json <<EOF
{ "KPlugin": { "Id": "GogglesOS", "Name": "$DISTRO_NAME", "License": "CC-BY-SA-4.0",
  "Authors": [ { "Name": "$DISTRO_NAME" } ] } }
EOF

log "Branding: Plasma look-and-feel"
LNF_SRC=/usr/share/plasma/look-and-feel/org.kubuntu.desktop
LNF=/usr/share/plasma/look-and-feel/org.$DISTRO_ID.desktop
TPL_SRC=/usr/share/plasma/layout-templates/org.kubuntu.desktop.defaultPanel
TPL=/usr/share/plasma/layout-templates/org.$DISTRO_ID.desktop.defaultPanel
rm -rf "$LNF" "$TPL"
cp -a "$LNF_SRC" "$LNF"; cp -a "$TPL_SRC" "$TPL"
sed -i -e "s/org.kubuntu.desktop/org.$DISTRO_ID.desktop/g" -e "s/\"Kubuntu\"/\"$DISTRO_NAME\"/g" \
  "$LNF/metadata.json" "$TPL/metadata.json"
sed -i -e "s#^Image=.*#Image=GogglesOS#" -e "s#^ColorScheme=.*#ColorScheme=GogglesDark#" \
       -e "/^\[kdeglobals\]\[Icons\]/,/^\[/ s#^Theme=.*#Theme=Papirus-Dark#" \
       -e "/^\[plasmarc\]\[Theme\]/,/^\[/ s#^name=.*#name=gogglesos#" "$LNF/contents/defaults"
sed -i -e "s#file:///usr/share/wallpapers/Kubuntu\#day-night#file:///usr/share/wallpapers/GogglesOS#" \
       -e "/writeConfig( *'DynamicMode'/d" \
       -e "s/org.kubuntu.desktop.defaultPanel/org.$DISTRO_ID.desktop.defaultPanel/" \
  "$LNF/contents/layouts/org.kde.plasma.desktop-layout.js"
sed -i -e "s/'start-here-kubuntu'/'$DISTRO_ID'/" "$TPL/contents/layout.js"
# Pin Steam next to the existing taskbar launchers
sed -i "0,/applications:systemsettings.desktop/s//applications:steam.desktop', 'applications:systemsettings.desktop/" "$TPL/contents/layout.js" || true

# /etc/xdg overrides Kubuntu's defaults dir (see /etc/xdg/plasma-workspace/env/env.sh)
cat > /etc/xdg/kdeglobals <<EOF
[KDE]
LookAndFeelPackage=org.$DISTRO_ID.desktop

[General]
ColorScheme=GogglesDark

[Icons]
Theme=Papirus-Dark
EOF
cat > /etc/xdg/plasmarc <<EOF
[Theme]
name=gogglesos
EOF
cat > /etc/xdg/kscreenlockerrc <<EOF
[Daemon]
Autolock=true
Timeout=15

[Greeter][Wallpaper][org.kde.image][General]
Image=file://$WP/contents/images/1920x1080.png
PreviewImage=file://$WP/contents/images/1920x1080.png
EOF

log "Appearance: rounded corners, Goggles Glass (Kvantum), Glass/Lite modes"
# KDE-Rounded-Corners from its author's PPA (rebuilt for each KWin update)
if [ ! -f /etc/apt/sources.list.d/matinlotfali-ubuntu-kde-rounded-corners-$DISTRO_CODENAME.sources ]; then
  add-apt-repository -y -n ppa:matinlotfali/kde-rounded-corners || warn "could not add rounded-corners PPA"
fi
apt-get update -qq
"${APT[@]}" install kwin-effect-roundcorners || warn "rounded-corners effect not installed (Breeze's own rounding still applies)"

# Kvantum "GogglesGlass": KvFlat (dark, Breeze-like) + translucency, blur and Goggles colours
KV=/usr/share/Kvantum
if [ -f $KV/KvFlat/KvFlat.kvconfig ]; then
  rm -rf $KV/GogglesGlass; mkdir -p $KV/GogglesGlass
  cp $KV/KvFlat/KvFlat.svg $KV/GogglesGlass/GogglesGlass.svg
  cp $KV/KvFlat/KvFlat.kvconfig $KV/GogglesGlass/GogglesGlass.kvconfig
  kv() { # section key value
    local f=$KV/GogglesGlass/GogglesGlass.kvconfig
    if sed -n "/^\[$1\]/,/^\[/p" "$f" | grep -q "^$2="; then
      sed -i "/^\[$1\]/,/^\[/ s|^$2=.*|$2=$3|" "$f"
    else
      sed -i "/^\[$1\]/a $2=$3" "$f"
    fi
  }
  kv '%General' comment 'Goggles OS glass theme'
  kv '%General' translucent_windows true
  kv '%General' blurring true
  kv '%General' popup_blurring true
  kv '%General' reduce_window_opacity 22
  kv '%General' reduce_menu_opacity 15
  kv '%General' menu_blur_radius 4
  kv '%General' tooltip_blur_radius 4
  kv GeneralColors window.color '#14201d'
  kv GeneralColors base.color '#0f1916'
  kv GeneralColors alt.base.color '#15231f'
  kv GeneralColors button.color '#1c2c28'
  kv GeneralColors mid.color '#1f302b'
  kv GeneralColors dark.color '#08100e'
  kv GeneralColors highlight.color '#3ddc84'
  kv GeneralColors inactive.highlight.color '#2a8f58'
  kv GeneralColors highlight.text.color '#06120c'
  kv GeneralColors link.color '#3ddc84'
else
  warn "Kvantum themes missing; Glass mode will use Breeze"
fi

# Panel: floating; translucent in Glass, opaque in Lite (reads gogglesosrc written by goggles-theme)
sed -i "s/^\( *\)panel_obj.floating = 0;/\1panel_obj.floating = 1;\n\1try { const gcfg = ConfigFile('gogglesosrc'); gcfg.group = 'Theme';\n\1  panel_obj.opacity = (gcfg.readEntry('Mode') === 'lite') ? 'opaque' : 'translucent'; } catch (e) {}/" \
  "$TPL/contents/layout.js"

install -D -m644 $A/appearance-glass.png /usr/share/$DISTRO_ID/appearance-glass.png
install -D -m644 $A/appearance-lite.png  /usr/share/$DISTRO_ID/appearance-lite.png
chmod 755 /usr/bin/goggles-theme
# Default for the live session and new installs (the installer can switch it to Lite)
/usr/bin/goggles-theme glass --system

log "Appearance: Goggles Dark colours and Goggles Glass taskbar theme"
# Colour scheme: Breeze Dark with teal-tinted greys and the Goggles green accent
sed -e 's/^Name=.*/Name=Goggles Dark/' \
    -e 's/\b32,35,38\b/15,30,27/g'  -e 's/\b41,44,48\b/22,40,36/g' -e 's/\b20,22,24\b/10,22,19/g' \
    -e 's/\b29,31,34\b/14,28,25/g'  -e 's/\b49,54,59\b/26,46,41/g' -e 's/\b30,87,116\b/24,88,58/g' \
    -e 's/\b61,174,233\b/61,220,132/g' -e 's/\b29,153,243\b/61,220,132/g' \
    /usr/share/color-schemes/BreezeDark.colors > /usr/share/color-schemes/GogglesDark.colors
# Plasma desktop theme "gogglesos": Breeze shapes, more see-through, Goggles colours, stronger
# blur contrast/saturation for a frosted-glass look. Missing files fall back to Breeze.
PT_D=/usr/share/plasma/desktoptheme/gogglesos; BREEZE_D=/usr/share/plasma/desktoptheme/default
rm -rf "${PT_D:?}"; mkdir -p $PT_D/translucent/widgets $PT_D/translucent/dialogs $PT_D/widgets $PT_D/dialogs
cat > $PT_D/metadata.json <<EOF
{ "KPlugin": { "Id": "gogglesos", "Name": "Goggles Glass", "Description": "Frosted green glass for Goggles OS",
  "License": "LGPL", "Version": "$DISTRO_VERSION", "Authors": [ { "Name": "$DISTRO_NAME" } ] },
  "X-Plasma-API-Minimum-Version": "6.0" }
EOF
cat > $PT_D/plasmarc <<EOF
[ContrastEffect]
enabled=true
contrast=0.55
intensity=1.6
saturation=2.2

[AdaptiveTransparency]
enabled=true
EOF
cp /usr/share/color-schemes/GogglesDark.colors $PT_D/colors
glassify() { # src dst opacity
  zcat "$1" | sed "s/opacity:0.85;fill:currentColor/opacity:$3;fill:currentColor/" | gzip -9n > "$2"
}
glassify $BREEZE_D/translucent/widgets/panel-background.svgz $PT_D/translucent/widgets/panel-background.svgz 0.55
glassify $BREEZE_D/translucent/dialogs/background.svgz       $PT_D/translucent/dialogs/background.svgz       0.62
glassify $BREEZE_D/translucent/widgets/background.svgz       $PT_D/translucent/widgets/background.svgz       0.62
glassify $BREEZE_D/widgets/panel-background.svgz             $PT_D/widgets/panel-background.svgz             0.70
glassify $BREEZE_D/dialogs/background.svgz                   $PT_D/dialogs/background.svgz                   0.75
[ -d /usr/share/plasma/desktoptheme/kubuntu-dark/icons ] && cp -r /usr/share/plasma/desktoptheme/kubuntu-dark/icons $PT_D/ \
  && rm -f $PT_D/icons/start.svgz

log "Appearance: Windows 10-style start menu (Tiled Menu)"
# Pinned, reviewed copies live in third_party/ (see third_party/SHA256SUMS); nothing is fetched here
TP=$G/third_party
(cd $TP && sha256sum -c --quiet SHA256SUMS) || { warn "third_party checksum mismatch"; exit 1; }
TM_DIR=/usr/share/plasma/plasmoids/com.github.zren.tiledmenu
if [ -f $TP/plasma-applet-tiledmenu-21c8540.tar.gz ]; then
  rm -rf /tmp/tm && mkdir /tmp/tm && tar xzf $TP/plasma-applet-tiledmenu-21c8540.tar.gz -C /tmp/tm --strip-components=1
  rm -rf "${TM_DIR:?}" && cp -r /tmp/tm/package "$TM_DIR" && chown -R root:root "$TM_DIR"
  find "$TM_DIR" -type d -exec chmod 755 {} + ; find "$TM_DIR" -type f -exec chmod 644 {} +
  rm -rf /tmp/tm
  TILES=$(python3 -c 'import json,sys,base64; print(base64.b64encode(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")).encode()).decode())' $G/chroot/tiledmenu-tiles.json)
  # Swap Kickoff for Tiled Menu in the default panel and give it Goggles defaults
  sed -i -e "s/addWidget( 'org.kde.plasma.kickoff' )/addWidget( 'com.github.zren.tiledmenu' )/" \
         -e "s|^\( *\)kickoff_obj.writeConfig( *'icon', *'$DISTRO_ID' );|&\n\1kickoff_obj.writeConfig( 'tileModel', '$TILES' );\n\1kickoff_obj.writeConfig( 'sidebarFollowsTheme', 'true' );\n\1kickoff_obj.writeConfig( 'searchFieldFollowsTheme', 'true' );\n\1kickoff_obj.writeConfig( 'defaultTileColor', '#26ffffff' );\n\1kickoff_obj.writeConfig( 'tileScale', '0.9' );\n\1kickoff_obj.writeConfig( 'favGridCols', '6' );\n\1kickoff_obj.writeConfig( 'appListWidth', '320' );\n\1kickoff_obj.writeConfig( 'popupHeight', '640' );\n\1kickoff_obj.writeConfig( 'tilesLocked', 'false' );\n\1kickoff_obj.writeConfig( 'sidebarShortcuts', 'xdg:DOCUMENTS,xdg:DOWNLOADS,xdg:PICTURES,org.kde.dolphin.desktop,systemsettings.desktop' );|" \
         "$TPL/contents/layout.js"
  grep -q "com.github.zren.tiledmenu" "$TPL/contents/layout.js" && grep -q "tileModel" "$TPL/contents/layout.js" \
    || warn "could not switch the panel to Tiled Menu (Kickoff kept)"
else
  warn "Tiled Menu package missing (Kickoff kept)"
fi

log "Appearance: lock screen and Papirus-Dark green icons"
chmod 755 /usr/libexec/gogglesos/*
/usr/libexec/gogglesos/patch-lockscreen
# papirus-folders v1.14.0 (MIT, reviewed: only re-points folder icon symlinks; no network)
install -o root -g root -m755 $TP/papirus-folders /usr/bin/papirus-folders
/usr/bin/papirus-folders -C green --theme Papirus-Dark || warn "papirus-folders failed (blue folders)"
# User picture: Goggles icon instead of Kubuntu's
install -m644 $A/icons/256.png /etc/skel/.face
gtk-update-icon-cache -q -f /usr/share/icons/Papirus-Dark 2>/dev/null || true

log "Cleanup: Kubuntu desktop links and menu entries"
rm -f /etc/skel/Desktop/org.kfocus.web.howtos.desktop /etc/skel/Desktop/org.kubuntu.web.home.desktop
mkdir -p /usr/local/share/applications
for d in org.kfocus.web.howtos org.kubuntu.web.home org.kubuntu.restore-desktop-links; do
  # /usr/local/share overrides /usr/share, and survives package updates
  printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "$d" \
    > /usr/local/share/applications/$d.desktop
done
chmod 755 /usr/local/bin/goggles-vr-setup

log "Branding: login screen (SDDM)"
SDDM_THEME=$(grep -h '^Current=' /etc/sddm.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2)
SDDM_THEME=${SDDM_THEME:-breeze}
if [ -d "/usr/share/sddm/themes/$SDDM_THEME" ]; then
  cat > "/usr/share/sddm/themes/$SDDM_THEME/theme.conf.user" <<EOF
[General]
background=$WP/contents/images/1920x1080.png
type=image
showlogo=shown
logo=/usr/share/$DISTRO_ID/logo-dark.png
EOF
else
  warn "SDDM theme $SDDM_THEME not found"
fi

log "Branding: boot splash (Plymouth)"
PT=/usr/share/plymouth/themes/$DISTRO_ID
if [ -d /usr/share/plymouth/themes/spinner ]; then
  rm -rf "$PT"; cp -a /usr/share/plymouth/themes/spinner "$PT"
  mv "$PT/spinner.plymouth" "$PT/$DISTRO_ID.plymouth"
  install -m644 $A/logo-dark-420.png "$PT/watermark.png"
  sed -i -e "s#^ImageDir=.*#ImageDir=$PT#" -e '/^Name\[/d' -e '/^Description\[/d' \
         -e "s/^Name=.*/Name=$DISTRO_NAME/" \
         -e "s/^Description=.*/Description=$DISTRO_NAME boot splash/" \
         -e "s/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.5/" \
         -e "s/^VerticalAlignment=.*/VerticalAlignment=.75/" \
         -e "s/^BackgroundStartColor=.*/BackgroundStartColor=0x0a2a26/" \
         -e "s/^BackgroundEndColor=.*/BackgroundEndColor=0x0a2a26/" \
         "$PT/$DISTRO_ID.plymouth"
  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$PT/$DISTRO_ID.plymouth" 200
  update-alternatives --set default.plymouth "$PT/$DISTRO_ID.plymouth"
else
  warn "plymouth spinner theme not found; boot splash left as-is"
fi

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
