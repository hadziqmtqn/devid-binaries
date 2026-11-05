#!/bin/bash
# Build the extension catalog (Devid Phase 6, D-021) for one PHP version, against the build root
# that scripts/build-php.sh just built, so every extension matches its PHP release.
#   PHP_VER=8.4 scripts/build-ext.sh [name ...]   (default: every recipe in extensions/)
#   -> dist/ext-<name>-<version>-php8.4-darwin-<arch>.tar.gz
# The archive root holds <name>.so, ext.json (read by manifest.py), LICENSES/ and BUILDINFO, plus
# whatever the recipe adds (imagick: etc/). Paths in ext.json "env" are relative to that root.
set -euo pipefail
# /bin/bash on macOS is 3.2: an empty array expands as unbound under set -u, hence ${a[@]+"${a[@]}"}.

: "${PHP_VER:?set PHP_VER, e.g. 8.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"      # the same work dir as build-php.sh (spc, source, buildroot)
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
BR="$WORK/buildroot"
RECIPES="$ROOT/extensions"

# Same isolation as build-php.sh: no Homebrew headers, libraries or pkg-config paths.
unset PKG_CONFIG_PATH
export SDKROOT="$(xcrun --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=12.0
export PKG_CONFIG_LIBDIR="$BR/lib/pkgconfig"
export PATH="$BR/bin:$WORK/pkgroot/$ARCH-darwin/bin:$PATH"

FULL="$(php-config --version)"
[ "${FULL%.*}" = "$PHP_VER" ] || { echo "FAIL: the build root holds PHP $FULL, not $PHP_VER; run build-php.sh first" >&2; exit 1; }
PHP_API="$(php-config --extension-dir | grep -oE '[0-9]{8}$')"
PHP="$BR/bin/php"
FPM="$BR/bin/php-fpm"
XDEBUG="$BR/modules/xdebug.so"
mkdir -p "$WORK/ext/downloads" "$WORK/ext/src" "$WORK/ext/log" "$DIST"

# run <log name> <command...>: quiet on success, the log's tail on failure.
run() {
  local log="$WORK/ext/log/$1.log"; shift
  "$@" >"$log" 2>&1 || { tail -40 "$log" >&2; echo "FAIL: $* (log: $log)" >&2; return 1; }
}

# fetch <url> <sha256> <file>: download once, and refuse a file whose checksum does not match.
fetch() {
  [ -f "$3" ] || { curl -fsSL --retry 3 -o "$3.part" "$1" && mv "$3.part" "$3"; }
  echo "$2  $3" | shasum -a 256 -c - >/dev/null || { echo "FAIL: $1 does not match its pinned sha256" >&2; rm -f "$3"; return 1; }
}

# spc_libs <libs>: build static libraries into the build root with static-php-cli (reused if built).
spc_libs() {
  (cd "$WORK" && run "spc-download-$NAME" ./spc download --for-libs="$1" --retry=3 && run "spc-build-$NAME" ./spc build:libs "$1")
}

# fail_unless <description> <command...>
fail_unless() { local what="$1"; shift; "$@" || { echo "FAIL: $NAME: $what" >&2; return 1; }; }

# The .so is a flat-namespace bundle: every undefined symbol is looked up at load time in PHP's
# binary or a system library it links. Prints the ones that are in neither (must be none); a
# missing one fails the load, or crashes later when the code reaches it (Devid E1 spike).
missing_symbols() {
  comm -23 <(nm -u "$1" | sort -u) <(nm -gU "$2" | awk '{print $3}' | sort -u) |
    /usr/bin/python3 -I -c 'import ctypes, sys
libs = [ctypes.CDLL(p) for p in sys.argv[1:]]
# dyld_stub_binder (no leading underscore) is the lazy-binding helper of dyld itself.
print("\n".join(s for s in sys.stdin.read().split() if s.startswith("_") and not any(hasattr(l, s[1:]) for l in libs)))' \
      $(otool -L "$1" | awk 'NR>1{print $1}')
}

