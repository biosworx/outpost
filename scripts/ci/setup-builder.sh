#!/usr/bin/env bash
#
# Prepare the archlinux:base-devel container for building:
#   - create the unprivileged "builder" user with passwordless sudo
#     (makepkg refuses to run as root; --syncdeps needs sudo pacman)
#   - hand the workspace to that user
#   - register the [aurstrich] repo so packages can depend on each other,
#     but only once the repo actually exists remotely (bootstrap-safe).
#     Run pacman -Syu afterwards: this does not sync.
#
# Env: SKIP_PACMAN=1 for jobs that install no packages (publishing,
#      removing): leaves pacman's configuration and keyring alone.
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

if [[ "${SKIP_PACMAN:-0}" == "1" ]]; then
  log "SKIP_PACMAN=1: not registering [${REPO_NAME}]"
  exit 0
fi

group_start "Registering [${REPO_NAME}] repository"
server_url="$(repo_read_url)"
db_url="${server_url}/${REPO_NAME}.db"
headers="$(curl -sSI --max-time 20 "$db_url" 2>&1 || true)"
status="$(awk 'toupper($1) ~ /^HTTP\// { code = $2 } END { print code }' <<<"$headers")"

if grep -q "^\[${REPO_NAME}\]" /etc/pacman.conf; then
  log "[${REPO_NAME}] already present in pacman.conf"
elif [[ "$status" == "200" ]]; then
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
Server = ${server_url}
EOF
  ok "added [${REPO_NAME}] -> ${server_url}"
elif [[ "$status" == "404" ]]; then
  warn "${db_url} does not exist yet; skipping (first publish?)"
else
  # Anything else means the repo exists but this runner was refused, e.g. a
  # Cloudflare bot challenge (cf-mitigated: challenge). Builds still run, but
  # packages depending on other [REPO_NAME] packages will fail to resolve.
  mitigated="$(awk -F': *' 'tolower($1) == "cf-mitigated" { sub(/\r$/, "", $2); print $2 }' <<<"$headers")"
  msg="${db_url} returned HTTP ${status:-none}${mitigated:+ (cf-mitigated: ${mitigated})}; [${REPO_NAME}] is unavailable as a dependency source in this job"
  warn "$msg"
  if in_ci; then printf '::warning title=%s unreachable::%s\n' "$REPO_NAME" "$msg"; fi
fi
group_end
