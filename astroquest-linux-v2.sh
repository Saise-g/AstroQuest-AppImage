#!/usr/bin/env bash
# Linux launcher for AstroQuest PC VR: a port of "Play Astro Bot VR.bat" + pc-vr/launch.ps1.
#
# Two ways to use it:
#  * Next to the emulator (pc-vr/ folder): settings.txt and the games folder are beside it.
#  * Inside an AppImage (built by build-appimage.sh): settings live in ~/.config/AstroQuest,
#    the emulator's saves and logs in ~/.local/share/AstroQuest, and the game wherever you
#    point it to the first time (it is remembered as game= in settings.txt).
#
#   ./astroquest-linux.sh                 look for the game and start it (settings menu first)
#   ./astroquest-linux.sh /path/to/game   a folder with eboot.bin, an eboot.bin, or a .pkg
#   ./astroquest-linux.sh --menu          show the settings menu even if menu=0 is saved
#   ./astroquest-linux.sh --no-menu       skip the settings menu this time
#   ./astroquest-linux.sh --gui | --tty   force dialog windows (zenity/kdialog) or the terminal
#   ./astroquest-linux.sh --dry-run       print the environment and command, do not start
#
# Emulator: ./shadps4 (native build) or ./shadps4.exe (Windows build through Proton or Wine:
# PROTON="/path/to/proton" ./astroquest-linux.sh). PKGTOOL=/path/to/PkgTool.Core unpacks a .pkg.
set -u

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
if [[ -n ${APPIMAGE:-} || ${ASTROQUEST_APPMODE:-0} == 1 ]]; then
  APPMODE=1
  CONF="${XDG_CONFIG_HOME:-$HOME/.config}/AstroQuest"
  DATA="${XDG_DATA_HOME:-$HOME/.local/share}/AstroQuest"
  ROOT="$DATA"; GAMES="$DATA/games"
  SETTINGS="${ASTROQUEST_SETTINGS:-$CONF/settings.txt}"
  mkdir -p "$CONF" "$GAMES"
  [[ -f $SETTINGS ]] || printf '# AstroQuest settings. The menu at start edits them; every key is explained in README-PC-VR.md.\n' >"$SETTINGS"
else
  APPMODE=0
  ROOT="$(dirname "$HERE")"; DATA="$HERE"; GAMES="$ROOT/games"
  SETTINGS="${ASTROQUEST_SETTINGS:-$HERE/settings.txt}"
fi
# A game packed inside the AppImage (build-appimage.sh with GAME_DIR=...) lives here:
EMBEDDED="$(dirname "$HERE")/share/astroquest/games"
ZERO_PASSCODE=00000000000000000000000000000000
MADE_FOR_REGEX='CUSA1(2392|2431)'
LONGEST_INSIDE=126

if [[ -t 1 ]]; then Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else Y=''; R=''; C=''; N=''; fi
say()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$Y" "$*" "$N"; }

# --- dialogs: zenity (GNOME) or kdialog (KDE) when there is a display, the terminal otherwise ---
GUI_TOOL=""
detect_gui() {
  [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || return 1
  local want=zenity other=kdialog
  if [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]]; then want=kdialog; other=zenity; fi
  if command -v "$want" >/dev/null 2>&1; then GUI_TOOL=$want
  elif command -v "$other" >/dev/null 2>&1; then GUI_TOOL=$other
  else return 1; fi
}
use_gui() { [[ -n $GUI_TOOL ]]; }

# gui_msg error|warning|info "text"   (nothing when there is no dialog tool)
gui_msg() {
  local kind=$1; shift; local text=$*
  use_gui || return 0
  case $GUI_TOOL in
    zenity) zenity "--$kind" --no-markup --title="Astro Bot VR" --text="$text" --width=480 2>/dev/null || true ;;
    kdialog)
      case $kind in
        error) kdialog --title "Astro Bot VR" --error "$text" ;;
        warning) kdialog --title "Astro Bot VR" --sorry "$text" ;;
        *) kdialog --title "Astro Bot VR" --msgbox "$text" ;;
      esac 2>/dev/null || true ;;
  esac
}
notify() { command -v notify-send >/dev/null 2>&1 && notify-send "Astro Bot VR" "$*" 2>/dev/null; return 0; }
die() { printf '%s%s%s\n' "$R" "$*" "$N" >&2; gui_msg error "$*"; use_gui || notify "$*"; exit 1; }

