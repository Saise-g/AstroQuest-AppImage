#!/usr/bin/env bash
# Builds AstroQuest-x86_64.AppImage from a compiled shadps4 binary + the launcher script.
# Run it in the Fedora distrobox where shadps4 was compiled (so the libraries match):
#
#   sudo dnf install -y patchelf binutils desktop-file-utils file wget python3
#   ./build-appimage.sh /path/to/AstroQuest/shadps4-arm64-main/build/shadps4 [launcher.sh]
#
# By default the game is NOT put inside (13 GB): the AppImage asks for its folder the first time.
# To pack the game in as well (personal use only, never share the result):
#   GAME_DIR=/path/to/CUSA12392 ./build-appimage.sh /path/to/shadps4
# (the folder with eboot.bin in it; needs about 30 GB free while building).
# Name and icon shown by Gear Lever / the app menu (all optional):
#   APP_NAME="Astro Bot VR" ICON_FILE=/path/to/icon.png VERSION=1.0 ./build-appimage.sh ...
# SKIP_PACKAGE=1 only assembles AppDir (no downloads, no AppImage) so it can be inspected.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:?usage: $0 /path/to/shadps4 [launcher.sh]}"
LAUNCHER="${2:-$HERE/astroquest-linux-v2.sh}"
[[ -x $BIN ]] || { echo "Not an executable: $BIN" >&2; exit 1; }
[[ -f $LAUNCHER ]] || { echo "Launcher not found: $LAUNCHER (pass it as the 2nd argument)" >&2; exit 1; }
WORK="${WORK:-$HERE/appimage-work}"
APPDIR="$WORK/AppDir"
TOOLS="$WORK/tools"
OUT="${OUT:-$HERE/AstroQuest-x86_64.AppImage}"
rm -rf "$APPDIR"; mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$TOOLS"
echo "== libraries the binary needs that this system cannot find (should be none):"
ldd "$BIN" | grep "not found" || echo "   none"
install -m755 "$BIN" "$APPDIR/usr/bin/shadps4"
install -m755 "$LAUNCHER" "$APPDIR/usr/bin/astroquest-linux.sh"

# Icon logic:
# 1. Use ICON_FILE if provided
# 2. Try downloading from SteamGridDB
# 3. Fall back to searching the source tree for shadps4.png
ICON=""
if [[ -n ${ICON_FILE:-} ]]; then
    [[ -f $ICON_FILE ]] || { echo "ICON_FILE not found: $ICON_FILE" >&2; exit 1; }
    ICON="$ICON_FILE"
else
    ICON="$WORK/astroquest.png"
    echo "== attempting to download icon from SteamGridDB"
    if wget -q --show-progress -O "$ICON" "https://cdn2.steamgriddb.com/grid/c53ac9ade3474ca5919bd1f5eb5c17e1.png"; then
        echo "== icon downloaded successfully"
    else
        echo "== download failed, falling back to local search"
        SRC_ICON="$(find "$(dirname "$BIN")/.." -maxdepth 4 -name 'shadps4.png' 2>/dev/null | head -n1 || true)"
        if [[ -n $SRC_ICON ]]; then
            cp "$SRC_ICON" "$ICON"
            echo "== using local source icon: $SRC_ICON"
        else
            echo "== no icon found, proceeding without custom icon"
            ICON=""
        fi
    fi
fi

APP_NAME="${APP_NAME:-Astro Bot VR}"
VERSION="${VERSION:-1.0}"
DESKTOP="$APPDIR/usr/share/applications/astroquest.desktop"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
GenericName=VR game launcher
Comment=ASTRO BOT Rescue Mission in VR through AstroQuest
Exec=astroquest-linux.sh
Icon=astroquest
Categories=Game;
Keywords=VR;PS4;AstroBot;emulator;
Terminal=false
StartupNotify=false
X-AppImage-Name=AstroQuest
X-AppImage-Version=$VERSION
Actions=Settings;
[Desktop Action Settings]
Name=Settings
Exec=astroquest-linux.sh --menu
EOF
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$DESKTOP" && echo "== desktop file is valid" || echo "== desktop-file-validate complained (see above)"
fi
cat > "$WORK/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/astroquest-linux.sh" "$@"
EOF
chmod +x "$WORK/AppRun"

# The game goes in after the libraries are collected, so no tool ever scans it.
add_game() {
    [[ -n ${GAME_DIR:-} ]] || return 0
    [[ -f $GAME_DIR/eboot.bin ]] || { echo "GAME_DIR must be the game's folder (the one with eboot.bin in it): $GAME_DIR" >&2; exit 1; }
    local dest="$APPDIR/usr/share/astroquest/games/$(basename "$GAME_DIR")"
    mkdir -p "$(dirname "$dest")"
    echo "== adding the game ($(du -sh "$GAME_DIR" | cut -f1)) to the image"
    cp -al "$GAME_DIR" "$dest" 2>/dev/null || cp -a --reflink=auto "$GAME_DIR" "$dest"
}

if [[ ${SKIP_PACKAGE:-0} == 1 ]]; then
    add_game
    cp "$WORK/AppRun" "$APPDIR/AppRun"
    [[ -n $ICON && -f $ICON ]] && cp "$ICON" "$APPDIR/$(basename "$ICON")"
    echo "AppDir assembled in $APPDIR (SKIP_PACKAGE=1: nothing else done)"; exit 0
fi

export APPIMAGE_EXTRACT_AND_RUN=1   # the tools are AppImages themselves; no FUSE needed here
export ARCH=x86_64
fetch() { [[ -x $TOOLS/$1 ]] || { wget -q --show-progress -O "$TOOLS/$1" "$2" && chmod +x "$TOOLS/$1"; }; }
fetch linuxdeploy "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
fetch appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

echo "== collecting libraries"
ICON_ARGS=()
if [[ -n $ICON && -f $ICON ]]; then
    ICON_ARGS=(--icon-file "$ICON" --icon-filename astroquest)
fi

"$TOOLS/linuxdeploy" --appdir "$APPDIR" --executable "$APPDIR/usr/bin/shadps4" \
    --desktop-file "$DESKTOP" \
    "${ICON_ARGS[@]}" --custom-apprun "$WORK/AppRun"

# The host's own Vulkan loader and graphics libraries must be used, never a copy from here.
find "$APPDIR/usr/lib" "$APPDIR/usr/lib64" -maxdepth 3 \( -name 'libvulkan*' -o -name 'libGL.so*' -o -name 'libEGL*' -o -name 'libgbm*' -o -name 'libdrm*' \) -print -delete 2>/dev/null || true

add_game

COMP=()
[[ -n ${GAME_DIR:-} ]] && COMP=(--comp zstd)   # a 13 GB image: zstd packs fast and unpacks fast
echo "== packing"
"$TOOLS/appimagetool" --no-appstream "${COMP[@]}" "$APPDIR" "$OUT"

echo
echo "Done: $OUT"
echo "Run it on the host (not in the distrobox):  chmod +x '$OUT' && '$OUT'"
echo "Or open it with Gear Lever (Flatpak: it.mijorus.gearlever) and add it to the app menu."
echo "If it complains about FUSE:                  APPIMAGE_EXTRACT_AND_RUN=1 '$OUT'"