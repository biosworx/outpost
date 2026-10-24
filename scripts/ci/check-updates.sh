#!/usr/bin/env bash
#
# Find packages whose upstream has a newer release than their PKGBUILD.
#
# A package opts in with packages/<name>/update.conf (key=value, not sourced):
#
#   source=github-release   latest non-prerelease GitHub release
#   source=github-tag       highest tag (by vercmp) among recent tags
#   repo=OWNER/NAME         GitHub repository
#   tag_prefix=v            optional; stripped from the tag to get pkgver
#
# Writes a JSON array to the step output "updates", e.g.
#   [{"package":"legcord","current":"1.3.1","version":"1.3.2"}]
# Versions whose update branch already has a PR (open, merged or closed)
# are left out, so a rejected update is not proposed again.
#
# Usage: check-updates.sh [name...]     (default: every package with update.conf)
# Env:   GH_TOKEN, GITHUB_REPOSITORY (for the existing-PR check; skipped if unset)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd gh jq vercmp

# Read one key from an update.conf without executing it.
conf_get() {
  awk -F= -v key="$2" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == key { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

# Current pkgver straight from the PKGBUILD assignment (no sourcing).
current_pkgver() {
  sed -n 's/^pkgver=\(.*\)$/\1/p' "$1" | head -n1 | tr -d "\"'"
}

latest_tag() {
  local source="$1" repo="$2"
  case "$source" in
    github-release)
      gh api "repos/${repo}/releases/latest" --jq '.tag_name'
      ;;
    github-tag)
      gh api "repos/${repo}/tags?per_page=50" --jq '.[].name'
      ;;
    *)
      return 1
      ;;
  esac
}

# Turn a tag into a valid pkgver: strip the prefix, '-' is not allowed.
to_pkgver() {
  local tag="$1" prefix="$2"
  tag="${tag#"$prefix"}"
  printf '%s' "${tag//-/_}"
}

pr_exists() {
  local branch="$1"
  [[ -n "${GITHUB_REPOSITORY:-}" ]] || return 1
  [[ -n "$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state all --json number --jq '.[].number')" ]]
}

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  names=()
  for conf in "$PACKAGES_DIR"/*/update.conf; do
    [[ -f "$conf" ]] && names+=("$(basename "$(dirname "$conf")")")
  done
fi

updates="[]"
for name in "${names[@]}"; do
  conf="${PACKAGES_DIR}/${name}/update.conf"
  pkgbuild="${PACKAGES_DIR}/${name}/PKGBUILD"
  if [[ ! -f "$conf" || ! -f "$pkgbuild" ]]; then
    warn "${name}: missing update.conf or PKGBUILD; skipping"
    continue
  fi

  source="$(conf_get "$conf" source)"
  repo="$(conf_get "$conf" repo)"
  prefix="$(conf_get "$conf" tag_prefix)"
  current="$(current_pkgver "$pkgbuild")"
  if [[ -z "$source" || -z "$repo" || -z "$current" ]]; then
    warn "${name}: update.conf needs source= and repo=, PKGBUILD needs pkgver=; skipping"
    continue
  fi

  if ! tags="$(latest_tag "$source" "$repo")" || [[ -z "$tags" ]]; then
    warn "${name}: could not query ${source} for ${repo}; skipping"
    continue
  fi

  # Pick the highest version among the candidates (one for releases).
  latest=""
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    [[ -z "$prefix" || "$tag" == "$prefix"* ]] || continue
    candidate="$(to_pkgver "$tag" "$prefix")"
    # Upstream tags are untrusted input that ends up in a shell; accept only
    # plain version strings.
    [[ "$candidate" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || continue
    if [[ -z "$latest" || "$(vercmp "$candidate" "$latest")" -gt 0 ]]; then
      latest="$candidate"
    fi
  done <<<"$tags"

  if [[ -z "$latest" ]]; then
    warn "${name}: no usable version among upstream tags; skipping"
  elif [[ "$(vercmp "$latest" "$current")" -le 0 ]]; then
    log "${name}: up to date (${current})"
  elif pr_exists "update/${name}-${latest}"; then
    log "${name}: ${latest} available, PR already exists"
  else
    ok "${name}: ${current} -> ${latest}"
    updates="$(jq -c --arg p "$name" --arg c "$current" --arg v "$latest" \
      '. + [{package: $p, current: $c, version: $v}]' <<<"$updates")"
  fi
done

set_output updates "$updates"
