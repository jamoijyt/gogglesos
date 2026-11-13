#!/bin/bash
# Goggles OS system configuration: overlay files, branding, themes, start menu, login and
# boot splash. Shared by the ISO build and Goggles Update, so an update gives the same
# result as a fresh ISO.
#
#   ISO build:     chroot/customize.sh runs it inside the live filesystem (APPLY_MODE=build)
#   Goggles Update: /usr/bin/goggles-update runs it on an installed system (APPLY_MODE=update)
#
# Environment:
#   G              source tree (config.sh, overlay/, chroot/, third_party/)
#   A              branding assets made by branding/make-assets.sh
#   APPLY_MODE     build | update
#   SOURCE_COMMIT  git commit of the source tree (recorded in /var/lib/gogglesos/version)
set -euo pipefail
: "${G:?G (source tree) not set}" "${A:?A (assets) not set}"
APPLY_MODE="${APPLY_MODE:-build}"
case "$APPLY_MODE" in build|update) ;; *) echo "APPLY_MODE must be build or update" >&2; exit 2;; esac
# shellcheck source=../config.sh
source "$G/config.sh"
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
log()  { printf '\n\033[1;36m--> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

STATE=/var/lib/gogglesos
mkdir -p "$STATE"; chmod 755 "$STATE"
# hash of files, for "did this change?" checks
fp() { find "$@" -type f -exec sha256sum {} + 2>/dev/null | sort || true; }

if [ "$APPLY_MODE" = update ]; then
  # Stop before changing anything if the Kubuntu pieces we build on are missing
  for d in /usr/share/plasma/look-and-feel/org.kubuntu.desktop \
           /usr/share/plasma/layout-templates/org.kubuntu.desktop.defaultPanel \
           /usr/share/plasma/desktoptheme/default /usr/share/color-schemes/BreezeDark.colors; do
    [ -e "$d" ] || { echo "ERROR: $d is missing; not updating (reinstall the package that provides it)" >&2; exit 1; }
  done
  # Appearance mode chosen in the installer (or the build default)
  SYSTEM_MODE=$(sed -n 's/^Mode=//p' /etc/xdg/gogglesosrc 2>/dev/null | tail -1)
  case "$SYSTEM_MODE" in glass|lite) ;; *) SYSTEM_MODE=glass;; esac
  echo "Keeping the system appearance: $SYSTEM_MODE"
  # Settings that only take effect after regenerating something
  BEFORE_GRUB=$(fp /etc/default/grub.d/90-gogglesos.cfg)
  BEFORE_SYSCTL=$(fp /etc/sysctl.d/90-gogglesos.conf)
  BEFORE_SPLASH="$(fp "/usr/share/plymouth/themes/$DISTRO_ID")$(readlink -f /etc/alternatives/default.plymouth 2>/dev/null || true)"
fi

