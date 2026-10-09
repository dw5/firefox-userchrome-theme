#!/usr/bin/env bash
#
# firefox-userchrome-theme - linux installer
#
#   ./install.sh                  install to the default profile (menu if several)
#   ./install.sh -p NAME          install to a specific profile
#   ./install.sh --uninstall      remove theme, restore latest backup
#   ./install.sh -y               non-interactive (prints sudo cmds instead of asking)
#
# what it installs:
#   chrome/     -> <profile>/chrome/          (userChrome.css)
#   user.js     -> <profile>/user.js
#   autoconfig.js -> <firefox-install>/defaults/pref/
#   mozilla.cfg   -> <firefox-install>/       (may need sudo; skipped on flatpak/snap)
#
# existing chrome/ and user.js are backed up as *.bak-<timestamp> first.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MARKER="firefox-userchrome-theme"
TS="$(date +%Y%m%d-%H%M%S)"

# --- output helpers ----------------------------------------------------------
C_G=""; C_Y=""; C_R=""; C_0=""
if [ -t 1 ]; then
  C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_0=$'\033[0m'
fi
info() { printf '%s\n' "${C_G}==>${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}warning:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}error:${C_0} $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: install.sh [options]

  installs this theme into a firefox profile:
    chrome/                       -> <profile>/chrome/
    user.js                       -> <profile>/user.js
    autoconfig.js + mozilla.cfg   -> firefox install dir (asks for root)

options:
  -p, --profile NAME   target profile (dir name or full path); skips the menu
  -u, --uninstall      remove theme, restore latest backup if one exists
  -y, --yes            non-interactive: never prompt (prints sudo cmds instead)
  -h, --help           show this help
EOF
}

# --- args --------------------------------------------------------------------
PROFILE_OPT=""
UNINSTALL=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile)
      [ $# -ge 2 ] || die "--profile needs an argument"
      PROFILE_OPT="$2"; shift 2 ;;
    -u|--uninstall) UNINSTALL=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- repo sanity -------------------------------------------------------------
[ -f "$SCRIPT_DIR/user.js" ]    || die "user.js not found next to install.sh"
[ -f "$SCRIPT_DIR/autoconfig.js" ] || die "autoconfig.js not found next to install.sh"
[ -f "$SCRIPT_DIR/mozilla.cfg" ]   || die "mozilla.cfg not found next to install.sh"
[ -d "$SCRIPT_DIR/chrome" ]     || die "chrome/ not found next to install.sh"

# --- profile discovery -------------------------------------------------------
PROFILE_DIRS=()

add_profile_dir() {
  local d
  d="$(cd -- "$1" 2>/dev/null && pwd)" || return 0
  local x
  for x in ${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}; do
    [ "$x" = "$d" ] && return 0
  done
  PROFILE_DIRS+=("$d")
}

add_profile() {  # $1 = root, $2 = Path/Default value from profiles.ini
  local p="$2"
  case "$p" in /*) ;; *) p="$1/$p" ;; esac
  add_profile_dir "$p"
}

scan_root() {
  local root="$1" ini="$root/profiles.ini"
  [ -f "$ini" ] || return 0

  local rel
  # profiles referenced by an [Install...] section = what firefox actually launches
  while IFS= read -r rel; do
    [ -n "$rel" ] && add_profile "$root" "$rel"
  done < <(awk -v RS= -F'\n' '
      /^\[Install/ { for (i = 1; i <= NF; i++) if ($i ~ /^Default=/) { sub(/^Default=/, "", $i); print $i } }
    ' "$ini")

  # classic [ProfileN] sections flagged Default=1
  while IFS= read -r rel; do
    [ -n "$rel" ] && add_profile "$root" "$rel"
  done < <(awk -v RS= -F'\n' '
      /^\[Profile/ && /(^|\n)Default=1(\n|$)/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^Path=/) { sub(/^Path=/, "", $i); print $i }
      }
    ' "$ini")

  # fallback: glob common profile dir names
  if [ "${#PROFILE_DIRS[@]}" -eq 0 ]; then
    for rel in "$root"/*.default-release "$root"/*.default "$root"/*.default-esr \
               "$root"/profiles/*.default-release "$root"/profiles/*.default; do
      [ -d "$rel" ] && add_profile_dir "$rel"
    done
  fi
}

choose_profile() {
  if [ "${#PROFILE_DIRS[@]}" -eq 0 ]; then
    die "no firefox profile found.
searched: ~/.mozilla/firefox, flatpak, snap, ~/.librewolf, ~/.waterfox
open about:profiles in firefox to find your profile root dir."
  fi

  if [ -n "$PROFILE_OPT" ]; then
    local d
    for d in "${PROFILE_DIRS[@]}"; do
      case "$d" in
        "$PROFILE_OPT"|*/"$PROFILE_OPT") PROFILE_DIR="$d"; return 0 ;;
      esac
    done
    die "no profile matches '$PROFILE_OPT'"
  fi

  if [ "${#PROFILE_DIRS[@]}" -eq 1 ]; then
    PROFILE_DIR="${PROFILE_DIRS[0]}"
    return 0
  fi

  if [ ! -t 0 ]; then
    die "multiple profiles found and no tty; rerun with --profile <name>"
  fi

  echo "multiple profiles found:"
  local i=1 d
  for d in "${PROFILE_DIRS[@]}"; do
    printf '  %d) %s\n' "$i" "$d"
    i=$((i + 1))
  done
  local n
  while :; do
    if ! read -r -p "install to which profile? [1]: " n; then
      echo
      die "aborted - no input"
    fi
    n="${n:-1}"
    case "$n" in
      ''|*[!0-9]*) ;;
      *) [ "$n" -ge 1 ] && [ "$n" -le "${#PROFILE_DIRS[@]}" ] && break ;;
    esac
    echo "  invalid choice"
  done
  PROFILE_DIR="${PROFILE_DIRS[$((n - 1))]}"
}

