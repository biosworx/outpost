#!/usr/bin/env bash
#
# Determine which packages under packages/ need to be (re)built.
#
# Resolution order:
#   1. INPUT_PACKAGES (workflow_dispatch): explicit names, or "all".
#   2. git diff from a base commit to HEAD, where the base is the first valid of:
#        a. head SHA of the last successful run of this workflow (needs gh + GH_TOKEN)
#        b. EVENT_BEFORE (github.event.before)
#        c. HEAD~1
#   3. If no usable base exists (first commit, history rewritten), build everything.
#
# Each run builds one package. Writes the step outputs:
#   packages  every selected name, space-separated (empty: nothing to build)
#   package   the name when exactly one is selected, so this run builds it
#   dispatch  the names when more than one is selected; the workflow starts
#             one run per name (dispatch-builds.sh) and builds nothing itself
#
# Only push runs count as "last successful run": they finish once their one
# build, or their dispatches, succeeded. A package whose own run failed is
# not retried by the next push; re-run that run instead.
#
# Env: INPUT_PACKAGES, EVENT_BEFORE, GH_TOKEN, GITHUB_REPOSITORY,
#      WORKFLOW_FILE (default build.yml), BRANCH (default main)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd git

cd "$REPO_ROOT"

ZERO_SHA="0000000000000000000000000000000000000000"

all_packages() {
  local pkgbuild
  for pkgbuild in "$PACKAGES_DIR"/*/PKGBUILD; do
    [[ -f "$pkgbuild" ]] || continue
    basename "$(dirname "$pkgbuild")"
  done
}

# A base is usable when it exists locally and is an ancestor of HEAD.
usable_base() {
  local sha="$1"
  [[ -n "$sha" && "$sha" != "$ZERO_SHA" ]] || return 1
  git cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
  # A base equal to HEAD means "no changes since last success"; that is usable.
  return 0
}

last_successful_sha() {
  command -v gh >/dev/null 2>&1 || return 0
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 0
  gh api \
    "repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE:-build.yml}/runs?status=success&event=push&branch=${BRANCH:-main}&per_page=1" \
    --jq '.workflow_runs[0].head_sha // empty' 2>/dev/null || true
}

emit() {
  local list="$*" single="" dispatch=""
  case "$#" in
    0) ok "nothing to build" ;;
    1) ok "package to build: $list"; single="$1" ;;
    *) ok "packages to build, one run each: $list"; dispatch="$list" ;;
  esac
  set_output packages "$list"
  set_output package "$single"
  set_output dispatch "$dispatch"
}

# --- 1. Explicit selection ------------------------------------------------------
if [[ -n "${INPUT_PACKAGES:-}" ]]; then
  if [[ "$INPUT_PACKAGES" == "all" ]]; then
    mapfile -t selected < <(all_packages)
  else
    selected=()
    read -r -a requested <<<"$INPUT_PACKAGES"
    for name in "${requested[@]}"; do
      [[ -f "$PACKAGES_DIR/$name/PKGBUILD" ]] || die "no such package: packages/$name"
      selected+=("$name")
    done
  fi
  emit "${selected[@]}"
  exit 0
fi

# --- 2. Diff-based detection -------------------------------------------------------
base=""
for candidate in "$(last_successful_sha)" "${EVENT_BEFORE:-}" "$(git rev-parse -q --verify HEAD~1 2>/dev/null || true)"; do
  if usable_base "$candidate"; then
    base="$candidate"
    break
  elif [[ -n "$candidate" ]]; then
    warn "ignoring unusable base commit: $candidate"
  fi
done

if [[ -z "$base" ]]; then
  warn "no usable base commit found; building all packages"
  mapfile -t selected < <(all_packages)
  emit "${selected[@]}"
  exit 0
fi

log "diffing packages/ against base ${base}"

selected=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ -f "$PACKAGES_DIR/$name/PKGBUILD" ]]; then
    selected+=("$name")
  else
    warn "packages/$name changed but has no PKGBUILD (removed?); skipping"
  fi
done < <(
  git diff --name-only --no-renames "$base" HEAD -- packages/ \
    | awk -F/ 'NF >= 3 && $1 == "packages" { print $2 }' \
    | sort -u
)

emit "${selected[@]}"
