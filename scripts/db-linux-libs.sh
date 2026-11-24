#!/bin/bash
# Shared libraries that the official MySQL and MongoDB builds need but some Linux distributions lack
# (Devid D-058), built with static-php-cli's zig for glibc 2.17 into a directory:
#   scripts/db-linux-libs.sh <libaio|libnuma|ncurses|openssl> <dest dir>
#     libaio   -> libaio.so.1            mysqld; Ubuntu 24.04 has only libaio.so.1t64
#     libnuma  -> libnuma.so.1           mysqld; not installed everywhere
#     ncurses  -> libncurses.so.6, libtinfo.so.6
#                                        the mysql client; Arch has only the wide-character libncursesw
#     openssl  -> libssl.so.3, libcrypto.so.3
#                                        mongod; Arch moved to OpenSSL 4 (libssl.so.4)
# Each library may need only glibc 2.17 or older, besides the others in <dest dir>. Its license goes
# to $LICENSES_DIR, and "<name> <version> <source URL>" to stdout.
set -euo pipefail
# Say where a command failed: callers keep only this script's last line of output.
trap 'echo "FAIL: db-linux-libs.sh ${NAME:-}: line $LINENO: $BASH_COMMAND" >&2' ERR
NAME="${1:?usage: db-linux-libs.sh <libaio|libnuma|ncurses|openssl> <dest dir>}"
DEST="$(mkdir -p "${2:?dest dir}" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LICENSES_DIR="${LICENSES_DIR:?set LICENSES_DIR}"
GLIBC_MIN=2.17
BUILD="$ROOT/work/db-linux-libs"
mkdir -p "$BUILD" "$LICENSES_DIR"

src="$NAME"; [ "$NAME" = libnuma ] && src=numactl
read -r VER URL SHA <<<"$(python3 "$ROOT/scripts/db.py" source "$src")"
# Built once per library and version (the MongoDB and MySQL jobs bundle the same ones per series).
CACHE="$BUILD/out/$NAME-$VER"
if [ -f "$CACHE/done" ]; then
  find "$CACHE" -maxdepth 1 -name 'lib*.so.*' -exec cp {} "$DEST/" \;
  cp "$CACHE/LICENSE" "$LICENSES_DIR/$NAME.txt"
  echo "$NAME $VER $URL"
  exit 0
fi

# zig from static-php-cli, as build-php.sh and build-postgres.sh use it.
"$ROOT/scripts/fetch-spc.sh" "$ROOT/work"
# Capture first: on a fresh runner pkgroot does not exist yet, and under pipefail a failing find
# would end the script here.
zig="$(find "$ROOT/work/pkgroot" -type f -name zig -perm -u+x 2>/dev/null | head -1 || true)"
if [ -z "$zig" ]; then
  (cd "$ROOT/work" && SPC_TARGET="x86_64-linux-gnu.$GLIBC_MIN" ./spc doctor --auto-fix)
  zig="$(find "$ROOT/work/pkgroot" -type f -name zig -perm -u+x | head -1 || true)"
fi
[ -n "$zig" ] || { echo "FAIL: no zig under $ROOT/work/pkgroot" >&2; exit 1; }
CC="$BUILD/zigcc"
printf '#!/bin/sh\nexec "%s" cc -target x86_64-linux-gnu.%s "$@"\n' "$zig" "$GLIBC_MIN" > "$CC"
chmod +x "$CC"

S="$BUILD/$src-$VER"
cd "$BUILD"
[ -f "$src-$VER.tar.gz" ] || curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$src-$VER.tar.gz" "$URL"
echo "$SHA  $src-$VER.tar.gz" | shasum -a 256 -c -
rm -rf "$S" && mkdir "$S" && tar -xzf "$src-$VER.tar.gz" -C "$S" --strip-components=1
cd "$S"

