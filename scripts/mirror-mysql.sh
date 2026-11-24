#!/bin/bash
# Mirror the official MySQL Community Server build for Devid (D-058), without rebuilding it: verify
# the archive against the SHA-256 pinned in db/versions.json, then repackage the files a local server
# needs, unmodified.
#   SERIES=9.7 OS=darwin ARCH=arm64 scripts/mirror-mysql.sh -> dist/mysql-<ver>-<os>-<arch>.tar.gz
#   OS is darwin (default) or linux, ARCH x86_64 (default) or arm64 (macOS only). A Linux archive
#   is made on Linux, which builds the libraries it bundles.
#
# Left out: mysqld-debug and the debug plugins, the MeCab parser and its 120 MB dictionary, static
# libraries, headers, man pages and mysql_config. On Linux, scripts/db-linux-libs.sh builds libaio
# and libnuma (for mysqld; Ubuntu 24.04 ships libaio only as libaio.so.1t64) and ncurses 6 (for the
# mysql client; Arch has only libncursesw) into lib/private, the binaries' runpath.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIES="${SERIES:?set SERIES, e.g. 9.7}"
OS="${OS:-darwin}"
ARCH="${ARCH:-x86_64}"
VER="$(python3 "$ROOT/scripts/db.py" version mysql "$SERIES" "$OS-$ARCH")"
SHA="$(python3 "$ROOT/scripts/db.py" mysql-sha256 "$SERIES" "$OS-$ARCH")"
WORK="${WORK:-$ROOT/work}/mysql/$VER-$OS-$ARCH"
DIST="${DIST:-$ROOT/dist}"
case "$OS-$ARCH" in
  darwin-x86_64) ASSET="mysql-$VER-macos15-x86_64.tar.gz" ;;
  darwin-arm64) ASSET="mysql-$VER-macos15-arm64.tar.gz" ;;
  linux-x86_64) ASSET="mysql-$VER-linux-glibc2.28-x86_64-minimal.tar.xz" ;;
  *) echo "unknown OS-ARCH $OS-$ARCH" >&2; exit 1 ;;
esac
URL="https://cdn.mysql.com/Downloads/MySQL-$SERIES/$ASSET"

rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
cd "$WORK"
# Oracle's CDN keeps recent releases; older ones move to its archive.
if ! curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$ASSET" "$URL"; then
  URL="https://downloads.mysql.com/archives/get/p/23/file/$ASSET"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$ASSET" "$URL"
fi
echo "$SHA  $ASSET" | shasum -a 256 -c -
mkdir unpacked && tar -xf "$ASSET" -C unpacked
SRC="$(echo unpacked/mysql-*)"
[ -x "$SRC/bin/mysqld" ] && [ -f "$SRC/LICENSE" ] || { echo "FAIL: $ASSET lacks bin/mysqld or LICENSE" >&2; exit 1; }

NAME="mysql-$VER-$OS-$ARCH"
STAGE="$WORK/stage"
mkdir -p "$STAGE/LICENSES"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/share" "$STAGE/"
[ -d "$SRC/docs" ] && cp -R "$SRC/docs" "$STAGE/"   # INFO_BIN / INFO_SRC: how Oracle built it
cp "$SRC/LICENSE" "$STAGE/LICENSES/mysql.txt"
cp "$SRC/README" "$STAGE/LICENSES/mysql-README.txt"
rm -rf "$STAGE/bin/mysqld-debug" "$STAGE/bin/mysql_config" "$STAGE/lib/plugin/debug" "$STAGE/lib/mecab" \
  "$STAGE/lib/plugin/libpluginmecab.so" "$STAGE/lib/pkgconfig" "$STAGE/share/aclocal"
rm -f "$STAGE"/lib/*.a

# Capture first: `cmd | grep -q` under pipefail fails on SIGPIPE (see build-php.sh).
if [ "$OS" = darwin ]; then
  for f in "$STAGE"/bin/* "$STAGE"/lib/*.dylib "$STAGE"/lib/plugin/*.so; do
    file -b "$f" | grep -q Mach-O || continue
    # Dependencies only: a dylib's own install name (Oracle's /usr/local/mysql/lib/...) loads nothing.
    id="$(otool -D "$f" | sed -n 2p)"
    links="$(otool -L "$f" | sed 1d | grep -vF "${id:-//none//}" || true)"
    if grep -qE '/usr/local|/opt/homebrew' <<<"$links"; then
      echo "FAIL: $f links libraries from /usr/local or /opt/homebrew" >&2; echo "$links" >&2; exit 1
    fi
  done
  min="macos_min $(vtool -show-build "$STAGE/bin/mysqld" 2>/dev/null | awk '/minos/ {print $2; exit}')"
else
  # libaio and libnuma (LGPL-2.1) for mysqld, ncurses 6 (MIT) for the mysql client, into lib/private,
  # where the binaries' runpath looks first.
  for lib in libaio libnuma ncurses; do
    LICENSES_DIR="$STAGE/LICENSES" "$ROOT/scripts/db-linux-libs.sh" "$lib" "$STAGE/lib/private" | tail -1 >> bundled.txt
  done
  # Every library mysqld and the clients need must be in the archive or in every supported
  # distribution (glibc, libstdc++, libgcc).
  missing="$(cd "$STAGE" && for f in bin/mysqld bin/mysql bin/mysqldump bin/mysqladmin; do ldd "$f"; done | grep 'not found' || true)"
  [ -z "$missing" ] || { echo "FAIL: unresolved libraries: $missing" >&2; exit 1; }
  min="glibc_min 2.28; bundles $(cut -d' ' -f1,2 bundled.txt | paste -sd, -)"
fi

{
  echo "mysql $VER"
  echo "os $OS"
  echo "arch $ARCH"
  echo "$min"
  echo "source $URL (official build; files not modified, a subset repackaged)"
  echo "sha256 $SHA"
  echo "mirrored $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
# On its own OS and arch, the archive must run a server (SMOKE=0 skips it, e.g. when mirroring
# for another platform).
if [ "${SMOKE:-1}" = 1 ] && [ "$OS" = "$(uname -s | tr '[:upper:]' '[:lower:]')" ] && [ "$ARCH" = "$(uname -m)" ]; then
  "$ROOT/scripts/db-smoke.sh" "$DIST/$NAME.tar.gz"
fi
