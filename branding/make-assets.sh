#!/bin/bash
# Generate all branding images from branding/source into $1 (output dir).
# Needs ImageMagick (convert) with webp support.
set -euo pipefail
# Fixed timestamps inside the PNGs: the same artwork always gives the same files, so Goggles
# Update can tell when the boot splash really changed (and skip regenerating the initramfs)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
SRC="$(cd "$(dirname "$0")/source" && pwd)"
OUT="$1"
mkdir -p "$OUT/icons"

# Wallpaper (KDE wallpaper package wants png/jpg per resolution)
convert "$SRC/wallpaper.webp" -resize 1920x1080^ -gravity center -extent 1920x1080 "$OUT/wallpaper-1920x1080.png"
convert "$OUT/wallpaper-1920x1080.png" -resize 400x225 "$OUT/wallpaper-preview.png"

# App/distributor icon at standard sizes
for s in 16 22 24 32 48 64 96 128 256 512; do
  convert "$SRC/icon.png" -background none -resize ${s}x${s} "$OUT/icons/${s}.png"
done
cp "$OUT/icons/256.png" "$OUT/gogglesos-logo.png"

# Wordmark: source is black text on transparent -> white + black versions
convert "$SRC/wordmark.png" -fill white -colorize 100 -trim +repage "$OUT/wordmark-white.png"
convert "$SRC/wordmark.png" -trim +repage "$OUT/wordmark-black.png"

# Horizontal logo for dark backgrounds: icon + white wordmark
convert "$SRC/icon.png" -trim +repage -resize x300 "$OUT/_icon300.png"
convert "$OUT/wordmark-white.png" -resize x150 "$OUT/_wm150.png"
convert -background none "$OUT/_icon300.png" \( -size 60x1 xc:none \) "$OUT/_wm150.png" -gravity center +append "$OUT/logo-dark.png"
rm -f "$OUT/_icon300.png" "$OUT/_wm150.png"
# Horizontal logo for light backgrounds (as supplied)
convert "$SRC/logo-horizontal.png" -trim +repage "$OUT/logo-light.png"

# Sized variants used by boot splash / installer / login
convert "$OUT/logo-dark.png" -resize 420x "$OUT/logo-dark-420.png"
convert "$OUT/logo-dark.png" -resize 800x "$OUT/logo-dark-800.png"

# Installer (Calamares) welcome banner, 800x300, and 86px sidebar logo
# (white-text logo: the installer runs in the dark Glass theme)
convert "$OUT/logo-dark.png" -resize 760x260 -background none -gravity center -extent 800x300 "$OUT/welcome.png"
convert "$SRC/icon.png" -background none -resize 86x86 "$OUT/calamares-logo.png"

# Installer slideshow (1920x1080): wallpaper + dark panel + text
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
FONTB=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
slide() { # n title body
  convert "$OUT/wallpaper-1920x1080.png" \
    \( -size 1920x1080 xc:none -fill 'rgba(5,25,22,0.72)' -draw 'roundrectangle 120,300 1300,700 40,40' \) -composite \
    \( "$OUT/logo-dark.png" -resize x110 \) -gravity northwest -geometry +120+120 -composite \
    -font "$FONTB" -pointsize 76 -fill white -annotate +190+350 "$2" \
    \( -size 1020x -background none -font "$FONT" -pointsize 44 -fill '#d8f5e3' caption:"$3" \) \
    -gravity northwest -geometry +190+490 -composite \
    "$OUT/slide-$1.png"
}
slide 1 "Welcome to Goggles OS" "The Linux desktop built for PC VR gaming. Sit back while it installs."
slide 2 "VR ready with GogglesXR" "GogglesXR streams your VR games to standalone headsets such as the Meta Quest. Steam and Proton tools come preinstalled."
slide 3 "Tuned for your GPU" "AMD Mesa and NVIDIA drivers, low-latency kernel scheduling and GameMode keep frame times smooth."
slide 4 "Put your headset on" "Open GogglesXR from the app menu, connect your headset, and start a VR game from Steam or from the dashboard inside the headset."
slide 5 "Stream and chat" "OBS Studio, Discord, MangoHud and ProtonUp-Qt are ready the moment you log in."

# Installer "Appearance" previews (960x540): a window over the wallpaper, glass vs solid
appearance() { # name window-fill blur
  local W="$OUT/wallpaper-1920x1080.png" T="$OUT/_ap"
  convert "$W" -resize 960x540 "$T-bg.png"
  # window body: blurred wallpaper (glass) or flat colour (lite), rounded 18px
  if [ "$3" = blur ]; then
    convert "$T-bg.png" -crop 560x340+200+100 +repage -blur 0x14 \
      \( -size 560x340 xc:"$2" \) -composite "$T-win.png"
  else
    convert -size 560x340 xc:"$2" "$T-win.png"
  fi
  convert -size 560x340 xc:none -fill white -draw 'roundrectangle 0,0 559,339 18,18' "$T-mask.png"
  convert "$T-win.png" "$T-mask.png" -alpha off -compose CopyOpacity -composite "$T-win.png"
  # title bar + fake content lines
  convert "$T-win.png" -fill 'rgba(255,255,255,0.10)' -draw 'rectangle 0,0 560,38' \
    -fill 'rgba(61,220,132,0.95)' -draw 'roundrectangle 24,70 220,92 8,8' \
    -fill 'rgba(255,255,255,0.35)' -draw 'roundrectangle 24,120 500,134 6,6' \
    -draw 'roundrectangle 24,150 440,164 6,6' -draw 'roundrectangle 24,180 470,194 6,6' "$T-win.png"
  convert "$T-bg.png" \( "$T-win.png" -background black -shadow 60x12+0+8 \) -geometry +188+96 -composite \
    "$T-win.png" -geometry +200+100 -composite \
    \( -size 960x44 xc:"$2" \) -geometry +0+496 -composite "$OUT/appearance-$1.png"
  rm -f "$T"-*.png
}
appearance glass 'rgba(8,30,26,0.55)' blur
appearance lite  'rgb(30,36,34)' solid

echo "Assets written to $OUT"
