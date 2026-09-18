#!/usr/bin/env bash
#
# cleanup.sh — Universal Interactive Linux Cleanup Suite
# Works on any Linux distribution (Arch, Debian, Ubuntu, Fedora, openSUSE, Alpine, Void, etc.)
# Run with: bash cleanup.sh
#

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config/cleanup"
mkdir -p "$CONFIG_DIR"

STATE_FILE="$HOME/.cache/cleanup-state"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

LOG_FILE="$CONFIG_DIR/cleanup-log.txt"
touch "$LOG_FILE"

# Per-package permanent ignore list
SKIPPED_PKGS_FILE="$CONFIG_DIR/skipped_packages.txt"
touch "$SKIPPED_PKGS_FILE"

# ── Core Helpers ──────────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}ERROR: Do not run this script as root!${RESET}"
    echo -e "${DIM}The script prompts for sudo privileges only when required.${RESET}"
    exit 1
  fi
}

log_action() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

clear_screen() {
  clear 2>/dev/null || true
}

is_pkg_skipped() {
  local pkg="$1"
  grep -Fxq "$pkg" "$SKIPPED_PKGS_FILE" 2>/dev/null && return 0
  return 1
}

mark_pkg_skipped() {
  local pkg="$1"
  if ! is_pkg_skipped "$pkg"; then
    echo "$pkg" >>"$SKIPPED_PKGS_FILE"
  fi
}

get_skipped_pkg_count() {
  if [[ -s "$SKIPPED_PKGS_FILE" ]]; then
    local c
    c=$( (grep -c . "$SKIPPED_PKGS_FILE" 2>/dev/null || true) | tr -d "[:space:]")
    echo "${c:-0}"
  else
    echo 0
  fi
}

read_input() {
  local varname="$1"
  local val=""
  if [[ -t 0 ]]; then
    read -r val || true
  elif [[ -p /dev/stdin ]]; then
    read -r val || true
  elif [[ -r /dev/tty && -e /dev/tty ]]; then
    read -r val </dev/tty || true
  else
    read -r val || true
  fi
  eval "$varname=\"\$val\""
}

pause() {
  echo ""
  echo -en "  ${DIM}Press ENTER to continue...${RESET}"
  local _dummy
  read_input _dummy
}

get_path_bytes() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo 0
    return
  fi
  local bytes=""
  # du may encounter permission-denied subdirectories; capture size safely without failing pipefail
  bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1; exit}' || true)
  if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
    bytes=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024; exit}' || true)
  fi
  if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
    bytes=0
  fi
  echo "$bytes"
}

format_bytes() {
  local b="${1:-0}"
  b="${b%.*}"
  awk -v b="$b" 'BEGIN {
        if (b <= 0) printf "0 B";
        else if (b >= 1073741824) printf "%.2f GiB", b / 1073741824;
        else if (b >= 1048576) printf "%.2f MiB", b / 1048576;
        else if (b >= 1024) printf "%.2f KiB", b / 1024;
        else printf "%d B", b;
    }'
}

# ── Distribution & Package Manager Abstraction ────────────────────────────
DISTRO_NAME="Linux"
DISTRO_ID="generic"
DISTRO_VER=""
PKG_MANAGER="generic"

detect_pkg_manager() {
  if command -v pacman &>/dev/null; then
    echo "pacman"
  elif command -v apt-get &>/dev/null || command -v apt &>/dev/null; then
    echo "apt"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v zypper &>/dev/null; then
    echo "zypper"
  elif command -v apk &>/dev/null; then
    echo "apk"
  elif command -v xbps-install &>/dev/null; then
    echo "xbps"
  else
    echo "generic"
  fi
}

init_system_info() {
  if [[ -f /etc/os-release ]]; then
    local pretty id ver
    pretty=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    ver=$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    [[ -n "$pretty" ]] && DISTRO_NAME="$pretty"
    [[ -n "$id" ]] && DISTRO_ID="$id"
    [[ -n "$ver" ]] && DISTRO_VER="$ver"
  elif command -v lsb_release &>/dev/null; then
    DISTRO_NAME=$(lsb_release -ds 2>/dev/null || echo "Linux")
    DISTRO_ID=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "generic")
  fi

  PKG_MANAGER=$(detect_pkg_manager)
}

# Returns total count of installed packages
pkg_get_installed_count() {
  case "$PKG_MANAGER" in
  pacman) (pacman -Qq 2>/dev/null || true) | wc -l ;;
  apt) (dpkg-query -f '.\n' -W 2>/dev/null || true) | wc -l ;;
  dnf | zypper) (rpm -qa 2>/dev/null || true) | wc -l ;;
  apk) (apk info 2>/dev/null || true) | wc -l ;;
  xbps) (xbps-query -l 2>/dev/null || true) | wc -l ;;
  *) echo 0 ;;
  esac
}

# Returns total count of explicitly/user-installed packages
pkg_get_explicit_count() {
  case "$PKG_MANAGER" in
  pacman) (pacman -Qqe 2>/dev/null || true) | wc -l ;;
  apt) (apt-mark showmanual 2>/dev/null || true) | wc -l ;;
  dnf) (dnf repoquery --userinstalled 2>/dev/null || rpm -qa 2>/dev/null || true) | wc -l ;;
  zypper) (rpm -qa 2>/dev/null || true) | wc -l ;;
  apk) (wc -l </etc/apk/world 2>/dev/null || echo 0) ;;
  xbps) (xbps-query -m 2>/dev/null || true) | wc -l ;;
  *) echo 0 ;;
  esac
}

# Returns list of orphan / unneeded dependency package names (one per line)
pkg_get_orphans() {
  case "$PKG_MANAGER" in
  pacman)
    pacman -Qdtq 2>/dev/null || true
    ;;
  apt)
    apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}' || true
    ;;
  dnf)
    dnf repoquery --unneeded 2>/dev/null || package-cleanup --leaves 2>/dev/null || true
    ;;
  zypper)
    zypper packages --unneeded 2>/dev/null | awk -F'|' 'NR>4 && NF>=3 {gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 != "") print $3}' || true
    ;;
  xbps)
    xbps-query -O 2>/dev/null || true
    ;;
  apk)
    # apk handles dependencies directly
    true
    ;;
  *)
    true
    ;;
  esac
}

# Removes orphan packages
pkg_remove_orphans() {
  local orphans=("$@")
  case "$PKG_MANAGER" in
  pacman)
    sudo pacman -Rns "${orphans[@]}" --noconfirm 2>&1
    ;;
  apt)
    sudo apt-get autoremove --purge -y 2>&1
    ;;
  dnf)
    sudo dnf autoremove -y "${orphans[@]}" 2>&1
    ;;
  zypper)
    sudo zypper rm -u -y "${orphans[@]}" 2>&1
    ;;
  xbps)
    sudo xbps-remove -o -y 2>&1
    ;;
  apk)
    sudo apk del "${orphans[@]}" 2>&1
    ;;
  *)
    echo "Package removal not supported in generic mode."
    return 1
    ;;
  esac
}

# Removes a package with unneeded dependencies
pkg_remove() {
  local pkg="$1"
  case "$PKG_MANAGER" in
  pacman)
    sudo pacman -Rns "$pkg" --noconfirm 2>&1
    ;;
  apt)
    sudo apt purge --autoremove -y "$pkg" 2>&1
    ;;
  dnf)
    sudo dnf remove -y "$pkg" 2>&1
    ;;
  zypper)
    sudo zypper rm -u -y "$pkg" 2>&1
    ;;
  apk)
    sudo apk del "$pkg" 2>&1
    ;;
  xbps)
    sudo xbps-remove -R -y "$pkg" 2>&1
    ;;
  *)
    echo "Package removal not supported in generic mode."
    return 1
    ;;
  esac
}

# Returns size in bytes for a single package
pkg_get_size() {
  local pkg="$1"
  case "$PKG_MANAGER" in
  pacman)
    (LC_ALL=C pacman -Qi "$pkg" 2>/dev/null || true) | awk '
      /^Installed Size[ \t]*:/ {
        sub(/^[^:]*:[ \t]*/, ""); val=$1; unit=$2; mult=1;
        if (unit ~ /^[Kk]/) mult=1024;
        else if (unit ~ /^[Mm]/) mult=1048576;
        else if (unit ~ /^[Gg]/) mult=1073741824;
        else if (unit ~ /^[Tt]/) mult=1099511627776;
        print int(val * mult); exit;
      }'
    ;;
  apt)
    dpkg-query -W -f='${Installed-Size}\n' "$pkg" 2>/dev/null | awk '{print int($1 * 1024); exit}' || echo 0
    ;;
  dnf | zypper)
    rpm -q --queryformat '%{SIZE}\n' "$pkg" 2>/dev/null | head -1 || echo 0
    ;;
  apk)
    apk info -s "$pkg" 2>/dev/null | awk 'NR==2 {print int($1); exit}' || echo 0
    ;;
  xbps)
    xbps-query -S "$pkg" 2>/dev/null | awk '/installed_size/ {print $2; exit}' || echo 0
    ;;
  *)
    echo 0
    ;;
  esac
}

