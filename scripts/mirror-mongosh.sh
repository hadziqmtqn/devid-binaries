#!/bin/bash
# Mirror the official mongosh build (MongoDB's shell, Apache-2.0) for Devid (D-058), without
# rebuilding it: verify it against the SHA-256 GitHub recorded for the release asset, then
# repackage it with its license.
#   OS=darwin ARCH=arm64 scripts/mirror-mongosh.sh -> dist/mongosh-<ver>-<os>-<arch>.tar.gz
#   OS is darwin (default) or linux, ARCH x86_64 (default) or arm64 (macOS only).
# Linux uses the build with its own OpenSSL (mongosh-<ver>-linux-x64.tgz).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="${OS:-darwin}"
ARCH="${ARCH:-x86_64}"
VER="$(python3 "$ROOT/scripts/db.py" version mongosh)"
WORK="${WORK:-$ROOT/work}/mongosh/$VER-$OS-$ARCH"
DIST="${DIST:-$ROOT/dist}"
TAG="v$VER"
case "$OS-$ARCH" in
  darwin-x86_64) ASSET="mongosh-$VER-darwin-x64.zip" ;;
  darwin-arm64) ASSET="mongosh-$VER-darwin-arm64.zip" ;;
  linux-x86_64) ASSET="mongosh-$VER-linux-x64.tgz" ;;
  *) echo "unknown OS-ARCH $OS-$ARCH" >&2; exit 1 ;;
esac
URL="https://github.com/mongodb-js/mongosh/releases/download/$TAG/$ASSET"

rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
cd "$WORK"
# shortcut: trusts GitHub's API over HTTPS, as mirror-mailpit.sh does.
DIGEST="$(python3 "$ROOT/scripts/upstream.py" --digest mongodb-js/mongosh "$TAG" "$ASSET")"
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$ASSET" "$URL"
echo "$DIGEST  $ASSET" | shasum -a 256 -c -
mkdir unpacked
case "$ASSET" in
  *.zip) (cd unpacked && unzip -q "../$ASSET") ;;
  *) tar -xzf "$ASSET" -C unpacked ;;
esac
SRC="$(echo unpacked/mongosh-*)"
[ -x "$SRC/bin/mongosh" ] && [ -f "$SRC/LICENSE-mongosh" ] ||
  { echo "FAIL: $ASSET lacks bin/mongosh or LICENSE-mongosh" >&2; ls -R unpacked | head -20 >&2; exit 1; }

NAME="mongosh-$VER-$OS-$ARCH"
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/LICENSES"
cp "$SRC/bin/mongosh" "$STAGE/bin/mongosh"
# Its bundled crypt library (Queryable Encryption), when the build has one.
for f in "$SRC"/bin/mongosh_crypt_v1.*; do [ -f "$f" ] && cp "$f" "$STAGE/bin/"; done
for f in "$SRC"/LICENSE-* "$SRC"/THIRD_PARTY_NOTICES*; do [ -f "$f" ] && cp "$f" "$STAGE/LICENSES/"; done

{
  echo "mongosh $VER"
  echo "os $OS"
  echo "arch $ARCH"
  echo "source $URL (official build, not modified)"
  echo "sha256 $DIGEST"
  echo "mirrored $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
if [ "${SMOKE:-1}" = 1 ] && [ "$OS" = "$(uname -s | tr '[:upper:]' '[:lower:]')" ] && [ "$ARCH" = "$(uname -m)" ]; then
  "$ROOT/scripts/db-smoke.sh" "$DIST/$NAME.tar.gz"
fi
