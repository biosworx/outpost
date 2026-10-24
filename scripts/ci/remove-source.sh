#!/usr/bin/env bash
#
# Remove a package's source from the repository after it has been taken out
# of the published database (publish.sh remove).
#
# Usage: remove-source.sh <name>
#
#   1. close open update/<name>-* and aur/<name>-* PRs (and delete their
#      branches)
#   2. git rm -r packages/<l>/<name>, commit and push to the current branch
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_ACTOR (credited in the commit),
#      DRY_RUN=1 to stop before pushing or touching PRs.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 1 ]] || die "usage: $(basename "$0") <name>"
name="$1"
dry_run="${DRY_RUN:-0}"

require_cmd git
[[ "$dry_run" == "1" ]] || { require_cmd gh; require_env GH_TOKEN GITHUB_REPOSITORY; }

cd "$REPO_ROOT"

# --- 1. Close pending update PRs ---------------------------------------------------
if [[ "$dry_run" != "1" ]]; then
  group_start "Closing open update PRs for ${name}"
  while IFS= read -r pr; do
    [[ -n "$pr" ]] || continue
    gh pr close "$pr" --repo "$GITHUB_REPOSITORY" --delete-branch \
      --comment "${name} was removed from [${REPO_NAME}]."
    log "closed PR #${pr}"
  done < <(
    gh pr list --repo "$GITHUB_REPOSITORY" --state open --json number,headRefName \
      --jq ".[] | select(.headRefName | startswith(\"update/${name}-\") or startswith(\"aur/${name}-\")) | .number"
  )
  group_end
fi

# --- 2. Delete the source ------------------------------------------------------------
dir="$(pkg_path "$name")"
if [[ ! -d "$dir" ]] || [[ -z "$(git ls-files -- "$dir")" ]]; then
  log "${dir} is not in the repository; nothing to delete"
  exit 0
fi

group_start "Deleting ${dir}"
git rm -r -q -- "$dir"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -q -m "Remove ${name}" \
  -m "Removed from [${REPO_NAME}] by the remove-package workflow${GITHUB_ACTOR:+, run by @${GITHUB_ACTOR}}."
git --no-pager log --stat -1

if [[ "$dry_run" == "1" ]]; then
  log "DRY_RUN=1: not pushing"
else
  gh auth setup-git
  git push -q origin "HEAD:$(git rev-parse --abbrev-ref HEAD)"
  ok "pushed removal of ${dir}"
fi
group_end
