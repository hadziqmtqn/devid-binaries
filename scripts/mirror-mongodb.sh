#!/bin/bash
# Mirror the official MongoDB Community Server build for Devid (D-058), without rebuilding it:
# verify the archive against the SHA-256 in MongoDB's own full.json, then repackage mongod with its
# licenses, unmodified.
#   SERIES=9.0 OS=darwin ARCH=arm64 scripts/mirror-mongodb.sh -> dist/mongodb-<ver>-<os>-<arch>.tar.gz
#   OS is darwin (default) or linux, ARCH x86_64 (default) or arm64 (macOS only). A Linux archive
#   is made on Linux, which builds the libraries it bundles.
#
# Linux uses the Ubuntu 22.04 build. It links OpenSSL 3, which Arch replaced with OpenSSL 4, so
# scripts/db-linux-libs.sh builds libssl.so.3 and libcrypto.so.3 into lib/: run mongod with
# LD_LIBRARY_PATH=<archive>/lib (mongod has no runpath, and stays unmodified). libcurl 4 comes from
# the system; mongod needs its CURL_OPENSSL_4 symbols, which Ubuntu, Debian and Arch all have.
# MongoDB 5.0 and later need AVX on x86_64 (Sandy Bridge or newer), above the Nehalem floor of the
# rest of Devid's Linux runtime. Left out: mongos (sharding only) and
# install_compass. mongosh is a separate archive (mirror-mongosh.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIES="${SERIES:?set SERIES, e.g. 9.0}"
OS="${OS:-darwin}"
ARCH="${ARCH:-x86_64}"
VER="$(python3 "$ROOT/scripts/db.py" version mongodb "$SERIES")"
read -r URL SHA <<<"$(python3 "$ROOT/scripts/db.py" mongodb-asset "$VER" "$OS" "$ARCH")"
WORK="${WORK:-$ROOT/work}/mongodb/$VER-$OS-$ARCH"
DIST="${DIST:-$ROOT/dist}"
ASSET="$(basename "$URL")"

rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
cd "$WORK"
# shortcut: trusts MongoDB's full.json over HTTPS, as mirror-caddy.sh trusts Caddy's checksums file.
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$ASSET" "$URL"
echo "$SHA  $ASSET" | shasum -a 256 -c -
mkdir unpacked && tar -xzf "$ASSET" -C unpacked
SRC="$(echo unpacked/mongodb-*)"
[ -x "$SRC/bin/mongod" ] && [ -f "$SRC/LICENSE-Community.txt" ] ||
  { echo "FAIL: $ASSET lacks bin/mongod or LICENSE-Community.txt" >&2; exit 1; }

NAME="mongodb-$VER-$OS-$ARCH"
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/LICENSES"
cp "$SRC/bin/mongod" "$STAGE/bin/mongod"
cp "$SRC/LICENSE-Community.txt" "$STAGE/LICENSES/mongodb-sspl.txt"
for f in MPL-2 THIRD-PARTY-NOTICES README; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$STAGE/LICENSES/mongodb-$f.txt"
done

# Capture first: `cmd | grep -q` under pipefail fails on SIGPIPE (see build-php.sh).
if [ "$OS" = darwin ]; then
  links="$(otool -L "$STAGE/bin/mongod")"
  if grep -qE '/usr/local|/opt/homebrew' <<<"$links"; then
    echo "FAIL: mongod links libraries from /usr/local or /opt/homebrew" >&2; echo "$links" >&2; exit 1
  fi
  min="macos_min $(vtool -show-build "$STAGE/bin/mongod" 2>/dev/null | awk '/minos/ {print $2; exit}')"
else
  needed="$(objdump -p "$STAGE/bin/mongod" | awk '/NEEDED/ {print $2}' | paste -sd' ' -)"
  ossl="$(LICENSES_DIR="$STAGE/LICENSES" "$ROOT/scripts/db-linux-libs.sh" openssl "$STAGE/lib" | tail -1)"
  if [ "$(uname -s)" = Linux ]; then
    missing="$(LD_LIBRARY_PATH="$STAGE/lib" ldd "$STAGE/bin/mongod" | grep 'not found' || true)"
    [ -z "$missing" ] || { echo "FAIL: unresolved libraries: $missing" >&2; exit 1; }
  fi
  min="needs $needed; bundles ${ossl% *} in lib/ (run with LD_LIBRARY_PATH=<archive>/lib); cpu x86-64 with AVX"
fi

{
  echo "mongodb $VER"
  echo "os $OS"
  echo "arch $ARCH"
  echo "$min"
  echo "source $URL (official Community build, not modified)"
  echo "sha256 $SHA"
  echo "license SSPL-1.0"
  echo "mirrored $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
if [ "${SMOKE:-1}" = 1 ] && [ "$OS" = "$(uname -s | tr '[:upper:]' '[:lower:]')" ] && [ "$ARCH" = "$(uname -m)" ]; then
  "$ROOT/scripts/db-smoke.sh" "$DIST/$NAME.tar.gz"
fi