# Shows detailed information for a package
pkg_show_details() {
  local pkg="$1"
  echo ""
  echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${BOLD}${CYAN}📦 Package: $pkg (${PKG_MANAGER})${RESET}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  case "$PKG_MANAGER" in
  pacman)
    local short_desc
    short_desc=$( (pacman -Qi "$pkg" 2>/dev/null || pacman -Si "$pkg" 2>/dev/null || true) | awk -F': ' '/^Description/ {print $2}' | head -1)
    [[ -n "$short_desc" ]] && echo -e "  ${GREEN}Summary: $short_desc${RESET}\n"
    (pacman -Qi "$pkg" 2>/dev/null || pacman -Si "$pkg" 2>/dev/null || true) | grep -E "^(Name|Version|Description|Architecture|Installed Size|Required By|Optional For|Depends On)" | while IFS= read -r line; do
      echo -e "  ${DIM}$line${RESET}"
    done || true
    echo ""
    echo -e "  ${BOLD}Files Installed:${RESET}"
    (pacman -Ql "$pkg" 2>/dev/null || true) | wc -l | awk '{printf "    %s files\n", $1}'
    ;;
  apt)
    (apt show "$pkg" 2>/dev/null || dpkg -s "$pkg" 2>/dev/null || true) | grep -E "^(Package|Version|Section|Installed-Size|Depends|Description)" | head -15 | while IFS= read -r line; do
      echo -e "  ${DIM}$line${RESET}"
    done || true
    echo ""
    echo -e "  ${BOLD}Files Installed:${RESET}"
    (dpkg -L "$pkg" 2>/dev/null || true) | wc -l | awk '{printf "    %s files\n", $1}'
    ;;
  dnf | zypper)
    (rpm -qi "$pkg" 2>/dev/null || dnf info "$pkg" 2>/dev/null || true) | grep -E "^(Name|Version|Release|Architecture|Install Date|Size|Summary|URL)" | while IFS= read -r line; do
      echo -e "  ${DIM}$line${RESET}"
    done || true
    echo ""
    echo -e "  ${BOLD}Files Installed:${RESET}"
    (rpm -ql "$pkg" 2>/dev/null || true) | wc -l | awk '{printf "    %s files\n", $1}'
    ;;
  apk)
    apk info -a "$pkg" 2>/dev/null || true
    ;;
  xbps)
    xbps-query -S "$pkg" 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Files Installed:${RESET}"
    (xbps-query -f "$pkg" 2>/dev/null || true) | wc -l | awk '{printf "    %s files\n", $1}'
    ;;
  *)
    echo -e "  ${DIM}Package details unavailable in generic mode.${RESET}"
    ;;
  esac
  echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Search packages
pkg_search() {
  local query="$1"
  case "$PKG_MANAGER" in
  pacman) (pacman -Qs "$query" 2>/dev/null || true) | head -30 || echo "  No results." ;;
  apt) (apt-cache search "$query" 2>/dev/null || true) | head -30 || echo "  No results." ;;
  dnf) (rpm -qa 2>/dev/null | grep -i "$query" || true) | head -30 || echo "  No results." ;;
  zypper) (zypper se -i "$query" 2>/dev/null || true) | head -30 || echo "  No results." ;;
  apk) (apk info 2>/dev/null | grep -i "$query" || true) | head -30 || echo "  No results." ;;
  xbps) (xbps-query -s "$query" 2>/dev/null || true) | head -30 || echo "  No results." ;;
  *) echo "  Search not supported in generic mode." ;;
  esac
}

# Returns package cache directories
pkg_get_cache_dirs() {
  case "$PKG_MANAGER" in
  pacman) pacman-conf CacheDir 2>/dev/null || echo "/var/cache/pacman/pkg/" ;;
  apt) echo "/var/cache/apt/archives" ;;
  dnf) echo "/var/cache/dnf" ;;
  zypper) echo "/var/cache/zypp" ;;
  apk) echo "/var/cache/apk" ;;
  xbps) echo "/var/cache/xbps" ;;
  *) echo "/var/cache" ;;
  esac
}

# Returns total bytes in package cache
pkg_get_cache_bytes() {
  local total=0 dir
  for dir in $(pkg_get_cache_dirs); do
    if [[ -d "$dir" ]]; then
      local bytes
      bytes=$(get_path_bytes "$dir")
      total=$((total + bytes))
    fi
  done
  echo "$total"
}

# Emits sorted package list: bytes \t name \t size_str \t desc
# Filters out permanently skipped packages ($SKIPPED_PKGS_FILE)
pkg_get_sorted_packages() {
  case "$PKG_MANAGER" in
  pacman)
    (LC_ALL=C pacman -Qi 2>/dev/null || true) | awk -v skip_file="$SKIPPED_PKGS_FILE" '
      BEGIN {
        if (skip_file != "") {
          while ((getline line < skip_file) > 0) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line);
            if (line != "") skip[line] = 1;
          }
          close(skip_file);
        }
      }
      /^Name[ \t]*:/ { sub(/^[^:]*:[ \t]*/, ""); name = $0 }
      /^Installed Size[ \t]*:/ {
        sub(/^[^:]*:[ \t]*/, "");
        size_str = $0;
        val = $1; unit = $2;
        mult = 1;
        if (unit ~ /^[Kk]/) mult = 1024;
        else if (unit ~ /^[Mm]/) mult = 1048576;
        else if (unit ~ /^[Gg]/) mult = 1073741824;
        else if (unit ~ /^[Tt]/) mult = 1099511627776;
        bytes = int(val * mult);
      }
      /^Description[ \t]*:/ { sub(/^[^:]*:[ \t]*/, ""); desc = $0 }
      /^$/ {
        if (name != "" && !(name in skip)) {
          print bytes "\t" name "\t" size_str "\t" desc;
        }
        name = ""; size_str = ""; desc = ""; bytes = 0;
      }
      END {
        if (name != "" && !(name in skip)) {
          print bytes "\t" name "\t" size_str "\t" desc;
        }
      }
    ' | sort -t$'\t' -k1 -rn 2>/dev/null || true
    ;;

  apt)
    (dpkg-query -W -f='${Installed-Size}\t${Package}\t${Version}\t${binary:Summary}\n' 2>/dev/null || true) | awk -F'\t' -v skip_file="$SKIPPED_PKGS_FILE" '
      BEGIN {
        if (skip_file != "") {
          while ((getline line < skip_file) > 0) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line);
            if (line != "") skip[line] = 1;
          }
          close(skip_file);
        }
      }
      NF >= 2 {
        kib = $1; name = $2; ver = $3; desc = $4;
        if (name != "" && !(name in skip)) {
          bytes = int(kib * 1024);
          if (bytes >= 1073741824) size_str = sprintf("%.2f GiB", bytes / 1073741824);
          else if (bytes >= 1048576) size_str = sprintf("%.2f MiB", bytes / 1048576);
          else if (bytes >= 1024) size_str = sprintf("%.2f KiB", bytes / 1024);
          else size_str = sprintf("%d B", bytes);
          print bytes "\t" name "\t" size_str "\t" desc;
        }
      }
    ' | sort -t$'\t' -k1 -rn 2>/dev/null || true
    ;;

  dnf | zypper)
    (rpm -qa --queryformat '%{SIZE}\t%{NAME}\t%{VERSION}\t%{SUMMARY}\n' 2>/dev/null || true) | awk -F'\t' -v skip_file="$SKIPPED_PKGS_FILE" '
      BEGIN {
        if (skip_file != "") {
          while ((getline line < skip_file) > 0) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line);
            if (line != "") skip[line] = 1;
          }
          close(skip_file);
        }
      }
      NF >= 2 {
        bytes = int($1); name = $2; ver = $3; desc = $4;
        if (name != "" && !(name in skip)) {
          if (bytes >= 1073741824) size_str = sprintf("%.2f GiB", bytes / 1073741824);
          else if (bytes >= 1048576) size_str = sprintf("%.2f MiB", bytes / 1048576);
          else if (bytes >= 1024) size_str = sprintf("%.2f KiB", bytes / 1024);
          else size_str = sprintf("%d B", bytes);
          print bytes "\t" name "\t" size_str "\t" desc;
        }
      }
    ' | sort -t$'\t' -k1 -rn 2>/dev/null || true
    ;;

  *)
    true
    ;;
  esac
}

# ── Cache Target Cleaning Helpers ─────────────────────────────────────────
clean_target_user_cache() {
  local b a f
  b=$(get_path_bytes "$HOME/.cache")
  echo -e "  ${YELLOW}Cleaning User Cache (~/.cache)...${RESET}"
  find "$HOME/.cache" -mindepth 1 -not -name "cleanup-*" -delete 2>/dev/null || true
  a=$(get_path_bytes "$HOME/.cache")
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: ~/.cache — Freed $(format_bytes "$f")"
  echo "$f"
}

clean_target_trash() {
  local b a f
  b=$(get_path_bytes "$HOME/.local/share/Trash")
  echo -e "  ${YELLOW}Cleaning Trash Bin (~/.local/share/Trash)...${RESET}"
  find "$HOME/.local/share/Trash" -mindepth 1 -delete 2>/dev/null || true
  a=$(get_path_bytes "$HOME/.local/share/Trash")
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: Trash Bin — Freed $(format_bytes "$f")"
  echo "$f"
}