case "$NAME" in
  libaio)
    # Its Makefile names PIC objects *.os, which zig cc does not take for objects: same sources as *.o.
    objs="$(sed -n 's/^libaio_srcs [:+]= //p' src/Makefile | tr ' ' '\n' | sed -n 's/\.c$/.o/p' | paste -sd' ' -)"
    [ -n "$objs" ] || { echo "FAIL: no libaio_srcs in libaio's Makefile" >&2; exit 1; }
    make -C src -s CC="$CC" LDFLAGS=-s libaio_sobjs="$objs" > /dev/null
    cp src/libaio.so.1.0.* "$DEST/libaio.so.1"
    cp COPYING "$LICENSES_DIR/libaio.txt"
    FILES=(libaio.so.1)
    ;;
  libnuma)
    # Without libtool, which does not drive zig's link, and without -Wl,-init/-fini, which zig's
    # linker refuses (numa_init and numa_fini are already a constructor and a destructor).
    srcs="$(sed -n 's/^libnuma_la_SOURCES = //p' Makefile.am | tr ' ' '\n' | grep '\.c$' || true)"
    [ -n "$srcs" ] || { echo "FAIL: no libnuma_la_SOURCES in numactl's Makefile.am" >&2; exit 1; }
    ./configure --quiet CC="$CC" > /dev/null
    for f in $srcs; do "$CC" -O2 -fPIC -Wall -DHAVE_CONFIG_H -I. -c "$f" -o "${f%.c}.pic.o"; done
    "$CC" -shared -s -Wl,--version-script,versions.ldscript -Wl,-soname,libnuma.so.1 -o "$DEST/libnuma.so.1" ./*.pic.o
    cp LICENSE.LGPL2.1 "$LICENSES_DIR/libnuma.txt"
    FILES=(libnuma.so.1)
    ;;
  ncurses)
    # The narrow-character ABI 6 with a separate libtinfo, as Debian, Ubuntu and Oracle Linux build it,
    # reading the terminfo directories of all of them and of Arch.
    ./configure --quiet CC="$CC" CFLAGS=-O2 LDFLAGS=-s --with-shared --without-normal --without-debug \
      --without-cxx --without-cxx-binding --without-ada --without-progs --without-tests --without-manpages \
      --without-pkg-config --disable-db-install --with-termlib --disable-widec --with-abi-version=6 \
      --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
      --with-default-terminfo-dir=/usr/share/terminfo > /dev/null
    # zig's linker refuses ncurses' -Wl,...,-stats,-lc.
    sed -i 's/,-stats,-lc -o/ -o/' ncurses/Makefile
    make -s -C include > /dev/null && make -s -C ncurses libs > /dev/null
    cp lib/libncurses.so.6.* "$DEST/libncurses.so.6"
    cp lib/libtinfo.so.6.* "$DEST/libtinfo.so.6"
    cp COPYING "$LICENSES_DIR/ncurses.txt"
    FILES=(libncurses.so.6 libtinfo.so.6)
    ;;
  openssl)
    # OpenSSL 3.5 LTS, as build-postgres.sh links it statically; providers built in.
    CC="$CC" ./Configure linux-x86_64 shared no-tests no-docs no-apps no-module no-legacy \
      --openssldir=/etc/ssl --libdir=lib -s > /dev/null
    make -s -j"$(nproc)" build_libs > /dev/null
    cp libcrypto.so.3 libssl.so.3 "$DEST/"
    cp LICENSE.txt "$LICENSES_DIR/openssl.txt"
    FILES=(libcrypto.so.3 libssl.so.3)
    ;;
  *) echo "unknown library $NAME" >&2; exit 1 ;;
esac

# Each file: glibc's libraries and the other bundled ones only, glibc 2.17 at most, no runpath.
cd "$DEST"
bundled="$(ls | grep -E '^lib.*\.so\.[0-9]+$' | sed 's/\./\\./g' | paste -sd'|' -)"
fail=0
for f in "${FILES[@]}"; do
  needed="$(objdump -p "$f" | awk '/NEEDED/ {print $2}')"
  other="$(grep -vxE "lib(c|m|dl|pthread|rt|util|resolv)\.so\.[0-9]+|ld-linux-x86-64\.so\.2|$bundled" <<<"$needed" || true)"
  [ -z "$other" ] || { echo "FAIL: $f links libraries outside glibc: $(tr '\n' ' ' <<<"$other")" >&2; fail=1; }
  dyn="$(objdump -p "$f")"   # capture first: `cmd | grep -q` under pipefail fails on SIGPIPE
  if grep -qE 'RPATH|RUNPATH' <<<"$dyn"; then echo "FAIL: $f has a runpath" >&2; fail=1; fi
  newest="$(objdump -T "$f" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"
  if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MIN" | sort -V | tail -1)" != "$GLIBC_MIN" ]; then
    echo "FAIL: $f needs glibc $newest, newer than $GLIBC_MIN" >&2; fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
rm -rf "$CACHE" && mkdir -p "$CACHE"
cp "${FILES[@]}" "$CACHE/"
cp "$LICENSES_DIR/$NAME.txt" "$CACHE/LICENSE"
touch "$CACHE/done"
echo "$NAME $VER $URL"
