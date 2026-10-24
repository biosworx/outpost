#!/usr/bin/env bash
#
# Interactively set the GitHub Actions secrets and variables the build
# workflow needs. Values are read without echo and piped to `gh` on stdin,
# so they never appear in argv, shell history or files.
#
# Usage: scripts/set-secrets.sh [options]
#
# Options:
#   --repo OWNER/NAME   target repository (default: biosworx/outpost)
#   --op-vault VAULT    1Password vault holding the GPG items (default: Private)
#   --no-op             prompt for GPG values instead of reading 1Password
#   --only NAME[,NAME]  set only these secrets/variables
#   --dry-run           validate and print what would be set; change nothing
#   -h, --help          show this help
#
# 1Password items read when op is used (rename with the env vars below):
#   OP_KEY_DOC   document holding the armoured secret key ("bios GPG private key")
#   OP_PASS_ITEM password item with the passphrase       ("bios GPG passphrase")
#
# Requires: gh (authenticated), gpg, curl, jq; optional: op

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  sed -n '3,/^$/{s/^# \{0,1\}//;p}' "$0"
  exit "${1:-0}"
}

repo="biosworx/outpost" vault="Private" use_op=1 only="" dry_run=0
OP_KEY_DOC="${OP_KEY_DOC:-bios GPG private key}"
OP_PASS_ITEM="${OP_PASS_ITEM:-bios GPG passphrase}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:?--repo needs a value}"; shift ;;
    --op-vault) vault="${2:?--op-vault needs a value}"; shift ;;
    --no-op) use_op=0 ;;
    --only) only=",${2:?--only needs a value},"; shift ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage 0 ;;
    *) warn "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

require_cmd gh gpg curl jq
[[ -t 0 ]] || die "run this from an interactive terminal"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
if [[ "$use_op" -eq 1 ]] && ! command -v op >/dev/null 2>&1; then
  warn "op not found; falling back to prompts for GPG values"
  use_op=0
fi

wanted() { [[ -z "$only" || "$only" == *",$1,"* ]]; }

# Values collected so far, for cross-checks (never printed).
declare -A val=()

prompt_secret() {
  local name="$1" label="$2" value
  read -rsp "  ${label}: " value </dev/tty
  printf '\n' >&2
  [[ -n "$value" ]] || die "$name must not be empty"
  val[$name]="$value"
}

prompt_plain() {
  local name="$1" label="$2" default="${3:-}" value
  read -rp "  ${label}${default:+ [$default]}: " value </dev/tty
  value="${value:-$default}"
  [[ -n "$value" ]] || die "$name must not be empty"
  val[$name]="$value"
}

store_secret() {
  local name="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    log "would set secret $name (${#val[$name]} chars)"
  else
    printf '%s' "${val[$name]}" | gh secret set "$name" --repo "$repo"
    ok "set secret $name"
  fi
}

# curl with credentials passed as a config on stdin, keeping them out of argv.
curl_auth() {
  local auth_line="$1"; shift
  printf '%s\n' "$auth_line" | curl -sS --max-time 20 -K - "$@"
}

store_variable() {
  local name="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    log "would set variable $name=${val[$name]}"
  else
    gh variable set "$name" --repo "$repo" --body "${val[$name]}"
    ok "set variable $name=${val[$name]}"
  fi
}

log "target repository: $repo$( [[ "$dry_run" -eq 1 ]] && printf ' (dry run)')"

# --- GPG ---------------------------------------------------------------------------
if wanted GPG_PRIVATE_KEY || wanted GPG_PASSPHRASE || wanted GPG_KEY_ID; then
  group_start "GPG signing key"
  if [[ "$use_op" -eq 1 ]]; then
    log "reading from 1Password vault '$vault'"
    val[GPG_PRIVATE_KEY]="$(op document get "$OP_KEY_DOC" --vault "$vault")"
    val[GPG_PASSPHRASE]="$(op read "op://${vault}/${OP_PASS_ITEM}/password")"
  else
    log "paste the armoured secret key, then press Ctrl-D:"
    val[GPG_PRIVATE_KEY]="$(cat </dev/tty)"
    prompt_secret GPG_PASSPHRASE "passphrase (empty not allowed)"
  fi

  grep -q 'BEGIN PGP PRIVATE KEY BLOCK' <<<"${val[GPG_PRIVATE_KEY]}" \
    || die "GPG_PRIVATE_KEY is not an armoured secret key"

  # Derive the fingerprint from the key itself rather than asking for it.
  val[GPG_KEY_ID]="$(
    gpg --batch --with-colons --show-keys <<<"${val[GPG_PRIVATE_KEY]}" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }'
  )"
  [[ -n "${val[GPG_KEY_ID]}" ]] || die "could not read a fingerprint from the key"
  log "fingerprint: ${val[GPG_KEY_ID]}"

  # Check the passphrase in a throwaway keyring so the real one is untouched.
  tmp_gnupg="$(mktemp -d)"
  trap 'gpgconf --homedir "$tmp_gnupg" --kill gpg-agent 2>/dev/null || true; rm -rf "$tmp_gnupg"' EXIT
  gpg --homedir "$tmp_gnupg" --batch --quiet --import <<<"${val[GPG_PRIVATE_KEY]}" 2>/dev/null
  if printf 'check\n' | gpg --homedir "$tmp_gnupg" --batch --pinentry-mode loopback \
       --passphrase-fd 3 --local-user "${val[GPG_KEY_ID]}" --detach-sign --output /dev/null \
       3< <(printf '%s' "${val[GPG_PASSPHRASE]}") 2>/dev/null; then
    ok "passphrase unlocks the key"
  else
    die "passphrase does not unlock the key"
  fi

  pub="${REPO_ROOT}/keys/${REPO_NAME}.asc"
  if [[ -f "$pub" ]] && ! grep -q PLACEHOLDER "$pub"; then
    pub_fpr="$(gpg --batch --with-colons --show-keys "$pub" | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "$pub_fpr" == "${val[GPG_KEY_ID]}" ]] \
      || die "keys/${REPO_NAME}.asc ($pub_fpr) does not match this key"
    ok "matches keys/${REPO_NAME}.asc"
  fi

  for name in GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID; do
    wanted "$name" && store_secret "$name"
  done
  group_end
