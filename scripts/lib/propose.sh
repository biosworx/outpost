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

# Test-build a prepared directory as the build user, unsigned, discarding
# the output. Logs to <log>. Returns makepkg's status.
test_build() {
  local dir="$1" log="$2" scratch="$3"
  # The package is thrown away, so skip the (slow, maximum) compression.
  # Sources and build trees go to scratch, never into the checkout.
  (cd "$dir" && PKGDEST="$scratch" SRCDEST="${scratch}/srcdest" BUILDDIR="${scratch}/builddir" PKGEXT=.pkg.tar \
     as_builder makepkg --syncdeps --noconfirm --cleanbuild --clean) >"$log" 2>&1
}
