#!/bin/bash
# Build static PHP (cli + fpm) for macOS with static-php-cli, plus xdebug/pcov as .so files,
# and package it for Devid.
#   PHP_VER=8.4 scripts/build-php.sh      -> dist/php-8.4.x-darwin-<arch>.tar.gz
# The archive root holds php, php-fpm, modules/*.so, LICENSES/ and BUILDINFO, the layout
# `devid php install --from <dir>` expects.
set -euo pipefail

: "${PHP_VER:?set PHP_VER, e.g. 8.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"      # spc, downloads, source, buildroot (cacheable)
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"

EXT="bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,redis,session,simplexml,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib"
# Loaded on demand as .so files (Devid D-008), not compiled in.
SHARED="xdebug,pcov"
# Pin a stable Xdebug; spc's default source picked an alpha.
XDEBUG_URL="https://pecl.php.net/get/xdebug-3.5.3.tgz"
# Compiled-in ini paths must not point at Homebrew's /usr/local/etc/php; Devid sets PHPRC anyway.
INI_DIR=/opt/devid/etc/php

mkdir -p "$WORK" "$DIST"
"$ROOT/scripts/fetch-spc.sh" "$WORK"
cd "$WORK"

# Keep Homebrew out of the build: no pkg-config paths, and SDKROOT makes clang/ld skip
# /usr/local/include and /usr/local/lib (Homebrew's openssl headers once broke the link).
unset PKG_CONFIG_PATH
export SDKROOT="$(xcrun --show-sdk-path)"
# Build for the oldest macOS Devid supports, whatever the CI runner's version is.
export MACOSX_DEPLOYMENT_TARGET=12.0

./spc doctor --auto-fix
./spc download --with-php="$PHP_VER" --for-extensions="$EXT,$SHARED" \
  --custom-url="xdebug:$XDEBUG_URL" --ignore-cache-sources=php-src,xdebug --retry=3
./spc build "$EXT" --build-cli --build-fpm --build-shared="$SHARED" \
  --with-config-file-path="$INI_DIR" --with-config-file-scan-dir="$INI_DIR/conf.d"

FULL="$(buildroot/bin/php -n -r 'echo PHP_VERSION;')"
NAME="php-$FULL-darwin-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/modules"
cp buildroot/bin/php buildroot/bin/php-fpm "$STAGE/"
cp buildroot/modules/xdebug.so buildroot/modules/pcov.so "$STAGE/modules/"
./spc dump-license --for-extensions="$EXT,$SHARED" --dump-dir="$STAGE/LICENSES"

# Checks that must hold for every shipped build. Capture output first: with pipefail,
# `cmd | grep -q` fails when grep exits early and cmd gets SIGPIPE, which made these checks
# flaky in CI and could hide a /usr/local link.
links="$(otool -L "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so)"
if grep -q /usr/local <<<"$links"; then
  echo "FAIL: links Homebrew (/usr/local) libraries" >&2; echo "$links" >&2; exit 1
fi
version="$("$STAGE/php" -n -d zend_extension="$STAGE/modules/xdebug.so" -v)"
grep -q Xdebug <<<"$version" || { echo "FAIL: xdebug.so does not load" >&2; exit 1; }
modules="$("$STAGE/php" -n -m)"
for ext in pdo_pgsql pdo_sqlite intl gd redis sodium zip bcmath; do
  grep -qx "$ext" <<<"$modules" || { echo "FAIL: missing extension $ext" >&2; exit 1; }
done

codesign --force --sign - "$STAGE/php" "$STAGE/php-fpm" "$STAGE"/modules/*.so   # ad-hoc (D-010)
{
  echo "php $FULL"
  echo "arch $ARCH"
  echo "macos_min $MACOSX_DEPLOYMENT_TARGET"
  echo "static-php-cli $(./spc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  echo "extensions $EXT"
  echo "shared $SHARED (xdebug 3.5.3)"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
