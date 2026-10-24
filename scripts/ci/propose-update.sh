#!/usr/bin/env bash
#
# Bump one package to a new upstream version, test-build it and open a PR.
#
# Usage: propose-update.sh <name> <version>
#
#   1. branch update/<name>-<version> from the current HEAD
#   2. pick the PKGBUILD to bump:
#        standalone   packages/<name>/PKGBUILD
#        AUR-linked   packages/<name>/override/PKGBUILD; when there is no
#                     override, or only a stale one, it is first copied from
#                     AUR at the pinned commit. The new override is newer than
#                     AUR, so it takes precedence until AUR catches up.
#   3. pkgver=<version>, pkgrel=1, updpkgsums
#   4. test build: makepkg --syncdeps --cleanbuild (unsigned, output discarded)
#   5. commit, push, open a PR: ready if the build passed, draft with the
#      build log tail if it failed
#   6. close older open update/<name>-* PRs this one supersedes
#
# Merging the PR publishes the package via the normal build workflow.
# Exits non-zero when the test build failed (after opening the draft PR),
# so the run shows red.
#
# Must run as root after setup-builder.sh. Env: GH_TOKEN, GITHUB_REPOSITORY,
# DRY_RUN=1 to stop before pushing (prints the diff and build result).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"
# shellcheck source=../lib/propose.sh
source "$(dirname "$0")/../lib/propose.sh"

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <name> <version>"
name="$1" version="$2"
dry_run="${DRY_RUN:-0}"

[[ "$(id -u)" -eq 0 ]] || die "propose-update.sh must run as root (after setup-builder.sh)"
require_cmd git makepkg updpkgsums sudo
[[ "$dry_run" == "1" ]] || { require_cmd gh; require_env GH_TOKEN GITHUB_REPOSITORY; }

pkg_dir="${PACKAGES_DIR}/${name}"
is_package "$name" || die "no PKGBUILD or aur.conf at packages/${name}"
[[ "$version" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || die "invalid pkgver: $version"

branch="update/${name}-${version}"
work="$(mktemp -d)"
chown "${BUILD_USER:-builder}:" "$work"
trap 'rm -rf "$work"' EXIT

cd "$REPO_ROOT"
git checkout -q -B "$branch"

# --- 1. Pick (or create) the PKGBUILD to bump ----------------------------------------
note=""
if is_aur_linked "$name"; then
  dir="${pkg_dir}/override"
  base="$(aur_pkgbase "$name")"
  resolve_package "$name" "${work}/resolved" || die "could not resolve packages/${name}"
  if [[ "$OVERRIDE_STATE" == "none" || "$OVERRIDE_STATE" == "stale" ]]; then
    group_start "Creating override from AUR ${base} ${AUR_VERSION}"
    # resolve_package built from AUR, so its copy is AUR's files at the pin.
    create_override "$name" "${work}/resolved" \
      "bumped to upstream ${version}, which AUR lacks. Retired once AUR catches up."
    note="AUR \`${base}\` is still at \`${AUR_VERSION}\`, so this adds \`packages/${name}/override/\` (AUR's files at the pin, bumped). It takes precedence until AUR catches up, then the daily AUR check proposes deleting it."
    group_end
  else
    note="Bumps the ${OVERRIDE_STATE} override in \`packages/${name}/override/\` (AUR \`${base}\` is at \`${AUR_VERSION}\`)."
  fi
else
  dir="$pkg_dir"
fi
pkgbuild="${dir}/PKGBUILD"
current="$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$pkgbuild" | head -n1 | tr -d "\"'")"

# --- 2. Bump ---------------------------------------------------------------------
group_start "Bumping ${name} ${current} -> ${version}"
sed -i -e "s/^pkgver=.*/pkgver=${version}/" -e 's/^pkgrel=.*/pkgrel=1/' "$pkgbuild"
chown -R "${BUILD_USER:-builder}:" "$dir"

result="passed"
if ! (cd "$dir" && SRCDEST="${work}/srcdest" as_builder updpkgsums) >"${work}/updpkgsums.log" 2>&1; then
  result="failed"
  cp "${work}/updpkgsums.log" "${work}/build.log"
  warn "updpkgsums failed"
fi
git add -A -- "$pkg_dir"
git --no-pager diff --cached -- "$pkg_dir"
group_end

# --- 3. Test build ------------------------------------------------------------------
if [[ "$result" == "passed" ]]; then
  group_start "Test-building ${name} ${version}"
  if import_source_keys "$pkg_dir" && import_source_keys "$dir" \
       && test_build "$dir" "${work}/build.log" "$work"; then
    ok "test build passed"
  else
    result="failed"
    warn "test build failed"
  fi
  tail -n 40 "${work}/build.log"
  group_end
fi

if [[ "$dry_run" == "1" ]]; then
  log "DRY_RUN=1: not committing or pushing (test build ${result})"
  git reset -q -- "$pkg_dir"
  git checkout -q -- "$pkg_dir"
  git clean -fdq -- "$pkg_dir"
  [[ "$result" == "passed" ]]
  exit
fi

# --- 4. Commit, push and open the PR -------------------------------------------------
group_start "Opening pull request"
body="${work}/body.md"
# Backticks below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
{
  printf 'Updates **%s** from `%s` to `%s` (`pkgrel=1`, checksums refreshed).\n\n' "$name" "$current" "$version"
  [[ -z "$note" ]] || printf '%s\n\n' "$note"
  if [[ "$result" == "passed" ]]; then
    printf 'The test build **passed** in a clean `archlinux:base-devel` container.\n'
    printf 'Merging publishes it to `[%s]` through the build workflow.\n' "$REPO_NAME"
  else
    printf 'The test build **failed**, so this PR is a draft. Fix the PKGBUILD on\n'
    printf 'this branch, then mark it ready and merge.\n\n'
    printf '<details><summary>Last 60 lines of the build log</summary>\n\n```\n'
    tail -n 60 "${work}/build.log"
    printf '\n```\n</details>\n'
  fi
} >"$body"

open_update_pr "$branch" "update/${name}-" "$result" \
  "${name}: ${current} → ${version}" "$body" \
  "${name}: update to ${version}" "Automated update from ${current}. Test build ${result}."
group_end

[[ "$result" == "passed" ]] || die "${name} ${version}: test build failed (draft PR opened)"