# ------------------------------------------------------------------ system files
log "Applying system overlay"
# Install file by file so existing system directories keep their own owner and mode
(cd $G/overlay && find . -type f -print0) | while IFS= read -r -d '' f; do
  case "$f" in ./usr/bin/*|./usr/local/bin/*|./usr/libexec/gogglesos/*) m=755;; *) m=644;; esac
  install -D -o root -g root -m $m "$G/overlay/$f" "/${f#./}"
done
# Files a previous version installed but this one no longer ships
(cd $G/overlay && find . -type f | sed 's#^\.##' | sort) > "$STATE/overlay-files.new"
if [ -f "$STATE/overlay-files" ]; then
  comm -23 <(sort "$STATE/overlay-files") "$STATE/overlay-files.new" | while IFS= read -r f; do
    case "$f" in /etc/*|/usr/*) echo "removing $f (no longer part of $DISTRO_NAME)"; rm -f "$f";; esac
  done
fi
mv "$STATE/overlay-files.new" "$STATE/overlay-files"
sed -i "s|@KERNEL_CMDLINE_EXTRA@|$KERNEL_CMDLINE_EXTRA|" /etc/default/grub.d/90-gogglesos.cfg
sed -i "s|@DISTRO_URL@|$DISTRO_URL|" /etc/xdg/kcm-about-distrorc

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
# Visor layout: the bar hugs its contents and sits centred (switch with goggles-panel)
sed -i "s/^\( *\)setPanelSizeFn( *panel_obj, is_horiz );/&\n\1if ( is_horiz ) { try { panel_obj.lengthMode = 'fit'; panel_obj.alignment = 'center'; } catch (e) {} }/" \
  "$TPL/contents/layout.js"
grep -q "lengthMode = 'fit'" "$TPL/contents/layout.js" || warn "could not set the Visor taskbar layout (full-width bar kept)"

install -D -m644 $A/appearance-glass.png /usr/share/$DISTRO_ID/appearance-glass.png
install -D -m644 $A/appearance-lite.png  /usr/share/$DISTRO_ID/appearance-lite.png
chmod 755 /usr/bin/goggles-theme
if [ "$APPLY_MODE" = build ]; then
  # Default for the live session and new installs (the installer can switch it to Lite)
  /usr/bin/goggles-theme glass --system
else
  # Keep the mode chosen in the installer. --defaults rewrites system defaults only, never
  # users' own choices (made with Goggles Appearance).
  /usr/bin/goggles-theme "$SYSTEM_MODE" --defaults
fi

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
rm -rf "${PT_D:?}"; mkdir -p $PT_D/translucent/widgets $PT_D/translucent/dialogs $PT_D/opaque/widgets $PT_D/widgets $PT_D/dialogs
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
# Taskbar: the "Visor" (rounded glass bar with a glowing accent line along the top), drawn by
# visor-panel.py for each transparency level. Falls back to a see-through Breeze bar.
visor() { # dst opacity breeze-fallback [panel|dialog]
  if python3 "$G/chroot/visor-panel.py" "$2" "${4:-panel}" > "$1.tmp" && [ -s "$1.tmp" ]; then
    gzip -9n < "$1.tmp" > "$1"; rm -f "$1.tmp"
  else
    rm -f "$1.tmp"; warn "could not draw the Goggles Glass background ($1); using Breeze's"
    [ -f "$3" ] && glassify "$3" "$1" "$2"
  fi
}
visor $PT_D/translucent/widgets/panel-background.svgz 0.55 $BREEZE_D/translucent/widgets/panel-background.svgz
visor $PT_D/widgets/panel-background.svgz             0.70 $BREEZE_D/widgets/panel-background.svgz
visor $PT_D/opaque/widgets/panel-background.svgz      1    $BREEZE_D/opaque/widgets/panel-background.svgz
# Popups (volume, network, calendar, notifications): the same glass with a light rim, rounder
# corners and a quieter accent line
visor $PT_D/translucent/dialogs/background.svgz       0.62 $BREEZE_D/translucent/dialogs/background.svgz dialog
visor $PT_D/dialogs/background.svgz                   0.75 $BREEZE_D/dialogs/background.svgz             dialog
glassify $BREEZE_D/translucent/widgets/background.svgz       $PT_D/translucent/widgets/background.svgz       0.62
# Plasma caches rendered theme graphics per theme version, so give each design its own
THEME_REV=$(find $PT_D -type f \( -name '*.svgz' -o -name plasmarc \) -exec sha256sum {} + | sort | sha256sum | cut -c1-8)
sed -i "s/\"Version\": \"[^\"]*\"/\"Version\": \"$DISTRO_VERSION.$THEME_REV\"/" $PT_D/metadata.json
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
  # Fix: the view buttons (Alphabetical / Categories) draw their own icon, so the button itself
  # has none and the widget style falls back to drawing the label under it. Keep the name for
  # the tooltip, and only give the button a label when the sidebar is expanded.
  TMUI="$TM_DIR/contents/ui"
  sed -i '/^\t\t\tSidebarViewButton {/,/^\t\t\t}/ s/^\(\t*\)text: i18n(/\1title: i18n(/' "$TMUI/SidebarView.qml"
  sed -i 's/^\tproperty string appletIconName: ""$/&\n\tproperty string title: ""\n\ttext: expanded ? title : ""\n\ttipText: title/' "$TMUI/SidebarViewButton.qml"
  sed -i -e 's/^\tproperty bool closeOnClick: true$/&\n\tproperty string tipText: text/' \
         -e 's/^\t\ttext: sidebarItem.text$/\t\ttext: sidebarItem.tipText/' "$TMUI/SidebarItem.qml"
  { [ "$(grep -c 'title: i18n(' "$TMUI/SidebarView.qml")" = 3 ] && grep -q 'tipText: title' "$TMUI/SidebarViewButton.qml" \
      && grep -q 'text: sidebarItem.tipText' "$TMUI/SidebarItem.qml"; } || warn "could not patch the start menu's view buttons"
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

log "Appearance: Goggles Glass terminal"
# Konsole profile and colours come from the overlay (/usr/share/konsole); make it the default
# for users who haven't picked a profile themselves
kwriteconfig6 --file /etc/xdg/konsolerc --group "Desktop Entry" --key DefaultProfile GogglesGlass.profile \
  || warn "could not set the default Konsole profile"

log "Cleanup: Kubuntu desktop links and menu entries"
rm -f /etc/skel/Desktop/org.kfocus.web.howtos.desktop /etc/skel/Desktop/org.kubuntu.web.home.desktop
mkdir -p /usr/local/share/applications
for d in org.kfocus.web.howtos org.kubuntu.web.home org.kubuntu.restore-desktop-links; do
  # /usr/local/share overrides /usr/share, and survives package updates
  printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "$d" \
    > /usr/local/share/applications/$d.desktop
done

log "Branding: login screen (SDDM)"
# Goggles login theme (chroot/sddm-theme): plain QtQuick, no extra dependencies
SDDM_GOGGLES=/usr/share/sddm/themes/$DISTRO_ID
SDDM_THEME=$(grep -h '^Current=' /etc/sddm.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2 || true)
if [ -d /usr/share/sddm/themes ]; then
  rm -rf "${SDDM_GOGGLES:?}"; mkdir -p "$SDDM_GOGGLES"
  install -m644 "$G"/chroot/sddm-theme/Main.qml "$G"/chroot/sddm-theme/metadata.desktop "$SDDM_GOGGLES/"
  cat > "$SDDM_GOGGLES/theme.conf" <<EOF
[General]
background=$WP/contents/images/1920x1080.png
logo=/usr/share/$DISTRO_ID/logo-dark.png
EOF
  # Make it the login screen unless another theme was chosen (System Settings > Login Screen)
  case "$SDDM_THEME" in
    ""|breeze|kubuntu|kubuntu-light|"$DISTRO_ID")
      SDDM_CONF=$(grep -l '^Current=' /etc/sddm.conf.d/*.conf 2>/dev/null | tail -1 || true)
      kwriteconfig6 --file "${SDDM_CONF:-/etc/sddm.conf.d/kde_settings.conf}" --group Theme --key Current "$DISTRO_ID" \
        || warn "could not select the Goggles login screen" ;;
    *) echo "Login screen: keeping the chosen theme ($SDDM_THEME)" ;;
  esac
fi
# Kubuntu's own login themes stay installed; give them the Goggles wallpaper and logo too
for t in breeze kubuntu; do
  [ -d "/usr/share/sddm/themes/$t" ] || continue
  cat > "/usr/share/sddm/themes/$t/theme.conf.user" <<EOF
[General]
background=$WP/contents/images/1920x1080.png
type=image
showlogo=shown
logo=/usr/share/$DISTRO_ID/logo-dark.png
EOF
done

log "Branding: startup splash"
# The lenses-and-visor splash (chroot/splash) replaces Breeze's in the Goggles look-and-feel
install -D -m644 "$G/chroot/splash/Splash.qml" "$LNF/contents/splash/Splash.qml"
sed -i "/^\[KSplash\]/,/^\[/ s#^Theme=.*#Theme=org.$DISTRO_ID.desktop#" "$LNF/contents/defaults"
kwriteconfig6 --file /etc/xdg/ksplashrc --group KSplash --key Theme "org.$DISTRO_ID.desktop" || warn "could not select the Goggles splash"
kwriteconfig6 --file /etc/xdg/ksplashrc --group KSplash --key Engine KSplashQML || true

log "GogglesXR dashboard"
# The Godot project (gogglesxr/dashboard). Run with: gogglesxr dashboard
XR_DASH=/usr/share/$DISTRO_ID/gogglesxr-dashboard
if [ -f "$G/gogglesxr/dashboard/project.godot" ]; then
  rm -rf "${XR_DASH:?}"; mkdir -p "$XR_DASH"
  install -m644 "$G"/gogglesxr/dashboard/project.godot "$G"/gogglesxr/dashboard/*.tscn "$G"/gogglesxr/dashboard/*.gd \
    "$G"/gogglesxr/dashboard/*.tres "$G"/gogglesxr/dashboard/*.uid "$G"/gogglesxr/dashboard/*.gdextension "$XR_DASH/"
  # The overlay extension (source in gogglesxr/overlay-extension) lets it draw on top of games
  install -D -m755 -t "$XR_DASH/bin" "$G"/gogglesxr/dashboard/bin/*.so
  # The home environment: the 360-degree picture shown while no game is running
  install -D -m644 -t "$XR_DASH/environments" "$G"/gogglesxr/dashboard/environments/*.jpg
else
  warn "GogglesXR dashboard sources missing"
fi
# The desktop view (gogglesxr/desktop-grab): pictures of the desktop for the dashboard. KWin only
# answers programs listed in a desktop file (overlay: org.gogglesos.gogglesxr-desktop-grab.desktop)
if [ -f "$G/gogglesxr/desktop-grab/gogglesxr-desktop-grab" ]; then
  install -D -m755 "$G/gogglesxr/desktop-grab/gogglesxr-desktop-grab" "/usr/libexec/$DISTRO_ID/gogglesxr-desktop-grab"
else
  warn "GogglesXR desktop view missing"
fi
# The capture layer (gogglesxr/capture-layer): screenshots and recordings of the headset view.
# gogglesxr copies it into each user's home folder, where Steam's game containers can load it
if [ -f "$G/gogglesxr/capture-layer/libgogglesxr_capture.so" ]; then
  install -D -m755 "$G/gogglesxr/capture-layer/libgogglesxr_capture.so" \
    "/usr/share/$DISTRO_ID/gogglesxr/layer/libgogglesxr_capture.so"
else
  warn "GogglesXR capture layer missing"
fi

log "Goggles Link"
# GogglesXR's own link software (github.com/jamoijyt/goggles-link, a fork of WiVRn): the PC side
# goes to /opt/goggles-link and the headset app to /usr/share/$DISTRO_ID/goggles-link.apk. Both
# come from a release of that repository, pinned by checksum in third_party/goggles-link.sha256
# (the file names carry the version). Skipped when that version is already installed.
GL_ROOT=/opt/goggles-link
GL_URL="https://github.com/jamoijyt/goggles-link/releases/download"
if [ -f "$G/third_party/goggles-link.sha256" ]; then
  gl_server=$(awk '/goggles-link-server-.*\.tar\.zst$/{print $2}' "$G/third_party/goggles-link.sha256")
  gl_apk=$(awk '/goggles-link-[0-9].*\.apk$/{print $2}' "$G/third_party/goggles-link.sha256")
  gl_version=${gl_server#goggles-link-server-}; gl_version=${gl_version%-x86_64.tar.zst}
  if [ -z "$gl_server" ] || [ -z "$gl_apk" ]; then
    warn "third_party/goggles-link.sha256 doesn't name a server archive and an APK"
  elif [ "$(cat "$GL_ROOT/VERSION" 2>/dev/null)" = "$gl_version" ] && [ -f "/usr/share/$DISTRO_ID/goggles-link.apk" ] \
      && [ "$(cat "/usr/share/$DISTRO_ID/goggles-link.version" 2>/dev/null)" = "$gl_version" ]; then
    : # already installed
  else
    gl_tmp=$(mktemp -d)
    if (cd "$gl_tmp" && wget -q -T 120 -t 3 "$GL_URL/gl-$gl_version/$gl_server" "$GL_URL/gl-$gl_version/$gl_apk" \
        && sha256sum -c --status "$G/third_party/goggles-link.sha256"); then
      rm -rf "${GL_ROOT:?}.new"; mkdir -p "$GL_ROOT.new"
      if tar --zstd -xf "$gl_tmp/$gl_server" -C "$GL_ROOT.new" --no-same-owner; then
        chown -R root:root "$GL_ROOT.new"; chmod -R go-w "$GL_ROOT.new"
        rm -rf "${GL_ROOT:?}"; mv "$GL_ROOT.new" "$GL_ROOT"
        install -D -m644 "$gl_tmp/$gl_apk" "/usr/share/$DISTRO_ID/goggles-link.apk"
        echo "$gl_version" > "/usr/share/$DISTRO_ID/goggles-link.version"
        # The Ubuntu libraries it was built against (listed by its build)
        if [ -s "$GL_ROOT/DEPENDS" ]; then
          gl_missing=$(while read -r pkg; do dpkg -s "$pkg" >/dev/null 2>&1 || echo "$pkg"; done < "$GL_ROOT/DEPENDS")
          if [ -n "$gl_missing" ]; then
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $gl_missing \
              || warn "some libraries Goggles Link needs couldn't be installed: $gl_missing"
          fi
        fi
      else
        rm -rf "${GL_ROOT:?}.new"; warn "the Goggles Link archive couldn't be unpacked"
      fi
    else
      warn "Goggles Link $gl_version couldn't be downloaded or didn't match its checksum; GogglesXR keeps using WiVRn"
    fi
    rm -rf "$gl_tmp"
  fi
fi

log "GogglesXR controller models"
# The dashboard draws your real controllers (Quest, Rift, Index, Vive...) using the WebXR Input
# Profiles models (MIT licence). They are data files, too big to keep in the repository, so they
# are downloaded from a pinned release and checked against third_party/webxr-controller-models.sha256.
# Files that are already installed and match are kept, so Goggles Update doesn't fetch them again.
# Without them the dashboard falls back to its own simple controller shapes.
XR_MODELS=/usr/share/$DISTRO_ID/gogglesxr-controllers
XR_MODELS_URL="https://cdn.jsdelivr.net/npm/@webxr-input-profiles/assets@1.0.20"
if [ -f "$G/third_party/webxr-controller-models.sha256" ]; then
  models_missing=0
  while read -r sum file; do
    [ -n "$file" ] || continue
    case "$file" in *..*|/*) warn "bad controller model path: $file"; continue ;; esac
    if [ -f "$XR_MODELS/$file" ] && echo "$sum  $XR_MODELS/$file" | sha256sum -c --status; then
      continue
    fi
    url="$XR_MODELS_URL/dist/profiles/$file"
    [ "$file" = LICENSE.md ] && url="$XR_MODELS_URL/LICENSE.md"
    tmp=$(mktemp)
    if wget -q -T 60 -t 3 -O "$tmp" "$url" && echo "$sum  $tmp" | sha256sum -c --status; then
      install -D -m644 "$tmp" "$XR_MODELS/$file"
    else
      models_missing=$((models_missing + 1))
    fi
    rm -f "$tmp"
  done < "$G/third_party/webxr-controller-models.sha256"
  [ "$models_missing" -eq 0 ] || warn "$models_missing controller model file(s) couldn't be downloaded; the dashboard uses simple shapes for those controllers"
fi

log "Desktop widget: Goggles HUD"
# CPU / RAM / GPU / network readouts (chroot/hud-plasmoid). Shown with goggles-hud or Add Widgets
HUD_DIR=/usr/share/plasma/plasmoids/org.$DISTRO_ID.hud
rm -rf "${HUD_DIR:?}"; mkdir -p "$HUD_DIR/contents/ui"
install -m644 "$G/chroot/hud-plasmoid/metadata.json" "$HUD_DIR/"
install -m644 "$G"/chroot/hud-plasmoid/contents/ui/*.qml "$HUD_DIR/contents/ui/"

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

# ------------------------------------------------------------------ updates
log "Goggles Update"
# Defaults for /usr/bin/goggles-update. Local changes go in /etc/gogglesos/update.conf.
mkdir -p "/usr/share/$DISTRO_ID"
cat > "/usr/share/$DISTRO_ID/update-defaults.conf" <<EOF
# Generated from config.sh. Override in /etc/gogglesos/update.conf (e.g. sudo goggles-update --channel main)
REPO=$UPDATE_REPO
CHANNEL=$UPDATE_CHANNEL
BRANCH=$UPDATE_BRANCH
DISTRO_ID=$DISTRO_ID
EOF
# Daily update check in every user session (systemd user timer)
mkdir -p /etc/systemd/user/timers.target.wants
ln -sf /usr/lib/systemd/user/goggles-update-check.timer /etc/systemd/user/timers.target.wants/goggles-update-check.timer

if [ "$APPLY_MODE" = update ]; then
  # Install apps added to config.sh since the last build or update. Apps the user removed
  # (listed in the last record) are not reinstalled.
  NEW=()
  for p in "${APT_PACKAGES[@]}"; do
    [ -f "$STATE/apt-packages" ] && grep -qxF -- "$p" "$STATE/apt-packages" && continue
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && continue
    NEW+=("$p")
  done
  if [ ${#NEW[@]} -gt 0 ]; then
    log "Installing new apps: ${NEW[*]}"
    "${APT[@]}" install "${NEW[@]}" || warn "some new apps could not be installed"
  fi
  for fp_id in "${FLATPAKS[@]}"; do
    [ -f "$STATE/flatpaks" ] && grep -qxF -- "$fp_id" "$STATE/flatpaks" && continue
    flatpak info --system "$fp_id" >/dev/null 2>&1 && continue
    log "Installing Flatpak $fp_id"
    flatpak install --system -y --noninteractive flathub "$fp_id" || warn "flatpak $fp_id failed"
  done

  # Regenerate what the changed settings feed into
  if [ "$BEFORE_GRUB" != "$(fp /etc/default/grub.d/90-gogglesos.cfg)" ]; then
    log "Kernel options changed: updating GRUB (takes effect after a reboot)"
    update-grub || warn "update-grub failed"
  fi
  if [ "$BEFORE_SYSCTL" != "$(fp /etc/sysctl.d/90-gogglesos.conf)" ]; then
    log "System tuning changed: reloading sysctl settings"
    sysctl --system >/dev/null || warn "sysctl reload failed"
  fi
  if [ "$BEFORE_SPLASH" != "$(fp "/usr/share/plymouth/themes/$DISTRO_ID")$(readlink -f /etc/alternatives/default.plymouth 2>/dev/null || true)" ]; then
    log "Boot splash changed: regenerating initramfs"
    update-initramfs -u || warn "update-initramfs failed"
  fi
  # Re-apply what package updates can undo (same as the APT hook)
  /usr/libexec/gogglesos/reapply || true
fi

# Records for the next update
printf '%s\n' "${APT_PACKAGES[@]}" > "$STATE/apt-packages"
printf '%s\n' "${FLATPAKS[@]}" > "$STATE/flatpaks"
cat > "$STATE/version" <<EOF
COMMIT=${SOURCE_COMMIT:-unknown}
SOURCE=$APPLY_MODE
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 644 "$STATE/apt-packages" "$STATE/flatpaks" "$STATE/version" "$STATE/overlay-files"
log "System configuration applied ($APPLY_MODE, ${SOURCE_COMMIT:-unknown})"
