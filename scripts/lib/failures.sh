# shellcheck shell=bash
#
# Failure issues: one open issue per failing thing, found by its exact title.
# Source after common.sh; do not execute. Needs gh, jq, GH_TOKEN and
# GITHUB_REPOSITORY.
#
# The body of a build failure issue carries "<!-- tip: <40 hex> -->", the
# upstream commit of a git package when it failed (see check-git.sh).

FAILURE_LABEL="ci-failure"

build_failure_title() { printf 'Build failing: %s' "$1"; }

# Print "<number><TAB><body as one JSON string>" of the open failure issue
# titled <title>, or nothing.
find_failure_issue() {
  gh issue list --repo "$GITHUB_REPOSITORY" --label "$FAILURE_LABEL" --state open --limit 200 \
    --json number,title,body 2>/dev/null \
    | jq -r --arg t "$1" '.[] | select(.title == $t) | "\(.number)\t\(.body | tojson)"' \
    | head -n1 || true
}

# Open (or update) the failure issue <title> with <body>; comment <comment>
# when it already existed so watchers are notified again.
raise_failure() {
  local title="$1" body="$2" comment="$3" found number
  gh label create "$FAILURE_LABEL" --repo "$GITHUB_REPOSITORY" --color d73a4a \
    --description "A build or check failed" >/dev/null 2>&1 || true
  found="$(find_failure_issue "$title")"
  if [[ -n "$found" ]]; then
    number="${found%%$'\t'*}"
    gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body "$body" >/dev/null
    gh issue comment "$number" --repo "$GITHUB_REPOSITORY" --body "$comment" >/dev/null
    ok "updated issue #${number}: ${title}"
  else
    gh issue create --repo "$GITHUB_REPOSITORY" --label "$FAILURE_LABEL" --title "$title" --body "$body"
  fi
}

# Close the failure issue <title> if there is one.
clear_failure() {
  local title="$1" comment="$2" found number
  found="$(find_failure_issue "$title")"
  [[ -n "$found" ]] || return 0
  number="${found%%$'\t'*}"
  gh issue close "$number" --repo "$GITHUB_REPOSITORY" --comment "$comment" >/dev/null
  ok "closed issue #${number}: ${title}"
}