clean_target_thumbnails() {
  local b1 b2 b a1 a2 a f
  b1=$(get_path_bytes "$HOME/.thumbnails")
  b2=$(get_path_bytes "$HOME/.cache/thumbnails")
  b=$((b1 + b2))
  echo -e "  ${YELLOW}Cleaning Thumbnails...${RESET}"
  [[ -d "$HOME/.thumbnails" ]] && find "$HOME/.thumbnails" -mindepth 1 -delete 2>/dev/null || true
  [[ -d "$HOME/.cache/thumbnails" ]] && find "$HOME/.cache/thumbnails" -mindepth 1 -delete 2>/dev/null || true
  a1=$(get_path_bytes "$HOME/.thumbnails")
  a2=$(get_path_bytes "$HOME/.cache/thumbnails")
  a=$((a1 + a2))
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: Thumbnails — Freed $(format_bytes "$f")"
  echo "$f"
}

clean_target_tmp() {
  local b a f
  b=$(get_path_bytes "/tmp")
  echo -e "  ${YELLOW}Cleaning System Temp (/tmp)...${RESET}"
  sudo find /tmp -mindepth 1 -maxdepth 2 -not -path "*/.*" -delete 2>/dev/null || true
  a=$(get_path_bytes "/tmp")
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: /tmp — Freed $(format_bytes "$f")"
  echo "$f"
}

clean_target_pkg_cache() {
  local b a f
  b=$(pkg_get_cache_bytes)
  echo -e "  ${YELLOW}Cleaning Package Cache ($PKG_MANAGER)...${RESET}"
  case "$PKG_MANAGER" in
  pacman)
    sudo pacman -Sc --noconfirm 2>&1 >/dev/null || true
    if command -v paccache &>/dev/null; then
      sudo paccache -r 2>/dev/null || true
    fi
    ;;
  apt)
    sudo apt-get clean 2>&1 >/dev/null || true
    sudo apt-get autoclean 2>&1 >/dev/null || true
    ;;
  dnf)
    sudo dnf clean all 2>&1 >/dev/null || true
    ;;
  zypper)
    sudo zypper clean -a 2>&1 >/dev/null || true
    ;;
  apk)
    sudo apk cache clean 2>&1 >/dev/null || true
    ;;
  xbps)
    sudo xbps-remove -O 2>&1 >/dev/null || true
    ;;
  *)
    echo -e "    ${DIM}Generic mode: skipping package manager cache.${RESET}"
    ;;
  esac
  a=$(pkg_get_cache_bytes)
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: Package Cache ($PKG_MANAGER) — Freed $(format_bytes "$f")"
  echo "$f"
}

clean_target_journal() {
  if command -v journalctl &>/dev/null; then
    echo -e "  ${YELLOW}Vacuuming systemd journal logs (keeping 3 days / max 100M)...${RESET}"
    sudo journalctl --vacuum-time=3d --vacuum-size=100M 2>&1 | sed 's/^/    /' || true
    log_action "VACUUMED: systemd journal logs"
  else
    echo -e "  ${DIM}journalctl not installed.${RESET}"
  fi
  echo 0
}

clean_target_flatpak() {
  if command -v flatpak &>/dev/null; then
    local flatpak_count
    flatpak_count=$(flatpak list --runtime 2>/dev/null | wc -l || echo 0)
    if [[ ${flatpak_count:-0} -gt 0 ]]; then
      echo -e "  ${YELLOW}Cleaning Flatpak unused runtimes...${RESET}"
      flatpak uninstall --unused --noninteractive 2>/dev/null || true
      echo -e "    ${GREEN}✅ Done${RESET}"
      log_action "CLEANED: Flatpak unused runtimes"
    else
      echo -e "  ${DIM}No unused Flatpak runtimes found.${RESET}"
    fi
  else
    echo -e "  ${DIM}Flatpak not installed.${RESET}"
  fi
  echo 0
}

clean_target_snap() {
  if command -v snap &>/dev/null; then
    echo -e "  ${YELLOW}Cleaning disabled/old Snap revisions...${RESET}"
    LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
      [[ -n "$snapname" && -n "$revision" ]] && sudo snap remove "$snapname" --revision="$revision" 2>/dev/null || true
    done
    echo -e "    ${GREEN}✅ Done${RESET}"
    log_action "CLEANED: Disabled Snap revisions"
  else
    echo -e "  ${DIM}Snap not installed.${RESET}"
  fi
  echo 0
}

clean_target_aur_cache() {
  local b=0 a=0 f=0
  for aur_dir in "$HOME/.cache/yay" "$HOME/.cache/paru"; do
    if [[ -d "$aur_dir" ]]; then
      local b_single
      b_single=$(get_path_bytes "$aur_dir")
      b=$((b + b_single))
    fi
  done
  echo -e "  ${YELLOW}Cleaning AUR Helper Caches (yay/paru)...${RESET}"
  for aur_dir in "$HOME/.cache/yay" "$HOME/.cache/paru"; do
    if [[ -d "$aur_dir" ]]; then
      rm -rf "$aur_dir" 2>/dev/null || true
      local a_single
      a_single=$(get_path_bytes "$aur_dir")
      a=$((a + a_single))
    fi
  done
  f=$((b - a))
  [[ $f -lt 0 ]] && f=0
  echo -e "    ${GREEN}✅ Freed $(format_bytes "$f")${RESET}"
  log_action "CLEANED: AUR Cache — Freed $(format_bytes "$f")"
  echo "$f"
}

# ── Option 0: System Overview ─────────────────────────────────────────────
show_overview() {
  clear_screen
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║          🧹 DISK CLEANUP — System Overview                   ║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}System Info:${RESET}"
  echo -e "    Distribution:        ${GREEN}${DISTRO_NAME}${RESET} (${DISTRO_ID} ${DISTRO_VER:-})"
  echo -e "    Kernel:              ${CYAN}$(uname -r)${RESET} (${CYAN}$(uname -m)${RESET})"
  echo -e "    Package Manager:     ${YELLOW}${PKG_MANAGER}${RESET}"
  echo ""
  echo -e "  ${BOLD}Disk Usage (/):${RESET}"
  df -h / | tail -1 | awk '{printf "    Filesystem: %s  Size: %s  Used: %s  Available: %s  Use%%: %s\n", $1, $2, $3, $4, $5}'
  echo ""
  echo -e "  ${BOLD}Top Space Consumers (~/):${RESET}"
  echo -e "  ${DIM}$(du -sh "$HOME"/*/ 2>/dev/null | sort -rh | head -10 | awk '{printf "    %-50s %s\n", $2, $1}' || true)${RESET}"
  echo ""
  echo -e "  ${BOLD}Package Stats:${RESET}"
  echo -e "    Installed packages:  $(pkg_get_installed_count)"
  echo -e "    Permanently skipped: $(get_skipped_pkg_count)"
  echo -e "    Orphan packages:     $(pkg_get_orphan_count)"
  echo -e "    Explicit / User:     $(pkg_get_explicit_count)"
  echo -e "    Package cache:       $(format_bytes "$(pkg_get_cache_bytes)")"
  echo ""
  echo -e "  ${DIM}Actions logged to: $LOG_FILE${RESET}"
  pause
}

pkg_get_orphan_count() {
  local count
  count=$( (pkg_get_orphans 2>/dev/null || true) | grep -c . || true)
  count="${count:-0}"
  echo "${count//[[:space:]]/}"
}

