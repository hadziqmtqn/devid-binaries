#!/bin/bash
# Mirror the official MySQL Community Server build for Devid (D-058), without rebuilding it: verify
# the archive against the SHA-256 pinned in db/versions.json, then repackage the files a local server
# needs, unmodified.
#   SERIES=9.7 OS=darwin ARCH=arm64 scripts/mirror-mysql.sh -> dist/mysql-<ver>-<os>-<arch>.tar.gz
#   OS is darwin (default) or linux, ARCH x86_64 (default) or arm64 (macOS only).
#
# Left out: mysqld-debug and the debug plugins, the MeCab parser and its 120 MB dictionary, static
# libraries, headers, man pages and mysql_config. On Linux, libaio and libnuma are built from source
# into lib/private (the binaries' runpath): mysqld needs both, and Ubuntu 24.04 ships libaio only
# as libaio.so.1t64.
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
  # Build libaio and libnuma (LGPL-2.1) for lib/private, where mysqld's runpath looks first.
  for lib in libaio numactl; do
    read -r v url sha <<<"$(python3 "$ROOT/scripts/db.py" source "$lib")"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$lib.tar.gz" "$url"
    echo "$sha  $lib.tar.gz" | shasum -a 256 -c -
    mkdir "$lib-src" && tar -xzf "$lib.tar.gz" -C "$lib-src" --strip-components=1
    echo "$lib $v $url" >> bundled.txt
  done
  # With static-php-cli's zig for glibc 2.17, as PHP: the runner's own glibc (2.39) would make
  # them need symbols that Ubuntu 22.04 and Debian 12 lack (__isoc23_strtol and the like).
  "$ROOT/scripts/fetch-spc.sh" "$ROOT/work"
  (cd "$ROOT/work" && SPC_TARGET="x86_64-linux-gnu.2.17" ./spc doctor --auto-fix)
  zig="$(find "$ROOT/work/pkgroot" -type f -name zig -perm -u+x | head -1)"
  [ -n "$zig" ] || { echo "FAIL: no zig under $ROOT/work/pkgroot" >&2; exit 1; }
  printf '#!/bin/sh\nexec "%s" cc -target x86_64-linux-gnu.2.17 "$@"\n' "$zig" > zigcc && chmod +x zigcc
  # libaio's Makefile names its PIC objects *.os, which zig cc does not take for objects: build the
  # library from the same sources as *.o (make's built-in rule, with the Makefile's -fPIC).
  objs="$(sed -n 's/^libaio_srcs [:+]= //p' libaio-src/src/Makefile | tr ' ' '\n' | sed -n 's/\.c$/.o/p' | paste -sd' ' -)"
  [ -n "$objs" ] || { echo "FAIL: no libaio_srcs in libaio's Makefile" >&2; exit 1; }
  make -C libaio-src/src -s CC="$WORK/zigcc" libaio_sobjs="$objs" > /dev/null
  cp libaio-src/src/libaio.so.1.0.* "$STAGE/lib/private/libaio.so.1"
  cp libaio-src/COPYING "$STAGE/LICENSES/libaio.txt"
  # libnuma without libtool, which does not link with zig, and without its -Wl,-init/-fini, which
  # zig's linker refuses (numa_init and numa_fini are already a constructor and a destructor).
  srcs="$(sed -n 's/^libnuma_la_SOURCES = //p' numactl-src/Makefile.am | tr ' ' '\n' | grep '\.c$' || true)"
  [ -n "$srcs" ] || { echo "FAIL: no libnuma_la_SOURCES in numactl's Makefile.am" >&2; exit 1; }
  (
    cd numactl-src && ./configure --quiet CC="$WORK/zigcc" > /dev/null
    for f in $srcs; do "$WORK/zigcc" -O2 -fPIC -Wall -DHAVE_CONFIG_H -I. -c "$f" -o "${f%.c}.pic.o"; done
    "$WORK/zigcc" -shared -Wl,--version-script,versions.ldscript -Wl,-soname,libnuma.so.1 -o libnuma.so.1 ./*.pic.o
  )
  cp numactl-src/libnuma.so.1 "$STAGE/lib/private/libnuma.so.1"
  cp numactl-src/LICENSE.LGPL2.1 "$STAGE/LICENSES/libnuma.txt"
  # Both may need only glibc, no newer than MySQL's own floor.
  "$ROOT/scripts/check-linux.sh" 2.28 "$STAGE/lib/private/libaio.so.1" "$STAGE/lib/private/libnuma.so.1"
  # Every library mysqld and the clients need must be in the archive or in a stock Ubuntu 22.04
  # or Debian 12 (glibc, libstdc++, libgcc, ncurses 6).
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