# --- helpers -----------------------------------------------------------------
backup_path() {  # $1 = existing file or dir -> move to *.bak-$TS
  [ -e "$1" ] || return 0
  local bak="${1}.bak-$TS"
  mv -- "$1" "$bak" && info "backed up $(basename -- "$1") -> $(basename -- "$bak")"
}

is_ours() {  # $1 = file; true if it carries our marker comment
  [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null
}

place_file() {  # $1 = src, $2 = dst; backs up foreign files instead of clobbering
  if [ -e "$2" ] && ! is_ours "$2"; then
    backup_path "$2"
  fi
  cp -f -- "$1" "$2"
}

firefox_running() {
  pgrep -x firefox >/dev/null 2>&1 && return 0
  pgrep -x firefox-bin >/dev/null 2>&1 && return 0
  pgrep -f '/firefox/firefox( |$)' >/dev/null 2>&1 && return 0
  return 1
}

warn_if_running() {
  if firefox_running; then
    warn "firefox is running - restart it after this to apply changes"
  fi
}

# --- autoconfig (mozilla.cfg) ------------------------------------------------
FLATPAK=0
SNAP=0
[ -d "$HOME/.var/app/org.mozilla.firefox" ] && FLATPAK=1
[ -d "$HOME/snap/firefox" ] && SNAP=1
if command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1; then
  FLATPAK=1
fi

is_install_dir() {
  [ -d "$1" ] || return 1
  { [ -x "$1/firefox" ] || [ -x "$1/firefox-bin" ] || [ -x "$1/firefox-esr" ]; } || return 1
  [ -d "$1/defaults/pref" ] || return 1
  return 0
}

find_firefox_install_dir() {
  local name bin d cand
  for name in firefox firefox-bin firefox-esr; do
    if bin="$(command -v "$name" 2>/dev/null)"; then
      d="$(dirname -- "$(readlink -f -- "$bin" 2>/dev/null || echo "$bin")")"
      if is_install_dir "$d"; then printf '%s\n' "$d"; return 0; fi
    fi
  done
  for cand in /usr/lib/firefox /usr/lib/firefox-esr /usr/lib64/firefox /usr/lib64/firefox-esr \
              /usr/local/lib/firefox /opt/firefox; do
    if is_install_dir "$cand"; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

install_autoconfig() {
  if [ "$FLATPAK" = 1 ] || [ "$SNAP" = 1 ]; then
    warn "flatpak/snap firefox detected - skipping autoconfig.js/mozilla.cfg"
    warn "(the firefox install dir is read-only there; chrome/ + user.js are fully installed)"
    return 0
  fi

  local install_dir
  install_dir="$(find_firefox_install_dir)" || {
    warn "could not locate the firefox install dir - skipping mozilla.cfg part"
    warn "(chrome/ + user.js are installed; the locked new-tab prefs just won't apply)"
    return 0
  }
  info "firefox install dir: $install_dir"

  local prefdir="$install_dir/defaults/pref"
  if { [ -d "$prefdir" ] && [ -w "$prefdir" ]; } || { [ ! -d "$prefdir" ] && [ -w "$install_dir" ]; }; then
    mkdir -p -- "$prefdir"
    place_file "$SCRIPT_DIR/autoconfig.js" "$prefdir/autoconfig.js"
    place_file "$SCRIPT_DIR/mozilla.cfg" "$install_dir/mozilla.cfg"
    info "installed autoconfig.js + mozilla.cfg"
    return 0
  fi

  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    warn "no write access to $install_dir - to finish the mozilla.cfg part, run:"
    echo "    sudo mkdir -p '$prefdir'"
    echo "    sudo cp -f '$SCRIPT_DIR/autoconfig.js' '$prefdir/'"
    echo "    sudo cp -f '$SCRIPT_DIR/mozilla.cfg' '$install_dir/'"
    return 0
  fi

  local a
  printf 'write access to %s needs root - run sudo now? [y/N]: ' "$install_dir"
  if ! read -r a; then
    warn "no input - skipped autoconfig install (rerun later to retry)"
    return 0
  fi
  case "$a" in
    y|Y|yes|Yes)
      sudo mkdir -p -- "$prefdir" \
        && sudo cp -f -- "$SCRIPT_DIR/autoconfig.js" "$prefdir/" \
        && sudo cp -f -- "$SCRIPT_DIR/mozilla.cfg" "$install_dir/" \
        && info "installed autoconfig.js + mozilla.cfg (root)" \
        || warn "sudo step failed - mozilla.cfg part skipped"
      ;;
    *) warn "skipped autoconfig install (rerun later to retry)" ;;
  esac
}

