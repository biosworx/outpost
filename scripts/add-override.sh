#!/usr/bin/env bash
#
# Start an override for an AUR-linked package: copy AUR's files at the pin
# into packages/<name>/override/ to edit.
#
# Usage: scripts/add-override.sh [--permanent] <name>
#
# An override takes precedence while its epoch:pkgver-pkgrel is newer than
# AUR's; the daily check proposes deleting it once AUR catches up. The copy
# starts at AUR's version, so bump pkgver or pkgrel. --permanent writes
# override/override.conf with permanent=1: the override is always built,
# whatever AUR's version, for changes AUR will never have.
#
# Refuses to replace an existing override.

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

permanent=0 name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--permanent) permanent=1 ;;
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
require_cmd git
is_aur_linked "$name" || die "packages/${name} has no aur.conf"
aur_validate "$name"
[[ ! -e "${PACKAGES_DIR}/${name}/override" ]] || die "packages/${name}/override already exists"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
aur_clone "$(aur_pkgbase "$name")" "$(aur_commit "$name")" "${work}/aur" || die "could not fetch the pinned AUR commit"
version="$(srcinfo_version "${work}/aur")"

if [[ "$permanent" -eq 1 ]]; then
  create_override "$name" "${work}/aur" "edited by hand. Permanent: see override.conf."
  cat >"${PACKAGES_DIR}/${name}/override/override.conf" <<'EOF'
# Never retire this override automatically: it carries changes AUR
# does not have. New AUR commits still get a PR, to review for changes
# worth carrying over.
permanent=1
EOF
else
  create_override "$name" "${work}/aur" "edited by hand. Retired once AUR catches up."
fi
ok "copied AUR $(aur_pkgbase "$name") ${version} to packages/${name}/override/"

cat >&2 <<EOF

Next steps:
  1. Edit packages/${name}/override/PKGBUILD.$(
  [[ "$permanent" -eq 1 ]] || printf '\n     Bump pkgver or pkgrel past %s, or AUR still wins.' "$version")
  2. Refresh checksums:       (cd packages/${name}/override && updpkgsums)
  3. Build in a clean chroot: scripts/local-build.sh ${name}
  4. Commit and push.
EOF
