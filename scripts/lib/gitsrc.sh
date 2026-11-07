# shellcheck shell=bash
#
# Where a git package's sources come from and how far upstream has moved.
# Source after common.sh, vercmp.sh and aur.sh; do not execute.

# Print the source=() entries of a resolved package, one per line. AUR's
# files are never sourced here; our own PKGBUILDs are, as makepkg would.
# Needs RESOLVED_FROM from resolve_package.
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

# Read source entries on stdin. Print "<url><TAB><ref>" for the first git
# source that follows a branch, or "pinned" when it is fixed to a commit or
# tag, or nothing without a git source.
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

# Print the upstream tip (40 hex) a git package follows, or "pinned" when its
# source is fixed to a commit or tag. Resolves the package into <work>/<name>.
# Returns non-zero (after a warning) when there is nothing to report.
upstream_tip() {
  local name="$1" work="$2" source_line url ref tip
  export GIT_TERMINAL_PROMPT=0
  if ! resolve_package "$name" "${work}/${name}" >/dev/null 2>&1; then
    warn "${name}: could not resolve"
    return 1
  fi
  source_line="$(source_entries "${work}/${name}" | first_git_source)"
  if [[ -z "$source_line" ]]; then
    warn "${name}: no git source found"
    return 1
  fi
  if [[ "$source_line" == pinned ]]; then
    printf 'pinned'
    return 0
  fi
  IFS=$'\t' read -r url ref <<<"$source_line"
  tip="$(git ls-remote -q "$url" "$ref" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ ! "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    warn "${name}: could not read ${ref} of ${url}"
    return 1
  fi
  printf '%s' "$tip"
}