# ── Option 1: Interactive Package Cleaner ─────────────────────────────────
clean_packages() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  📦 PACKAGE CLEANER — Interactive Package Removal (${PKG_MANAGER})  ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  if [[ "$PKG_MANAGER" == "generic" ]]; then
    echo -e "  ${YELLOW}Package manager not detected. Generic mode cannot inspect packages.${RESET}"
    pause
    return
  fi

  echo -e "  ${GREEN}Commands:${RESET}"
  echo -e "    ${YELLOW}n/ENTER${RESET} = next package (skip for now)"
  echo -e "    ${YELLOW}b${RESET}       = go BACK to previous package"
  echo -e "    ${YELLOW}y${RESET}       = delete package"
  echo -e "    ${YELLOW}d${RESET}       = show full details"
  echo -e "    ${YELLOW}a${RESET}       = never ask about THIS package again"
  echo -e "    ${YELLOW}s${RESET}       = search packages"
  echo -e "    ${YELLOW}q${RESET}       = quit package cleaner"
  echo ""

  echo -e "  ${DIM}Analyzing installed packages...${RESET}"
  local pkg_lines=()
  mapfile -t pkg_lines < <(pkg_get_sorted_packages)

  if [[ ${#pkg_lines[@]} -eq 0 || -z "${pkg_lines[0]:-}" ]]; then
    echo -e "${GREEN}No packages left to review (or all are in skip list).${RESET}"
    pause
    return
  fi

  local count=${#pkg_lines[@]}
  local skipped_total
  skipped_total=$(get_skipped_pkg_count)
  echo -e "  ${DIM}Packages to review: $count (sorted largest first | $skipped_total permanently skipped)${RESET}"
  echo ""

  local idx=0
  while ((idx < count)); do
    local line="${pkg_lines[idx]}"
    if [[ -z "$line" ]]; then
      idx=$((idx + 1))
      continue
    fi

    local pkg_bytes pkg_name pkg_size pkg_desc
    IFS=$'\t' read -r pkg_bytes pkg_name pkg_size pkg_desc <<<"$line"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${BOLD}[$((idx + 1))/$count] ${YELLOW}$pkg_name${RESET} ${GREEN}(${pkg_size})${RESET}"
    echo -e "  ${DIM}$pkg_desc${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -en "  ${GREEN}[y]del${RESET} ${YELLOW}[n]ext${RESET} ${CYAN}[b]ack${RESET} ${YELLOW}[d]etails${RESET} ${YELLOW}[a]never ask${RESET} ${YELLOW}[s]earch${RESET} ${YELLOW}[q]uit> ${RESET}"

    local choice=""
    read_input choice

    case "$choice" in
    y | Y)
      echo -e "${RED}🗑️  Removing $pkg_name (${pkg_size})...${RESET}"
      if pkg_remove "$pkg_name"; then
        log_action "DELETED PACKAGE: $pkg_name (Freed: $pkg_size)"
        echo -e "${GREEN}  ✅ Successfully removed $pkg_name! Freed approx $pkg_size.${RESET}"
      else
        echo -e "${RED}  ❌ Failed to remove $pkg_name (check dependencies).${RESET}"
      fi
      echo ""
      idx=$((idx + 1))
      ;;
    b | B)
      if ((idx > 0)); then
        idx=$((idx - 1))
      else
        echo -e "\n${YELLOW}  ↳ Already at the first package.${RESET}\n"
        sleep 0.8
      fi
      ;;
    d | D)
      pkg_show_details "$pkg_name"
      echo -en "  ${GREEN}[y]del${RESET} ${YELLOW}[n]next${RESET} ${CYAN}[b]ack${RESET} ${YELLOW}[a]never ask${RESET} ${YELLOW}[q]uit> ${RESET}"
      local choice2=""
      read_input choice2
      case "$choice2" in
      y | Y)
        echo -e "${RED}🗑️  Removing $pkg_name (${pkg_size})...${RESET}"
        if pkg_remove "$pkg_name"; then
          log_action "DELETED PACKAGE: $pkg_name (Freed: $pkg_size)"
          echo -e "${GREEN}  ✅ Successfully removed $pkg_name! Freed approx $pkg_size.${RESET}"
        else
          echo -e "${RED}  ❌ Failed to remove $pkg_name.${RESET}"
        fi
        idx=$((idx + 1))
        ;;
      b | B)
        if ((idx > 0)); then
          idx=$((idx - 1))
        else
          echo -e "\n${YELLOW}  ↳ Already at the first package.${RESET}"
          sleep 0.8
        fi
        ;;
      a | A)
        mark_pkg_skipped "$pkg_name"
        echo -e "${YELLOW}  ↳ Added '$pkg_name' to permanent skip list.${RESET}"
        idx=$((idx + 1))
        ;;
      q | Q)
        echo -e "${YELLOW}Exiting package cleaner.${RESET}"
        break
        ;;
      *)
        idx=$((idx + 1))
        ;;
      esac
      echo ""
      ;;
    a | A)
      mark_pkg_skipped "$pkg_name"
      echo -e "${YELLOW}  ↳ Added '$pkg_name' to permanent skip list.${RESET}"
      echo -e "${DIM}    Saved to: $SKIPPED_PKGS_FILE${RESET}\n"
      sleep 0.8
      idx=$((idx + 1))
      ;;
    s | S)
      echo -en "  Search package name/keyword: "
      local query=""
      read_input query
      echo ""
      echo -e "  ${DIM}Results for '$query':${RESET}"
      pkg_search "$query"
      pause
      ;;
    q | Q)
      echo -e "${YELLOW}Exiting package cleaner.${RESET}"
      break
      ;;
    *)
      echo -e "${DIM}  ↳ Skipped.${RESET}\n"
      idx=$((idx + 1))
      ;;
    esac
  done
}

# ── Option 2: Show Biggest Packages ───────────────────────────────────────
show_biggest_packages() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  📊 TOP 30 LARGEST INSTALLED PACKAGES (${PKG_MANAGER})         ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  if [[ "$PKG_MANAGER" == "generic" ]]; then
    echo -e "  ${YELLOW}Package manager not detected. Generic mode cannot inspect packages.${RESET}"
    pause
    return
  fi

  echo -e "  ${DIM}Collecting package sizes (excluding permanently skipped)...${RESET}"
  local pkg_data
  pkg_data=$(pkg_get_sorted_packages)

  echo ""
  printf "  ${BOLD}%-4s %-38s %-14s %s${RESET}\n" "#" "Package Name" "Installed Size" "Description"
  echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────────────────${RESET}"

  set +o pipefail
  echo "$pkg_data" | awk -F'\t' '
        NR <= 30 && NF >= 3 {
            name = $2;
            size = $3;
            desc = $4;
            if (length(name) > 36) name = substr(name, 1, 33) "...";
            if (length(desc) > 42) desc = substr(desc, 1, 39) "...";
            printf "  %-4d %-38s %-14s %s\n", NR, name, size, desc;
        }
    '
  set -o pipefail

  echo ""
  echo -e "  ${DIM}Run Option [1] to inspect, navigate, or mark packages as permanently skipped.${RESET}"
  pause
}

