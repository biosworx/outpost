# shellcheck shell=bash
#
# Shared tail of propose-update.sh and propose-aur.sh: commit the staged
# change, push its branch and open a PR, then close the older PRs it
# supersedes. Source after common.sh; do not execute.

# Usage: open_update_pr <branch> <supersede-prefix> <result> <title> <body-file> <commit-subject> <commit-body>
#   <result>            passed | failed (failed opens a draft)
#   <supersede-prefix>  open PRs whose head starts with it are closed, e.g.
#                       "update/legcord-"
# Expects the change to be staged already.
open_update_pr() {
  local branch="$1" prefix="$2" result="$3" title="$4" body="$5" subject="$6" message="$7"
  local pr_url old pr_args

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git commit -q -m "$subject" -m "$message"
  gh auth setup-git
  git push -q --force origin "$branch"

  pr_args=(--repo "$GITHUB_REPOSITORY" --base main --head "$branch" --title "$title" --body-file "$body")
  [[ "$result" == "passed" ]] || pr_args+=(--draft)
  pr_url="$(gh pr create "${pr_args[@]}")"
  ok "opened ${pr_url}"

  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    gh pr close "$old" --repo "$GITHUB_REPOSITORY" --delete-branch \
      --comment "Superseded by ${pr_url}."
    log "closed superseded PR #${old}"
  done < <(
    gh pr list --repo "$GITHUB_REPOSITORY" --state open --json number,headRefName \
      --jq ".[] | select(.headRefName | startswith(\"${prefix}\")) | select(.headRefName != \"${branch}\") | .number"
  )
}

# Test-build a resolved directory as the build user, unsigned, with the
# build workflow's makepkg settings, so the merge can publish the result
# (lib/prebuilt.sh). Packages land in <scratch>/pkgdest; sources and build
# trees in <scratch> too. Logs to <log>. Returns makepkg's status.
test_build() {
  local dir="$1" log="$2" scratch="$3"
  as_builder mkdir -p "${scratch}/pkgdest"
  (cd "$dir" && PKGDEST="${scratch}/pkgdest" SRCDEST="${scratch}/srcdest" BUILDDIR="${scratch}/builddir" \
     as_builder makepkg --syncdeps --noconfirm --cleanbuild --clean) >"$log" 2>&1
}

# Bundle the packages of a passing test_build (<scratch>/pkgdest) as
# $OUT_DIR/prebuilt.tar and set the step output "prebuilt" to <key>, the
# artifact name check-updates.yml uploads it under. One tar, because
# artifact file names reject the ':' of an epoch.
offer_prebuilt() {
  local key="$1" pkgdest="$2/pkgdest" files=()
  shopt -s nullglob
  files=("$pkgdest"/*.pkg.tar.zst)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    warn "the test build left no packages to reuse"
    return 0
  fi
  mkdir -p "$OUT_DIR"
  (cd "$pkgdest" && tar -cf "${OUT_DIR}/prebuilt.tar" -- "${files[@]##*/}")
  set_output prebuilt "$key"
  ok "offering the test build for reuse as ${key}"
}
