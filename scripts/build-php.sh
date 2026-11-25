#!/bin/bash
# Build static PHP (cli + fpm) with static-php-cli, plus xdebug/pcov as .so files, and package it
# for Devid: on macOS for the runner's arch, on Linux for x86_64 with glibc (Devid D-057).
#   PHP_VER=8.4 scripts/build-php.sh      -> dist/php-8.4.x-<os>-<arch>.tar.gz (os: darwin or linux)
# The archive root holds php, php-fpm, modules/*.so, LICENSES/ and BUILDINFO, the layout
# `devid php install --from <dir>` expects.
#   REUSE_PHP=1 PHP_VER=8.4 scripts/build-php.sh   -> no build, no archive: keep the build root's
#   PHP 8.4 if it has one (a restored release cache) and extract its source, for build-ext.sh
set -euo pipefail

: "${PHP_VER:?set PHP_VER, e.g. 8.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"      # spc, downloads, source, buildroot (cacheable)
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin or linux

# mysqli (CodeIgniter 4, WordPress), readline (tinker, php -a) and soap: Devid D-022.
EXT="bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,readline,redis,session,simplexml,soap,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib"
# Loaded on demand as .so files (Devid D-008), not compiled in.
SHARED="xdebug,pcov"
# Sources spc downloads from these URLs instead of its own (spc download --custom-url). Pin a
# stable Xdebug; spc's default source picked an alpha.
CUSTOM_URLS=("xdebug:https://pecl.php.net/get/xdebug-3.5.3.tgz")
# PHP 8.6 (Devid D-062) is newer than static-php-cli 2.8.5 and than the stable releases of three
# sources, so it gets the first versions that build against it. Drop each one once its project
# releases 8.6 support.
if [ "$PHP_VER" = 8.6 ]; then
  CUSTOM_URLS=(
    # Xdebug 3.5 refuses PHP 8.6. 3.6.0alpha1 is a GitHub tag only, not on PECL.
    "xdebug:https://github.com/xdebug/xdebug/archive/refs/tags/3.6.0alpha1.tar.gz"
    # phpredis is compiled in; 6.3.0 does not build (8.6 passes the session save_path as a zend_string).
    "redis:https://pecl.php.net/get/redis-6.4.0RC1.tgz"
    # pcov 1.0.12 uses the INI_* macros 8.6 removed; the fix is merged (krakjoe/pcov#134), not released.
    "pcov:https://github.com/krakjoe/pcov/archive/c96a5742073e1c42e1d519f5b64bcfce28b1c644.tar.gz"
  )
fi
# Compiled-in ini paths must not point at Homebrew's /usr/local/etc/php; Devid sets PHPRC anyway.
INI_DIR=/opt/devid/etc/php
# Linux (Devid Phase 12 L1): glibc, so the .so files load (a static musl PHP cannot load any), and
# 2.17, so every distro since 2014 runs it. The arch is spelled out: zig's "native" builds for the
# build machine's CPU, and such a PHP died with SIGILL on older CPUs.
GLIBC_MIN=2.17

mkdir -p "$WORK" "$DIST"
"$ROOT/scripts/fetch-spc.sh" "$WORK"
cd "$WORK"

case "$OS" in
  darwin)
    # Keep Homebrew out of the build: no pkg-config paths, and SDKROOT makes clang/ld skip
    # /usr/local/include and /usr/local/lib (Homebrew's openssl headers once broke the link).
    # On Apple silicon Homebrew is in /opt/homebrew, which clang never searches.
    unset PKG_CONFIG_PATH
    export SDKROOT="$(xcrun --show-sdk-path)"
    # Build for the oldest macOS Devid supports, whatever the CI runner's version is.
    export MACOSX_DEPLOYMENT_TARGET=12.0
    ;;
  linux)
    [ "$ARCH" = x86_64 ] || { echo "FAIL: Linux builds are x86_64 only for now (Devid D-057)" >&2; exit 1; }
    unset PKG_CONFIG_PATH
    export SPC_TARGET="x86_64-linux-gnu.$GLIBC_MIN"   # spc builds with zig; `doctor --auto-fix` installs it
    ;;
  *) echo "FAIL: unsupported OS $OS" >&2; exit 1 ;;
