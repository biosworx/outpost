#!/usr/bin/env bash
#
# Move an AUR-linked package's pin to a new AUR commit and open a PR whose
# body shows AUR's diff for review: merging is what lets CI build and sign
# the new AUR code.
#
# Usage: propose-aur.sh <name> <commit>
#
#   1. branch aur/<name>-<commit:0:12> from the current HEAD
#   2. commit=<commit> in packages/<l>/<name>/aur.conf (when it changes)
#   3. the override, if any:
#        stale (not newer than AUR at <commit>)  deleted
#        active (still newer)                    kept, noted
#        permanent                               kept; the PR asks you to
#                                                carry AUR's changes over
#   4. test build of what would now be built, unless it is still an override
#      (AUR's change does not touch it then); a passing one is offered for
#      the merge to publish (lib/prebuilt.sh)
#   5. commit, push, open a PR (draft if the test build failed) and close
#      older open aur/<name>-* PRs
#
# <commit> may equal the current pin: that only deletes a stale override.
#
# Must run as root after setup-builder.sh. Env: GH_TOKEN, GITHUB_REPOSITORY,
# DRY_RUN=1 to stop before pushing.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"
# shellcheck source=../lib/propose.sh
source "$(dirname "$0")/../lib/propose.sh"
# shellcheck source=../lib/prebuilt.sh
source "$(dirname "$0")/../lib/prebuilt.sh"

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <name> <commit>"
name="$1" new="$2"
dry_run="${DRY_RUN:-0}"

[[ "$(id -u)" -eq 0 ]] || die "propose-aur.sh must run as root (after setup-builder.sh)"
require_cmd git makepkg sudo
[[ "$dry_run" == "1" ]] || { require_cmd gh; require_env GH_TOKEN GITHUB_REPOSITORY; }

is_aur_linked "$name" || die "$(pkg_path "$name") has no aur.conf"
aur_validate "$name"
[[ "$new" =~ ^[0-9a-f]{40}$ ]] || die "invalid commit: $new"

pkg_dir="$(pkg_dir "$name")"
conf="${pkg_dir}/aur.conf"
base="$(aur_pkgbase "$name")" old="$(aur_commit "$name")"
branch="aur/${name}-${new:0:12}"
work="$(mktemp -d)"
chown "${BUILD_USER:-builder}:" "$work"
trap 'rm -rf "$work"' EXIT

cd "$REPO_ROOT"
git checkout -q -B "$branch"

# --- 1. Fetch both ends -----------------------------------------------------------
group_start "Fetching AUR ${base}"
aur_clone "$base" "$new" "${work}/aur" || die "could not fetch ${new} of AUR ${base}"
git clone -q "${work}/aur" "${work}/aur-old"
history_note="" old_found=1
if git -C "${work}/aur-old" -c advice.detachedHead=false checkout -q "$old" 2>/dev/null; then
  old_version="$(srcinfo_version "${work}/aur-old")"
  if [[ "$old" != "$new" ]] && ! git -C "${work}/aur" merge-base --is-ancestor "$old" "$new"; then
    history_note="**AUR's history was rewritten:** the old pin is not an ancestor of the new one."
    warn "${old} is not an ancestor of ${new}"
  fi
else
  old_found=0 old_version="?"
  history_note="**AUR's history was rewritten:** the old pin no longer exists on AUR, so there is no diff to show. Review the whole PKGBUILD at the new pin."
  warn "${old} no longer exists on AUR"
fi
new_version="$(srcinfo_version "${work}/aur")"
log "pin ${old:0:12} (${old_version}) -> ${new:0:12} (${new_version})"
group_end

# --- 2. Move the pin and settle the override -------------------------------------------
sed -i "s/^\([[:space:]]*commit[[:space:]]*=\).*/\1${new}/" "$conf"
[[ "$(aur_commit "$name")" == "$new" ]] || die "could not update commit= in aur.conf"

resolve_package "$name" "${work}/build" "${work}/aur" || die "could not resolve $(pkg_path "$name")"
override_note=""
case "$OVERRIDE_STATE" in
  stale)
    git rm -r -q -- "${pkg_dir}/override"
    override_note="AUR now has \`${AUR_VERSION}\`, which is not older than the override's \`${OVERRIDE_VERSION}\`, so this **deletes \`override/\`** and builds AUR's PKGBUILD again."
    ;;
  active)
    override_note="The override (\`${OVERRIDE_VERSION}\`) is still newer than AUR's \`${AUR_VERSION}\` and stays in use; AUR's change does not affect the build yet."
    ;;
  permanent)
    override_note="The override is **permanent** (\`${OVERRIDE_VERSION}\`) and stays in use. Check AUR's diff below for changes worth carrying into \`override/\`."
    ;;
