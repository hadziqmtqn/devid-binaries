#!/bin/bash
# Build PostgreSQL from source for Devid (D-058), since postgresql.org publishes no macOS or Linux
# binaries; on macOS for the runner's arch, on Linux for x86_64 with glibc 2.17 and later.
#   SERIES=17 scripts/build-postgres.sh -> dist/postgresql-<ver>-<os>-<arch>.tar.gz
# The archive is relocatable: bin/ (server and clients), lib/ (libpq and the contrib modules),
# share/ (time zones and extension scripts), include/ (to build extensions such as pgvector with
# its pg_config), LICENSES/ and BUILDINFO.
#
# OpenSSL 3.5 is built here and linked statically, without atexit, its thread pool and QUIC: libpq
# refuses to link a library that can call exit() or pthread_exit(). macOS uses its own zlib and
# libedit (/usr/lib). Linux builds with static-php-cli's zig toolchain for glibc 2.17, as PHP does,
# with zlib, libedit and ncurses from static-php-cli, so the archive needs only glibc. No ICU (the
# libc and builtin collation providers remain), no uuid-ossp (gen_random_uuid() is built in), no
# LLVM JIT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIES="${SERIES:?set SERIES, e.g. 17}"
VER="$(python3 "$ROOT/scripts/db.py" version postgresql "$SERIES")"
WORK="${WORK:-$ROOT/work}"
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin or linux
PREFIX=/devid-postgresql   # only a placeholder: everything is installed under DESTDIR and moved
GLIBC_MIN=2.17
SRC_DIR="$WORK/postgresql/src"
mkdir -p "$SRC_DIR" "$DIST"
unset PKG_CONFIG_PATH

# Static OpenSSL, built once per version and target: build_openssl <Configure target> <openssldir> [flags]
read -r OSSL_VER OSSL_URL OSSL_SHA <<<"$(python3 "$ROOT/scripts/db.py" source openssl)"
DEPS="$WORK/postgresql/deps-openssl-$OSSL_VER-$OS-$ARCH"
build_openssl() {
  [ -f "$DEPS/lib/libssl.a" ] && return 0
  (
    cd "$SRC_DIR"
    [ -f "openssl-$OSSL_VER.tar.gz" ] || curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "openssl-$OSSL_VER.tar.gz" "$OSSL_URL"
    echo "$OSSL_SHA  openssl-$OSSL_VER.tar.gz" | shasum -a 256 -c -
    rm -rf "openssl-$OSSL_VER" && tar xzf "openssl-$OSSL_VER.tar.gz" && cd "openssl-$OSSL_VER"
    CC="$CC" ./Configure "$1" no-shared no-tests no-docs no-apps no-atexit no-thread-pool no-quic \
      --prefix="$DEPS" --libdir=lib --openssldir="$2" "${@:3}" > ../openssl-configure.log
    make -j"$JOBS" > ../openssl-make.log 2>&1 || { tail -30 ../openssl-make.log >&2; exit 1; }
    make install_sw > /dev/null
    cp LICENSE.txt "$DEPS/LICENSE.txt"
  )
}

if [ "$OS" = darwin ]; then
  export SDKROOT="$(xcrun --show-sdk-path)"
  export MACOSX_DEPLOYMENT_TARGET=12.0
  JOBS="$(sysctl -n hw.ncpu)"
  CC=cc
  build_openssl "darwin64-$ARCH-cc" /private/etc/ssl "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
  EXTRA=(--with-libedit-preferred)   # macOS's own libedit, through <editline/readline.h>
else
  JOBS="$(nproc)"
  export SPC_TARGET="x86_64-linux-gnu.$GLIBC_MIN"   # as build-php.sh; `doctor --auto-fix` installs zig
  "$ROOT/scripts/fetch-spc.sh" "$WORK"
  (cd "$WORK" && ./spc doctor --auto-fix && ./spc download zlib,libedit,ncurses --retry=3 &&
    ./spc build:libs zlib,libedit,ncurses)
  BR="$WORK/buildroot"
  zig="$(find "$WORK/pkgroot" -type f -name zig -perm -u+x | head -1)"
  [ -n "$zig" ] || { echo "FAIL: no zig under $WORK/pkgroot" >&2; exit 1; }
  # A wrapper, since configure and make take CC as one word.
  cat > "$WORK/postgresql/zigcc" <<EOF
