#!/bin/bash
# Mirror the official Mailpit release for Devid (no rebuild): verify it against the sha256 digest
# GitHub recorded when the asset was uploaded (Mailpit publishes no checksums file), then
# repackage it with its license.
#   OS=linux ARCH=x86_64 scripts/mirror-mailpit.sh   -> dist/mailpit-<ver>-<os>-<arch>.tar.gz (mailpit + LICENSES/ + BUILDINFO)
#   OS is darwin (default) or linux, ARCH x86_64 (default) or arm64 (macOS only for now, Devid D-057);
#   it runs on any OS, since nothing is built.
set -euo pipefail

MAILPIT_VER="${MAILPIT_VER:-$(python3 "$(dirname "$0")/upstream.py" mailpit)}"   # newest release unless pinned
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}/mailpit"
DIST="${DIST:-$ROOT/dist}"
TAG="v$MAILPIT_VER"
BASE="https://github.com/axllent/mailpit/releases/download/$TAG"
OS="${OS:-darwin}"
ARCH="${ARCH:-x86_64}"
case "$OS-$ARCH" in
  darwin-x86_64) ASSET="mailpit-darwin-amd64.tar.gz" ;;
  darwin-arm64) ASSET="mailpit-darwin-arm64.tar.gz" ;;
  linux-x86_64) ASSET="mailpit-linux-amd64.tar.gz" ;;
  *) echo "unknown OS-ARCH $OS-$ARCH" >&2; exit 1 ;;
esac

WORK="$WORK/$OS-$ARCH"
rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
cd "$WORK"
# shortcut: trusts GitHub's API over HTTPS, as mirror-caddy.sh trusts Caddy's checksums file;
# Mailpit signs nothing that could be checked instead.
DIGEST="$(python3 "$ROOT/scripts/upstream.py" --digest axllent/mailpit "$TAG" "$ASSET")"
curl -fsSLO "$BASE/$ASSET"
echo "$DIGEST  $ASSET" > expected.txt
shasum -a 256 -c expected.txt

mkdir unpacked && tar -xzf "$ASSET" -C unpacked
[ -f unpacked/mailpit ] && [ -f unpacked/LICENSE ] || { echo "FAIL: $ASSET lacks mailpit or LICENSE" >&2; exit 1; }
NAME="mailpit-$MAILPIT_VER-$OS-$ARCH"
STAGE="$WORK/stage/$NAME"
mkdir -p "$STAGE/LICENSES"
cp unpacked/mailpit "$STAGE/mailpit"
chmod 755 "$STAGE/mailpit"
cp unpacked/LICENSE "$STAGE/LICENSES/mailpit.txt"
{
  echo "mailpit $MAILPIT_VER"
  echo "os $OS"
  echo "arch $ARCH"
  echo "source $BASE/$ASSET (official build, not modified)"
  echo "sha256 $DIGEST"
  echo "mirrored $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