esac
git add -- "$conf"

# --- 3. Test build ------------------------------------------------------------------
result="passed" tested=0 key=""
if [[ "$RESOLVED_FROM" == "aur" ]]; then
  group_start "Test-building ${name} ${RESOLVED_VERSION} from AUR"
  tested=1
  key="$(prebuilt_key "$name" "${work}/build")"
  chown -R "${BUILD_USER:-builder}:" "$work"
  if import_source_keys "$pkg_dir" && import_source_keys "${work}/build" \
       && test_build "${work}/build" "${work}/build.log" "$work"; then
    ok "test build passed"
  else
    result="failed"
    warn "test build failed"
  fi
  tail -n 40 "${work}/build.log"
  group_end
fi

git --no-pager diff --cached --stat

if [[ "$dry_run" == "1" ]]; then
  log "DRY_RUN=1: not committing or pushing (test build ${result}, tested=${tested})"
  git reset -q -- "$pkg_dir"
  git checkout -q -- "$pkg_dir"
  [[ "$result" == "passed" ]]
  exit
fi

# --- 4. Commit, push and open the PR -------------------------------------------------
if [[ "$tested" -eq 1 && "$result" == "passed" ]]; then
  offer_prebuilt "$key" "$work" || warn "could not bundle the test build; the merge will build it"
fi

group_start "Opening pull request"
body="${work}/body.md"
diff_file="${work}/aur.diff"
if [[ "$old" != "$new" && "$old_found" -eq 1 ]]; then
  git -C "${work}/aur" diff "$old" "$new" -- . ':(exclude).SRCINFO' >"$diff_file" || true
else
  : >"$diff_file"
fi
diff_lines="$(wc -l <"$diff_file")"
# Backticks below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
{
  if [[ "$old" == "$new" ]]; then
    printf 'AUR `%s` is at `%s`, which has caught up with the override.\n\n' "$base" "$new_version"
  else
    printf 'Moves the AUR pin of **%s** (`%s`) from `%s` (`%s`) to `%s` (`%s`).\n\n' \
      "$name" "$base" "${old:0:12}" "$old_version" "${new:0:12}" "$new_version"
    printf '[AUR log](%s/cgit/aur.git/log/?h=%s)\n\n' "$AUR_URL" "$base"
  fi
  [[ -z "$history_note" ]] || printf '%s\n\n' "$history_note"
  [[ -z "$override_note" ]] || printf '%s\n\n' "$override_note"
  if [[ "$tested" -eq 0 ]]; then
    printf 'Not test-built: the override is what gets built.\n\n'
  elif [[ "$result" == "passed" ]]; then
    printf 'The test build of AUR `%s` **passed** in a clean `archlinux:base-devel` container.\n' "$RESOLVED_VERSION"
    printf 'Merging lets CI build, sign and publish it to `[%s]`.\n\n' "$REPO_NAME"
  else
    printf 'The test build **failed**, so this PR is a draft. To ship anyway, add an\n'
    printf '`override/` on this branch with a fixed PKGBUILD.\n\n'
    printf '<details><summary>Last 60 lines of the build log</summary>\n\n```\n'
    tail -n 60 "${work}/build.log"
    printf '\n```\n</details>\n\n'
  fi
  if [[ "$diff_lines" -gt 0 ]]; then
    printf '**Review AUR'"'"'s diff before merging** (`.SRCINFO` left out):\n\n'
    printf '<details><summary>%s lines</summary>\n\n```diff\n' "$diff_lines"
    head -n 500 "$diff_file"
    [[ "$diff_lines" -le 500 ]] || printf '\n... (truncated; see the AUR log)\n'
    printf '```\n</details>\n'
  fi
} >"$body"

if [[ "$old" == "$new" ]]; then
  title="${name}: drop override, AUR has ${new_version}"
  subject="${name}: drop override, AUR has ${new_version}"
else
  title="${name}: AUR ${old_version} → ${new_version}"
  subject="${name}: move AUR pin to ${new_version}"
fi
open_update_pr "$branch" "aur/${name}-" "$result" "$title" "$body" "$subject" \
  "AUR ${base} ${old:0:12} -> ${new:0:12}.${override_note:+ Override ${OVERRIDE_STATE}.} Test build ${result}."
group_end

[[ "$result" == "passed" ]] || die "${name}: test build failed (draft PR opened)"
