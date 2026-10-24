#!/usr/bin/env bash
#
# Import the repository signing key for the build user and cache its
# passphrase in gpg-agent so makepkg --sign and repo-add -s run unattended.
#
# Also adds the public key to the pacman keyring so [aurstrich] packages pulled
# in by --syncdeps verify, and exports it to $OUT_DIR/<repo>.asc for upload.
#
# Env (required): GPG_PRIVATE_KEY  ASCII-armoured secret key
#                 GPG_KEY_ID       key ID or fingerprint to sign with
# Env (optional): GPG_PASSPHRASE   empty for an unprotected key
#
# Must run as root (the builder user is created by setup-builder.sh).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ "$(id -u)" -eq 0 ]] || die "setup-gpg.sh must run as root"
require_cmd gpg gpgconf pacman-key sudo
require_env GPG_PRIVATE_KEY GPG_KEY_ID

BUILD_USER="${BUILD_USER:-builder}"
builder_home="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
[[ -n "$builder_home" ]] || die "build user '$BUILD_USER' does not exist; run setup-builder.sh first"

export GNUPGHOME="${builder_home}/.gnupg"
PRESET_BIN="/usr/lib/gnupg/gpg-preset-passphrase"

group_start "Configuring gpg-agent for ${BUILD_USER}"
as_builder install -d -m 700 "$GNUPGHOME"
as_builder tee "$GNUPGHOME/gpg-agent.conf" >/dev/null <<'EOF'
allow-preset-passphrase
default-cache-ttl 86400
max-cache-ttl 86400
EOF
as_builder tee "$GNUPGHOME/gpg.conf" >/dev/null <<'EOF'
use-agent
no-greeting
EOF
as_builder gpgconf --kill gpg-agent || true
as_builder gpgconf --launch gpg-agent
group_end

group_start "Importing signing key"
printf '%s\n' "$GPG_PRIVATE_KEY" | as_builder gpg --batch --quiet --import

fingerprint="$(
  as_builder gpg --batch --with-colons --list-secret-keys "$GPG_KEY_ID" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"
[[ -n "$fingerprint" ]] || die "secret key for '$GPG_KEY_ID' not found after import"
log "signing key fingerprint: $fingerprint"

printf '%s:6:\n' "$fingerprint" | as_builder gpg --batch --quiet --import-ownertrust
group_end

group_start "Caching passphrase in gpg-agent"
if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  [[ -x "$PRESET_BIN" ]] || die "$PRESET_BIN not found"
  mapfile -t keygrips < <(
    as_builder gpg --batch --with-colons --with-keygrip --list-secret-keys "$fingerprint" \
      | awk -F: '$1 == "grp" { print $10 }'
  )
  [[ "${#keygrips[@]}" -gt 0 ]] || die "no keygrips found for $fingerprint"
  for grip in "${keygrips[@]}"; do
    # Passphrase goes in on stdin so it never appears in the process list.
    printf '%s' "$GPG_PASSPHRASE" | as_builder "$PRESET_BIN" --preset "$grip"
  done
  ok "cached passphrase for ${#keygrips[@]} keygrip(s)"
else
  log "GPG_PASSPHRASE is empty; assuming an unprotected key"
fi

# Fail now rather than halfway through a build if the passphrase is wrong.
printf 'outpost signing self-test\n' \
  | as_builder gpg --batch --pinentry-mode error --local-user "$fingerprint" \
      --detach-sign --output /dev/null \
  || die "test signature failed; check GPG_PASSPHRASE / GPG_KEY_ID"
ok "test signature succeeded"
group_end

group_start "Trusting key in pacman keyring"
[[ -f /etc/pacman.d/gnupg/trustdb.gpg ]] || pacman-key --init
mkdir -p "$OUT_DIR"
pubkey="${OUT_DIR}/${REPO_NAME}.asc"
as_builder gpg --batch --armor --export "$fingerprint" >"$pubkey"
pacman-key --add "$pubkey"
pacman-key --lsign-key "$fingerprint"

if [[ -f "${REPO_ROOT}/keys/${REPO_NAME}.asc" ]] \
  && ! grep -q 'PLACEHOLDER' "${REPO_ROOT}/keys/${REPO_NAME}.asc" \
  && ! cmp -s <(as_builder gpg --batch --with-colons --show-keys "${REPO_ROOT}/keys/${REPO_NAME}.asc" | awk -F: '$1 == "fpr" { print $10; exit }') \
              <(printf '%s\n' "$fingerprint"); then
  warn "keys/${REPO_NAME}.asc does not match the CI signing key ($fingerprint)"
fi

if grep -q "^\[${REPO_NAME}\]" /etc/pacman.conf; then
  pacman -Sy --noconfirm
fi
group_end

set_env GNUPGHOME "$GNUPGHOME"
set_env GPGKEY "$fingerprint"