esac

if [ "$PHP_VER" = 8.6 ]; then
  # spc's configure command for PHP (its config/env.ini; the environment overrides it), with the two
  # fixes spc's unreleased v3 branch makes for 8.6 (crazywhalecc/static-php-cli#1226): 8.6 rejects
  # --with-pic (passed on Linux) in favour of --enable-pic, and C++ sources include <locale> first,
  # because php.h defines vsnprintf as ap_php_vsnprintf, which breaks libc++'s <locale> in ext/intl.
  # CXXFLAGS keeps configure's default -g -O2.
  case "$OS" in
    darwin) cfg="--enable-shared=no --enable-static=yes" micro=macos_iconv_84 ;;
    linux) cfg="--disable-shared --enable-static --enable-pic" micro=disable_huge_page_84 ;;
  esac
  export SPC_CMD_PREFIX_PHP_CONFIGURE="./configure --prefix= --with-valgrind=no $cfg --disable-all --disable-phpdbg 'CXXFLAGS=-g -O2 -include locale'"
  # spc applies phpmicro's patches to php-src on every build (SPC_MICRO_PATCHES), each in its newest
  # version up to the PHP version. Its version list ends at 8.5, so for 8.6 it took the 8.0 patches,
  # which do not apply. 8.6 gets by name what 8.5 gets (the 8.4 versions apply to 8.6 as they are),
  # without cli_checks, which only matters for the micro SAPI.
  export SPC_MICRO_PATCHES="$micro"
fi

./spc doctor --auto-fix

# Catalog checks of a recipe (catalog.yml) need a PHP to build and load extensions against, not a
# new one: the release cache holds the PHP that last shipped, and building it again took 12 to 38
# minutes per job. Its source comes back from the cached download (php-src recipes copy ext/<name>).
if [ "${REUSE_PHP:-}" = 1 ] && [ -x buildroot/bin/php ] && [ -x buildroot/bin/php-fpm ] && [ -f buildroot/modules/xdebug.so ]; then
  FULL="$(buildroot/bin/php -n -r 'echo PHP_VERSION;')"
  if [ "${FULL%.*}" = "$PHP_VER" ]; then
    ./spc extract php-src --source-only
    src="$(sed -n 's/^#define PHP_VERSION "\(.*\)"$/\1/p' source/php-src/main/php_version.h)"
    [ "$src" = "$FULL" ] || { echo "FAIL: the cached download holds php-src $src, the build root PHP $FULL" >&2; exit 1; }
    echo "Reusing PHP $FULL from the build root (REUSE_PHP=1); nothing built, nothing packaged"
    exit 0
  fi
  echo "The build root holds PHP $FULL, not $PHP_VER: building it"
fi

custom=()
for u in "${CUSTOM_URLS[@]}"; do custom+=(--custom-url="$u"); done
./spc download --with-php="$PHP_VER" --for-extensions="$EXT,$SHARED" \
  "${custom[@]}" --ignore-cache-sources=php-src,xdebug --retry=3
if ! ./spc build "$EXT" --build-cli --build-fpm --build-shared="$SHARED" \
  --with-config-file-path="$INI_DIR" --with-config-file-scan-dir="$INI_DIR/conf.d"; then
  # spc names only the command that failed; the compiler's messages are in its shell log.
  echo "--- errors in spc's shell log (log/spc.shell.log)" >&2
  grep -n -E 'error:|Error [0-9]+|undefined reference|ld(\.lld)?: ' log/spc.shell.log | tail -40 >&2 || true
  echo "--- the end of spc's shell log" >&2
  tail -n 60 log/spc.shell.log >&2 || true
  exit 1
fi

