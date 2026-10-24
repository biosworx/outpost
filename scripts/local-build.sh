#!/usr/bin/env bash
#
# Build a package from packages/<name> in a clean chroot, the same way an
# official Arch package would be built, so missing (make)depends show up
# before CI does. AUR-linked packages build what CI would: the pinned AUR
# files, or override/ when it takes precedence.
#
# Usage: scripts/local-build.sh [options] <name>
#
# Options:
#   -s, --sign        sign the resulting packages with your default GPG key
#   -u, --update      force pacman -Syu inside the chroot before building
#   -r, --recreate    delete and recreate the chroot from scratch
#   -n, --no-namcap   skip namcap checks
#   -h, --help        show this help
#
# Env:
#   CHROOT_DIR  chroot location (default: ${XDG_CACHE_HOME:-~/.cache}/outpost/chroot)
#   OUTPUT_DIR  where finished packages land (default: <repo>/out)
#
# Requires: devtools (mkarchroot, arch-nspawn, makechrootpkg); optional: namcap

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/vercmp.sh
source "$(dirname "$0")/lib/vercmp.sh"
# shellcheck source=lib/aur.sh
source "$(dirname "$0")/lib/aur.sh"

usage() {
  sed -n '3,/^$/{s/^# \{0,1\}//;p}' "$0"
  exit "${1:-0}"
}

sign=0 update=0 recreate=0 run_namcap=1 name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--sign) sign=1 ;;
    -u|--update) update=1 ;;
    -r|--recreate) recreate=1 ;;
    -n|--no-namcap) run_namcap=0 ;;
    -h|--help) usage 0 ;;
    -*) warn "unknown option: $1"; usage 1 ;;
    *)
      [[ -z "$name" ]] || die "only one package name may be given"
      name="${1%/}"
      name="${name#packages/}"
      ;;
  esac
  shift
done

[[ -n "$name" ]] || usage 1
[[ "$(id -u)" -ne 0 ]] || die "run as a regular user; sudo is used where needed"
[[ -f /etc/arch-release ]] || warn "this does not look like an Arch-based host"
require_cmd mkarchroot arch-nspawn makechrootpkg sudo git

is_package "$name" || die "no PKGBUILD or aur.conf at packages/${name}"

CHROOT_DIR="${CHROOT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/outpost/chroot}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/out}"
mkdir -p "$OUTPUT_DIR"

# --- Chroot management --------------------------------------------------------------
if [[ "$recreate" -eq 1 && -d "$CHROOT_DIR" ]]; then
  log "removing existing chroot at $CHROOT_DIR"
  sudo rm -rf --one-file-system "$CHROOT_DIR"
fi

if [[ ! -d "${CHROOT_DIR}/root" ]]; then
  log "creating clean chroot at ${CHROOT_DIR}/root"
  mkdir -p "$CHROOT_DIR"
  sudo mkarchroot "${CHROOT_DIR}/root" base-devel
  update=0
fi

# Refresh at most once a day unless asked.
stamp="${CHROOT_DIR}/.last-update"
if [[ "$update" -eq 1 || ! -f "$stamp" || -n "$(find "$stamp" -mmin +1440 2>/dev/null)" ]]; then
  log "updating chroot"
  sudo arch-nspawn "${CHROOT_DIR}/root" pacman -Syu --noconfirm
  touch "$stamp"
fi

# --- Build in a throwaway copy so the checkout stays clean ---------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/outpost-${name}.XXXXXX")"
trap 'rm -rf "$work"' EXIT
resolve_package "$name" "$work" || die "could not resolve packages/${name}"

log "building ${name} in clean chroot: $(describe_resolution "$name")"
(
  cd "$work"
  PKGDEST="$OUTPUT_DIR" makechrootpkg -c -r "$CHROOT_DIR" -- --noconfirm
)

mapfile -t built < <(
  cd "$work" && PKGDEST="$OUTPUT_DIR" makepkg --packagelist
)

if [[ "$sign" -eq 1 ]]; then
  require_cmd gpg
  for pkg in "${built[@]}"; do
    [[ -f "$pkg" ]] || continue
    log "signing $(basename "$pkg")"
    gpg --batch --yes --detach-sign --use-agent ${GPGKEY:+--local-user "$GPGKEY"} "$pkg"
  done
fi

if [[ "$run_namcap" -eq 1 ]]; then
  if command -v namcap >/dev/null 2>&1; then
    log "namcap: PKGBUILD"
    namcap "${work}/PKGBUILD" || true
    for pkg in "${built[@]}"; do
      [[ -f "$pkg" ]] || continue
      log "namcap: $(basename "$pkg")"
      namcap "$pkg" || true
    done
  else
    warn "namcap not installed; skipping lint (pacman -S namcap)"
  fi
fi

ok "done; packages in ${OUTPUT_DIR}:"
for pkg in "${built[@]}"; do
  if [[ -f "$pkg" ]]; then
    printf '    %s\n' "$(basename "$pkg")" >&2
  fi
done
