# shellcheck shell=bash
#
# AUR-linked packages and their local overrides. Source after common.sh and
# vercmp.sh; do not execute.
#
# A package directory takes one of two shapes:
#
#   standalone   packages/<l>/<name>/PKGBUILD (+ its files), built as is
#   AUR-linked   packages/<l>/<name>/aur.conf links the AUR original:
#                  pkgbase=<AUR package base>   (default: <name>)
#                  commit=<40-hex AUR git commit, the reviewed pin>
#                packages/<l>/<name>/override/ optionally holds a full PKGBUILD
#                (+ files) that takes precedence:
#                  - while its epoch:pkgver-pkgrel is newer than AUR's, or
#                  - always, with permanent=1 in override/override.conf
#                Once AUR catches up, a non-permanent override is stale: AUR
#                is built and the daily check proposes deleting it.
#
# update.conf and keys/pgp/ stay at packages/<l>/<name>/ in both shapes.

AUR_URL="${AUR_URL:-https://aur.archlinux.org}"

# Read one key from a key=value file without executing it.
conf_get() {
  [[ -f "$1" ]] || return 0
  awk -F= -v key="$2" '
    /^[[:space:]]*(#|$)/ { next }
    { k = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
    k == key { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

is_aur_linked() { [[ -f "$(pkg_dir "$1")/aur.conf" ]]; }

# Whether packages/<l>/<name> is a package at all (either shape).
is_package() {
  [[ -f "$(pkg_dir "$1")/PKGBUILD" || -f "$(pkg_dir "$1")/aur.conf" ]]
}

all_packages() {
  local dir
  for dir in "$PACKAGES_DIR"/*/*/; do
    dir="${dir%/}"
    is_package "${dir##*/}" && printf '%s\n' "${dir##*/}"
  done
  return 0
}

aur_pkgbase() {
  local base
  base="$(conf_get "$(pkg_dir "$1")/aur.conf" pkgbase)"
  printf '%s' "${base:-$1}"
}

aur_commit() { conf_get "$(pkg_dir "$1")/aur.conf" commit; }

has_override() { [[ -f "$(pkg_dir "$1")/override/PKGBUILD" ]]; }

override_is_permanent() {
  [[ "$(conf_get "$(pkg_dir "$1")/override/override.conf" permanent)" == "1" ]]
}

# Check aur.conf (and override.conf) for a package; dies on bad values,
# since the pin ends up in git commands.
aur_validate() {
  local name="$1" base commit
  base="$(aur_pkgbase "$name")"
  commit="$(aur_commit "$name")"
  [[ "$base" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || die "${name}: invalid pkgbase '${base}' in aur.conf"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "${name}: aur.conf needs commit=<full 40-hex AUR commit>, got '${commit}'"
  if [[ -f "$(pkg_dir "$name")/override/override.conf" ]] && ! has_override "$name"; then
    die "${name}: override/override.conf without override/PKGBUILD"
  fi
  if [[ -f "$(pkg_dir "$name")/PKGBUILD" ]]; then
    die "${name}: has both aur.conf and a top-level PKGBUILD; move the PKGBUILD to override/"
  fi
}

# Clone the AUR repository of <pkgbase> into <dest> (which must not exist)
# and check out <commit>, or stay on the tip when <commit> is empty.
aur_clone() {
  local base="$1" commit="$2" dest="$3"
  git clone --quiet "${AUR_URL}/${base}.git" "$dest" || return 1
  # An unknown package base clones as an empty repository.
  git -C "$dest" rev-parse -q --verify HEAD >/dev/null || { warn "${base}: no such AUR package"; return 1; }
  if [[ -n "$commit" ]]; then
    git -C "$dest" -c advice.detachedHead=false checkout --quiet "$commit" \
      || { warn "${base}: commit ${commit} not found on AUR"; return 1; }
  fi
}

# Print epoch:pkgver-pkgrel (epoch only when set) of an AUR checkout, from
# its .SRCINFO: AUR's files are untrusted, so they are never sourced here.
srcinfo_version() {
  awk '
    /^pkgname[[:space:]]*=/ { exit }  # stop at the first split package
    /^[[:space:]]*(epoch|pkgver|pkgrel)[[:space:]]*=/ {
      k = $1; v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); f[k] = v
    }
    END { printf "%s%s-%s", (f["epoch"] && f["epoch"] != "0") ? f["epoch"] ":" : "", f["pkgver"], f["pkgrel"] }
  ' "$1/.SRCINFO"
}

# Same for a PKGBUILD of our own (an override or a standalone package): it is
# sourced in a subshell, as makepkg would, so computed versions work.
pkgbuild_version() {
  (
    cd "$1" || exit 1
    set +eu
    epoch="" pkgver="" pkgrel=""
    # shellcheck disable=SC1091
    source ./PKGBUILD >/dev/null 2>&1
    printf '%s%s-%s' "${epoch:+${epoch}:}" "$pkgver" "$pkgrel"
  )
}

# Print what the package resolved into <dir> supplies and needs, one
# "provides<TAB>name" or "needs<TAB>name" line each, versions stripped:
#   provides  every pkgname of a split package and everything they provide
#   needs     what makepkg --syncdeps installs: the global depends,
#             makedepends and checkdepends (arch-specific ones included)
# Uses .SRCINFO when RESOLVED_FROM is aur (AUR's files are never sourced
# here), else sources the PKGBUILD in a subshell. Call after resolve_package.
pkg_relations() {
  local dir="$1"
  if [[ "$RESOLVED_FROM" == "aur" ]]; then
    awk '
      { line = $0; sub(/^[[:space:]]+/, "", line) }
      split(line, kv, " = ") < 2 { next }
      { key = kv[1]; value = substr(line, length(key) + 4); sub(/[<>=].*/, "", value) }
      key == "pkgname" { global = 0 }
      key ~ /^(pkgname|provides(_.+)?)$/ { print "provides\t" value; next }
      global && key ~ /^(depends|makedepends|checkdepends)(_.+)?$/ { print "needs\t" value }
      BEGIN { global = 1 }
    ' "${dir}/.SRCINFO"
    return 0
  fi
  (
    cd "$dir" || exit 1
    set +eu
    pkgname=() provides=() depends=() makedepends=() checkdepends=()
    # shellcheck disable=SC1091
    source ./PKGBUILD >/dev/null 2>&1
    local kind var v
    for var in pkgname provides "provides_${REPO_ARCH}" \
               depends makedepends checkdepends \
               "depends_${REPO_ARCH}" "makedepends_${REPO_ARCH}" "checkdepends_${REPO_ARCH}"; do
      [[ "$var" == p* ]] && kind=provides || kind=needs
      var="${var}[@]"
      for v in "${!var}"; do printf '%s\t%s\n' "$kind" "${v%%[<>=]*}"; done
    done
  )
}

# Decide which PKGBUILD a package builds from and copy it into <dest>.
#
# Usage: resolve_package <name> <dest> [aur-checkout]
#   <dest> is created; it receives the files to build, without .git.
#   [aur-checkout] reuses an existing clone at the pin instead of fetching.
#
# Sets:
#   RESOLVED_FROM      standalone | aur | override
#   RESOLVED_VERSION   version of the chosen PKGBUILD
#   AUR_VERSION        version at the pinned AUR commit (AUR-linked only)
#   OVERRIDE_VERSION   version of override/ (empty without one)
#   OVERRIDE_STATE     none | active | permanent | stale
resolve_package() {
  local name="$1" dest="$2" checkout="${3:-}" src tmp=""
  src="$(pkg_dir "$1")"
  RESOLVED_FROM="" RESOLVED_VERSION="" AUR_VERSION="" OVERRIDE_VERSION="" OVERRIDE_STATE="none"

  is_package "$name" || { warn "$(pkg_path "$name") is not a package"; return 1; }
  mkdir -p "$dest"

  if ! is_aur_linked "$name"; then
    cp -a "${src}/." "$dest/"
    RESOLVED_FROM="standalone"
    RESOLVED_VERSION="$(pkgbuild_version "$dest")"
    return 0
  fi

  aur_validate "$name"
  if [[ -z "$checkout" ]]; then
    tmp="$(mktemp -d)"
    checkout="${tmp}/aur"
    aur_clone "$(aur_pkgbase "$name")" "$(aur_commit "$name")" "$checkout" || { rm -rf "$tmp"; return 1; }
  fi
  AUR_VERSION="$(srcinfo_version "$checkout")"

  if has_override "$name"; then
    OVERRIDE_VERSION="$(pkgbuild_version "${src}/override")"
    if override_is_permanent "$name"; then
      OVERRIDE_STATE="permanent"
    elif [[ "$(pkg_vercmp "$OVERRIDE_VERSION" "$AUR_VERSION")" -gt 0 ]]; then
      OVERRIDE_STATE="active"
    else
      OVERRIDE_STATE="stale"
    fi
  fi

  if [[ "$OVERRIDE_STATE" == "active" || "$OVERRIDE_STATE" == "permanent" ]]; then
    cp -a "${src}/override/." "$dest/"
    rm -f "${dest}/override.conf"
    RESOLVED_FROM="override"
    RESOLVED_VERSION="$OVERRIDE_VERSION"
  else
    (cd "$checkout" && tar --exclude=./.git -cf - .) | (cd "$dest" && tar -xf -)
    RESOLVED_FROM="aur"
    RESOLVED_VERSION="$AUR_VERSION"
    if [[ "$OVERRIDE_STATE" == "stale" ]]; then
      warn "${name}: override ${OVERRIDE_VERSION} is not newer than AUR ${AUR_VERSION}; building AUR"
    fi
  fi
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  return 0
}

# Replace packages/<l>/<name>/override/ with a copy of the AUR files in <src>
# (a checkout or a resolved copy) and credit both maintainers in its PKGBUILD,
# keeping AUR's maintainer as a contributor. <why> continues the header line
# "Override of AUR `<pkgbase>` (<version> at <commit>),".
create_override() {
  local name="$1" src="$2" why="$3" dir tmp version
  dir="$(pkg_dir "$1")/override"
  version="$(srcinfo_version "$src")"
  rm -rf "$dir"
  mkdir -p "$dir"
  (cd "$src" && tar --exclude=./.git -cf - .) | (cd "$dir" && tar -xf -)
  rm -f "${dir}/.SRCINFO" "${dir}/.gitignore" "${dir}/.nvchecker.toml"
  tmp="$(mktemp)"
  # Backticks are Markdown-style quoting in a comment, not substitutions.
  # shellcheck disable=SC2016
  {
    printf '# Maintainer: %s\n' "$OVERRIDE_MAINTAINER"
    printf '# Contributor: Claude <noreply@anthropic.com>\n'
    sed -n '/^#/!q; s/^# *Maintainer:/# Contributor:/; p' "${dir}/PKGBUILD"
    printf '#\n# Override of AUR `%s` (%s at %s),\n# %s\n\n' \
      "$(aur_pkgbase "$name")" "$version" "$(aur_commit "$name" | cut -c1-12)" "$why"
    awk 'body || (!/^#/ && !/^[[:space:]]*$/) { body = 1; print }' "${dir}/PKGBUILD"
  } >"$tmp"
  mv "$tmp" "${dir}/PKGBUILD"
  chmod 644 "${dir}/PKGBUILD"
}

# One-line description of the last resolve_package result.
describe_resolution() {
  case "$RESOLVED_FROM" in
    standalone) printf 'standalone PKGBUILD %s' "$RESOLVED_VERSION" ;;
    aur) printf 'AUR %s %s%s' "$(aur_pkgbase "$1")" "$AUR_VERSION" \
           "$([[ "$OVERRIDE_STATE" == stale ]] && printf ' (stale override %s ignored)' "$OVERRIDE_VERSION")" ;;
    override) printf '%s override %s, AUR %s has %s' "$OVERRIDE_STATE" "$OVERRIDE_VERSION" \
                "$(aur_pkgbase "$1")" "$AUR_VERSION" ;;
  esac
}
