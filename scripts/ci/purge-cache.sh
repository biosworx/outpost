#!/usr/bin/env bash
#
# Purge the repository database objects from Cloudflare's edge cache.
#
# Uses purge-by-URL (available on every Cloudflare plan) for every
# aurstrich.db* / aurstrich.files* object, plus the public key.
#
# Env: CF_API_TOKEN (Zone > Cache Purge), CF_ZONE_ID

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_cmd curl jq
require_env CF_API_TOKEN CF_ZONE_ID

urls=()
for file in "${DB_OBJECTS[@]}"; do
  urls+=("${REPO_URL}/${file}")
done
urls+=("${REPO_BASE_URL}/${REPO_NAME}.asc")

payload="$(jq -cn '{files: $ARGS.positional}' --args "${urls[@]}")"

group_start "Purging ${#urls[@]} URL(s) from Cloudflare cache"
printf '    %s\n' "${urls[@]}" >&2

response="$(
  curl -sS --fail-with-body --retry 3 --retry-all-errors --max-time 30 \
    -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload"
)" || {
  printf '%s\n' "${response:-}" | jq -r '.errors[]? | "  \(.code): \(.message)"' >&2 || true
  die "Cloudflare purge request failed"
}

if [[ "$(jq -r '.success' <<<"$response")" != "true" ]]; then
  jq -r '.errors[]? | "  \(.code): \(.message)"' <<<"$response" >&2
  die "Cloudflare reported purge failure"
fi
ok "cache purged"
group_end
