#!/usr/bin/env bash
# Download a release archive, verify it against the checksum file published
# with the same release, and install one binary from it into $INSTALL_DIR.
#
# Usage: install-release.sh <archive-url> <checksums-url> <binary-path-in-archive>

set -euo pipefail

archive_url=$1
checksums_url=$2
member=$3
install_dir=${INSTALL_DIR:?INSTALL_DIR must be set}

archive=$(basename "$archive_url")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

curl -fsSL --retry 3 -o "$archive" "$archive_url"
curl -fsSL --retry 3 -o checksums "$checksums_url"

# Exactly one "<sha256>  <archive>" line must match, and the file must match it.
grep -E "^[0-9a-f]{64}  \*?${archive//./\\.}\$" checksums >expected || true
[[ $(wc -l <expected) -eq 1 ]] || { printf 'No unique checksum for %s\n' "$archive" >&2; exit 1; }
sha256sum --check --strict expected

tar -xzf "$archive" "$member"
mkdir -p "$install_dir"
install -m 0755 "$member" "$install_dir/$(basename "$member")"