build_one() {
  NAME="$1"
  # Recipe fields (extensions/<name>.sh sets them):
  #   VERSION, URL, SHA256  upstream release, pinned; URL=php-src builds ext/<name> of this PHP
  #   TYPE                  extension | zend_extension
  #   LICENSE               SPDX id of the extension's own license
  #   LICENSE_FILES         files to copy into LICENSES/ (relative to the source, or absolute)
  #   SPC_LICENSES          spc libraries linked into the .so, for `spc dump-license`
  #   ARGS                  configure arguments; prepare() may add to them
  #   ENV_JSON              environment Devid sets for this extension, paths relative to the archive
  #   INI, SMOKE            -d options and PHP code for the smoke test; check($ok, $what) is defined
  #   prepare()             runs before configure (build libraries)
  #   stage_extra()         adds files to $STAGE
  VERSION="" URL="" SHA256="" TYPE=extension LICENSE="" SPC_LICENSES="" ENV_JSON='{}' SMOKE=""
  LICENSE_FILES=(LICENSE) ARGS=() INI=()
  prepare() { :; }
  stage_extra() { :; }
  # shellcheck source=/dev/null
  source "$RECIPES/$NAME.sh"

  SRC="$WORK/ext/src/$NAME"
  rm -rf "$SRC"
  if [ "$URL" = php-src ]; then
    VERSION="$FULL"
    cp -R "$WORK/source/php-src/ext/$NAME" "$SRC"
    SOURCE="php-src $FULL (ext/$NAME)" SOURCE_SHA256=""
  else
    local tgz="$WORK/ext/downloads/$(basename "$URL")"
    fetch "$URL" "$SHA256" "$tgz"
    mkdir -p "$SRC" && tar -xzf "$tgz" -C "$SRC" --strip-components 1   # PECL: package.xml + <name>-<ver>/
    SOURCE="$URL" SOURCE_SHA256="$SHA256"
  fi

  prepare
  (cd "$SRC" && run "$NAME-phpize" phpize &&
    run "$NAME-configure" ./configure --with-php-config="$BR/bin/php-config" ${ARGS[@]+"${ARGS[@]}"} &&
    run "$NAME-make" make -j"$(sysctl -n hw.ncpu)")

  PKG="ext-$NAME-$VERSION-php$PHP_VER-darwin-$ARCH"
  STAGE="$WORK/stage/$PKG"
  SO="$STAGE/$NAME.so"
  rm -rf "$STAGE" && mkdir -p "$STAGE/LICENSES"
  cp "$SRC/modules/$NAME.so" "$SO"
  # Build paths must not ship: drop rpaths into the build root, then strip and sign (Devid D-010).
  for p in $(otool -l "$SO" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do install_name_tool -delete_rpath "$p" "$SO"; done
  strip -x "$SO"
  codesign --force --sign - "$SO"

  # Checks that must hold for every shipped extension; capture output first (see build-php.sh).
  local links missing m
  links="$(otool -L "$SO" | awk 'NR>1{print $1}')"
  fail_unless "links a library outside /usr/lib and /System: $links" \
    test -z "$(grep -vE '^(/usr/lib/|/System/)' <<<"$links" || true)"
  fail_unless "still has an LC_RPATH" test -z "$(otool -l "$SO" | grep LC_RPATH || true)"
  for b in "$PHP" "$FPM"; do
    missing="$(missing_symbols "$SO" "$b")"
    fail_unless "symbols neither $(basename "$b") nor a system library provides: $(head -5 <<<"$missing" | tr '\n' ' ')" test -z "$missing"
  done

  # LICENSES/<name>-<path with / as ->, so a bundled library's LICENSE never overwrites the extension's.
  for f in "${LICENSE_FILES[@]}"; do
    if [[ $f = /* ]]; then cp "$f" "$STAGE/LICENSES/$NAME-$(basename "$f")"; else cp "$SRC/$f" "$STAGE/LICENSES/$NAME-${f//\//-}"; fi
  done
  [ -z "$SPC_LICENSES" ] || (cd "$WORK" && run "spc-license-$NAME" ./spc dump-license --for-libs="$SPC_LICENSES" --without-php --dump-dir="$STAGE/LICENSES/libs")
  stage_extra

  # Load in the CLI and php-fpm, with and without Xdebug, then the recipe's smoke test, all on the
  # file that ships. Devid sets ENV_JSON at run time, with paths relative to the archive.
  local load=(-n -d "$TYPE=$SO") envv=()
  while IFS='=' read -r k v; do [ -n "$k" ] && envv+=("$k=$STAGE/$v"); done < <(
    /usr/bin/python3 -I -c 'import json, sys; [print(f"{k}={v}") for k, v in json.loads(sys.argv[1]).items()]' "$ENV_JSON")
  for cmd in "$PHP" "$FPM" "$PHP -d zend_extension=$XDEBUG"; do
    # shellcheck disable=SC2086 # $cmd is a binary plus optional -d flags
    m="$(env ${envv[@]+"${envv[@]}"} $cmd "${load[@]}" -m 2>&1)"
    fail_unless "does not load in '$cmd': $(grep -iE 'warning|error' <<<"$m" | head -3)" grep -qx "$NAME" <<<"$m"
    fail_unless "warnings while loading in '$cmd': $(grep -iE 'warning|error' <<<"$m" | head -3)" \
      test -z "$(grep -iE 'warning|error' <<<"$m" || true)"
  done
  if [ -n "$SMOKE" ]; then
    local smoke='function check($ok, $what) { if (!$ok) { fwrite(STDERR, "smoke test failed: $what\n"); exit(1); } }'
    fail_unless "smoke test" env ${envv[@]+"${envv[@]}"} "$PHP" "${load[@]}" ${INI[@]+"${INI[@]}"} -r "$smoke $SMOKE"
  fi

  /usr/bin/python3 -I -c 'import json, sys
a = sys.argv
json.dump({"name": a[2], "version": a[3], "php": a[4], "php_api": a[5], "type": a[6], "file": a[2] + ".so",
           "license": a[7], "source": a[8], "source_sha256": a[9], "env": json.loads(a[10])},
          open(a[1], "w"), indent=2)' \
    "$STAGE/ext.json" "$NAME" "$VERSION" "$PHP_VER" "$PHP_API" "$TYPE" "$LICENSE" "$SOURCE" "$SOURCE_SHA256" "$ENV_JSON"
  {
    echo "$NAME $VERSION"
    echo "php $FULL (api $PHP_API)"
    echo "arch $ARCH"
    echo "macos_min $MACOSX_DEPLOYMENT_TARGET"
    echo "source $SOURCE${SOURCE_SHA256:+ (sha256 $SOURCE_SHA256)}"
    echo "links $(tr '\n' ' ' <<<"$links")"
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion)"
  } > "$STAGE/BUILDINFO"
  tar -C "$STAGE" -czf "$DIST/$PKG.tar.gz" .
  ls -lh "$DIST/$PKG.tar.gz"
}

NAMES=("$@")
[ ${#NAMES[@]} -gt 0 ] || NAMES=($(cd "$RECIPES" && ls -- *.sh | sed 's/\.sh$//'))
for n in "${NAMES[@]}"; do
  ( build_one "$n" )   # a subshell per recipe, so one recipe's fields never leak into the next
done
