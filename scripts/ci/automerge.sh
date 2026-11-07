#!/usr/bin/env bash
#
# Merge a routine update PR and start its build.
#
# Usage: automerge.sh <pr-url-or-number> <package>
#
# Only called for PRs the propose scripts marked routine (a -bin package whose
# change is pkgver, pkgrel and checksums, with a passing test build). Checks
# again that the PR is open, not a draft and for this package, merges it, and
# starts the build workflow for the package: a merge made with GITHUB_TOKEN
# does not trigger the push workflow, but workflow_dispatch is allowed. The
# build reuses the test build the update check uploaded (lib/prebuilt.sh).
#
# If the PR cannot be merged (branch protection, a conflict) it is left open
# for a human and this exits 0 with a warning.
#
# Env: GH_TOKEN (contents, pull-requests and actions: write), GITHUB_REPOSITORY,
#      WORKFLOW_FILE (default build.yml), BRANCH (default main)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <pr-url-or-number> <package>"
pr="$1" name="$2"
require_cmd gh jq
require_env GH_TOKEN GITHUB_REPOSITORY
[[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ && "$name" == *-bin ]] || die "'${name}' is not a -bin package name"

info="$(gh pr view "$pr" --repo "$GITHUB_REPOSITORY" --json number,state,isDraft,headRefName)"
number="$(jq -r '.number' <<<"$info")"
head="$(jq -r '.headRefName' <<<"$info")"
if [[ "$(jq -r '.state' <<<"$info")" != OPEN || "$(jq -r '.isDraft' <<<"$info")" != false ]]; then
  warn "PR #${number} is not open and ready; leaving it alone"
  exit 0
fi
if [[ "$head" != "aur/${name}-"* && "$head" != "update/${name}-"* ]]; then
  warn "PR #${number} (${head}) is not an update PR for ${name}; leaving it alone"
  exit 0
fi

merged=0
for attempt in 1 2 3; do
  if gh pr merge "$number" --repo "$GITHUB_REPOSITORY" --merge --delete-branch >/dev/null 2>"${TMPDIR:-/tmp}/merge.err"; then
    merged=1
    break
  fi
  warn "merge attempt ${attempt} failed: $(tr '\n' ' ' <"${TMPDIR:-/tmp}/merge.err")"
  sleep $((attempt * 10))
done
if [[ "$merged" -ne 1 ]]; then
  warn "could not merge PR #${number}; it stays open for review"
  exit 0
fi
ok "merged PR #${number} (${head})"

gh api -X POST "repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE:-build.yml}/dispatches" \
  -f ref="${BRANCH:-main}" -f "inputs[packages]=${name}" >/dev/null
ok "started a build run for ${name}"
