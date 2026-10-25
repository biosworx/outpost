#!/usr/bin/env bash
#
# Start one build workflow run per package, so each package gets a run of
# its own (its own status, logs and re-run button), in dependency order.
#
# Usage: dispatch-builds.sh <name>...      (or PACKAGES="a b c")
#
# A package that needs another one in the list (depends, makedepends or
# checkdepends naming one of its pkgnames or provides) is started with
# wait_for=<that package's run id>: its run first waits for those runs to
# finish (wait-for-runs.sh), so it builds against the new version. The
# rest start at once and build in parallel.
#
# Env: GH_TOKEN (needs actions: write), GITHUB_REPOSITORY,
#      WORKFLOW_FILE (default build.yml), BRANCH (default main),
#      DRY_RUN=1 to print the order without starting anything

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"

require_cmd git
[[ "${DRY_RUN:-0}" == "1" ]] || { require_cmd gh; require_env GH_TOKEN GITHUB_REPOSITORY; }

if [[ $# -eq 0 && -n "${PACKAGES:-}" ]]; then
  read -r -a pkgs <<<"$PACKAGES"
else
  pkgs=("$@")
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- Who needs whom --------------------------------------------------------------
declare -A provider=() needs=() deps=() run_id=()
group_start "Reading dependencies of ${#pkgs[@]} packages"
for name in "${pkgs[@]}"; do
  if ! resolve_package "$name" "${work}/${name}" >/dev/null 2>&1; then
    warn "${name}: could not resolve; starting it without waiting for anything"
    continue
  fi
  while IFS=$'\t' read -r kind value; do
    [[ -n "$value" ]] || continue
    if [[ "$kind" == provides ]]; then
      provider["$value"]="$name"
    else
      needs["$name"]+=" ${value}"
    fi
  done < <(pkg_relations "${work}/${name}")
done
for name in "${pkgs[@]}"; do
  for dep in ${needs["$name"]:-}; do
    dep_pkg="${provider["$dep"]:-}"
    if [[ -n "$dep_pkg" && "$dep_pkg" != "$name" && " ${deps["$name"]:-} " != *" ${dep_pkg} "* ]]; then
      deps["$name"]+=" ${dep_pkg}"
    fi
  done
  [[ -z "${deps["$name"]:-}" ]] || log "${name} waits for:${deps["$name"]}"
done
group_end

# --- Start them, dependencies first --------------------------------------------------
dispatch() {
  local name="$1" wait_for="$2" args id
  args=(-X POST "repos/${GITHUB_REPOSITORY:-}/actions/workflows/${WORKFLOW_FILE:-build.yml}/dispatches"
    -f ref="${BRANCH:-main}" -f "inputs[packages]=${name}" -F return_run_details=true)
  [[ -z "$wait_for" ]] || args+=(-f "inputs[wait_for]=${wait_for}")
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    id="$(( ${#run_id[@]} + 1 ))"
  else
    # workflow_dispatch is one of the few events GITHUB_TOKEN may trigger.
    id="$(gh api "${args[@]}" --jq '.workflow_run_id')"
  fi
  [[ "$id" =~ ^[0-9]+$ ]] || die "${name}: no run id returned for the dispatched run"
  run_id["$name"]="$id"
  ok "started a build run for ${name} (run ${id})${wait_for:+, after runs ${wait_for}}"
}

remaining=("${pkgs[@]}")
while [[ "${#remaining[@]}" -gt 0 ]]; do
  next=() progressed=0
  for name in "${remaining[@]}"; do
    wait_for="" ready=1
    for dep in ${deps["$name"]:-}; do
      if [[ -n "${run_id["$dep"]:-}" ]]; then
        wait_for+="${wait_for:+ }${run_id["$dep"]}"
      else
        ready=0
      fi
    done
    if [[ "$ready" -eq 1 ]]; then
      dispatch "$name" "$wait_for"
      progressed=1
    else
      next+=("$name")
    fi
  done
  if [[ "$progressed" -eq 0 ]]; then
    # A cycle: start the rest, each waiting only for what has been started.
    warn "dependency cycle among: ${next[*]}; starting them without full ordering"
    for name in "${next[@]}"; do
      wait_for=""
      for dep in ${deps["$name"]:-}; do
        [[ -z "${run_id["$dep"]:-}" ]] || wait_for+="${wait_for:+ }${run_id["$dep"]}"
      done
      dispatch "$name" "$wait_for"
    done
    next=()
  fi
  remaining=("${next[@]}")
done
