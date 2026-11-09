#!/bin/bash
# Rebuild Kubuntu's live "Try or Install" welcome app (kubuntu-installer-prompt, GPL-3)
# with Goggles OS name, artwork and colours. Runs on the build host (same Ubuntu release
# as the image) and writes the binary to $3.
# Usage: build-installer-prompt.sh <version> <assets-dir> <output-binary>
set -euo pipefail
VER="$1"; ASSETS="$2"; OUTBIN="$3"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config.sh
source "$HERE/config.sh"
K=/var/lib/gogglesos-build/installer-prompt
rm -rf "$K"; mkdir -p "$K/lists/partial"; cd "$K"

# Fetch the exact source version without touching the host's apt sources
cat > src.sources <<EOF
Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $DISTRO_CODENAME $DISTRO_CODENAME-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
O=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$K" -o Dir::State::Lists="$K/lists")
apt-get "${O[@]}" update -qq
apt-get "${O[@]}" source -qq --download-only "kubuntu-installer-prompt=$VER"
mkdir src; tar xf kubuntu-installer-prompt_*.tar.* -C src --strip-components=1
cd src

# Build dependencies (host only)
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  cmake make g++ extra-cmake-modules libkf6config-bin libkf6networkmanagerqt-dev \
  qt6-base-dev qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools >/dev/null

# Artwork
cp "$ASSETS/wallpaper-1920x1080.png" img/background.png
convert "$ASSETS/logo-dark.png" -resize x170 -background none -gravity center -extent 875x170 img/kubuntu-logo.png

# Visible text: "Kubuntu" -> distro name (widget names like tryKubuntu are left alone)
sed -i -E "s/([ >;])Kubuntu([ <&.,])/\1${DISTRO_NAME}\2/g" src/*.ui
# Colours: Kubuntu blues -> Goggles greens
sed -i -e 's/#17325b/#0f3d36/Ig' -e 's/#112747/#0a2a26/Ig' -e 's/#183867/#145046/Ig' \
       -e 's/#142c53/#0e3a33/Ig' -e 's/#3f5369/#2f6b5e/Ig' -e 's/#3e5267/#2f6b5e/Ig' \
       -e 's/rgb(30, 144, 255)/rgb(61, 220, 132)/g' src/*.ui src/*.cpp

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
install -D -m755 build/kubuntu-installer-prompt "$OUTBIN" 2>/dev/null \
  || install -D -m755 "$(find build -type f -name kubuntu-installer-prompt -perm -u+x | head -1)" "$OUTBIN"
echo "Built $OUTBIN"