# ── Option 3: Orphan Packages ─────────────────────────────────────────────
clean_orphans() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  🗑️  ORPHAN PACKAGES CLEANER (${PKG_MANAGER})                   ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  if [[ "$PKG_MANAGER" == "generic" ]]; then
    echo -e "  ${YELLOW}Orphan package cleanup is not available in generic mode.${RESET}"
    pause
    return
  fi

  local orphans=()
  mapfile -t orphans < <(pkg_get_orphans)

  if [[ ${#orphans[@]} -eq 0 || -z "${orphans[0]:-}" ]]; then
    echo -e "${GREEN}✅ No orphan packages found! System is clean.${RESET}"
    pause
    return
  fi

  echo -e "${BOLD}${YELLOW}Found ${#orphans[@]} unneeded dependency packages:${RESET}\n"

  local total_orphan_bytes=0
  local i=1
  for o in "${orphans[@]}"; do
    [[ -z "$o" ]] && continue
    local b sz_str
    b=$(pkg_get_size "$o")
    b="${b:-0}"
    total_orphan_bytes=$((total_orphan_bytes + b))
    sz_str="$(format_bytes "$b")"
    printf "    ${CYAN}%2d.${RESET} %-35s ${GREEN}%s${RESET}\n" "$i" "$o" "$sz_str"
    i=$((i + 1))
  done

  echo ""
  echo -e "  ${BOLD}Total space reclaimable:${RESET} ${GREEN}$(format_bytes "$total_orphan_bytes")${RESET}"
  echo ""
  echo -en "  Remove all ${#orphans[@]} orphans? ${GREEN}[y/N]${RESET} "
  local confirm=""
  read_input confirm

  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    echo ""
    echo -e "${RED}🗑️  Removing orphan packages...${RESET}"
    if pkg_remove_orphans "${orphans[@]}"; then
      log_action "DELETED ORPHANS: ${orphans[*]} (Reclaimed: $(format_bytes "$total_orphan_bytes"))"
      echo -e "${GREEN}✅ Done! Reclaimed $(format_bytes "$total_orphan_bytes") of disk space.${RESET}"
    else
      echo -e "${RED}❌ Removal failed. Some packages may have broken dependencies.${RESET}"
    fi
  else
    echo -e "${DIM}  ↳ Operation skipped.${RESET}"
  fi
  pause
}

# ── Option 4: Selective Cache Cleaner ─────────────────────────────────────
clean_cache() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  🧹 SELECTIVE CACHE CLEANER — Choose What to Clean          ${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo ""

    local sz_user sz_trash sz_thumb sz_tmp sz_pkg
    sz_user=$(get_path_bytes "$HOME/.cache")
    sz_trash=$(get_path_bytes "$HOME/.local/share/Trash")
    local t1 t2
    t1=$(get_path_bytes "$HOME/.thumbnails")
    t2=$(get_path_bytes "$HOME/.cache/thumbnails")
    sz_thumb=$((t1 + t2))
    sz_tmp=$(get_path_bytes "/tmp")
    sz_pkg=$(pkg_get_cache_bytes)

    # Dynamic target discovery
    local target_labels=()
    local target_sizes=()
    local target_descs=()
    local target_keys=()

    # 1. User Cache
    target_labels+=("User Cache (~/.cache)")
    target_sizes+=("$(format_bytes "$sz_user")")
    target_descs+=("Application caches, browser data, temporary files")
    target_keys+=("user_cache")

    # 2. Trash Bin
    target_labels+=("Trash Bin (~/.local/share/Trash)")
    target_sizes+=("$(format_bytes "$sz_trash")")
    target_descs+=("Files sitting in user trash bin")
    target_keys+=("trash")

    # 3. Thumbnails
    target_labels+=("Thumbnails (~/.thumbnails)")
    target_sizes+=("$(format_bytes "$sz_thumb")")
    target_descs+=("Image & file manager thumbnail preview cache")
    target_keys+=("thumbnails")

    # 4. System Temp
    target_labels+=("System Temp (/tmp)")
    target_sizes+=("$(format_bytes "$sz_tmp")")
    target_descs+=("Temporary system and process runtime files")
    target_keys+=("tmp")

    # 5. Package Cache
    target_labels+=("Package Cache (${PKG_MANAGER})")
    target_sizes+=("$(format_bytes "$sz_pkg")")
    target_descs+=("Downloaded package installation archives")
    target_keys+=("pkg_cache")

    # 6. Systemd Journal Logs (if journalctl installed)
    if command -v journalctl &>/dev/null; then
      local sz_j
      sz_j=$(journalctl --disk-usage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+(\.[0-9]+)?[KMGTP]?B?$/ || $i ~ /^[0-9]+(\.[0-9]+)?[KMGTP]$/) {print $i; exit}}')
      target_labels+=("Systemd Journal Logs")
      target_sizes+=("${sz_j:-0 B}")
      target_descs+=("Archived system logs (vacuums logs > 3 days / 100M)")
      target_keys+=("journal")
    fi

    # 7. Flatpak (if flatpak installed)
    if command -v flatpak &>/dev/null; then
      target_labels+=("Flatpak Unused Runtimes")
      target_sizes+=("Installed")
      target_descs+=("Unused Flatpak runtimes and dependencies")
      target_keys+=("flatpak")
    fi

    # 8. Snap (if snap installed)
    if command -v snap &>/dev/null; then
      target_labels+=("Snap Disabled Revisions")
      target_sizes+=("Installed")
      target_descs+=("Old disabled snap revisions")
      target_keys+=("snap")
    fi

    # 9. AUR Cache (if yay or paru directories exist)
    if [[ -d "$HOME/.cache/yay" || -d "$HOME/.cache/paru" ]]; then
      local a1 a2 sz_aur
      a1=$(get_path_bytes "$HOME/.cache/yay")
      a2=$(get_path_bytes "$HOME/.cache/paru")
      sz_aur=$((a1 + a2))
      target_labels+=("AUR Helper Caches (yay/paru)")
      target_sizes+=("$(format_bytes "$sz_aur")")
      target_descs+=("AUR build artifacts and git packages")
      target_keys+=("aur")
    fi

    echo -e "  ${BOLD}Detected System Caches:${RESET}"
    echo ""
    printf "  ${BOLD}%-4s %-34s %-12s %s${RESET}\n" "#" "Cache Target" "Size" "Description"
    echo -e "  ${DIM}$(printf '─%.0s' {1..85})${RESET}"

    for i in "${!target_labels[@]}"; do
      printf "  ${YELLOW}%-3d.${RESET} %-34s ${CYAN}%-12s${RESET} ${DIM}%s${RESET}\n" \
        "$((i + 1))" "${target_labels[$i]}" "${target_sizes[$i]}" "${target_descs[$i]}"
    done

    echo ""
    echo -e "  ${GREEN}[a]${RESET} Clean ALL of the above"
    echo -e "  ${RED}[q]${RESET} Return to main menu"
    echo ""
    echo -en "  Choose cache(s) to clean (e.g. 1, 4 or 1-3) or [a]/[q]> "

    local raw_input=""
    read_input raw_input
    raw_input="$(echo "$raw_input" | xargs)"

    [[ -z "$raw_input" || "$raw_input" == "q" || "$raw_input" == "Q" ]] && return

    local selected_indices=()
    local total_targets=${#target_labels[@]}

    if [[ "$raw_input" == "a" || "$raw_input" == "A" ]]; then
      for ((i = 0; i < total_targets; i++)); do
        selected_indices+=("$i")
      done
    else
      local clean_input
      clean_input=$(echo "$raw_input" | tr ',' ' ')
      local tokens=()
      read -ra tokens <<<"$clean_input"
      for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
          local s="${token%-*}"
          local e="${token#*-}"
          if ((s > e)); then
            local tmp=$s
            s=$e
            e=$tmp
          fi
          for ((n = s; n <= e; n++)); do
            local idx=$((n - 1))
            if ((idx >= 0 && idx < total_targets)); then
              selected_indices+=("$idx")
            fi
          done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
          local idx=$((token - 1))
          if ((idx >= 0 && idx < total_targets)); then
            selected_indices+=("$idx")
          fi
        fi
      done
    fi

    if [[ ${#selected_indices[@]} -eq 0 ]]; then
      echo -e "\n  ${RED}No valid cache targets selected.${RESET}"
      sleep 1
      continue
    fi

    local unique_indices=()
    mapfile -t unique_indices < <(printf '%s\n' "${selected_indices[@]}" | sort -nu)

    echo ""
    echo -e "${RED}  Starting cleanup for selected targets...${RESET}"
    echo ""

    local total_freed=0
    for idx in "${unique_indices[@]}"; do
      local key="${target_keys[$idx]}"
      local freed=0
      case "$key" in
      user_cache) freed=$(clean_target_user_cache) ;;
      trash) freed=$(clean_target_trash) ;;
      thumbnails) freed=$(clean_target_thumbnails) ;;
      tmp) freed=$(clean_target_tmp) ;;
      pkg_cache) freed=$(clean_target_pkg_cache) ;;
      journal) clean_target_journal >/dev/null 2>&1 || true ;;
      flatpak) clean_target_flatpak >/dev/null 2>&1 || true ;;
      snap) clean_target_snap >/dev/null 2>&1 || true ;;
      aur) freed=$(clean_target_aur_cache) ;;
      esac
      freed=$(echo "$freed" | tail -1 | tr -dc '0-9')
      [[ -z "$freed" ]] && freed=0
      total_freed=$((total_freed + freed))
    done

    echo ""
    echo -e "  ${GREEN}✅ Selected cleanup complete! Total reclaimed: $(format_bytes "$total_freed")${RESET}"
    log_action "SELECTIVE CACHE CLEANUP: Freed $(format_bytes "$total_freed") total"
    pause
  done
}

