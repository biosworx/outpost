#!/usr/bin/env bash
#
# Find git packages (names ending in -git) whose upstream has commits that
# are not published yet, so the workflow can start a build run for them.
#
# Usage: check-git.sh [name...]     (default: every *-git package)
#
# A git package's version is computed while it builds (pkgver()), so nothing
# in this repository changes when upstream does, and there is no PR to open.
# The code that runs is the PKGBUILD that is already pinned and reviewed.
#
# For each package this reads the PKGBUILD it builds (lib/aur.sh), takes its
# first git source, asks upstream for the tip with git ls-remote and looks
# for the tip's short hash in the published versions of the package. Absent
# means new commits. Skipped, with a message:
#   - sources pinned with #commit= or #tag=: they do not follow upstream
#   - a build run for the package that is already queued or running
# A package that was never published, or whose published version carries no
# commit hash (so the check cannot tell), is selected every time.
#
# Also skipped: a package whose open failure issue (report-failure.sh) says it
# failed at the commit upstream is still at; new commits try it again.
#
# Env: OUT_DIR (with the pulled database, see fetch-db.sh), GH_TOKEN and
#      GITHUB_REPOSITORY (to see running builds; optional)
# Writes the step output "packages", space-separated (empty: nothing to do).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"
# shellcheck source=../lib/gitsrc.sh
source "$(dirname "$0")/../lib/gitsrc.sh"

require_cmd git jq bsdtar

# Published "name<TAB>version" lines from the pulled database.
declare -A published=()
db="${OUT_DIR}/${DB_ARCHIVE}"
if [[ -s "$db" ]]; then
  while IFS=$'\t' read -r pkg version; do
    published["$pkg"]+=" ${version}"
  done < <(
    bsdtar -xOf "$db" '*/desc' 2>/dev/null \
      | awk '/^%NAME%$/ { getline n } /^%VERSION%$/ { getline v; print n "\t" v }'
  )
else
  warn "no published database; every git package counts as unpublished"
fi

# Packages with a build run queued or running, so they are not started twice.
declare -A running=()
if [[ -n "${GITHUB_REPOSITORY:-}" ]] && command -v gh >/dev/null 2>&1; then
  for status in queued in_progress; do
    while IFS= read -r title; do
      [[ "$title" == "Build "* ]] && running["${title#Build }"]=1
    done < <(gh run list --repo "$GITHUB_REPOSITORY" --workflow build.yml --status "$status" \
               --limit 100 --json displayTitle --jq '.[].displayTitle' 2>/dev/null || true)
  done
fi

# Upstream tips that open failure issues recorded (report-failure.sh), by
# package: a build that failed at the tip upstream is still at is not started
# again until upstream moves.
tip_marker="<!-- tip: ([0-9a-f]{40}) -->"
declare -A failed_tip=() failed_issue=()
if [[ -n "${GITHUB_REPOSITORY:-}" ]] && command -v gh >/dev/null 2>&1; then
  while IFS=$'\t' read -r number title body; do
    [[ "$title" == "Build failing: "* ]] || continue
    pkg="${title#Build failing: }"
    failed_issue["$pkg"]="$number"
    if [[ "$body" =~ $tip_marker ]]; then
      failed_tip["$pkg"]="${BASH_REMATCH[1]}"
    fi
  done < <(gh issue list --repo "$GITHUB_REPOSITORY" --label ci-failure --state open --limit 200 \
             --json number,title,body 2>/dev/null \
             | jq -r '.[] | [.number, .title, .body] | @tsv' || true)
fi

check_one() {
  local name="$1" work="$2" tip short
  if [[ -n "${running["$name"]:-}" ]]; then
    log "${name}: a build run is already queued or running"
    return 1
  fi
  if ! tip="$(upstream_tip "$name" "$work")"; then
    warn "${name}: skipping"
    return 1
  fi
  if [[ "$tip" == pinned ]]; then
    log "${name}: git source is pinned to a commit or tag; nothing to follow"
    return 1
  fi
  if [[ -n "${failed_issue["$name"]:-}" && "${failed_tip["$name"]:-}" == "$tip" ]]; then
    warn "${name}: failed at this upstream commit (${tip:0:7}); see issue #${failed_issue["$name"]}"
    return 1
  fi
  short="${tip:0:7}"

  if [[ -z "${published["$name"]:-}" ]]; then
    ok "${name}: not published yet (upstream ${short})"
    return 0
  fi
  if [[ "${published["$name"]}" == *"$short"* ]]; then
    log "${name}: up to date (upstream ${short})"
    return 1
  fi
  ok "${name}: upstream is at ${short}, published:${published["$name"]}"
  return 0
}

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  mapfile -t names < <(all_packages | grep -- '-git$' || true)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

selected=()
for name in "${names[@]}"; do
  is_package "$name" || { warn "${name}: not a package; skipping"; continue; }
  if check_one "$name" "$work"; then
    selected+=("$name")
  fi
done

set_output packages "${selected[*]:-}"
