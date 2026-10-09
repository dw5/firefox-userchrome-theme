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
#   chrome/       -> <profile>/chrome/          (userChrome.css)
#   user.js       -> <profile>/user.js
#   autoconfig.js -> <firefox-install>/defaults/pref/
#   mozilla.cfg   -> <firefox-install>/         (may need sudo; skipped on flatpak/snap)
#   policies.json -> <firefox-install>/distribution/   (duckduckgo default + uBlock Origin)
#
# existing chrome/ and user.js are backed up as *.bak-<timestamp> first.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MARKER="firefox-userchrome-theme"
TS="$(date +%Y%m%d-%H%M%S)"
XDG_CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

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
    policies.json                 -> firefox install dir/distribution/
                                    (duckduckgo default + uBlock Origin)

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
[ -f "$SCRIPT_DIR/policies.json" ] || die "policies.json not found next to install.sh"
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

  local rel before="${#PROFILE_DIRS[@]}"

  # profiles referenced by an [Install...] section = what firefox actually
  # launches (authoritative). when one exists, legacy Default=1 flags are
  # ignored - they often point at stale leftover profiles.
  while IFS= read -r rel; do
    [ -n "$rel" ] && add_profile "$root" "$rel"
  done < <(awk -v RS= -F'\n' '
      /^\[Install/ { for (i = 1; i <= NF; i++) if ($i ~ /^Default=/) { sub(/^Default=/, "", $i); print $i } }
    ' "$ini")

  # fall back to classic [ProfileN] sections flagged Default=1
  if [ "${#PROFILE_DIRS[@]}" -eq "$before" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] && add_profile "$root" "$rel"
    done < <(awk -v RS= -F'\n' '
        /^\[Profile/ && /(^|\n)Default=1(\n|$)/ {
          for (i = 1; i <= NF; i++) if ($i ~ /^Path=/) { sub(/^Path=/, "", $i); print $i }
        }
      ' "$ini")
  fi

  # fallback: glob common profile dir names
  if [ "${#PROFILE_DIRS[@]}" -eq "$before" ]; then
    for rel in "$root"/*.default-release "$root"/*.default "$root"/*.default-esr \
               "$root"/profiles/*.default-release "$root"/profiles/*.default; do
      [ -d "$rel" ] && add_profile_dir "$rel"
    done
  fi
}

choose_profile() {
  if [ "${#PROFILE_DIRS[@]}" -eq 0 ]; then
    die "no firefox profile found.
searched: ~/.mozilla/firefox, ~/.config/mozilla/firefox (firefox 147+),
flatpak, snap, librewolf, waterfox.
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

is_ours() {  # $1 = file; true if it was installed by this script
  [ -f "$1" ] || return 1
  grep -q "$MARKER" "$1" 2>/dev/null && return 0
  # policies.json is plain json (no comments allowed), so identify ours by content
  grep -q 'uBlock0@raymondhill.net' "$1" 2>/dev/null &&
    grep -q 'DuckDuckGo' "$1" 2>/dev/null
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
  pgrep -x firefox-esr >/dev/null 2>&1 && return 0
  pgrep -x librewolf >/dev/null 2>&1 && return 0
  pgrep -x waterfox >/dev/null 2>&1 && return 0
  pgrep -f '/firefox/firefox( |$)' >/dev/null 2>&1 && return 0
  return 1
}

warn_if_running() {
  if firefox_running; then
    warn "firefox is running - restart it after this to apply changes"
  fi
}

# Apply saved toolbar customization once per install, never through user.js.
tidy_navbar() {
  if firefox_running; then
    warn "navbar tidy skipped: firefox is running and would overwrite prefs.js; fully quit it and rerun the installer"
    return 0
  fi
  [ -f "$PROFILE_DIR/prefs.js" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "navbar tidy skipped: python3 is not installed"
    return 0
  fi
  python3 - "$PROFILE_DIR/prefs.js" "$TS" <<'PYTHON'
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

path = Path(sys.argv[1])
temporary = None
try:
    original = path.read_bytes()
    text = original.decode("utf-8")
    pattern = re.compile(r'^(\s*user_pref\("browser\.uiCustomization\.state",\s*)("(?:[^"\\\r\n]|\\.)*")(\s*\);[^\r\n]*)', re.MULTILINE)
    matches = list(pattern.finditer(text))
    if not matches:
        if re.search(r'^\s*user_pref\("browser\.uiCustomization\.state"', text, re.MULTILINE):
            raise ValueError("malformed customization pref")
        sys.exit(0)
    if len(matches) != 1:
        raise ValueError("multiple customization prefs")
    match = matches[0]
    state = json.loads(json.loads(match.group(2)))
    navbar = state["placements"]["nav-bar"]
    if not isinstance(navbar, list) or not all(isinstance(item, str) for item in navbar):
        raise ValueError("navbar placements must be an array of strings")
    if "urlbar-container" not in navbar:
        raise ValueError("navbar has no urlbar-container")
    placements = state["placements"]
    # the search box goes directly after the urlbar, wherever it was before
    # (another nav-bar slot or another toolbar), so drop it everywhere first
    before = {area: list(items) for area, items in placements.items() if isinstance(items, list)}
    for area, items in before.items():
        placements[area] = [item for item in items if item != "search-container"]
    tidy = [item for item in placements["nav-bar"] if item != "toolbarspring" and not re.fullmatch(r"customizableui-special-spring\d+", item)]
    tidy.insert(tidy.index("urlbar-container") + 1, "search-container")
    placements["nav-bar"] = tidy
    if all(placements[area] == items for area, items in before.items()):
        sys.exit(0)
    quoted = json.dumps(json.dumps(state, ensure_ascii=False, separators=(",", ":")), ensure_ascii=False)
    updated = (text[:match.start(2)] + quoted + text[match.end(2):]).encode("utf-8")
    backup = Path(str(path) + ".bak-" + sys.argv[2])
    with backup.open("xb") as out:
        out.write(original)
    shutil.copystat(path, backup)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".prefs.js-", delete=False) as out:
        temporary = out.name
        out.write(updated)
    shutil.copystat(path, temporary)
    os.replace(temporary, path)
    temporary = None
    print("==> tidied navbar; backed up prefs.js -> " + backup.name)
except Exception as error:
    print("warning: navbar tidy skipped: " + str(error), file=sys.stderr)
finally:
    if temporary is not None:
        os.unlink(temporary)
PYTHON
}

# --- autoconfig (mozilla.cfg) ------------------------------------------------
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
  # profiles inside a flatpak/snap sandbox home have a read-only install dir
  # reachable only from inside the sandbox - skip the install-dir part there.
  # NOTE: deliberately path-based, not "is flatpak installed": leftover
  # ~/.var/app dirs must not disable the feature for normal profiles.
  case "$PROFILE_DIR" in
    "$HOME"/.var/app/*|"$HOME"/snap/*)
      warn "flatpak/snap firefox profile detected - skipping autoconfig.js/mozilla.cfg/policies.json"
      warn "(chrome/ + user.js are fully installed; duckduckgo default + uBlock Origin"
      warn " and the locked new-tab prefs must be set up manually in that case)"
      return 0
      ;;
  esac

  local install_dir
  install_dir="$(find_firefox_install_dir)" || {
    warn "could not locate the firefox install dir - skipping mozilla.cfg part"
    warn "(chrome/ + user.js are installed; the locked new-tab prefs just won't apply)"
    return 0
  }
  info "firefox install dir: $install_dir"

  local prefdir="$install_dir/defaults/pref" distdir="$install_dir/distribution"
  if { [ -d "$prefdir" ] && [ -w "$prefdir" ]; } || { [ ! -d "$prefdir" ] && [ -w "$install_dir" ]; }; then
    mkdir -p -- "$prefdir" "$distdir"
    place_file "$SCRIPT_DIR/autoconfig.js" "$prefdir/autoconfig.js"
    place_file "$SCRIPT_DIR/mozilla.cfg" "$install_dir/mozilla.cfg"
    place_file "$SCRIPT_DIR/policies.json" "$distdir/policies.json"
    info "installed autoconfig.js + mozilla.cfg + policies.json (duckduckgo default, uBlock Origin)"
    return 0
  fi

  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    warn "no write access to $install_dir - to finish the mozilla.cfg + policies part, run:"
    echo "    sudo mkdir -p '$prefdir' '$distdir'"
    echo "    sudo cp -f '$SCRIPT_DIR/autoconfig.js' '$prefdir/'"
    echo "    sudo cp -f '$SCRIPT_DIR/mozilla.cfg' '$install_dir/'"
    echo "    sudo cp -f '$SCRIPT_DIR/policies.json' '$distdir/'"
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
      sudo mkdir -p -- "$prefdir" "$distdir" \
        && sudo cp -f -- "$SCRIPT_DIR/autoconfig.js" "$prefdir/" \
        && sudo cp -f -- "$SCRIPT_DIR/mozilla.cfg" "$install_dir/" \
        && sudo cp -f -- "$SCRIPT_DIR/policies.json" "$distdir/" \
        && info "installed autoconfig.js + mozilla.cfg + policies.json (root)" \
        || warn "sudo step failed - mozilla.cfg/policies part skipped"
      ;;
    *) warn "skipped autoconfig install (rerun later to retry)" ;;
  esac
}

uninstall_autoconfig() {
  local install_dir
  install_dir="$(find_firefox_install_dir)" || return 0
  local f
  for f in "$install_dir/defaults/pref/autoconfig.js" "$install_dir/mozilla.cfg" \
           "$install_dir/distribution/policies.json"; do
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

  tidy_navbar
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
  "$HOME/.mozilla/firefox"                        # classic location (MOZ_LEGACY_PROFILES=1)
  "$XDG_CONF/mozilla/firefox"                     # firefox 147+ default (xdg)
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"        # flatpak (legacy)
  "$HOME/.var/app/org.mozilla.firefox/.config/mozilla/firefox" # flatpak (firefox 147+)
  "$HOME/snap/firefox/common/.mozilla/firefox"                 # snap (legacy)
  "$HOME/snap/firefox/common/.config/mozilla/firefox"          # snap (firefox 147+)
  "$HOME/.librewolf"
  "$XDG_CONF/librewolf"
  "$HOME/.waterfox"
  "$XDG_CONF/waterfox"
)

for root in "${PROFILE_ROOTS[@]}"; do
  scan_root "$root"
done

if [ "$UNINSTALL" = 1 ]; then
  do_uninstall
else
  do_install
fi
