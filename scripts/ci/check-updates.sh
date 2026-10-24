#!/usr/bin/env bash
#
# Find packages with something to propose. Two kinds:
#
#   aur       AUR-linked packages (aur.conf) whose AUR repository moved past
#             the pin, or whose override went stale at the current pin.
#             Handled by propose-aur.sh.
#   upstream  packages with an update.conf whose upstream has a newer
#             release than both the PKGBUILD that would be built and AUR's
#             latest (when AUR has it, the aur update covers it). Handled by
#             propose-update.sh.
#
# update.conf (key=value, not sourced):
#
#   source=github-release   latest non-prerelease GitHub release
#   source=github-tag       highest tag (by pacman vercmp) among recent tags
#   repo=OWNER/NAME         GitHub repository
#   tag_prefix=v            optional; stripped from the tag to get pkgver
#
# Writes a JSON array to the step output "updates", e.g.
#   [{"package":"legcord","kind":"upstream","current":"1.3.1","version":"1.3.2","commit":""},
#    {"package":"xeve","kind":"aur","current":"0.7.1-1","version":"0.7.2-1","commit":"<sha>"}]
# Updates whose branch already has a PR (open, merged or closed) are left
# out, so a rejected update is not proposed again.
#
# Usage: check-updates.sh [name...]     (default: every package)
# Env:   GH_TOKEN, GITHUB_REPOSITORY (for the existing-PR check; skipped if unset)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"

require_cmd gh jq git

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

# pkgver part of [epoch:]pkgver-pkgrel.
pkgver_of() {
  local v="${1#*:}"
  printf '%s' "${v%-*}"
}

pr_exists() {
  local branch="$1"
  [[ -n "${GITHUB_REPOSITORY:-}" ]] || return 1
  [[ -n "$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state all --json number --jq '.[].number')" ]]
}

updates="[]"
add_update() {
  updates="$(jq -c --arg p "$1" --arg k "$2" --arg c "$3" --arg v "$4" --arg s "${5:-}" \
    '. + [{package: $p, kind: $k, current: $c, version: $v, commit: $s}]' <<<"$updates")"
}

# Highest plain version among upstream's tags, or nothing.
upstream_latest() {
  local conf="$1" name="$2" source repo prefix tags tag candidate latest=""
  source="$(conf_get "$conf" source)"
  repo="$(conf_get "$conf" repo)"
  prefix="$(conf_get "$conf" tag_prefix)"
  if [[ -z "$source" || -z "$repo" ]]; then
    warn "${name}: update.conf needs source= and repo=; skipping upstream check"
    return 0
  fi
  if ! tags="$(latest_tag "$source" "$repo")" || [[ -z "$tags" ]]; then
    warn "${name}: could not query ${source} for ${repo}; skipping upstream check"
    return 0
  fi
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    [[ -z "$prefix" || "$tag" == "$prefix"* ]] || continue
    candidate="$(to_pkgver "$tag" "$prefix")"
    # Upstream tags are untrusted input that ends up in a shell; accept only
    # plain version strings.
    [[ "$candidate" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || continue
    if [[ -z "$latest" || "$(pkg_vercmp "$candidate" "$latest")" -gt 0 ]]; then
      latest="$candidate"
    fi
  done <<<"$tags"
  printf '%s' "$latest"
}

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  mapfile -t names < <(all_packages)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for name in "${names[@]}"; do
  if ! is_package "$name"; then
    warn "${name}: not a package; skipping"
    continue
  fi
  conf="$(pkg_dir "$name")/update.conf"
  # Newest pkgver already covered: by what is built now, and by AUR's tip.
  covered=""

  # --- AUR ---------------------------------------------------------------------
  if is_aur_linked "$name"; then
    if ! (aur_validate "$name"); then
      continue
    fi
    base="$(aur_pkgbase "$name")" pin="$(aur_commit "$name")"
    tip_dir="${work}/${name}-tip" pin_dir="${work}/${name}-pin"
    if ! aur_clone "$base" "" "$tip_dir"; then
      warn "${name}: could not fetch AUR ${base}; skipping"
      continue
    fi
    tip="$(git -C "$tip_dir" rev-parse HEAD)"
    tip_version="$(srcinfo_version "$tip_dir")"
    git clone -q "$tip_dir" "$pin_dir"
    if ! git -C "$pin_dir" -c advice.detachedHead=false checkout -q "$pin" 2>/dev/null; then
      warn "${name}: pinned commit ${pin} is gone from AUR (history rewritten?); proposing the tip"
      add_update "$name" aur "?" "$tip_version" "$tip"
      continue
    fi
    resolve_package "$name" "${work}/${name}-resolved" "$pin_dir" >/dev/null 2>&1 \
      || { warn "${name}: could not resolve; skipping"; continue; }
    covered="$(pkgver_of "$RESOLVED_VERSION")"
    if [[ "$(pkg_vercmp "$(pkgver_of "$tip_version")" "$covered")" -gt 0 ]]; then
      covered="$(pkgver_of "$tip_version")"
    fi

    if [[ "$tip" != "$pin" ]]; then
      if pr_exists "aur/${name}-${tip:0:12}"; then
        log "${name}: AUR ${tip_version} (${tip:0:12}) available, PR already exists"
      else
        ok "${name}: AUR ${AUR_VERSION} -> ${tip_version} (${tip:0:12})"
        add_update "$name" aur "$AUR_VERSION" "$tip_version" "$tip"
      fi
    elif [[ "$OVERRIDE_STATE" == "stale" ]]; then
      if pr_exists "aur/${name}-${pin:0:12}"; then
        log "${name}: stale override, PR already exists"
      else
        ok "${name}: override ${OVERRIDE_VERSION} is stale (AUR has ${AUR_VERSION})"
        add_update "$name" aur "$OVERRIDE_VERSION" "$AUR_VERSION" "$pin"
      fi
    else
      log "${name}: AUR pin up to date ($(describe_resolution "$name"))"
    fi
  fi

  # --- Upstream ----------------------------------------------------------------
  [[ -f "$conf" ]] || continue
  if [[ -z "$covered" ]]; then
    covered="$(pkgver_of "$(pkgbuild_version "$(pkg_dir "$name")")")"
  fi
  if [[ -z "$covered" ]]; then
    warn "${name}: could not read the current pkgver; skipping upstream check"
    continue
  fi
  latest="$(upstream_latest "$conf" "$name")"
  if [[ -z "$latest" ]]; then
    warn "${name}: no usable version among upstream tags; skipping"
  elif [[ "$(pkg_vercmp "$latest" "$covered")" -le 0 ]]; then
    log "${name}: upstream up to date (${covered})"
  elif pr_exists "update/${name}-${latest}"; then
    log "${name}: upstream ${latest} available, PR already exists"
  else
    ok "${name}: upstream ${covered} -> ${latest}"
    add_update "$name" upstream "$covered" "$latest"
  fi
done

set_output updates "$updates"
