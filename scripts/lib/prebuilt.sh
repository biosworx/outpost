# shellcheck shell=bash
#
# Reuse an update PR's test build once the PR is merged. Source after
# common.sh; do not execute.
#
# The update check (propose-update.sh, propose-aur.sh) test-builds the
# resolved package with the build workflow's makepkg settings, unsigned, and
# uploads the packages as an artifact named prebuilt_key: a hash of the
# resolved build directory and those settings. When the merge resolves to
# the same hash, build-packages.sh signs that artifact's packages instead of
# building them again. They were built from exactly the files that were
# reviewed, and the signing key never meets unreviewed code.
#
# Artifacts are kept for 7 days (check-updates.yml). A PR merged later, or
# changed before merging, is built as usual.

PREBUILT_WORKFLOW=".github/workflows/check-updates.yml"

# Artifact name for what <dir> (a resolve_package result) builds.
prebuilt_key() {
  local name="$1" dir="$2" digest
  digest="$(
    {
      (cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
      cat /etc/makepkg.conf.d/outpost.conf 2>/dev/null || true
    } | sha256sum
  )"
  printf 'prebuilt-%s-%s' "$name" "${digest:0:32}"
}

# Print the id of the newest run that holds an unexpired artifact <key> and
# may supply one: the update check, scheduled or started by hand, on this
# repository's main. Any pull request run (a fork's too) can upload an
# artifact of any name, so those never count.
prebuilt_run() {
  local key="$1" runs id info path event branch repo
  runs="$(gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts?name=$(jq -rn --arg k "$key" '$k | @uri')&per_page=20" \
    --jq '.artifacts[] | select(.expired | not) | .workflow_run.id')" || return 1
  for id in $runs; do
    info="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}" \
      --jq '[.path, .event, .head_branch, .head_repository.full_name] | @tsv')" || continue
    IFS=$'\t' read -r path event branch repo <<<"$info"
    [[ "$path" == "$PREBUILT_WORKFLOW" || "$path" == "${PREBUILT_WORKFLOW}@"* ]] || continue
    [[ "$event" == schedule || "$event" == workflow_dispatch ]] || continue
    [[ "$branch" == main && "$repo" == "$GITHUB_REPOSITORY" ]] || continue
    printf '%s' "$id"
    return 0
  done
  return 1
}

# Sign the packages of artifact <key> and move them into <pkgdest>, when a
# trusted run has it and it holds exactly <expected>... (makepkg --packagelist
# paths; none for VCS packages, whose version only their build knows).
# Returns non-zero, leaving <pkgdest> untouched, when there is nothing to use.
prebuilt_use() {
  local key="$1" pkgdest="$2"
  shift 2
  local expected=("$@") run tmp files=() f
  command -v gh >/dev/null 2>&1 || return 1
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GPGKEY:-}" ]] || return 1
  run="$(prebuilt_run "$key")" || return 1

  tmp="$(mktemp -d)"
  if ! gh run download "$run" --repo "$GITHUB_REPOSITORY" --name "$key" --dir "$tmp" >/dev/null \
       || ! tar -xf "${tmp}/prebuilt.tar" -C "$tmp"; then
    warn "could not download ${key} from run ${run}; building instead"
    rm -rf "$tmp"
    return 1
  fi
  shopt -s nullglob
  files=("$tmp"/*.pkg.tar.zst)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]] || { [[ "${#expected[@]}" -gt 0 ]] \
       && ! cmp -s <(printf '%s\n' "${files[@]##*/}" | sort) <(printf '%s\n' "${expected[@]##*/}" | sort); }; then
    warn "${key} does not hold the expected packages; building instead"
    rm -rf "$tmp"
    return 1
  fi

  chown -R "${BUILD_USER:-builder}:" "$tmp" 2>/dev/null || true
  for f in "${files[@]}"; do
    # What makepkg --sign runs.
    if ! as_builder gpg --batch --detach-sign --use-agent --no-armor --local-user "$GPGKEY" \
         --output "${f}.sig" "$f"; then
      warn "could not sign $(basename "$f"); building instead"
      rm -rf "$tmp"
      return 1
    fi
  done
  for f in "${files[@]}"; do
    mv -f "$f" "${f}.sig" "$pkgdest/"
  done
  rm -rf "$tmp"
  log "using the update check's test build (run ${run})"
}
