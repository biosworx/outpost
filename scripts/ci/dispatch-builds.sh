#!/usr/bin/env bash
#
# Start one build workflow run per package, so each package gets a run of
# its own (its own status, logs and re-run button).
#
# Usage: dispatch-builds.sh <name>...      (or PACKAGES="a b c")
#
# Env: GH_TOKEN (needs actions: write), GITHUB_REPOSITORY,
#      WORKFLOW_FILE (default build.yml), BRANCH (default main)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd gh
require_env GH_TOKEN GITHUB_REPOSITORY

if [[ $# -eq 0 && -n "${PACKAGES:-}" ]]; then
  read -r -a pkgs <<<"$PACKAGES"
else
  pkgs=("$@")
fi

for name in "${pkgs[@]}"; do
  # workflow_dispatch is one of the few events GITHUB_TOKEN may trigger.
  gh workflow run "${WORKFLOW_FILE:-build.yml}" --repo "$GITHUB_REPOSITORY" \
    --ref "${BRANCH:-main}" -f packages="$name"
  ok "started a build run for ${name}"
done
