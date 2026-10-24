# shellcheck shell=bash disable=SC2034  # constants are used by the scripts that source this file
#
# Shared helpers and constants for outpost scripts.
# Source this file; do not execute it.

[[ -n "${_OUTPOST_COMMON_LOADED:-}" ]] && return 0
_OUTPOST_COMMON_LOADED=1

# --- Repository constants ----------------------------------------------------
REPO_NAME="${REPO_NAME:-aurstrich}"
REPO_ARCH="${REPO_ARCH:-x86_64}"
REPO_DOMAIN="${REPO_DOMAIN:-https://outpost.bios.plus}"
# Path prefix for this repo on the host and in the bucket, so the rest of
# outpost.bios.plus stays free for other things (e.g. mirrors).
REPO_PREFIX="${REPO_PREFIX:-$REPO_NAME}"
REPO_BASE_URL="${REPO_DOMAIN}/${REPO_PREFIX}"
REPO_URL="${REPO_BASE_URL}/${REPO_ARCH}"

# Maintainer line for PKGBUILDs CI writes (new overrides).
OVERRIDE_MAINTAINER="${OVERRIDE_MAINTAINER:-BiosPlus <9003059+BiosPlus@users.noreply.github.com>}"

# rclone remote name; configured purely through RCLONE_CONFIG_B2_* env vars.
RCLONE_REMOTE="${RCLONE_REMOTE:-b2}"

# B2 "friendly URL" host of the bucket (EU Central). CI reads [aurstrich]
# from here directly, because Cloudflare's Bot Fight Mode challenges GitHub's
# runners on the public domain.
B2_DOWNLOAD_HOST="${B2_DOWNLOAD_HOST:-https://f003.backblazeb2.com}"

# Absolute path of the repository checkout.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGES_DIR="${REPO_ROOT}/packages"

# Packages live under their first letter, packages/<l>/<name>, so packages/
# stays browsable as the list grows. pkg_path is repo-relative (for messages
# and git), pkg_dir absolute.
pkg_path() { printf 'packages/%s/%s' "${1:0:1}" "$1"; }
pkg_dir() { printf '%s/%s' "$REPO_ROOT" "$(pkg_path "$1")"; }

# Working directory holding the repo database and freshly built packages.
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/.repo}"

# Database / files artifacts: the real tarballs and the names pacman fetches.
DB_ARCHIVE="${REPO_NAME}.db.tar.gz"
FILES_ARCHIVE="${REPO_NAME}.files.tar.gz"
DB_OBJECTS=(
  "${REPO_NAME}.db"
  "${REPO_NAME}.db.sig"
  "${REPO_NAME}.db.tar.gz"
  "${REPO_NAME}.db.tar.gz.sig"
  "${REPO_NAME}.files"
  "${REPO_NAME}.files.sig"
  "${REPO_NAME}.files.tar.gz"
  "${REPO_NAME}.files.tar.gz.sig"
)

# --- Logging -------------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_info=$'\e[1;34m' _c_warn=$'\e[1;33m' _c_err=$'\e[1;31m' _c_ok=$'\e[1;32m' _c_off=$'\e[0m'
else
  _c_info='' _c_warn='' _c_err='' _c_ok='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*" >&2; }
ok()   { printf '%s==>%s %s\n' "$_c_ok" "$_c_off" "$*" >&2; }
warn() { printf '%s==> WARNING:%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s==> ERROR:%s %s\n' "$_c_err" "$_c_off" "$*" >&2; exit 1; }

# GitHub Actions log grouping; harmless no-ops elsewhere.
in_ci() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }
group_start() { if in_ci; then printf '::group::%s\n' "$*"; else log "$*"; fi; }
group_end()   { if in_ci; then printf '::endgroup::\n'; fi; }

# --- Utilities ---------------------------------------------------------------------
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

require_env() {
  local var
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "required environment variable is not set: $var"
  done
}

# Write a key=value pair to the GitHub step output (or stdout outside CI).
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# Export a variable to subsequent GitHub Actions steps.
set_env() {
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV"
  fi
  export "$1=$2"
}

# Remote base of the repo inside the bucket, e.g. b2:my-bucket/aurstrich
remote_base() {
  require_env B2_BUCKET
  printf '%s:%s/%s' "$RCLONE_REMOTE" "$B2_BUCKET" "$REPO_PREFIX"
}

# Remote path of the arch directory, e.g. b2:my-bucket/aurstrich/x86_64
remote_path() {
  require_env B2_BUCKET
  printf '%s/%s' "$(remote_base)" "$REPO_ARCH"
}

# Run a command as the unprivileged build user when we are root.
as_builder() {
  if [[ "$(id -u)" -eq 0 ]]; then
    sudo -u "${BUILD_USER:-builder}" -H --preserve-env=GNUPGHOME,GPGKEY,PACKAGER,PKGDEST,PKGEXT,SRCDEST,BUILDDIR -- "$@"
  else
    "$@"
  fi
}

# Import the upstream signing keys a package keeps in keys/pgp/*.asc (the
# layout of Arch's packaging repos) into the build user's keyring, so makepkg
# can verify sources listed in validpgpkeys.
import_source_keys() {
  local dir="$1" keys=()
  shopt -s nullglob
  keys=("${dir}"/keys/pgp/*.asc)
  shopt -u nullglob
  [[ "${#keys[@]}" -gt 0 ]] || return 0
  as_builder gpg --batch --quiet --import "${keys[@]}"
}

# Print every package filename referenced by a repo database (one per line).
db_filenames() {
  local db="$1"
  [[ -s "$db" ]] || return 0
  # An empty database has no desc entries and bsdtar exits non-zero; that is
  # "no packages", not an error (and must not trip pipefail in callers).
  { bsdtar -xOf "$db" '*/desc' 2>/dev/null || true; } \
    | awk '/^%FILENAME%$/ { getline; print }'
}
