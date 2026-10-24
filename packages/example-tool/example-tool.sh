#!/usr/bin/env bash
#
# example-tool: print a short report about the running system.
# Shipped as the reference package for the [aurstrich] repository.

set -euo pipefail

VERSION="@VERSION@"

usage() {
  cat <<USAGE
Usage: example-tool [--version | --help]

Prints kernel, uptime and pacman repository information.
USAGE
}

case "${1:-}" in
  -V|--version) printf 'example-tool %s\n' "$VERSION"; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

printf 'kernel:  %s\n' "$(uname -sr)"
printf 'uptime:  %s\n' "$(uptime -p 2>/dev/null || echo unknown)"
if command -v pacman-conf >/dev/null 2>&1; then
  printf 'repos:   %s\n' "$(pacman-conf --repo-list | paste -sd ' ')"
fi