#!/bin/sh
exec "$zig" cc -target $SPC_TARGET "\$@"
EOF
  chmod +x "$WORK/postgresql/zigcc"
  CC="$WORK/postgresql/zigcc"
  build_openssl linux-x86_64 /usr/lib/ssl   # Debian's and Ubuntu's OpenSSL directory
  # -s: zig cc emits DWARF by default (postgres was 64 MB); the linker drops it and the static
  # symbol table, and keeps the dynamic symbols that modules bind to.
  CPPFLAGS="-I$DEPS/include -I$BR/include" LDFLAGS="-L$DEPS/lib -L$BR/lib -s"
  # Static archives: libedit needs ncurses' terminfo, which static-php-cli may build wide or not.
  ncurses=ncurses; [ -f "$BR/lib/libncursesw.a" ] && ncurses=ncursesw
  EXTRA=(--with-libedit-preferred LIBS="-l$ncurses")
fi

cd "$SRC_DIR"
TARBALL="postgresql-$VER.tar.bz2"
BASE="https://ftp.postgresql.org/pub/source/v$VER"
if [ ! -f "$TARBALL" ]; then
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$TARBALL" "$BASE/$TARBALL"
fi
# shortcut: trusts the .sha256 file next to the source over HTTPS, as mirror-caddy.sh does.
SHA="$(curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$BASE/$TARBALL.sha256" | awk '{print $1}')"
echo "$SHA  $TARBALL" | shasum -a 256 -c -
rm -rf "postgresql-$VER" && tar xjf "$TARBALL"
cd "postgresql-$VER"

# Linux links every binary and module with the runpath $ORIGIN/../lib, which from bin/ and from lib/
# alike is lib/, where libpq is; make's $$ is a $, and PostgreSQL quotes it for the shell. Setting
# it afterwards with patchelf gave an initdb that ran under QEMU but crashed at once on the runner.
if [ "$OS" = darwin ]; then RPATH=(--disable-rpath) MAKE_RPATH=(); else RPATH=() MAKE_RPATH=('rpathdir=$$ORIGIN/../lib'); fi
./configure CC="$CC" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" CFLAGS="-O2" \
  --prefix="$PREFIX" "${RPATH[@]+"${RPATH[@]}"}" --with-openssl --with-zlib --without-icu --without-llvm \
  "${EXTRA[@]}" > ../configure-$VER.log
grep -q '^#define USE_OPENSSL 1' src/include/pg_config.h || { echo "FAIL: built without OpenSSL" >&2; exit 1; }
make -j"$JOBS" "${MAKE_RPATH[@]+"${MAKE_RPATH[@]}"}" world-bin > ../make-$VER.log 2>&1 || { tail -40 ../make-$VER.log >&2; exit 1; }
rm -rf "$WORK/postgresql/destdir"
make "${MAKE_RPATH[@]+"${MAKE_RPATH[@]}"}" install-world-bin DESTDIR="$WORK/postgresql/destdir" > /dev/null

