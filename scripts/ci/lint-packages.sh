#!/usr/bin/env bash
#
# Sanity-check every package (or the given ones) without building:
#   - aur.conf / override.conf hold valid values and the pin exists on AUR
#   - the PKGBUILD that would be built parses (makepkg --printsrcinfo)
#   - namcap on that PKGBUILD
#   - every package directory sits under its first letter, packages/<l>/<name>
# A stale override is reported but does not fail: the daily check proposes
# deleting it.
#
# Usage: lint-packages.sh [name...]
#
# Runs makepkg as the build user when root (useradd builder first).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"

require_cmd git makepkg namcap

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  mapfile -t names < <(all_packages)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0

# A package filed under the wrong letter (or straight in packages/) is
# invisible to the scripts, so it would silently never build.
for file in "$PACKAGES_DIR"/*/{PKGBUILD,aur.conf} "$PACKAGES_DIR"/*/*/{PKGBUILD,aur.conf}; do
  [[ -f "$file" ]] || continue
  dir="${file%/*}"
  name="${dir##*/}"
  if [[ "$dir" != "$(pkg_dir "$name")" ]]; then
    warn "${dir#"${REPO_ROOT}/"} is misplaced; move it to $(pkg_path "$name")"
    status=1
  fi
done

for name in "${names[@]}"; do
  group_start "$name"
  dir="${work}/${name}"
  # aur_validate dies on bad values; keep going with the other packages.
  if ! (resolve_package "$name" "$dir"; describe_resolution "$name" >"${dir}.desc"); then
    warn "${name}: could not resolve"
    status=1
    group_end
    continue
  fi
  log "${name}: $(cat "${dir}.desc")"
  [[ "$(id -u)" -ne 0 ]] || chown -R "${BUILD_USER:-builder}:" "$work"
  (cd "$dir" && as_builder makepkg --printsrcinfo >/dev/null) || { warn "${name}: PKGBUILD does not parse"; status=1; }
  namcap "${dir}/PKGBUILD" || status=1
  group_end
done

exit "$status"
