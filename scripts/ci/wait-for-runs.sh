#!/usr/bin/env bash
#
# Wait for the build runs of a package's dependencies to finish, so it
# builds against their new versions. dispatch-builds.sh passes their ids as
# the workflow input wait_for.
#
# Fails when one did not succeed: building now would use the old version of
# the dependency, or none. Re-run the failed run, then this one; a re-run
# keeps its id, so this waits for the new attempt.
#
# Usage: wait-for-runs.sh <run-id>...      (or RUN_IDS="1 2 3")
# Env:   GH_TOKEN (actions: read), GITHUB_REPOSITORY, POLL_SECONDS (default 30, backs off to 90)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd gh
require_env GH_TOKEN GITHUB_REPOSITORY

if [[ $# -eq 0 && -n "${RUN_IDS:-}" ]]; then
  read -r -a ids <<<"$RUN_IDS"
else
  ids=("$@")
fi
for id in "${ids[@]}"; do
  [[ "$id" =~ ^[0-9]+$ ]] || die "not a run id: ${id}"
done

group_start "Waiting for ${#ids[@]} dependency run(s)"
pending=("${ids[@]}")
poll_delay="${POLL_SECONDS:-30}"
max_poll_delay=90
while [[ "${#pending[@]}" -gt 0 ]]; do
  still=()
  for id in "${pending[@]}"; do
    IFS=$'\t' read -r status conclusion title < <(
      gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}" \
        --jq '[.status, (.conclusion // ""), .display_title] | @tsv'
    ) || { still+=("$id"); continue; }
    if [[ "$status" != completed ]]; then
      still+=("$id")
    elif [[ "$conclusion" == success ]]; then
      ok "${title} (run ${id}) succeeded"
    else
      die "${title} (run ${id}) finished: ${conclusion}. Re-run it, then re-run this run."
    fi
  done
  pending=("${still[@]}")
  if [[ "${#pending[@]}" -gt 0 ]]; then
    sleep "$poll_delay"
    if [[ -z "${POLL_SECONDS:-}" && "$poll_delay" -lt "$max_poll_delay" ]]; then
      poll_delay=$(( poll_delay + 30 ))
      [[ "$poll_delay" -le "$max_poll_delay" ]] || poll_delay="$max_poll_delay"
    fi
  fi
done
group_end
