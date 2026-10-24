#!/usr/bin/env bash
#
# Bump one package to a new upstream version, test-build it and open a PR.
#
# Usage: propose-update.sh <name> <version>
#
#   1. branch update/<name>-<version> from the current HEAD
#   2. pkgver=<version>, pkgrel=1, updpkgsums
#   3. test build: makepkg --syncdeps --cleanbuild (unsigned, output discarded)
#   4. commit, push, open a PR: ready if the build passed, draft with the
#      build log tail if it failed
#   5. close older open update/<name>-* PRs this one supersedes
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

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <name> <version>"
name="$1" version="$2"
dry_run="${DRY_RUN:-0}"

[[ "$(id -u)" -eq 0 ]] || die "propose-update.sh must run as root (after setup-builder.sh)"
require_cmd git makepkg updpkgsums sudo
[[ "$dry_run" == "1" ]] || { require_cmd gh; require_env GH_TOKEN GITHUB_REPOSITORY; }

dir="${PACKAGES_DIR}/${name}"
pkgbuild="${dir}/PKGBUILD"
[[ -f "$pkgbuild" ]] || die "no PKGBUILD at packages/${name}"
[[ "$version" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || die "invalid pkgver: $version"

branch="update/${name}-${version}"
current="$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$pkgbuild" | head -n1 | tr -d "\"'")"
work="$(mktemp -d)"
chown "${BUILD_USER:-builder}:" "$work"
trap 'rm -rf "$work"' EXIT

cd "$REPO_ROOT"
git checkout -q -B "$branch"

# --- 1. Bump ---------------------------------------------------------------------
group_start "Bumping ${name} ${current} -> ${version}"
sed -i -e "s/^pkgver=.*/pkgver=${version}/" -e 's/^pkgrel=.*/pkgrel=1/' "$pkgbuild"
chown -R "${BUILD_USER:-builder}:" "$dir"

result="passed"
if ! (cd "$dir" && as_builder updpkgsums) >"${work}/updpkgsums.log" 2>&1; then
  result="failed"
  cp "${work}/updpkgsums.log" "${work}/build.log"
  warn "updpkgsums failed"
fi
git --no-pager diff -- "$pkgbuild"
group_end

# --- 2. Test build ------------------------------------------------------------------
if [[ "$result" == "passed" ]]; then
  group_start "Test-building ${name} ${version}"
  if (cd "$dir" && PKGDEST="$work" as_builder makepkg --syncdeps --noconfirm --cleanbuild --clean) \
       >"${work}/build.log" 2>&1; then
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
  git checkout -q -- "$pkgbuild"
  [[ "$result" == "passed" ]]
  exit
fi

# --- 3. Commit and push ---------------------------------------------------------------
group_start "Opening pull request"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -- "$pkgbuild"
git commit -q -m "${name}: update to ${version}" \
  -m "Automated update from ${current}. Test build ${result}."
gh auth setup-git
git push -q --force origin "$branch"

body="${work}/body.md"
# Backticks below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
{
  printf 'Updates **%s** from `%s` to `%s` (`pkgrel=1`, checksums refreshed).\n\n' "$name" "$current" "$version"
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

pr_args=(--repo "$GITHUB_REPOSITORY" --base main --head "$branch"
  --title "${name}: ${current} → ${version}" --body-file "$body")
[[ "$result" == "passed" ]] || pr_args+=(--draft)
pr_url="$(gh pr create "${pr_args[@]}")"
ok "opened ${pr_url}"

# Close older update PRs for this package; this one replaces them.
while IFS= read -r old; do
  [[ -n "$old" ]] || continue
  gh pr close "$old" --repo "$GITHUB_REPOSITORY" --delete-branch \
    --comment "Superseded by ${pr_url}."
  log "closed superseded PR #${old}"
done < <(
  gh pr list --repo "$GITHUB_REPOSITORY" --state open --json number,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"update/${name}-\")) | select(.headRefName != \"${branch}\") | .number"
)
group_end

[[ "$result" == "passed" ]] || die "${name} ${version}: test build failed (draft PR opened)"
