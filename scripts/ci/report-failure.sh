#!/usr/bin/env bash
#
# Open, update or close the failure issue for a build or a workflow.
#
# Usage:
#   report-failure.sh build-fail <package> <run-url>   a build failed
#   report-failure.sh build-ok   <package> <run-url>   a build succeeded
#   report-failure.sh job-fail   <workflow> <run-url>  a workflow failed
#   report-failure.sh job-ok     <workflow> <run-url>  a workflow succeeded
#
# One open issue per package or workflow (label ci-failure), titled
# "Build failing: <package>" or "Workflow failing: <workflow>". A repeated
# failure edits it and adds a comment, so watchers are notified again; the
# next success closes it. For a *-git package the issue records the upstream
# commit it failed at, so the 6-hourly check does not start the same failing
# build again until upstream moves (check-git.sh); closing the issue by hand
# makes it try again.
#
# Env: GH_TOKEN (issues: write), GITHUB_REPOSITORY

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"
# shellcheck source=../lib/gitsrc.sh
source "$(dirname "$0")/../lib/gitsrc.sh"
# shellcheck source=../lib/failures.sh
source "$(dirname "$0")/../lib/failures.sh"

[[ $# -eq 3 ]] || die "usage: $(basename "$0") build-fail|build-ok|job-fail|job-ok <name> <run-url>"
action="$1" name="$2" run_url="$3"
require_cmd gh jq
require_env GH_TOKEN GITHUB_REPOSITORY

# A manual run may name several packages; those have no single issue.
case "$action" in
  build-*)
    if [[ ! "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; then
      warn "'${name}' is not a single package name; nothing to report"
      exit 0
    fi
    ;;
esac

case "$action" in
  build-fail)
    title="$(build_failure_title "$name")"
    tip="" tip_line=""
    if [[ "$name" == *-git ]] && is_package "$name"; then
      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT
      tip="$(upstream_tip "$name" "$work" 2>/dev/null || true)"
      [[ "$tip" =~ ^[0-9a-f]{40}$ ]] || tip=""
    fi
    if [[ -n "$tip" ]]; then
      tip_line="Upstream was at \`${tip:0:12}\` when it failed. The 6-hourly check will not try this package again until upstream has new commits; close this issue to make it try again.

<!-- tip: ${tip} -->"
    fi
    body="The build of **${name}** failed: ${run_url}

${tip_line}

This issue closes itself when a later build of ${name} succeeds."
    raise_failure "$title" "$body" "Failed again: ${run_url}${tip:+ (upstream ${tip:0:12})}"
    ;;
  build-ok)
    clear_failure "$(build_failure_title "$name")" "Built successfully: ${run_url}"
    ;;
  job-fail)
    raise_failure "Workflow failing: ${name}" \
      "The **${name}** workflow failed: ${run_url}

This issue closes itself when the workflow next succeeds." \
      "Failed again: ${run_url}"
    ;;
  job-ok)
    clear_failure "Workflow failing: ${name}" "Succeeded: ${run_url}"
    ;;
  *) die "unknown action '${action}'" ;;
esac
