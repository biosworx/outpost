#!/usr/bin/env bash
#
# After a failed build run: if the failure looks like infrastructure (a lost
# runner, a container that would not start, a failed download or publish) and
# not like the package failing to build, start the build once more, so a
# one-off glitch does not raise an alert (report-failure.sh).
#
# Usage: retry-build.sh <package> <run-id>
#
# A failure is the package's own when the build job reached its "Report
# failure" step (build-packages.sh finished and named a failed package), or
# ran into the job timeout. Anything else is infrastructure. The retry is
# the same workflow dispatched with retry=1, which is never retried again.
#
# Writes the step output "retried": true when a retry run was started.
#
# Env: GH_TOKEN (actions: write), GITHUB_REPOSITORY,
#      WORKFLOW_FILE (default build.yml), BRANCH (default main),
#      TIMEOUT_SECONDS (default 6600: a build job that ran this long hit its
#      120 minute limit, which is a build failure)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <package> <run-id>"
name="$1" run_id="$2"
require_cmd gh jq
require_env GH_TOKEN GITHUB_REPOSITORY
[[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || { warn "'${name}' is not a single package name; not retrying"; set_output retried false; exit 0; }
[[ "$run_id" =~ ^[0-9]+$ ]] || die "invalid run id '${run_id}'"

jobs_json="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/jobs?per_page=100" 2>/dev/null)" \
  || { warn "could not read the jobs of run ${run_id}; not retrying"; set_output retried false; exit 0; }

# 1 when a job failed at the package's own build.
own_failure="$(jq -r --argjson limit "${TIMEOUT_SECONDS:-6600}" '
  [ .jobs[]
    | select(.conclusion == "failure")
    | select(
        any(.steps[]?; .name == "Report failure" and .conclusion == "failure")
        or (((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) >= $limit)
      )
  ] | length' <<<"$jobs_json")"

if [[ "$own_failure" != 0 ]]; then
  log "${name}: the package itself failed to build; not retrying"
  set_output retried false
  exit 0
fi

warn "${name}: run ${run_id} failed outside the package build (infrastructure?); starting it once more"
if gh api -X POST "repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE:-build.yml}/dispatches" \
     -f ref="${BRANCH:-main}" -f "inputs[packages]=${name}" -f "inputs[retry]=1" >/dev/null; then
  ok "started a retry build of ${name}"
  set_output retried true
else
  warn "could not start the retry; reporting the failure instead"
  set_output retried false
fi