NAME="postgresql-$VER-$OS-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/LICENSES"
cp -R "$WORK/postgresql/destdir$PREFIX"/{bin,lib,share,include} "$STAGE/"
rm -rf "$STAGE/lib/pkgconfig"
rm -f "$STAGE"/lib/*.a
cp COPYRIGHT "$STAGE/LICENSES/postgresql.txt"
cp "$DEPS/LICENSE.txt" "$STAGE/LICENSES/openssl.txt"

# Binaries find share/ and lib/ relative to themselves; only the links to libpq (and ecpg's
# libraries) carry the build prefix. Point them next to the binary instead.
if [ "$OS" = darwin ]; then
  find "$STAGE" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$STAGE/lib" "$f")"
    changed=0
    case "$f" in *.dylib) install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null; changed=1 ;; esac
    while read -r dep; do
      install_name_tool -change "$dep" "@loader_path/$rel/$(basename "$dep")" "$f" 2>/dev/null
      changed=1
    done < <(otool -L "$f" | sed 1d | awk '{print $1}' | grep "^$PREFIX/lib/" || true)
    [ "$changed" = 1 ] && codesign --force --sign - "$f" 2>/dev/null   # ad-hoc (Devid D-010)
    links="$(otool -L "$f" | sed 1d)"
    if grep -qE "/usr/local|/opt/homebrew|$PREFIX" <<<"$links"; then
      echo "FAIL: $f links outside the archive and the system" >&2; echo "$links" >&2; exit 1
    fi
  done
  strip -x "$STAGE"/bin/* 2>/dev/null || true
  for f in "$STAGE"/bin/*; do file -b "$f" | grep -q Mach-O && codesign --force --sign - "$f"; done
  min="macos_min $MACOSX_DEPLOYMENT_TARGET" host="macOS $(sw_vers -productVersion)"
else
  bundled='libpq\.so\.5|libecpg\.so\.6|libecpg_compat\.so\.3|libpgtypes\.so\.3'
  fail=0
  while read -r f; do
    file -b "$f" | grep -q ELF || continue
    needed="$(objdump -p "$f" | awk '/NEEDED/ {print $2}')"
    runpath="$(objdump -p "$f" | awk '/RUNPATH|RPATH/ {print $2}')"
    if [ -n "$runpath" ] && [ "$runpath" != '$ORIGIN/../lib' ]; then
      echo "FAIL: $f has the runpath $runpath" >&2; fail=1
    fi
    if grep -qE "^($bundled)$" <<<"$needed" && [ -z "$runpath" ]; then
      echo "FAIL: $f needs libpq but has no runpath" >&2; fail=1
    fi
    other="$(grep -vxE "lib(c|m|dl|pthread|rt|util|resolv)\.so\.[0-9]+|ld-linux-x86-64\.so\.2|$bundled" <<<"$needed" || true)"
    [ -z "$other" ] || { echo "FAIL: $f links libraries outside glibc: $(tr '\n' ' ' <<<"$other")" >&2; fail=1; }
    newest="$(objdump -T "$f" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"
    if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MIN" | sort -V | tail -1)" != "$GLIBC_MIN" ]; then
      echo "FAIL: $f needs glibc $newest, newer than $GLIBC_MIN" >&2; fail=1
    fi
  done < <(find "$STAGE/bin" "$STAGE/lib" -type f)
  [ "$fail" = 0 ] || exit 1
  # An older CPU (Devid Phase 12 L1): the server and psql must at least start there.
  for b in postgres psql initdb; do
    out="$(qemu-x86_64 -cpu Nehalem "$STAGE/bin/$b" --version 2>&1)" ||
      { echo "FAIL: $b does not run on a Nehalem CPU: $out" >&2; exit 1; }
  done
  (cd "$WORK" && ./spc dump-license --for-libs=zlib,libedit,ncurses --without-php --dump-dir="$STAGE/LICENSES/libs")
  min="glibc_min $GLIBC_MIN ($SPC_TARGET, zig $("$zig" version))" host="$(. /etc/os-release && echo "$PRETTY_NAME")"
fi

info="$("$STAGE/bin/postgres" --version)"
grep -q "(PostgreSQL) $VER" <<<"$info" || { echo "FAIL: postgres --version: $info" >&2; exit 1; }
{
  echo "postgresql $VER"
  echo "os $OS"
  echo "arch $ARCH"
  echo "$min"
  echo "source $BASE/$TARBALL"
  echo "sha256 $SHA"
  echo "configure $("$STAGE/bin/pg_config" --configure | sed "s|$WORK|<work>|g")"
  echo "openssl $OSSL_VER (static)"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $host"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
if [ "${SMOKE:-1}" = 1 ]; then "$ROOT/scripts/db-smoke.sh" "$DIST/$NAME.tar.gz"; fi