uninstall_autoconfig() {
  local install_dir
  install_dir="$(find_firefox_install_dir)" || return 0
  local f
  for f in "$install_dir/defaults/pref/autoconfig.js" "$install_dir/mozilla.cfg"; do
    [ -e "$f" ] || continue
    if is_ours "$f"; then
      rm -f -- "$f" && info "removed $f"
    else
      warn "$f was not installed by this script - leaving it alone"
    fi
  done
}

# --- install / uninstall -----------------------------------------------------
do_install() {
  choose_profile
  info "profile: $PROFILE_DIR"
  warn_if_running

  backup_path "$PROFILE_DIR/chrome"
  backup_path "$PROFILE_DIR/user.js"

  cp -r -- "$SCRIPT_DIR/chrome" "$PROFILE_DIR/chrome" \
    || die "failed to copy chrome/ into $PROFILE_DIR"
  cp -f -- "$SCRIPT_DIR/user.js" "$PROFILE_DIR/user.js" \
    || die "failed to copy user.js into $PROFILE_DIR"
  info "installed chrome/ and user.js"

  install_autoconfig

  echo
  info "done - restart firefox to apply the theme"
}

do_uninstall() {
  choose_profile
  info "profile: $PROFILE_DIR"
  warn_if_running

  local -a cbaks=() jbaks=()
  local glob
  for glob in "$PROFILE_DIR"/chrome.bak-*;   do [ -e "$glob" ] && cbaks+=("$glob"); done
  for glob in "$PROFILE_DIR"/user.js.bak-*;  do [ -e "$glob" ] && jbaks+=("$glob"); done

  rm -rf -- "$PROFILE_DIR/chrome" "$PROFILE_DIR/user.js"
  info "removed chrome/ and user.js"

  if [ "${#cbaks[@]}" -gt 0 ] || [ "${#jbaks[@]}" -gt 0 ]; then
    local restore=1 a
    if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
      printf 'restore latest backup? [Y/n]: '
      if ! read -r a; then
        restore=0
        warn "no input - keeping backups, nothing restored"
      else
        case "$a" in n*|N*) restore=0 ;; esac
      fi
    fi
    if [ "$restore" = 1 ]; then
      if [ "${#cbaks[@]}" -gt 0 ]; then
        mv -- "${cbaks[-1]}" "$PROFILE_DIR/chrome" && info "restored $(basename -- "${cbaks[-1]}")"
      fi
      if [ "${#jbaks[@]}" -gt 0 ]; then
        mv -- "${jbaks[-1]}" "$PROFILE_DIR/user.js" && info "restored $(basename -- "${jbaks[-1]}")"
      fi
    fi
  fi

  uninstall_autoconfig
  echo
  info "done - restart firefox"
}

# --- main --------------------------------------------------------------------
PROFILE_ROOTS=(
  "$HOME/.mozilla/firefox"
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
  "$HOME/snap/firefox/common/.mozilla/firefox"
  "$HOME/.librewolf"
  "$HOME/.waterfox"
)

for root in "${PROFILE_ROOTS[@]}"; do
  scan_root "$root"
done

if [ "$UNINSTALL" = 1 ]; then
  do_uninstall
else
  do_install
fi
