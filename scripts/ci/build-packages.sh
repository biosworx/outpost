#!/usr/bin/env bash
#
# Build and sign the given packages with makepkg as the build user.
#
# Usage: build-packages.sh <name>...      (or PACKAGES="a b c")
#
# - Skips a package when every file it would produce is already listed in
#   the pulled repo database. Same-version rebuilds are not reproducible, and
#   republishing a filename with new bytes/signature would collide with
#   CDN-cached copies. Bump pkgrel to republish.
# - A failing package does not stop the others. Failures are reported via
#   the step output "failed" so publishing can still go ahead for the rest.
# - Built package paths are appended to $OUT_DIR/.built for publish.sh.
# - AUR-linked packages are resolved first (lib/aur.sh): the pinned AUR
#   files or the override, copied to a work directory and built there.
#
# Env: OUT_DIR (with the pulled database), GPGKEY (from setup-gpg.sh).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vercmp.sh
source "$(dirname "$0")/../lib/vercmp.sh"
# shellcheck source=../lib/aur.sh
source "$(dirname "$0")/../lib/aur.sh"

require_cmd makepkg bsdtar git

if [[ $# -eq 0 && -n "${PACKAGES:-}" ]]; then
  read -r -a pkgs <<<"$PACKAGES"
else
  pkgs=("$@")
fi

if [[ "${#pkgs[@]}" -eq 0 ]]; then
  ok "no packages given; nothing to build"
  set_output built ""
  set_output failed ""
  exit 0
fi

mkdir -p "$OUT_DIR"
built_list="${OUT_DIR}/.built"
: >"$built_list"

# Build output and source caches live outside the checkout.
export PKGDEST="${OUT_DIR}/.pkgdest"
export SRCDEST="${SRCDEST:-${OUT_DIR}/.srcdest}"
as_builder mkdir -p "$PKGDEST" "$SRCDEST"
work_root="${OUT_DIR}/.work"

mapfile -t published < <(db_filenames "${OUT_DIR}/${DB_ARCHIVE}")

is_published() {
  local file="$1" entry
  for entry in "${published[@]}"; do
    [[ "$entry" == "$file" ]] && return 0
  done
  return 1
}

built=()
skipped=()
failed=()

for name in "${pkgs[@]}"; do
  group_start "Building ${name}"

  # Resolve into a fresh directory the build user owns.
  dir="${work_root}/${name}"
  rm -rf "$dir"
  if ! resolve_package "$name" "$dir"; then
    warn "${name}: could not resolve $(pkg_path "$name")"
    failed+=("$name")
    group_end
    continue
  fi
  chown -R "${BUILD_USER:-builder}:" "$work_root" 2>/dev/null || true
  log "${name}: building $(describe_resolution "$name")"

  # --packagelist evaluates the PKGBUILD without building. VCS packages with
  # a pkgver() function only know their version after fetching sources, so
  # they always build.
  if ! grep -qE '^[[:space:]]*pkgver[[:space:]]*\(\)' "${dir}/PKGBUILD"; then
    if ! packagelist="$(cd "$dir" && as_builder makepkg --packagelist)"; then
      warn "${name}: failed to evaluate PKGBUILD"
      failed+=("$name")
      group_end
      continue
    fi
    mapfile -t expected <<<"$packagelist"
    all_published=1
    for path in "${expected[@]}"; do
      is_published "$(basename "$path")" || { all_published=0; break; }
    done
    if [[ "${#expected[@]}" -gt 0 && "$all_published" -eq 1 ]]; then
      warn "${name}: version already published; bump pkgrel to rebuild"
      skipped+=("$name")
      group_end
      continue
    fi
  fi

  # Collect only what this build produces.
  before="$(mktemp)"
  find "$PKGDEST" -maxdepth 1 -name '*.pkg.tar.zst' | sort >"$before"

  if import_source_keys "$(pkg_dir "$name")" && import_source_keys "$dir" \
       && (cd "$dir" && as_builder makepkg --syncdeps --noconfirm --cleanbuild --clean --sign); then
    mapfile -t new_files < <(
      find "$PKGDEST" -maxdepth 1 -name '*.pkg.tar.zst' | sort | comm -13 "$before" -
    )
    # VCS packages skip the pre-build check, so an upstream with no new
    # commits rebuilds a version that is already published. Drop those files.
    fresh=()
    for f in "${new_files[@]}"; do
      if is_published "$(basename "$f")"; then
        rm -f "$f" "${f}.sig"
      else
        fresh+=("$f")
      fi
    done
    if [[ "${#new_files[@]}" -gt 0 && "${#fresh[@]}" -eq 0 ]]; then
      warn "${name}: version already published (no upstream changes)"
      skipped+=("$name")
    elif [[ "${#new_files[@]}" -eq 0 ]]; then
      warn "${name}: makepkg succeeded but produced no packages"
      failed+=("$name")
    else
      new_files=("${fresh[@]}")
      for f in "${new_files[@]}"; do
        [[ -f "${f}.sig" ]] || die "${name}: missing signature for $(basename "$f")"
        printf '%s\n' "$f" >>"$built_list"
        ok "built $(basename "$f")"
      done
      built+=("$name")
    fi
  else
    warn "${name}: build failed"
    failed+=("$name")
  fi
  rm -f "$before"
  rm -rf "$dir"
  group_end
done

log "built:   ${built[*]:-(none)}"
log "skipped: ${skipped[*]:-(none)}"
if [[ "${#failed[@]}" -gt 0 ]]; then
  warn "failed:  ${failed[*]}"
fi

set_output built "${built[*]}"
set_output failed "${failed[*]}"