FULL="$(buildroot/bin/php -n -r 'echo PHP_VERSION;')"
NAME="php-$FULL-$OS-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/modules"
cp buildroot/bin/php buildroot/bin/php-fpm "$STAGE/"
cp buildroot/modules/xdebug.so buildroot/modules/pcov.so "$STAGE/modules/"
./spc dump-license --for-extensions="$EXT,$SHARED" --dump-dir="$STAGE/LICENSES"

# Checks that must hold for every shipped build. Capture output first: with pipefail,
# `cmd | grep -q` fails when grep exits early and cmd gets SIGPIPE, which made these checks
# flaky in CI and could hide a /usr/local link.
if [ "$OS" = darwin ]; then
  links="$(otool -L "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so)"
  if grep -qE '/usr/local|/opt/homebrew' <<<"$links"; then
    echo "FAIL: links Homebrew (/usr/local or /opt/homebrew) libraries" >&2; echo "$links" >&2; exit 1
  fi
else
  # spc links with a runpath into the build root; nothing there is needed at run time (glibc only),
  # and build paths must not ship, as with the rpaths build-ext.sh drops on macOS.
  for f in "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so; do patchelf --remove-rpath "$f"; done
  "$ROOT/scripts/check-linux.sh" "$GLIBC_MIN" "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so
  # Older CPUs: QEMU's Nehalem (x86-64-v2) is the oldest these builds promise.
  qemu="$(qemu-x86_64 -cpu Nehalem "$STAGE/php" -n -d zend_extension="$STAGE/modules/xdebug.so" -v 2>&1)" ||
    { echo "FAIL: php does not run on a Nehalem CPU: $qemu" >&2; exit 1; }
  qemu="$(qemu-x86_64 -cpu Nehalem "$STAGE/php-fpm" -n -v 2>&1)" ||
    { echo "FAIL: php-fpm does not run on a Nehalem CPU: $qemu" >&2; exit 1; }
fi
version="$("$STAGE/php" -n -d zend_extension="$STAGE/modules/xdebug.so" -v)"
grep -q Xdebug <<<"$version" || { echo "FAIL: xdebug.so does not load" >&2; exit 1; }
version="$("$STAGE/php-fpm" -n -d zend_extension="$STAGE/modules/xdebug.so" -m)"
grep -qx Xdebug <<<"$version" || { echo "FAIL: xdebug.so does not load in php-fpm" >&2; exit 1; }
for bin in php php-fpm; do
  version="$("$STAGE/$bin" -n -d extension="$STAGE/modules/pcov.so" -m)"
  grep -qx pcov <<<"$version" || { echo "FAIL: pcov.so does not load in $bin" >&2; exit 1; }
done
modules="$("$STAGE/php" -n -m)"
for ext in pdo_pgsql pdo_sqlite intl gd redis sodium zip bcmath mysqli readline soap; do
  grep -qx "$ext" <<<"$modules" || { echo "FAIL: missing extension $ext" >&2; exit 1; }
done

if [ "$OS" = darwin ]; then
  codesign --force --sign - "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so   # ad-hoc (D-010)
  min="macos_min $MACOSX_DEPLOYMENT_TARGET" host="$(sw_vers -productVersion)"
else
  zig="$(find "$WORK/pkgroot" -type f -name zig -perm -u+x | head -1)"
  min="glibc_min $GLIBC_MIN ($SPC_TARGET, zig $("$zig" version))" host="$(. /etc/os-release && echo "$PRETTY_NAME")"
fi
# The versions that were built, as the extensions report them (8.6 pins its own, see CUSTOM_URLS).
xdebug="$("$STAGE/php" -n -d zend_extension="$STAGE/modules/xdebug.so" -r 'echo phpversion("xdebug");')"
pcov="$("$STAGE/php" -n -d extension="$STAGE/modules/pcov.so" -r 'echo phpversion("pcov");')"
redis="$("$STAGE/php" -n -r 'echo phpversion("redis");')"
{
  echo "php $FULL"
  echo "arch $ARCH"
  echo "$min"
  echo "static-php-cli $(./spc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  echo "extensions $EXT"
  echo "shared $SHARED (xdebug $xdebug, pcov $pcov)"
  echo "redis $redis"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $host"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
