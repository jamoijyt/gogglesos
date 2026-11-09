# Goggles OS build configuration. Sourced by build.sh and chroot/customize.sh.

DISTRO_NAME="Goggles OS"
DISTRO_ID="gogglesos"              # used for file names / branding dirs (os-release ID stays "ubuntu")
DISTRO_VERSION="26.04"
DISTRO_CODENAME="resolute"
DISTRO_URL="https://example.com/gogglesos"   # TODO: your website / GitHub
ISO_VOLID="GogglesOS 26.04"        # max 32 chars

# Base: official Kubuntu LTS ISO (Plasma + Calamares + signed boot chain)
BASE_ISO_URL="https://cdimage.ubuntu.com/kubuntu/releases/26.04/release/kubuntu-26.04.1-desktop-amd64.iso"
BASE_ISO_SHA256="831e4d4bb85098339ba43d3502cd6619b27e76daf37246a084cd68a6413090b8"

# Where big files go. CACHE/OUTPUT can live on another Windows drive (/mnt/d/...);
# ROOTFS must be on a Linux filesystem (inside WSL) because it is chrooted into.
CACHE_DIR="/mnt/d/GogglesOS/cache"
OUTPUT_DIR="/mnt/d/GogglesOS/output"
WORK_DIR="/var/lib/gogglesos-build"

# GPU variant:
#   nvidia : Mesa (AMD/Intel) + NVIDIA proprietary driver. Works on AMD too.
#   amd    : Mesa only (smaller ISO).
GPU_VARIANT="${GPU_VARIANT:-nvidia}"

# NVIDIA 580 is the last branch supporting GTX 900/10-series (Pascal, e.g. GTX 1080)
# and also covers RTX 20/30/40. RTX 50-series needs the open modules: use "580-open".
NVIDIA_BRANCH="${NVIDIA_BRANCH:-580}"

# Extra kernel boot options for low-latency VR (stock Ubuntu kernel is PREEMPT_DYNAMIC).
KERNEL_CMDLINE_EXTRA="preempt=full threadirqs"

# Packages from the Ubuntu archive
APT_PACKAGES=(
  steam-installer steam-devices                 # Steam + udev rules for Index/Vive/Quest/controllers
  obs-studio
  gamemode libgamemode0:i386
  mangohud goverlay
  protontricks
  mesa-vulkan-drivers mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 vulkan-tools
  flatpak plasma-discover-backend-flatpak
  libcap2-bin
  qt6-style-kvantum qt-style-kvantum-themes      # Goggles Glass theme engine
  papirus-icon-theme                            # default icons (green folders)
  open-vm-tools open-vm-tools-desktop           # VMware guest tools (resize, clipboard)
  software-properties-common
)

# Flatpaks (installed system-wide from Flathub at build time; failures are non-fatal)
FLATPAKS=(
  net.davidotek.pupgui2      # ProtonUp-Qt: install Proton-GE etc.
)

# Third-party .deb downloads
DISCORD_DEB_URL="https://discord.com/api/download?platform=linux&format=deb"