fi

# --- Backblaze B2 ---------------------------------------------------------------------
if wanted B2_KEY_ID || wanted B2_APP_KEY || wanted B2_BUCKET; then
  group_start "Backblaze B2"
  prompt_plain  B2_BUCKET  "bucket name"
  prompt_plain  B2_KEY_ID  "application keyID"
  prompt_secret B2_APP_KEY "applicationKey (hidden)"

  # b2_authorize_account confirms the key works and which bucket it is scoped to.
  auth="$(
    curl_auth "user = \"${val[B2_KEY_ID]}:${val[B2_APP_KEY]}\"" \
      https://api.backblazeb2.com/b2api/v3/b2_authorize_account
  )" || die "could not reach Backblaze"
  if [[ "$(jq -r '.accountId // empty' <<<"$auth")" == "" ]]; then
    die "B2 rejected the key: $(jq -r '(.code // "error" | tostring) + ((.message // "") | if . == "" then "" else " (" + . + ")" end)' <<<"$auth")"
  fi
  # Search the whole response: the "allowed" block sits at different depths
  # in the v2 and v3 APIs (v2: allowed.bucketName, v3: allowed.buckets[].name).
  scoped="$(jq -r '[.. | objects | (.buckets? | arrays | .[].name?), .bucketName? | strings] | first // empty' <<<"$auth")"
  caps="$(jq -r '[.. | objects | .capabilities? | arrays] | first // [] | join(",")' <<<"$auth")"
  download_url="$(jq -r '[.. | objects | .downloadUrl? | strings] | first // empty' <<<"$auth")"
  [[ -n "$caps" ]] || die "could not read the key's capabilities from the B2 response"
  if [[ -n "$scoped" && "$scoped" != "${val[B2_BUCKET]}" ]]; then
    die "key is restricted to bucket '$scoped', not '${val[B2_BUCKET]}'"
  fi
  [[ -n "$scoped" ]] || warn "key is not restricted to one bucket; consider a bucket-scoped key"
  for cap in listFiles readFiles writeFiles deleteFiles; do
    [[ ",$caps," == *",$cap,"* ]] || die "key lacks the '$cap' capability"
  done
  ok "B2 key valid for bucket '${val[B2_BUCKET]}'"
  [[ -z "$download_url" ]] || log "B2 download host: ${download_url#https://} (needed for the Cloudflare CNAME)"

  wanted B2_KEY_ID && store_secret B2_KEY_ID
  wanted B2_APP_KEY && store_secret B2_APP_KEY
  wanted B2_BUCKET && store_variable B2_BUCKET
  group_end
fi

# --- Cloudflare -------------------------------------------------------------------------
if wanted CF_API_TOKEN || wanted CF_ZONE_ID; then
  group_start "Cloudflare"
  prompt_plain  CF_ZONE_ID   "zone ID"
  prompt_secret CF_API_TOKEN "API token (hidden)"

  verify="$(
    curl_auth "header = \"Authorization: Bearer ${val[CF_API_TOKEN]}\"" \
      https://api.cloudflare.com/client/v4/user/tokens/verify
  )" || die "could not reach Cloudflare"
  [[ "$(jq -r '.result.status // empty' <<<"$verify")" == "active" ]] \
    || die "Cloudflare token is not active: $(jq -c '.errors' <<<"$verify")"

  zone="$(
    curl_auth "header = \"Authorization: Bearer ${val[CF_API_TOKEN]}\"" \
      "https://api.cloudflare.com/client/v4/zones/${val[CF_ZONE_ID]}"
  )" || die "could not reach Cloudflare"
  zone_name="$(jq -r '.result.name // empty' <<<"$zone")"
  if [[ -n "$zone_name" ]]; then
    [[ "${REPO_DOMAIN#https://}" == *"$zone_name" ]] \
      || warn "zone '$zone_name' does not contain ${REPO_DOMAIN#https://}"
    ok "token active; zone '$zone_name'"
  else
    # A purge-only token may not be allowed to read zone details.
    warn "token is active but cannot read zone ${val[CF_ZONE_ID]}; double-check the zone ID"
  fi

  wanted CF_ZONE_ID && store_secret CF_ZONE_ID
  wanted CF_API_TOKEN && store_secret CF_API_TOKEN
  group_end
fi

ok "done. Check with: gh secret list --repo $repo && gh variable list --repo $repo"
