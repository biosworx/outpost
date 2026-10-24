#!/usr/bin/env bash
#
# Prepare the archlinux:base-devel container for building:
#   - create the unprivileged "builder" user with passwordless sudo
#     (makepkg refuses to run as root; --syncdeps needs sudo pacman)
#   - hand the workspace to that user
#   - register the [aurstrich] repo so packages can depend on each other,
#     but only once the repo actually exists remotely (bootstrap-safe)
#
# Must run as root.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ "$(id -u)" -eq 0 ]] || die "setup-builder.sh must run as root"
require_cmd useradd visudo curl

BUILD_USER="${BUILD_USER:-builder}"

group_start "Creating build user '${BUILD_USER}'"
if ! id -u "$BUILD_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$BUILD_USER"
fi

sudoers_file="/etc/sudoers.d/90-${BUILD_USER}"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$BUILD_USER" >"$sudoers_file"
chmod 0440 "$sudoers_file"
visudo -cf "$sudoers_file" >/dev/null || die "generated sudoers file is invalid"

mkdir -p "$OUT_DIR"
chown -R "$BUILD_USER:$BUILD_USER" "$REPO_ROOT"
group_end

group_start "Configuring makepkg"
# Use all cores and stamp packages with a consistent packager identity.
mkdir -p /etc/makepkg.conf.d
cat >/etc/makepkg.conf.d/outpost.conf <<EOF
MAKEFLAGS="-j$(nproc)"
PACKAGER="${PACKAGER:-outpost CI <ci@${REPO_DOMAIN#https://}>}"
# Do not split out -debug packages into the repo.
OPTIONS=("\${OPTIONS[@]/#debug/!debug}")
# Maximum zstd compression: ~55% smaller than the default for legcord; slower
# to build, decompression is unaffected.
COMPRESSZST=(zstd -c -T0 --ultra -22 -)
EOF
group_end

group_start "Registering [${REPO_NAME}] repository"
if grep -q "^\[${REPO_NAME}\]" /etc/pacman.conf; then
  log "[${REPO_NAME}] already present in pacman.conf"
elif curl -fsSI --max-time 20 "${REPO_URL}/${REPO_NAME}.db" >/dev/null 2>&1; then
  # Trust the committed public key so [REPO_NAME] packages verify even in
  # jobs that never import the private signing key (e.g. update test builds).
  pubkey="${REPO_ROOT}/keys/${REPO_NAME}.asc"
  if [[ ! -f "$pubkey" ]] || grep -q PLACEHOLDER "$pubkey"; then
    die "keys/${REPO_NAME}.asc is missing; cannot trust [${REPO_NAME}]"
  fi
  # Always init: the base image has a trustdb but no local key to lsign with.
  pacman-key --init
  pacman-key --add "$pubkey"
  while IFS= read -r fpr; do
    pacman-key --lsign-key "$fpr"
  done < <(gpg --batch --with-colons --show-keys "$pubkey" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')

  cat >>/etc/pacman.conf <<EOF

[${REPO_NAME}]
SigLevel = Required DatabaseOptional
Server = ${REPO_URL}
EOF
  pacman -Sy --noconfirm
  ok "added [${REPO_NAME}] -> ${REPO_URL}"
else
  warn "${REPO_URL}/${REPO_NAME}.db not reachable yet; skipping (first publish?)"
fi
group_end
