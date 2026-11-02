#!/bin/bash
# Mirror the official Caddy macOS release for Devid (no rebuild): verify it against Caddy's
# published SHA-512 checksums, then repackage it with its license.
#   scripts/mirror-caddy.sh   -> dist/caddy-<ver>-darwin-x86_64.tar.gz (caddy + LICENSES/ + BUILDINFO)
set -euo pipefail

CADDY_VER="${CADDY_VER:-2.11.7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}/caddy"
DIST="${DIST:-$ROOT/dist}"
BASE="https://github.com/caddyserver/caddy/releases/download/v$CADDY_VER"
ASSET="caddy_${CADDY_VER}_mac_amd64.tar.gz"
SUMS="caddy_${CADDY_VER}_checksums.txt"

rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
cd "$WORK"
curl -fsSLO "$BASE/$ASSET"
curl -fsSLO "$BASE/$SUMS"
# shortcut: trusts the checksums file over HTTPS from Caddy's release; verifying its cosign
# signature (.sig/.pem are published) can follow if the threat model needs it.
grep " $ASSET\$" "$SUMS" > expected.txt || { echo "FAIL: $ASSET not listed in $SUMS" >&2; exit 1; }
shasum -a 512 -c expected.txt

mkdir unpacked && tar -xzf "$ASSET" -C unpacked
NAME="caddy-$CADDY_VER-darwin-x86_64"
STAGE="$WORK/stage/$NAME"
mkdir -p "$STAGE/LICENSES"
cp unpacked/caddy "$STAGE/caddy"
cp unpacked/LICENSE "$STAGE/LICENSES/caddy.txt"
{
  echo "caddy $CADDY_VER"
  echo "arch x86_64"
  echo "source $BASE/$ASSET (official build, not modified)"
  echo "sha512 $(cut -d' ' -f1 expected.txt)"
  echo "mirrored $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