# ── Option 5: Safe Multi-Distro Kernel Cleaner ────────────────────────────
clean_kernels() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  🧬 SAFE KERNEL CLEANER (${DISTRO_NAME})                     ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  local current_uname
  current_uname=$(uname -r)
  echo -e "  ${BOLD}Running Kernel Release:${RESET} ${GREEN}$current_uname${RESET}\n"

  local kernel_pkgs=()
  local removable_kernels=()

  case "$PKG_MANAGER" in
  pacman)
    local running_pkg
    running_pkg=$(pacman -Qoq "/usr/lib/modules/$current_uname" 2>/dev/null || true)
    local all_candidates
    all_candidates=$(pacman -Qq 2>/dev/null | grep -E '^linux(-[a-z0-9]+)*$' | grep -vE '(-headers|-docs|^linux-firmware|^linux-api-headers|^linux-tools|^linux-util)' || true)

    for candidate in $all_candidates; do
      if pacman -Ql "$candidate" 2>/dev/null | grep -qE '/(vmlinuz|modules/[^/]+/vmlinuz)'; then
        kernel_pkgs+=("$candidate")
      fi
    done

    for k in "${kernel_pkgs[@]}"; do
      local k_ver k_size
      k_ver=$( (pacman -Qi "$k" 2>/dev/null || true) | awk -F': ' '/^Version/ {print $2}' | tr -d ' ')
      k_size=$( (pacman -Qi "$k" 2>/dev/null || true) | awk -F': ' '/^Installed Size/ {print $2}')
      local is_active=0
      local flavor="${k#linux-}"
      if [[ -n "$running_pkg" && "$k" == "$running_pkg" ]]; then
        is_active=1
      elif [[ "$current_uname" == *"$flavor"* && "$current_uname" == *"$k_ver"* ]]; then
        is_active=1
      fi

      if [[ $is_active -eq 1 ]]; then
        echo -e "    - ${CYAN}$k${RESET} ($k_ver) - ${GREEN}[CURRENTLY ACTIVE - PROTECTED]${RESET} (Size: ${k_size:-unknown})"
      else
        echo -e "    - ${YELLOW}$k${RESET} ($k_ver) - ${RED}[REMOVABLE]${RESET} (Size: ${k_size:-unknown})"
        removable_kernels+=("$k")
      fi
    done
    ;;

  apt)
    mapfile -t kernel_pkgs < <(dpkg-query -W -f='${Package}\t${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '/installed/ {print $1}' || true)
    for k in "${kernel_pkgs[@]}"; do
      local sz
      sz=$(dpkg-query -W -f='${Installed-Size}' "$k" 2>/dev/null | awk '{print int($1 * 1024)}' || echo 0)
      if [[ "$k" == *"$current_uname"* ]]; then
        echo -e "    - ${CYAN}$k${RESET} - ${GREEN}[CURRENTLY ACTIVE - PROTECTED]${RESET} (Size: $(format_bytes "$sz"))"
      else
        echo -e "    - ${YELLOW}$k${RESET} - ${RED}[REMOVABLE]${RESET} (Size: $(format_bytes "$sz"))"
        removable_kernels+=("$k")
      fi
    done
    ;;

  dnf | zypper)
    mapfile -t kernel_pkgs < <(rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -E '^(kernel-core|kernel-default|kernel)-[0-9]' || true)
    for k in "${kernel_pkgs[@]}"; do
      local sz
      sz=$(rpm -q --queryformat '%{SIZE}' "$k" 2>/dev/null || echo 0)
      if [[ "$k" == *"$current_uname"* ]]; then
        echo -e "    - ${CYAN}$k${RESET} - ${GREEN}[CURRENTLY ACTIVE - PROTECTED]${RESET} (Size: $(format_bytes "$sz"))"
      else
        echo -e "    - ${YELLOW}$k${RESET} - ${RED}[REMOVABLE]${RESET} (Size: $(format_bytes "$sz"))"
        removable_kernels+=("$k")
      fi
    done
    ;;

  *)
    echo -e "  ${YELLOW}Automated kernel removal is not supported in Generic Linux mode.${RESET}"
    echo -e "  ${DIM}Running kernel: $current_uname${RESET}"
    pause
    return
    ;;
  esac

  echo ""
  if [[ ${#kernel_pkgs[@]} -le 1 ]]; then
    echo -e "${GREEN}✅ Only one kernel installed (${kernel_pkgs[*]:-current}). Nothing to clean.${RESET}"
    pause
    return
  fi

  # Hard Fail-Safe: Never allow queueing all kernels for deletion
  if [[ ${#removable_kernels[@]} -ge ${#kernel_pkgs[@]} ]]; then
    echo -e "${RED}⚠️  SAFETY ABORT: Failed to detect the active running kernel.${RESET}"
    echo -e "${RED}   All kernels were marked removable. Cleanup canceled to protect the system.${RESET}"
    pause
    return
  fi

  if [[ ${#removable_kernels[@]} -eq 0 ]]; then
    echo -e "${GREEN}No inactive kernels eligible for removal.${RESET}"
    pause
    return
  fi

  echo -e "  ${DIM}Associated headers will also be removed automatically.${RESET}"
  echo ""
  echo -en "  Remove unused kernel packages (${removable_kernels[*]})? ${GREEN}[y/N]${RESET} "
  local confirm=""
  read_input confirm

  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    for rk in "${removable_kernels[@]}"; do
      echo -e "${RED}🗑️  Removing $rk...${RESET}"
      local to_remove=("$rk")

      # Detect associated headers
      if [[ "$PKG_MANAGER" == "pacman" ]]; then
        local headers_pkg="${rk}-headers"
        if pacman -Qq "$headers_pkg" &>/dev/null; then
          to_remove+=("$headers_pkg")
        fi
      elif [[ "$PKG_MANAGER" == "apt" ]]; then
        local headers_pkg="${rk/linux-image/linux-headers}"
        if dpkg-query -W "$headers_pkg" &>/dev/null; then
          to_remove+=("$headers_pkg")
        fi
      fi

      if pkg_remove "${to_remove[@]}"; then
        log_action "DELETED KERNEL: ${to_remove[*]}"
        echo -e "${GREEN}  ✅ Successfully removed ${to_remove[*]}.${RESET}"
      else
        echo -e "${RED}  ❌ Failed to remove $rk.${RESET}"
      fi
    done
  else
    echo -e "${DIM}  ↳ Canceled.${RESET}"
  fi
  pause
}

# ── Option 6: Detailed Directory Cleaner ──────────────────────────────────
clean_target_dir() {
  local label="$1"
  local path="$2"

  echo ""
  echo -e "  ${BOLD}Analyzing $label ($path)...${RESET}"
  if [[ ! -d "$path" ]]; then
    echo -e "  ${DIM}Directory does not exist. Skipping.${RESET}"
    return
  fi

  local before_bytes item_count
  before_bytes=$(get_path_bytes "$path")
  item_count=$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

  echo -e "    Current size: ${YELLOW}$(format_bytes "$before_bytes")${RESET} ($item_count items)"
  echo -en "    Delete all contents in $label? ${GREEN}[y/N]${RESET} "
  local confirm=""
  read_input confirm

  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    echo -e "    ${RED}🗑️  Cleaning $path...${RESET}"
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    local after_bytes freed_bytes
    after_bytes=$(get_path_bytes "$path")
    freed_bytes=$((before_bytes - after_bytes))
    [[ $freed_bytes -lt 0 ]] && freed_bytes=0
    echo -e "    ${GREEN}✅ Cleaned! Reclaimed: $(format_bytes "$freed_bytes")${RESET}"
    log_action "CLEANED DIRECTORY: $path (Freed $(format_bytes "$freed_bytes"))"
  else
    echo -e "    ${DIM}↳ Skipped.${RESET}"
  fi
}

clean_directories() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  📁 DIRECTORY CLEANER — Auto-Detected Space Consumers       ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  # ── Build dynamic directory list from $HOME ────────────────────
  local dir_options=()
  local dir_labels=()
  local dir_sizes=()
  local idx=0

  # Scan user home directories (top-level folders in ~)
  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    [[ ! -d "$path" ]] && continue
    local basename
    basename=$(basename "$path")
    [[ "$basename" == "." ]] && continue
    idx=$((idx + 1))
    dir_options+=("$idx|$path")
    dir_labels+=("$basename")
    dir_sizes+=("$size")
  done < <(du -sh "$HOME"/*/ 2>/dev/null | sort -rh | awk '{print $1 "\t" $2}' || true)

  # Add common system cache/temp dirs if they exist and have size
  local pkg_cache_dir
  pkg_cache_dir=$(pkg_get_cache_dirs | head -1)

  local system_dirs=(
    "$HOME/.cache"
    "/tmp"
  )
  [[ -n "$pkg_cache_dir" && -d "$pkg_cache_dir" ]] && system_dirs+=("$pkg_cache_dir")

  for sysdir in "${system_dirs[@]}"; do
    [[ -d "$sysdir" ]] || continue
    local sz
    sz=$(get_path_bytes "$sysdir")
    [[ "$sz" -eq 0 ]] && continue
    idx=$((idx + 1))
    local display_name
    if [[ "$sysdir" == "$HOME/.cache" ]]; then
      display_name="~/.cache (user cache)"
    elif [[ "$sysdir" == "/tmp" ]]; then
      display_name="/tmp (system temp)"
    elif [[ "$sysdir" == "$pkg_cache_dir" ]]; then
      display_name="$sysdir (${PKG_MANAGER} cache)"
    else
      display_name="$sysdir"
    fi
    dir_options+=("$idx|$sysdir")
    dir_labels+=("$display_name")
    dir_sizes+=("$(format_bytes "$sz")")
  done

  if [[ ${#dir_options[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No directories found to clean.${RESET}"
    pause
    return
  fi

  # Display the dynamically built list
  echo -e "  ${BOLD}Detected directories (sorted by size):${RESET}"
  echo ""
  printf "  ${BOLD}%-4s %-50s %12s${RESET}\n" "#" "Directory" "Size"
  echo -e "  ${DIM}$(printf '─%.0s' {1..70})${RESET}"
  for i in "${!dir_options[@]}"; do
    local opt_label="${dir_labels[$i]}"
    local opt_size="${dir_sizes[$i]}"
    printf "  ${YELLOW}%-3d${RESET} %-50s %12s\n" "$((i + 1))" "$opt_label" "$opt_size"
  done
  echo ""
  echo -e "  ${GREEN}[a]${RESET} Clean ALL of the above"
  echo -e "  ${RED}[q]${RESET} Back to main menu"
  echo ""
  echo -en "  Choose option(s) or [a]/[q]> ${RESET}"
  local raw_choice=""
  read_input raw_choice

  case "$raw_choice" in
  a | A)
    echo ""
    local total_freed=0
    for i in "${!dir_options[@]}"; do
      local opt_path="${dir_options[$i]#*|}"
      local opt_label="${dir_labels[$i]}"
      local before
      before=$(get_path_bytes "$opt_path")
      echo -e "  ${YELLOW}Cleaning: ${opt_label} ($(format_bytes "$before"))...${RESET}"
      find "$opt_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
      local after freed
      after=$(get_path_bytes "$opt_path")
      freed=$((before - after))
      [[ $freed -lt 0 ]] && freed=0
      total_freed=$((total_freed + freed))
      echo -e "    ${GREEN}✅ Freed $(format_bytes "$freed")${RESET}"
      log_action "CLEANED DIRECTORY: $opt_path (Freed $(format_bytes "$freed"))"
    done
    echo ""
    echo -e "  ${GREEN}Done! Total reclaimed: $(format_bytes "$total_freed")${RESET}"
    log_action "CLEANED ALL DIRECTORIES: Total Freed $(format_bytes "$total_freed")"
    pause
    ;;
  q | Q)
    return
    ;;
  *)
    local choices
    choices=$(echo "$raw_choice" | tr ',' ' ' | tr -s ' ')
    for num in $choices; do
      [[ "$num" =~ ^[0-9]+$ ]] || continue
      local array_idx=$((num - 1))
      [[ $array_idx -ge 0 && $array_idx -lt ${#dir_options[@]} ]] || continue
      local opt_path="${dir_options[$array_idx]#*|}"
      local opt_label="${dir_labels[$array_idx]}"

      if [[ "$opt_path" == "/tmp" ]]; then
        echo -e "  ${YELLOW}Cleaning /tmp (requires sudo)...${RESET}"
        local before after freed
        before=$(get_path_bytes "/tmp")
        sudo find /tmp -mindepth 1 -maxdepth 2 -not -path "*/.*" -delete 2>/dev/null || true
        after=$(get_path_bytes "/tmp")
        freed=$((before - after))
        [[ $freed -lt 0 ]] && freed=0
        echo -e "    ${GREEN}✅ Freed $(format_bytes "$freed")${RESET}"
        log_action "CLEANED /tmp (Freed $(format_bytes "$freed"))"
      elif [[ -n "$pkg_cache_dir" && "$opt_path" == "$pkg_cache_dir" ]]; then
        clean_target_pkg_cache
      else
        local before after freed
        before=$(get_path_bytes "$opt_path")
        echo -e "  ${YELLOW}Cleaning: ${opt_label}...${RESET}"
        find "$opt_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        after=$(get_path_bytes "$opt_path")
        freed=$((before - after))
        [[ $freed -lt 0 ]] && freed=0
        echo -e "    ${GREEN}✅ Cleaned! Freed $(format_bytes "$freed")${RESET}"
        log_action "CLEANED DIRECTORY: $opt_path (Freed $(format_bytes "$freed"))"
      fi
    done
    pause
    ;;
  esac
}

# ── Option 7: Clean All Caches at Once (Batch) ────────────────────────────
clean_all_caches() {
  clear_screen
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  🧹 BATCH CLEAN ALL CACHES (Full System Audit)              ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  local b_user b_trash b_thumb b_tmp b_pkg b_aur
  b_user=$(get_path_bytes "$HOME/.cache")
  b_trash=$(get_path_bytes "$HOME/.local/share/Trash")
  local t1 t2
  t1=$(get_path_bytes "$HOME/.thumbnails")
  t2=$(get_path_bytes "$HOME/.cache/thumbnails")
  b_thumb=$((t1 + t2))
  b_tmp=$(get_path_bytes "/tmp")
  b_pkg=$(pkg_get_cache_bytes)
  local a1 a2
  a1=$(get_path_bytes "$HOME/.cache/yay")
  a2=$(get_path_bytes "$HOME/.cache/paru")
  b_aur=$((a1 + a2))

  local est_total=$((b_user + b_trash + b_thumb + b_tmp + b_pkg + b_aur))

  echo -e "  This action will clean ALL caches at once:"
  echo -e "    1. User Cache (~/.cache)             $(format_bytes "$b_user")"
  echo -e "    2. Trash Bin (~/.local/share/Trash)  $(format_bytes "$b_trash")"
  echo -e "    3. Thumbnails (~/.thumbnails)        $(format_bytes "$b_thumb")"
  echo -e "    4. System Temp (/tmp)                $(format_bytes "$b_tmp")"
  echo -e "    5. Package Cache (${PKG_MANAGER})         $(format_bytes "$b_pkg")"
  if command -v journalctl &>/dev/null; then
    echo -e "    6. Systemd Journal Logs (vacuum > 3 days / 100M)"
  fi
  if command -v flatpak &>/dev/null; then
    echo -e "    7. Flatpak Unused Runtimes"
  fi
  if command -v snap &>/dev/null; then
    echo -e "    8. Snap Old Revisions"
  fi
  if [[ -d "$HOME/.cache/yay" || -d "$HOME/.cache/paru" ]]; then
    echo -e "    9. AUR Helper Caches (yay/paru)      $(format_bytes "$b_aur")"
  fi
  echo ""
  echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
  echo -e "  ${BOLD}ESTIMATED RECLAIMABLE: ${GREEN}$(format_bytes "$est_total")${RESET}"
  echo ""
  echo -en "  Proceed with full batch cleanup? ${GREEN}[y/N]${RESET} "
  local confirm=""
  read_input confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${DIM}  ↳ Canceled.${RESET}"
    pause
    return
  fi

  echo ""
  echo -e "${RED}  Starting full batch cleanup...${RESET}"
  echo ""

  local f_user f_trash f_thumb f_tmp f_pkg f_aur
  f_user=$(clean_target_user_cache)
  f_user=$(echo "$f_user" | tail -1 | tr -dc '0-9')
  [[ -z "$f_user" ]] && f_user=0

  f_trash=$(clean_target_trash)
  f_trash=$(echo "$f_trash" | tail -1 | tr -dc '0-9')
  [[ -z "$f_trash" ]] && f_trash=0

  f_thumb=$(clean_target_thumbnails)
  f_thumb=$(echo "$f_thumb" | tail -1 | tr -dc '0-9')
  [[ -z "$f_thumb" ]] && f_thumb=0

  f_tmp=$(clean_target_tmp)
  f_tmp=$(echo "$f_tmp" | tail -1 | tr -dc '0-9')
  [[ -z "$f_tmp" ]] && f_tmp=0

  f_pkg=$(clean_target_pkg_cache)
  f_pkg=$(echo "$f_pkg" | tail -1 | tr -dc '0-9')
  [[ -z "$f_pkg" ]] && f_pkg=0

  clean_target_journal >/dev/null 2>&1 || true
  clean_target_flatpak >/dev/null 2>&1 || true
  clean_target_snap >/dev/null 2>&1 || true

  f_aur=0
  if [[ -d "$HOME/.cache/yay" || -d "$HOME/.cache/paru" ]]; then
    f_aur=$(clean_target_aur_cache)
    f_aur=$(echo "$f_aur" | tail -1 | tr -dc '0-9')
    [[ -z "$f_aur" ]] && f_aur=0
  fi

  local total_freed=$((f_user + f_trash + f_thumb + f_tmp + f_pkg + f_aur))

  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  📊 BATCH CLEANUP SUMMARY                                   ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  printf "  %-32s %s\n" "Cache Target" "Reclaimed"
  echo -e "  ────────────────────────────────────────────────────────────"
  printf "  %-32s ${GREEN}%s${RESET}\n" "User Cache (~/.cache)" "$(format_bytes "$f_user")"
  printf "  %-32s ${GREEN}%s${RESET}\n" "Trash Bin (~/.local/share/Trash)" "$(format_bytes "$f_trash")"
  printf "  %-32s ${GREEN}%s${RESET}\n" "Thumbnails" "$(format_bytes "$f_thumb")"
  printf "  %-32s ${GREEN}%s${RESET}\n" "System Temp (/tmp)" "$(format_bytes "$f_tmp")"
  printf "  %-32s ${GREEN}%s${RESET}\n" "Package Cache (${PKG_MANAGER})" "$(format_bytes "$f_pkg")"
  if [[ $f_aur -gt 0 ]]; then
    printf "  %-32s ${GREEN}%s${RESET}\n" "AUR Helper Caches" "$(format_bytes "$f_aur")"
  fi
  echo -e "  ────────────────────────────────────────────────────────────"
  echo -e "  ${BOLD}Total Reclaimed Space:${RESET} ${GREEN}$(format_bytes "$total_freed")${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"

  log_action "BATCH CLEAN ALL CACHES: Reclaimed $(format_bytes "$total_freed") total"
  pause
}

# ── Option 9: Skip List Manager ───────────────────────────────────────────
remove_skipped_packages() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  📦 MANAGE SKIPPED PACKAGES                                  ${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo ""

    if [[ ! -s "$SKIPPED_PKGS_FILE" ]]; then
      echo -e "  ${GREEN}No packages currently in the skip list.${RESET}\n"
      pause
      return
    fi

    local pkgs=()
    mapfile -t pkgs < <(grep -v '^[[:space:]]*$' "$SKIPPED_PKGS_FILE" 2>/dev/null || true)

    if [[ ${#pkgs[@]} -eq 0 ]]; then
      echo -e "  ${GREEN}No packages currently in the skip list.${RESET}\n"
      pause
      return
    fi

    echo -e "  ${BOLD}Permanently Skipped Packages (${#pkgs[@]} total):${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    for i in "${!pkgs[@]}"; do
      local p="${pkgs[$i]}"
      local p_size
      p_size=$(pkg_get_size "$p")
      p_size="${p_size:-0}"
      if [[ $p_size -gt 0 ]]; then
        printf "    ${CYAN}%2d.${RESET} %-35s ${GREEN}(%s)${RESET}\n" "$((i + 1))" "$p" "$(format_bytes "$p_size")"
      else
        printf "    ${CYAN}%2d.${RESET} %-35s ${DIM}(unknown size / uninstalled)${RESET}\n" "$((i + 1))" "$p"
      fi
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${DIM}Removing a package restores it so it will be prompted again in Option [1].${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    - Enter number(s) to remove (e.g. ${YELLOW}1${RESET}, ${YELLOW}1, 3${RESET}, or ${YELLOW}1-3${RESET})"
    echo -e "    - Type package name directly"
    echo -e "    - Enter ${YELLOW}a${RESET} to remove ALL from skip list"
    echo -e "    - Enter ${YELLOW}q${RESET} or press ${YELLOW}ENTER${RESET} to return"
    echo ""
    echo -en "  Select package(s) to remove> "

    local input=""
    read_input input
    input="$(echo "$input" | xargs)"

    if [[ -z "$input" || "$input" == "q" || "$input" == "Q" ]]; then
      return
    fi

    if [[ "$input" == "a" || "$input" == "A" ]]; then
      echo ""
      echo -en "  Remove all ${#pkgs[@]} package(s) from skip list? ${GREEN}[y/N]${RESET} "
      local confirm=""
      read_input confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        : >"$SKIPPED_PKGS_FILE"
        for p in "${pkgs[@]}"; do
          log_action "REMOVED FROM SKIP LIST: $p"
        done
        echo -e "\n  ${GREEN}✅ Cleared all packages from skip list!${RESET}"
        sleep 1.2
        return
      else
        echo -e "  ${DIM}↳ Canceled.${RESET}"
        sleep 0.8
        continue
      fi
    fi

    local clean_input
    clean_input=$(echo "$input" | tr ',' ' ')
    local tokens=()
    read -ra tokens <<<"$clean_input"

    local selected_indices=()
    local invalid_tokens=()

    for token in "${tokens[@]}"; do
      if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
        local start="${token%-*}"
        local end="${token#*-}"
        if ((start > end)); then
          local temp="$start"
          start="$end"
          end="$temp"
        fi
        for ((n = start; n <= end; n++)); do
          local idx=$((n - 1))
          if ((idx >= 0 && idx < ${#pkgs[@]})); then
            selected_indices+=("$idx")
          else
            invalid_tokens+=("$n")
          fi
        done
      elif [[ "$token" =~ ^[0-9]+$ ]]; then
        local idx=$((token - 1))
        if ((idx >= 0 && idx < ${#pkgs[@]})); then
          selected_indices+=("$idx")
        else
          invalid_tokens+=("$token")
        fi
      else
        local found=0
        for i in "${!pkgs[@]}"; do
          if [[ "${pkgs[$i]}" == "$token" ]]; then
            selected_indices+=("$i")
            found=1
            break
          fi
        done
        if ((found == 0)); then
          invalid_tokens+=("$token")
        fi
      fi
    done

    if [[ ${#invalid_tokens[@]} -gt 0 ]]; then
      echo -e "\n  ${YELLOW}⚠️  Unknown or out-of-range selection(s): ${invalid_tokens[*]}${RESET}"
    fi

    if [[ ${#selected_indices[@]} -eq 0 ]]; then
      echo -e "  ${RED}No valid packages selected.${RESET}"
      sleep 1.2
      continue
    fi

    local unique_indices=()
    mapfile -t unique_indices < <(printf '%s\n' "${selected_indices[@]}" | sort -nu)

    local to_remove=()
    for idx in "${unique_indices[@]}"; do
      to_remove+=("${pkgs[$idx]}")
    done

    local to_remove_file
    to_remove_file=$(mktemp)
    printf "%s\n" "${to_remove[@]}" >"$to_remove_file"

    local tmp_file
    tmp_file=$(mktemp)
    grep -Fxv -f "$to_remove_file" "$SKIPPED_PKGS_FILE" >"$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$SKIPPED_PKGS_FILE"
    rm -f "$to_remove_file"

    echo ""
    for pkg in "${to_remove[@]}"; do
      log_action "REMOVED FROM SKIP LIST: $pkg"
      echo -e "  ${GREEN}✅ Removed from skip list:${RESET} ${BOLD}$pkg${RESET}"
    done
    echo ""
    echo -e "  ${DIM}Updated skip list saved to $SKIPPED_PKGS_FILE${RESET}"
    sleep 1.2
  done
}

manage_skip_lists() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  ⚙️  MANAGE SKIPPED PACKAGES                                  ${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    echo ""

    local pkg_count
    pkg_count=$(get_skipped_pkg_count)

    echo -e "  ${BOLD}Configured Skips:${RESET}"
    echo -e "    Ignored packages file: ${CYAN}$SKIPPED_PKGS_FILE${RESET}"
    echo -e "    Items skipped:         ${YELLOW}$pkg_count package(s)${RESET}"
    echo ""
    echo -e "  ${GREEN}[1]${RESET} View & choose skipped packages to delete / unskip"
    echo -e "  ${GREEN}[2]${RESET} Clear entire skipped packages list"
    echo -e "  ${GREEN}[q]${RESET} Return to main menu"
    echo ""
    echo -en "  Choose an option> "
    local choice=""
    read_input choice

    case "$choice" in
    1)
      remove_skipped_packages
      ;;
    2)
      if [[ ! -s "$SKIPPED_PKGS_FILE" ]]; then
        echo -e "\n  ${YELLOW}Package skip list is already empty.${RESET}"
        sleep 1
        continue
      fi
      echo ""
      echo -en "  Are you sure you want to clear the entire package skip list? ${GREEN}[y/N]${RESET} "
      local confirm=""
      read_input confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        : >"$SKIPPED_PKGS_FILE"
        log_action "CLEARED ALL SKIPPED PACKAGES"
        echo -e "\n${GREEN}✅ Package skip list cleared! All packages will be prompted again.${RESET}"
        sleep 1.2
      else
        echo -e "  ${DIM}↳ Canceled.${RESET}"
        sleep 0.8
      fi
      ;;
    q | Q)
      return
      ;;
    *)
      echo -e "\n  ${RED}Invalid option.${RESET}"
      sleep 0.8
      ;;
    esac
  done
}

# ── Main Menu ─────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║                 🧹 DISK CLEANUP TOOL                         ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}System:${RESET} ${GREEN}${DISTRO_NAME}${RESET} | ${CYAN}${PKG_MANAGER}${RESET} | ${DIM}$(uname -m)${RESET}"
    echo -e "  ${BOLD}Storage (/):${RESET} ${GREEN}$(df -h / | tail -1 | awk '{print $4}')${RESET} available (${YELLOW}$(df -h / | tail -1 | awk '{print $5}')${RESET} used)"
    echo ""
    echo -e "  ${GREEN}[1]${RESET} 📦 Interactive Package Cleaner (largest first)"
    echo -e "  ${GREEN}[2]${RESET} 📊 Show Biggest Packages (Top 30)"
    echo -e "  ${GREEN}[3]${RESET} 🗑️  Remove Orphan Packages (unneeded dependencies)"
    echo -e "  ${GREEN}[4]${RESET} 🧹 Choose Which Caches to Clean (selective)"
    echo -e "  ${GREEN}[5]${RESET} 🧬 Clean Old Kernels (keeps active kernel safe)"
    echo -e "  ${GREEN}[6]${RESET} 📁 Directory Cleaner (Downloads, Videos, large dirs)"
    echo -e "  ${GREEN}[7]${RESET} 🧹 Clean All Caches at Once (batch)"
    echo -e "  ${GREEN}[8]${RESET} 📋 Show Cleanup Log"
    echo -e "  ${GREEN}[9]${RESET} ⚙️  Manage Skipped Packages"
    echo -e "  ${GREEN}[0]${RESET} 🔄 Show System Overview"
    echo -e "  ${RED}[q]${RESET} ❌ Quit"
    echo ""
    local ignored_count
    ignored_count=$(get_skipped_pkg_count)
    echo -e "  ${DIM}Permanently ignored packages: $ignored_count (in ~/.config/cleanup/skipped_packages.txt)${RESET}"
    echo ""
    echo -en "  Choose an option> "

    local choice=""
    read_input choice
    case "$choice" in
    1) clean_packages ;;
    2) show_biggest_packages ;;
    3) clean_orphans ;;
    4) clean_cache ;;
    5) clean_kernels ;;
    6) clean_directories ;;
    7) clean_all_caches ;;
    8)
      clear_screen
      echo -e "${BOLD}${CYAN}=== Action Log ($LOG_FILE) ===${RESET}\n"
      if [[ -s "$LOG_FILE" ]]; then
        cat "$LOG_FILE"
      else
        echo -e "${DIM}No actions logged yet.${RESET}"
      fi
      pause
      ;;
    9) manage_skip_lists ;;
    0) show_overview ;;
    q | Q)
      echo ""
      echo -e "${GREEN}Done! Check $LOG_FILE for a record of all operations.${RESET}"
      echo -e "${YELLOW}Final disk status:${RESET}"
      df -h /
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option.${RESET}"
      sleep 1
      ;;
    esac
  done
}

# ── Entry Point ───────────────────────────────────────────────────────────
check_root
init_system_info

echo -e "${CYAN}Welcome to Disk Cleanup Tool!${RESET}"
echo -e "${DIM}Detected OS: ${DISTRO_NAME} | Package Manager: ${PKG_MANAGER}${RESET}"
echo -e "${DIM}All operations are logged to $LOG_FILE${RESET}"
echo ""
echo -en "  ${DIM}Press ENTER to start...${RESET}"
_start_dummy=""
read_input _start_dummy
show_overview
main_menu
