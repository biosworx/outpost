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

require_cmd git jq bsdtar
export GIT_TERMINAL_PROMPT=0

# Print the source=() entries of a resolved package, one per line. AUR's
# files are never sourced here; our own PKGBUILDs are, as makepkg would.
source_entries() {
  local dir="$1"
  if [[ "$RESOLVED_FROM" == "aur" ]]; then
    awk -F' = ' -v arch="source_${REPO_ARCH}" '
      { k = $1; sub(/^[[:space:]]+/, "", k) }
      k == "source" || k == arch { print substr($0, index($0, " = ") + 3) }
    ' "${dir}/.SRCINFO"
    return 0
  fi
  (
    cd "$dir" || exit 1
    set +eu
    source=()
    # shellcheck disable=SC1091
    source ./PKGBUILD >/dev/null 2>&1
    local arch_var="source_${REPO_ARCH}[@]" s
    for s in "${source[@]}" "${!arch_var}"; do printf '%s\n' "$s"; done
  )
}

# Print "<url><TAB><ref>" for the first git source that follows a branch, or
# "pinned" when it is fixed to a commit or tag, or nothing without one.
first_git_source() {
  local entry url frag key value ref
  while IFS= read -r entry; do
    [[ "$entry" == *git+* ]] || continue
    entry="${entry#*::}"
    entry="${entry#git+}"
    entry="${entry%%\?*}"
    url="${entry%%#*}"
    frag=""
    [[ "$entry" == *#* ]] && frag="${entry#*#}"
    # The URL goes to git ls-remote: plain network URLs only.
    [[ "$url" =~ ^(https?|git)://[A-Za-z0-9][A-Za-z0-9._~:/@%+-]*$ ]] || continue
    ref="HEAD"
    if [[ -n "$frag" ]]; then
      key="${frag%%=*}"
      value="${frag#*=}"
      case "$key" in
        commit|tag) printf 'pinned'; return 0 ;;
        branch)
          [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]] || continue
          ref="refs/heads/${value}"
          ;;
      esac
    fi
    printf '%s\t%s' "$url" "$ref"
    return 0
  done
}

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

check_one() {
  local name="$1" work="$2" source_line url ref tip short
  if [[ -n "${running["$name"]:-}" ]]; then
    log "${name}: a build run is already queued or running"
    return 1
  fi
  if ! resolve_package "$name" "${work}/${name}" >/dev/null 2>&1; then
    warn "${name}: could not resolve; skipping"
    return 1
  fi
  source_line="$(source_entries "${work}/${name}" | first_git_source)"
  if [[ -z "$source_line" ]]; then
    warn "${name}: no git source found; skipping"
    return 1
  fi
  if [[ "$source_line" == pinned ]]; then
    log "${name}: git source is pinned to a commit or tag; nothing to follow"
    return 1
  fi
  IFS=$'\t' read -r url ref <<<"$source_line"

  tip="$(git ls-remote -q "$url" "$ref" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ ! "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    warn "${name}: could not read ${ref} of ${url}; skipping"
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
