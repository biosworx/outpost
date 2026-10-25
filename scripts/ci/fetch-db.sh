#!/usr/bin/env bash
#
# Download the published [aurstrich] database into $OUT_DIR, read-only, so
# build-packages.sh can skip versions that are already published.
#
# Plain HTTPS from the public bucket (lib/common.sh: repo_read_url), so the
# build job, which runs untrusted PKGBUILD code, holds no B2 credentials.
# The publish job, the only writer, uses `publish.sh pull` instead.
#
# Env: OUT_DIR, B2_BUCKET (optional; without it, the public domain)

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd curl bsdtar

mkdir -p "$OUT_DIR"
dest="${OUT_DIR}/${DB_ARCHIVE}"

group_start "Fetching ${DB_ARCHIVE}"
status="$(
  curl -sS --retry 3 --retry-all-errors --max-time 120 -o "${dest}.part" -w '%{http_code}' \
    "$(repo_read_url)/${DB_ARCHIVE}"
)" || { rm -f "${dest}.part"; die "failed to download ${DB_ARCHIVE}"; }

case "$status" in
  200)
    mv -f "${dest}.part" "$dest"
    bsdtar -tf "$dest" >/dev/null || die "fetched ${DB_ARCHIVE} is not a valid archive; refusing to continue"
    ok "fetched ${DB_ARCHIVE} ($(db_filenames "$dest" | wc -l) packages)"
    ;;
  404)
    rm -f "${dest}.part"
    warn "no published database yet (first publish?)"
    ;;
  *)
    rm -f "${dest}.part"
    die "${DB_ARCHIVE} returned HTTP ${status}"
    ;;
esac
group_end
