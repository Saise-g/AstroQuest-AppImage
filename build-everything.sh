#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  AstroQuest Full Build & AppImage Script${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo ""

# 1. Print dependencies
echo -e "${YELLOW}⚠ IMPORTANT: Dependency Check${NC}"
echo "This script is distro-agnostic and will NOT install dependencies for you."
echo "Please ensure the following packages are installed on your system before proceeding."
echo ""
echo "Copy and paste the command for your distribution if you haven't already:"
echo ""
echo -e "${CYAN}  Debian / Ubuntu:${NC}"
echo "  sudo apt install git cmake ninja-build clang patchelf binutils desktop-file-utils file wget python3 pkg-config libx11-dev libwayland-dev libasound2-dev libpulse-dev libvulkan-dev libudev-dev libevdev-dev libhidapi-dev libssl-dev zlib1g-dev libpng-dev libcurl4-openssl-dev"
echo ""
echo -e "${CYAN}  Fedora:${NC}"
echo "  sudo dnf install git cmake ninja-build clang patchelf binutils desktop-file-utils file wget python3 pkgconf-pkg-config libX11-devel wayland-devel alsa-lib-devel pulseaudio-libs-devel vulkan-loader-devel systemd-devel libevdev-devel hidapi-devel openssl-devel zlib-devel libpng-devel libcurl-devel"
echo ""
echo -e "${CYAN}  Arch Linux:${NC}"
echo "  sudo pacman -S git cmake ninja clang patchelf binutils desktop-file-utils file wget python pkgconf libx11 wayland alsa-lib pulseaudio vulkan-headers systemd-libs libevdev hidapi openssl zlib libpng curl"
echo ""
read -p "Have you installed these dependencies? (y/N): " confirm
if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
    echo -e "${RED}Aborting. Please install the required dependencies and run the script again.${NC}"
    exit 1
fi

# 2. Ask for game directory
echo ""
echo -e "${CYAN}🎮 Game Directory${NC}"
echo "To bundle the game inside the AppImage, provide the path to the game's folder."
echo "This folder MUST contain 'eboot.bin' (e.g., a folder named CUSA12392)."
echo "Leave empty to skip bundling (the AppImage will ask for the game on first run)."
read -e -p "Path to game directory (or press Enter to skip): " GAME_DIR_INPUT

if [[ -n "$GAME_DIR_INPUT" ]]; then
    # Resolve to absolute path
    GAME_DIR_INPUT="$(readlink -f "$GAME_DIR_INPUT")"
    if [[ ! -d "$GAME_DIR_INPUT" ]]; then
        echo -e "${RED}Error: Directory '$GAME_DIR_INPUT' does not exist.${NC}"
        exit 1
    fi
    if [[ ! -f "$GAME_DIR_INPUT/eboot.bin" ]]; then
        echo -e "${RED}Error: 'eboot.bin' not found in '$GAME_DIR_INPUT'. Is this the correct game folder?${NC}"
        exit 1
    fi
    echo -e "${YELLOW}✓ Game will be bundled from: $GAME_DIR_INPUT${NC}"
    export GAME_DIR="$GAME_DIR_INPUT"
else
    echo -e "${YELLOW}✓ Skipping game bundle. The AppImage will prompt for the game path on first run.${NC}"
fi

# 3. Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/astroquest-src"
BUILD_DIR="$REPO_DIR/shadps4-arm64-main/build"
SHADPS4_BIN="$BUILD_DIR/shadps4"
LAUNCHER_SCRIPT="$SCRIPT_DIR/astroquest-linux-v2.sh"
BUILD_APPIMAGE_SCRIPT="$SCRIPT_DIR/build-appimage.sh"

# 4. Verify helper scripts exist
if [[ ! -f "$LAUNCHER_SCRIPT" ]]; then
    echo -e "${RED}Error: Launcher script not found at $LAUNCHER_SCRIPT${NC}"
    echo "Please ensure 'astroquest-linux-v2.sh' is in the same directory as this script."
    exit 1
fi

if [[ ! -f "$BUILD_APPIMAGE_SCRIPT" ]]; then
    echo -e "${RED}Error: AppImage build script not found at $BUILD_APPIMAGE_SCRIPT${NC}"
    echo "Please ensure 'build-appimage.sh' is in the same directory as this script."
    exit 1
fi

# 5. Clone or update repository
echo ""
echo -e "${CYAN}📦 Fetching AstroQuest source code...${NC}"
if [[ -d "$REPO_DIR" ]]; then
    echo "Directory exists. Updating repository and submodules..."
    cd "$REPO_DIR"
    git pull --recurse-submodules
else
    git clone --recurse-submodules https://github.com/bigmak94/AstroQuest.git "$REPO_DIR"
    cd "$REPO_DIR"
fi

# 6. Compile shadps4
echo ""
echo -e "${CYAN}⚙️  Compiling shadps4 (this may take a while and requires ~4-8GB of RAM)...${NC}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Use clang as explicitly recommended by the upstream README for Linux native builds
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    ..

ninja

if [[ ! -x "$SHADPS4_BIN" ]]; then
    echo -e "${RED}Error: Compilation failed or shadps4 binary not found at $SHADPS4_BIN${NC}"
    exit 1
fi

echo -e "${YELLOW}✓ Compilation successful! Binary located at: $SHADPS4_BIN${NC}"

# 7. Build AppImage
echo ""
echo -e "${CYAN}📦 Building AppImage...${NC}"
cd "$SCRIPT_DIR"

# Ensure scripts are executable
chmod +x "$LAUNCHER_SCRIPT" "$BUILD_APPIMAGE_SCRIPT"

# Run the build-appimage.sh script, passing the compiled binary and the launcher.
# The GAME_DIR environment variable is automatically inherited by build-appimage.sh.
echo "Executing: $BUILD_APPIMAGE_SCRIPT $SHADPS4_BIN $LAUNCHER_SCRIPT"
"$BUILD_APPIMAGE_SCRIPT" "$SHADPS4_BIN" "$LAUNCHER_SCRIPT"

echo ""
echo -e "${CYAN}=======================================================${NC}"
echo -e "${YELLOW}🎉 Build Complete!${NC}"
echo -e "Your AppImage is ready at: ${SCRIPT_DIR}/AstroQuest-x86_64.AppImage"
if [[ -n "${GAME_DIR:-}" ]]; then
    echo -e "${YELLOW}Note: The game has been bundled inside the AppImage.${NC}"
else
    echo -e "${YELLOW}Note: No game was bundled. The AppImage will ask you for the game folder on first run.${NC}"
fi
echo -e "${CYAN}=======================================================${NC}"