DRY="${DRY_RUN:-0}"; GAME_ARG=""; FORCE_MENU=0; NO_MENU=0; UI="${ASTROQUEST_UI:-auto}"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --menu) FORCE_MENU=1 ;;
    --no-menu) NO_MENU=1 ;;
    --gui) UI=gui ;;
    --tty) UI=tty ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$SELF"; exit 0 ;;
    *) GAME_ARG="$a" ;;
  esac
done
if [[ $UI != tty ]]; then detect_gui || { [[ $UI == gui ]] && warn "--gui: no zenity/kdialog (or no display) found, using the terminal."; }; fi
can_ask() { use_gui || [[ -t 0 ]] || (( FORCE_MENU )); }

# --- settings (key=value per line; "env=NAME=value" lines are extra environment variables) ---
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
declare -A S=()
EXTRA_ENV=()
if [[ -f $SETTINGS ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    line=$(trim "$line")
    [[ -z $line || $line == \#* || $line != *=* ]] && continue
    key=$(trim "${line%%=*}"); key="${key,,}"
    val=$(trim "${line#*=}")
    [[ -z $key ]] && continue
    if [[ $key == env ]]; then EXTRA_ENV+=("$val"); else S[$key]=$val; fi
  done < "$SETTINGS"
fi
setting() { local k=$1 d=${2-}; if [[ -n ${S[$k]+x} ]]; then printf '%s' "${S[$k]}"; else printf '%s' "$d"; fi; }

# Writes key=value into settings.txt: in place of the line that sets it, or at the end.
save_setting() {
  local key=$1 value=$2 tmp line done=0
  S[$key]=$value
  tmp=$(mktemp)
  if [[ -f $SETTINGS ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%$'\r'}"
      if [[ $line =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then printf '%s=%s\n' "$key" "$value" >>"$tmp"; done=1
      else printf '%s\n' "$line" >>"$tmp"; fi
    done <"$SETTINGS"
  fi
  (( done )) || printf '%s=%s\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >"$SETTINGS" 2>/dev/null || warn "Could not write $SETTINGS"
  rm -f "$tmp"
}

get_fps() {
  local v; v=$(trim "$(setting fps full)"); v="${v,,}"
  if [[ $v != full && $v =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v n="$v" 'BEGIN{exit !(n>=10)}'; then printf '%s' "$v"; else printf 'full'; fi
}

# --- finding / unpacking the game --------------------------------------------------------------
find_game() {
  local top=$1 e d first=""
  [[ -d $top ]] || return 1
  while IFS= read -r e; do
    d=$(dirname "$e")
    [[ $d =~ -(UPDATE|patch|mods)$ ]] && continue
    case "$d" in */.u|*/.u/*|*/.unpacking|*/.unpacking/*) continue ;; esac
    if grep -qaE "$MADE_FOR_REGEX" "$d/sce_sys/param.sfo" 2>/dev/null; then printf '%s\n' "$e"; return 0; fi
    [[ -z $first ]] && first=$e
  done < <(find "$top" -maxdepth 4 -type f -name eboot.bin 2>/dev/null | sort)
  [[ -n $first ]] || return 1
  printf '%s\n' "$first"
}

pkg_magic_ok() { [[ $(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n') == 7f434e54 ]]; }
is_update_pkg() {
  pkg_magic_ok "$1" || return 1
  local b; read -r -a b < <(od -An -tu1 -j120 -N2 "$1")
  (( (b[0] & 0x60) != 0 || (b[1] & 0x30) != 0 ))
}

find_package() {
  local top=$1 f size best="" bestsize=-1 bestupd=1 upd
  [[ -d $top ]] || return 1
  while IFS= read -r f; do
    [[ $f == */.u/* ]] && continue
    size=$(stat -c %s "$f"); upd=0
    is_update_pkg "$f" && upd=1
    if [[ -z $best ]] || (( bestupd == 1 && upd == 0 )) || (( bestupd == upd && size > bestsize )); then
      best=$f; bestsize=$size; bestupd=$upd
    fi
  done < <(find "$top" -maxdepth 4 -type f -iname '*.pkg' 2>/dev/null | sort)
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

find_pkgtool() {
  local c
  for c in "${PKGTOOL:-}" "$HERE/pkgtool/PkgTool.Core" "$ROOT/tools/pkgtool/PkgTool.Core" "$(command -v PkgTool.Core 2>/dev/null || true)"; do
    if [[ -n $c && -x $c ]]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# Prints the unpacked game's eboot.bin on stdout; messages go to stderr.
expand_package() {
  local pkg=$1 tool content serial target work unpacked item size needed avail line idx name file a
  local left=" DIGESTS ENTRY_KEYS IMAGE_KEY GENERAL_DIGESTS METAS ENTRY_NAMES LICENSE_DAT LICENSE_INFO "
  pkg_magic_ok "$pkg" || { warn "$pkg is not a PlayStation 4 package." >&2; return 1; }
  if is_update_pkg "$pkg"; then
    warn "$pkg is an update of the game, not the game itself. Use the game's own package (about 7 GB)." >&2; return 1
  fi
  tool=$(find_pkgtool) || { warn "PkgTool.Core was not found: set PKGTOOL=/path/to/PkgTool.Core (LibOrbisPkg v0.2 release), or unpack the package yourself and point to the folder." >&2; return 1; }
  content=$(dd if="$pkg" bs=1 skip=64 count=36 2>/dev/null | tr -d '\0')
  serial=$(grep -oE '[A-Z]{4}[0-9]{5}' <<<"$content" | head -n1); serial=${serial:-game}
  target="$GAMES/$serial"; work="$GAMES/.u"
  size=$(stat -c %s "$pkg"); needed=$(( size * 185 / 100 ))
  mkdir -p "$GAMES"
  avail=$(df -B1 --output=avail "$GAMES" | tail -n1 | tr -d ' ')
  if (( avail < needed )); then warn "Unpacking needs about $(( needed / 1073741824 )) GB; only $(( avail / 1073741824 )) GB free in $GAMES." >&2; return 1; fi
  if [[ -t 0 ]]; then
    read -r -p "The game is a package ($(basename "$pkg")). Unpack it into $target now? [Y/n] " a >&2
    [[ ${a,,} == n* ]] && return 1
  fi
  rm -rf "$work"; mkdir -p "$work"
  say "Unpacking $pkg (a minute or a few)..." >&2
  if ! "$tool" pkg_extract --passcode "$ZERO_PASSCODE" "$pkg" "$work" \
        >"${TMPDIR:-/tmp}/AstroQuest-pkgtool-output.txt" 2>"${TMPDIR:-/tmp}/AstroQuest-pkgtool-errors.txt"; then
    warn "Unpacking failed (see ${TMPDIR:-/tmp}/AstroQuest-pkgtool-errors.txt). Only a package made from a dump can be unpacked, not an encrypted one from the PlayStation Store." >&2
    rm -rf "$work"; return 1
  fi
  unpacked="$work/uroot"; [[ -d $unpacked ]] || unpacked=$work
  [[ -f $unpacked/eboot.bin ]] || { warn "The package was unpacked but has no eboot.bin." >&2; rm -rf "$work"; return 1; }
  mkdir -p "$target"
  shopt -s dotglob nullglob
  for item in "$unpacked"/*; do rm -rf "${target:?}/$(basename "$item")"; mv "$item" "$target/"; done
  shopt -u dotglob nullglob
  while IFS= read -r line; do
    if [[ $line =~ ^0x[0-9A-Fa-f]+[[:space:]]+0x[0-9A-Fa-f]+[[:space:]]+[0-9A-Fa-f]+[[:space:]]+([0-9]+)[[:space:]]+([0-9]+[[:space:]]+)?([A-Z0-9_]+)[[:space:]]*$ ]]; then
      idx=${BASH_REMATCH[1]}; name=${BASH_REMATCH[3]}
      [[ $left == *" $name "* || $name == *_DDS ]] && continue
      file=${name,,}; file=${file//__//}
      [[ $file == *_* ]] && file="${file%_*}.${file##*_}"
      [[ $file == playgo_* ]] && file="playgo-${file#playgo_}"
      mkdir -p "$(dirname "$target/sce_sys/$file")"
      "$tool" pkg_extractentry --passcode "$ZERO_PASSCODE" "$pkg" "$idx" "$target/sce_sys/$file" >/dev/null 2>&1
    fi
  done < <("$tool" pkg_listentries "$pkg" 2>/dev/null)
  rm -rf "$work"
  [[ -f $target/sce_sys/param.sfo ]] || { warn "Unpacked, but param.sfo could not be read from the package: the emulator will not recognise the game." >&2; return 1; }
  say "Unpacked into $target" >&2
  if [[ -t 0 ]]; then
    read -r -p "The package is not needed any more. Delete it to get the space back? [y/N] " a >&2
    [[ ${a,,} == y* ]] && rm -f "$pkg"
  fi
  printf '%s\n' "$target/eboot.bin"
}

use_path() {
  local p=$1 e pk
  if [[ -d $p ]]; then
    if e=$(find_game "$p"); then printf '%s\n' "$e"; return 0; fi
    if pk=$(find_package "$p"); then expand_package "$pk"; return; fi
    return 1
  fi
  [[ -f $p ]] || return 1
  if [[ ${p,,} == *.pkg ]]; then expand_package "$p"; return; fi
  printf '%s\n' "$p"
}

resolve_game() {
  local named=${1:-$(setting game)} e pk
  if [[ -n $named ]]; then
    if e=$(use_path "$named"); then printf '%s\n' "$e"; return 0; fi
    warn "The game is named as $named, where it is not: looking in $GAMES" >&2
  fi
  if e=$(find_game "$EMBEDDED"); then printf '%s\n' "$e"; return 0; fi
  if e=$(find_game "$GAMES"); then printf '%s\n' "$e"; return 0; fi
  if pk=$(find_package "$GAMES"); then
    if e=$(expand_package "$pk"); then printf '%s\n' "$e"; return 0; fi
  fi
  return 1
}

# Asks where the game is (a folder picker, or a line in the terminal). Prints the path.
ask_game_path() {
  local p=""
  if use_gui; then
    gui_msg info "ASTRO BOT Rescue Mission was not found.${NL}${NL}Next, choose the game's folder (the one with eboot.bin in it, usually named CUSA12392)."
    case $GUI_TOOL in
      zenity) p=$(zenity --file-selection --directory --title="Where is ASTRO BOT Rescue Mission?" --filename="$HOME/" 2>/dev/null) || return 1 ;;
      kdialog) p=$(kdialog --title "Where is ASTRO BOT Rescue Mission?" --getexistingdirectory "$HOME" 2>/dev/null) || return 1 ;;
    esac
  else
    read -r -e -p "The game was not found in $GAMES. Path of its folder, eboot.bin or .pkg (empty to quit): " p || return 1
  fi
  [[ -n $p ]] || return 1
  printf '%s' "$p"
}
NL=$'\n'

# --- the emulator ------------------------------------------------------------------------------
MODE="${ASTROQUEST_MODE:-auto}"
if [[ $MODE == auto ]]; then
  if [[ -x $HERE/shadps4 ]]; then MODE=native
  elif [[ -f $HERE/shadps4.exe ]]; then MODE=windows
  else die "No emulator in $HERE: expected ./shadps4 (native build) or ./shadps4.exe (Windows build)."; fi
fi

GAME=$(resolve_game "$GAME_ARG") || GAME=""
tries=0
while [[ -z $GAME ]] && (( tries < 3 )) && can_ask; do
  tries=$((tries + 1))
  p=$(ask_game_path) || break
  if GAME=$(use_path "$p"); then
    case $GAME in "$GAMES"/*) ;; *) save_setting game "$GAME" ;; esac
  else
    GAME=""; gui_msg warning "No ASTRO BOT game was found at: $p"
  fi
done
[[ -n $GAME ]] || die "ASTRO BOT Rescue Mission was not found. Put the game's folder (the one with eboot.bin) or its .pkg in $GAMES, or run: $0 /path/to/game"
say "The game: $GAME"
GAME_DIR=$(dirname "$GAME")
if grep -qaE "$MADE_FOR_REGEX" "$GAME_DIR/sce_sys/param.sfo" 2>/dev/null; then
  [[ -f $GAME_DIR/sce_module/libc.prx ]] || die "This is not a complete copy of the game (sce_module/libc.prx is missing). A folder with only an update in it looks like this."
else
  warn "sce_sys/param.sfo is missing or is not CUSA12392 / CUSA12431: AstroQuest's fixes only apply to ASTRO BOT Rescue Mission, European or American release."
fi
if [[ $MODE == windows ]] && (( ${#GAME_DIR} + 1 + LONGEST_INSIDE > 259 )); then
  warn "Under Wine/Proton the game's path is long ($GAME_DIR): the emulator cannot open files with Windows paths over 259 characters. Move the folder somewhere shorter if it fails."
fi

# --- the settings menu (what the Windows launcher's window does) -------------------------------
# pick "Title" CURRENT_INDEX item...   -> sets PICKED to the chosen index (Enter keeps CURRENT)
pick() {
  local title=$1 cur=$2 i ans h; shift 2
  local items=("$@") args=()
  if use_gui; then
    case $GUI_TOOL in
      zenity)
        for i in "${!items[@]}"; do args+=("$([[ $i == "$cur" ]] && echo TRUE || echo FALSE)" "${items[i]}" "$i"); done
        h=$(( 170 + 30 * ${#items[@]} )); (( h > 720 )) && h=720
        ans=$(zenity --list --radiolist --title="Astro Bot VR" --text="$title" --no-markup \
              --column="" --column="Option" --column="Index" --hide-column=3 --print-column=3 \
              --width=660 --height=$h "${args[@]}" 2>/dev/null) || exit 0 ;;
      kdialog)
        for i in "${!items[@]}"; do args+=("$i" "${items[i]}" "$([[ $i == "$cur" ]] && echo on || echo off)"); done
        ans=$(kdialog --title "Astro Bot VR" --radiolist "$title" "${args[@]}" 2>/dev/null) || exit 0 ;;
    esac
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans < ${#items[@]} )); then PICKED=$ans; else PICKED=$cur; fi
    return 0
  fi
  printf '\n%s%s%s\n' "$C" "$title" "$N"
  for i in "${!items[@]}"; do
    printf '  %2d) %s%s\n' $((i + 1)) "${items[i]}" "$([[ $i == "$cur" ]] && printf '   <- current')"
  done
  while true; do
    read -r -p "Choose 1-${#items[@]} [Enter keeps ${items[cur]}]: " ans || ans=""
    if [[ -z $ans ]]; then PICKED=$cur; return 0; fi
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#items[@]} )); then PICKED=$((ans - 1)); return 0; fi
    echo "  Please type a number from 1 to ${#items[@]}."
  done
}

confirm_play() {
  if use_gui; then
    case $GUI_TOOL in
      zenity) zenity --question --no-markup --title="Astro Bot VR" --text="Settings saved. Start the game?" --ok-label=Play --cancel-label=Quit 2>/dev/null ;;
      kdialog) kdialog --title "Astro Bot VR" --yes-label Play --no-label Quit --yesno "Settings saved. Start the game?" 2>/dev/null ;;
    esac
    return
  fi
  local go
  read -r -p $'\nPress Enter to play, or q to quit: ' go || go=""
  [[ ${go,,} == q* ]] && return 1
  return 0
}

eye_height() {
  case $1 in 816) echo 870 ;; 960) echo 1080 ;; 1200) echo 1280 ;; *) echo $(( (1536 * $1 + 5760) / 11520 * 8 )) ;; esac
}
find_index() { local want=$1 n=0 i; shift; for i in "$@"; do [[ $i == "$want" ]] && { echo "$n"; return 0; }; n=$((n + 1)); done; echo -1; }

show_menu() {
  local widths=(816 960 1200 1440 1800 2160 2520 2880 3240 3600 3960 4320)
  local caps=(full 120 90 80 72 60 45 40 36 30)
  local langs=(en-US en-GB fr-FR fr-CA es-ES es-419 de-DE it-IT nl-NL pt-PT pt-BR ru-RU pl-PL tr-TR sv-SE nb-NO da-DK fi-FI cs-CZ hu-HU el-GR ro-RO ar-SA ja-JP ko-KR zh-Hant zh-Hans th-TH)
  local modes=(stereo spectator combined)
  local items=() w h label cur i sysl

  say ""; say "${C}ASTRO BOT Rescue Mission - PC VR: settings${N}  (saved in $SETTINGS)"

  for w in "${widths[@]}"; do
    h=$(eye_height "$w")
    if (( w < 1440 )); then label="$w x $h  (a console size, for headsets with fewer pixels)"
    elif (( w == 1440 )); then label="$w x $h  (the console's own, a PS4 Pro)"
    else label="$w x $h  ($(awk -v w="$w" -v h="$h" 'BEGIN{printf "%.2f", w*h/(1440*1536)}') times the console's pixels)"; fi
    items+=("$label")
  done
  cur=$(find_index "$(setting resolution 2880)" "${widths[@]}"); (( cur < 0 )) && cur=$(find_index 2880 "${widths[@]}")
  pick "Resolution of each eye (the game draws smaller by itself if the GPU cannot keep up)" "$cur" "${items[@]}"
  save_setting resolution "${widths[PICKED]}"

  items=()
  for i in "${caps[@]}"; do
    case $i in full) items+=("Full: the headset's refresh rate") ;; 60) items+=("at most 60 (the console's own)") ;; *) items+=("at most $i") ;; esac
  done
  cur=$(find_index "$(get_fps)" "${caps[@]}"); (( cur < 0 )) && cur=0
  pick "Frames a second (with a limit, a frame lasts a whole number of refreshes: at 120 Hz 120/60/40/30; at 90 Hz 90/45/30)" "$cur" "${items[@]}"
  save_setting fps "${caps[PICKED]}"

  sysl=${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}; sysl=${sysl%%.*}; sysl=${sysl%%@*}; sysl=${sysl//_/-}
  items=("As the system: ${sysl:-en-US}"); for i in "${langs[@]}"; do items+=("$i"); done
  cur=$(find_index "$(setting language windows)" "${langs[@]}"); cur=$((cur + 1))
  pick "Language of the game" "$cur" "${items[@]}"
  if (( PICKED == 0 )); then save_setting language windows; else save_setting language "${langs[PICKED - 1]}"; fi

  items=(); for i in 70 75 80 85 90 95 100; do
    if (( i == 100 )); then items+=("100%: all that the headset shows"); else items+=("$i%: sharper, with a dark border"); fi
  done
  cur=$(( ($(setting fov 100) - 70) / 5 )); (( cur < 0 || cur > 6 )) && cur=6
  pick "Field of view" "$cur" "${items[@]}"
  save_setting fov $(( 70 + PICKED * 5 ))

  items=("Stereo (both eyes)" "Single eye (spectator)" "Combined eyes (spectator)")
  cur=$(find_index "$(setting desktop_view stereo)" "${modes[@]}"); (( cur < 0 )) && cur=0
  pick "Desktop view (what the monitor shows)" "$cur" "${items[@]}"
  save_setting desktop_view "${modes[PICKED]}"
  if (( PICKED != 0 )); then
    pick "Crop top/bottom to fill the monitor?" "$([[ $(setting desktop_crop 0) == 1 ]] && echo 1 || echo 0)" "No" "Yes"
    save_setting desktop_crop "$PICKED"
  fi

  pick "Show this menu at every start? (bring it back later with --menu)" "$([[ $(setting menu 1) == 0 ]] && echo 1 || echo 0)" "Yes" "No"
  save_setting menu "$(( PICKED == 0 ? 1 : 0 ))"

  confirm_play
}

want_menu=0
if (( NO_MENU == 0 )); then
  if (( FORCE_MENU )); then want_menu=1
  elif [[ $(setting menu 1) != 0 ]] && { use_gui || [[ -t 0 ]]; }; then want_menu=1; fi
fi
if (( want_menu )); then show_menu || exit 0; fi

# --- what the settings mean to the emulator (same mapping as launch.ps1) ----------------------
res=$(setting resolution 2880); dynamic=$(setting dynamic 1)
if [[ $res == game ]]; then
  export SHADPS4_TITLE_RESOLUTION=title
else
  [[ $res =~ ^[0-9]+$ ]] || res=2880
  case $res in
    816)  export SHADPS4_TITLE_RESOLUTION=3 ;;
    960)  export SHADPS4_TITLE_RESOLUTION=4 ;;
    1200) export SHADPS4_TITLE_RESOLUTION=5 ;;
    *)
      w=$(( (res + 4) / 8 * 8 )); (( w < 1440 )) && w=1440; (( w > 4320 )) && w=4320
      (( w > 1440 )) && export SHADPS4_TITLE_EYE_WIDTH=$w
      [[ $dynamic == 0 ]] && export SHADPS4_TITLE_RESOLUTION=6
      ;;
  esac
fi
export SHADPS4_VR_SHARPEN; SHADPS4_VR_SHARPEN=$(setting sharpen 0.3)
dv=$(setting desktop_view stereo); [[ $dv == combined || $dv == spectator ]] || dv=stereo
export SHADPS4_VR_DESKTOP_VIEW=$dv
if [[ $(setting desktop_crop 0) == 1 ]]; then export SHADPS4_VR_DESKTOP_CROP=1; else export SHADPS4_VR_DESKTOP_CROP=0; fi
[[ -n $(setting msaa) ]] && export SHADPS4_MAX_MSAA="$(setting msaa)"
[[ $(setting antialias 1) == 0 ]] && export SHADPS4_RESOLVE_AA=0
[[ $(setting hands 1) == 0 ]] && export SHADPS4_XR_HANDS=0
[[ -n $(setting predict_ms) ]] && export SHADPS4_XR_PREDICT_MS="$(setting predict_ms)"
[[ $(setting stick_touchpad 1) == 0 ]] && export SHADPS4_STICK_TOUCHPAD=0
[[ -n $(setting mic_gain) ]] && export SHADPS4_MIC_GAIN="$(setting mic_gain)"
[[ $(setting surround 1) == 0 ]] && export SHADPS4_VIRTUAL_SURROUND=0
[[ $(setting real_time 1) == 0 ]] && export SHADPS4_TITLE_TIMESTEP=0
fov=$(setting fov 100); [[ $fov != 100 ]] && export SHADPS4_VR_FOV=$fov
[[ $(setting fov_of headset) != psvr ]] && export SHADPS4_VR_FOV_OF=headset
if [[ $(get_fps) == full ]]; then
  export SHADPS4_VR_PACE=1 SHADPS4_VR_FASTEST_PACE=1
else
  export SHADPS4_VR_FPS_CAP; SHADPS4_VR_FPS_CAP=$(get_fps)
fi
pace=$(setting pace "")
if [[ $pace == 1 ]]; then export SHADPS4_VR_FASTEST_PACE=1; unset SHADPS4_VR_FPS_CAP
elif [[ -n $pace && $pace != 2 ]]; then export SHADPS4_VR_PACE=$pace; fi
[[ $(setting headset 1) == 0 ]] && export SHADPS4_OPENXR=0
[[ $(setting pause 1) == 0 ]] && export SHADPS4_XR_PAUSE=0
[[ $(setting controllers 1) == 0 ]] && export SHADPS4_XR_CONTROLLERS=0
[[ $(setting controller_hand right) == left ]] && export SHADPS4_XR_PAD_HAND=left
export SHADPS4_XR_WAIT; SHADPS4_XR_WAIT=$(setting wait 60)
lang=$(setting language windows)
if [[ -z $lang || $lang == windows ]]; then
  l=${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}; l=${l%%.*}; l=${l%%@*}; lang=${l//_/-}
  [[ -z $lang || $lang == C || $lang == POSIX ]] && lang=en-US
fi
export SHADPS4_CONSOLE_LANGUAGE=$lang
[[ -n $(setting turn) ]] && export SHADPS4_VR_TURN="$(setting turn)"
for pair in "${EXTRA_ENV[@]}"; do
  [[ $pair == *=* && ${pair%%=*} != "" ]] && export "${pair%%=*}=${pair#*=}"
done

# --- what is there -----------------------------------------------------------------------------
say "${C}ASTRO BOT Rescue Mission - PC VR (Linux)${N}"
if [[ $MODE == native ]]; then
  runtime=${XR_RUNTIME_JSON:-}
  if [[ -z $runtime ]]; then
    for c in "${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json" /etc/xdg/openxr/1/active_runtime.json /usr/etc/xdg/openxr/1/active_runtime.json; do
      [[ -e $c ]] && { runtime=$c; break; }
    done
  fi
  if [[ -z $runtime ]]; then
    warn "No OpenXR runtime is set up: the game will only show on the monitor. Start WiVRn (or Monado) and make it the active runtime, or set XR_RUNTIME_JSON."
    notify "No OpenXR runtime found: the game will only show on the monitor unless WiVRn/Monado is set as the active runtime."
  else
    say "OpenXR runtime: $runtime"
  fi
fi
say "The DualSense: connect it to THIS PC (USB or Bluetooth), not to the headset."
say "Hold OPTIONS for a second (or press the PS button) to reset the view. Close the game's window to quit."
if [[ -r /proc/meminfo ]]; then
  spare_kb=$(awk '/^MemAvailable:/{a=$2} /^SwapFree:/{s=$2} END{print a+s}' /proc/meminfo)
  (( spare_kb < 16*1024*1024 )) && warn "Only $(( spare_kb / 1048576 )) GB of memory and swap are available and the emulator reserves about 14 GB: close other programs if it does not start."
fi
if [[ -r /proc/sys/vm/max_map_count ]] && (( $(cat /proc/sys/vm/max_map_count) < 1000000 )); then
  warn "vm.max_map_count is low ($(cat /proc/sys/vm/max_map_count)). Upstream shadPS4 Linux guides usually recommend raising it (sudo sysctl -w vm.max_map_count=2147483642) if the emulator crashes on start."
fi

# --- run ---------------------------------------------------------------------------------------
# The emulator keeps its config, saves and log in a "user" folder in its working directory
# (portable mode, as on Windows) when there is one: DATA is that directory. Where the emulator
# uses its default folder instead, the log is in ~/.local/share/shadPS4: both are followed.
mkdir -p "$DATA/user/log"
LOGDIR="$DATA/user/log"
LOGS=("$LOGDIR/shad_log.txt" "${XDG_DATA_HOME:-$HOME/.local/share}/shadPS4/log/shad_log.txt")
for f in "${LOGS[@]}"; do [[ -f $f ]] && mv -f "$f" "${f%.txt}.prev.txt"; done

winpath() { printf 'Z:%s' "${1//\//\\}"; }
case "$MODE" in
  native)  CMD=("$HERE/shadps4" -g "$GAME") ;;
  windows)
    if [[ -n ${PROTON:-} ]]; then
      export STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-$ROOT/prefix}"
      export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.local/share/Steam}"
      mkdir -p "$STEAM_COMPAT_DATA_PATH"
      CMD=("$PROTON" run "$HERE/shadps4.exe" -g "$(winpath "$GAME")")
    else
      command -v wine >/dev/null 2>&1 || die "Windows build found but neither PROTON nor wine is set up."
      CMD=(wine "$HERE/shadps4.exe" -g "$(winpath "$GAME")")
    fi ;;
  *) die "ASTROQUEST_MODE must be native or windows." ;;
esac

if [[ $DRY == 1 ]]; then
  say ""; say "--- dry run: paths ---"
  say "settings: $SETTINGS"; say "data/cwd:  $DATA"; say "games:    $GAMES"; say "ui:       ${GUI_TOOL:-terminal}"
  say "--- dry run: environment ---"
  env | grep -E '^(SHADPS4_|XR_RUNTIME_JSON|STEAM_COMPAT_)' | sort
  say "--- dry run: command (cwd: $DATA) ---"
  printf '%q ' "${CMD[@]}"; printf '\n'
  exit 0
fi

cd "$DATA" || exit 1
"${CMD[@]}" >"$LOGDIR/console.txt" 2>"$LOGDIR/console-errors.txt" &
EMU_PID=$!
( tail --pid="$EMU_PID" -n +1 -F "${LOGS[@]}" 2>/dev/null \
  | grep --line-buffered -E '^\[Core\.Vr\] <(Info|Warning)>|^\[Input\] <(Info|Warning)>.*Controller|^\[Lib\.AudioIn\] <(Info|Warning)>.*Microphone|<Critical>' \
  | sed -u -E 's/^\[[^]]*\] <[A-Za-z]+> \([^)]*\) [^ ]+ ([A-Za-z_]+: )?/  /' ) &
FILTER_PID=$!
wait "$EMU_PID"; code=$?
wait "$FILTER_PID" 2>/dev/null
say ""
if (( code != 0 )); then
  warn "The emulator ended with code $code. Its log is ${LOGS[0]} (or ${LOGS[1]}); console output in $LOGDIR/console*.txt."
  gui_msg error "The emulator ended with code $code.${NL}${NL}Its log is in:${NL}${LOGS[0]}${NL}or ${LOGS[1]}"
  exit "$code"
fi
say "The game was closed."
