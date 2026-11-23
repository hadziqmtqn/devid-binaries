#!/bin/bash
# Build the extension catalog (Devid Phase 6, D-021) for one PHP version, against the build root
# that scripts/build-php.sh just built, so every extension matches its PHP release.
#   PHP_VER=8.4 scripts/build-ext.sh [name ...]   (default: every recipe in extensions/)
#   -> dist/ext-<name>-<version>-php8.4-<os>-<arch>.tar.gz (os: darwin or linux)
# The archive root holds <name>.so, ext.json (read by manifest.py), LICENSES/ and BUILDINFO, plus
# whatever the recipe adds (imagick: etc/). Paths in ext.json "env" are relative to that root.
set -euo pipefail
# /bin/bash on macOS is 3.2: an empty array expands as unbound under set -u, hence ${a[@]+"${a[@]}"}.

: "${PHP_VER:?set PHP_VER, e.g. 8.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"      # the same work dir as build-php.sh (spc, source, buildroot)
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin or linux; recipes read it too
BR="$WORK/buildroot"
RECIPES="$ROOT/extensions"

# Same isolation as build-php.sh: no Homebrew headers, libraries or pkg-config paths.
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$BR/lib/pkgconfig"
export PATH="$BR/bin:$WORK/pkgroot/${ARCH/arm64/aarch64}-$OS/bin:$PATH"   # spc's GNU arch name
if [ "$OS" = darwin ]; then
  export SDKROOT="$(xcrun --show-sdk-path)"
  export MACOSX_DEPLOYMENT_TARGET=12.0
  JOBS="$(sysctl -n hw.ncpu)"
  BUILD_ENV=()
else
  # The same target as build-php.sh (Devid Phase 12 L1): spc builds the recipes' libraries with it,
  # and each extension's configure gets the same zig (BUILD_ENV; spc keeps its own compiler
  # settings). zig makes __DATE__ an error, which PECL extensions print in phpinfo().
  GLIBC_MIN=2.17
  export SPC_TARGET="x86_64-linux-gnu.$GLIBC_MIN"
  ZIG="$(find "$WORK/pkgroot" -type f -name zig -perm -u+x | head -1)"
  [ -n "$ZIG" ] || { echo "FAIL: no zig in $WORK/pkgroot; run build-php.sh first" >&2; exit 1; }
  BUILD_ENV=("CC=$ZIG cc -target $SPC_TARGET" "CXX=$ZIG c++ -target $SPC_TARGET"
    "CFLAGS=-O2 -Wno-date-time" "CXXFLAGS=-O2 -Wno-date-time")
  JOBS="$(nproc)"
fi

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

# The .so is a flat-namespace bundle (macOS) or a shared object (Linux): every undefined symbol is
# looked up at load time in PHP's binary or a system library it links. Prints the ones that are in
# neither (must be none); a missing one fails the load, or crashes later when the code reaches it
# (Devid E1 spike).
missing_symbols() {
  [ "$OS" = darwin ] || { missing_symbols_elf "$@"; return; }
  comm -23 <(nm -u "$1" | sort -u) <(nm -gU "$2" | awk '{print $3}' | sort -u) |
    /usr/bin/python3 -I -c 'import ctypes, sys
libs = [ctypes.CDLL(p) for p in sys.argv[1:]]
# dyld_stub_binder (no leading underscore) is the lazy-binding helper of dyld itself.
print("\n".join(s for s in sys.stdin.read().split() if s.startswith("_") and not any(hasattr(l, s[1:]) for l in libs)))' \
      $(otool -L "$1" | awk 'NR>1{print $1}')
}

# Linux: the .so's undefined (not weak) dynamic symbols, without their version, minus those PHP's
# binary exports, minus those its NEEDED libraries (glibc only, see check-linux.sh) have.
missing_symbols_elf() {
  comm -23 <(nm -D --undefined-only "$1" | awk '$1 == "U" {sub(/@.*/, "", $2); print $2}' | sort -u) \
      <(nm -D --defined-only "$2" | awk '{sub(/@.*/, "", $3); print $3}' | sort -u) |
    /usr/bin/python3 -I -c 'import ctypes, sys
libs = [ctypes.CDLL(p) for p in sys.argv[1:]]
print("\n".join(s for s in sys.stdin.read().split() if not any(hasattr(l, s) for l in libs)))' \
      $(readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
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
    run "$NAME-configure" env ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} ./configure --with-php-config="$BR/bin/php-config" ${ARGS[@]+"${ARGS[@]}"} &&
    run "$NAME-make" make -j"$JOBS")

  PKG="ext-$NAME-$VERSION-php$PHP_VER-$OS-$ARCH"
  STAGE="$WORK/stage/$PKG"
  SO="$STAGE/$NAME.so"
  rm -rf "$STAGE" && mkdir -p "$STAGE/LICENSES"
  cp "$SRC/modules/$NAME.so" "$SO"
  # Checks that must hold for every shipped extension; capture output first (see build-php.sh).
  local links missing m
  if [ "$OS" = darwin ]; then
    # Build paths must not ship: drop rpaths into the build root, then strip and sign (Devid D-010).
    for p in $(otool -l "$SO" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do install_name_tool -delete_rpath "$p" "$SO"; done
    strip -x "$SO"
    codesign --force --sign - "$SO"
    links="$(otool -L "$SO" | awk 'NR>1{print $1}')"
    fail_unless "links a library outside /usr/lib and /System: $links" \
      test -z "$(grep -vE '^(/usr/lib/|/System/)' <<<"$links" || true)"
    fail_unless "still has an LC_RPATH" test -z "$(otool -l "$SO" | grep LC_RPATH || true)"
  else
    # Build paths must not ship (a runpath into the build root), then strip.
    patchelf --remove-rpath "$SO"
    strip --strip-unneeded "$SO"
    links="$(readelf -d "$SO" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
    # glibc only, nothing newer than GLIBC_MIN, no rpath.
    fail_unless "fails the Linux checks" "$ROOT/scripts/check-linux.sh" "$GLIBC_MIN" "$SO"
  fi
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
  local rc
  for cmd in "$PHP" "$FPM" "$PHP -d zend_extension=$XDEBUG"; do
    # shellcheck disable=SC2086 # $cmd is a binary plus optional -d flags
    m="$(env ${envv[@]+"${envv[@]}"} $cmd "${load[@]}" -m 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ge 128 ] && command -v gdb >/dev/null; then
      # A crash (a signal): where, for the log.
      # shellcheck disable=SC2086
      env ${envv[@]+"${envv[@]}"} gdb -q -batch -ex run -ex bt --args $cmd "${load[@]}" -m 2>&1 | tail -25 >&2 || true
    fi
    fail_unless "crashes in '$cmd' (exit $rc)" test "$rc" -lt 128
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
    if [ "$OS" = darwin ]; then echo "macos_min $MACOSX_DEPLOYMENT_TARGET"; else echo "glibc_min $GLIBC_MIN ($SPC_TARGET)"; fi
    echo "source $SOURCE${SOURCE_SHA256:+ (sha256 $SOURCE_SHA256)}"
    echo "links $(tr '\n' ' ' <<<"$links")"
    if [ "$OS" = darwin ]; then echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion)"
    else echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(. /etc/os-release && echo "$PRETTY_NAME")"; fi
  } > "$STAGE/BUILDINFO"
  tar -C "$STAGE" -czf "$DIST/$PKG.tar.gz" .
  ls -lh "$DIST/$PKG.tar.gz"
}

NAMES=("$@")
[ ${#NAMES[@]} -gt 0 ] || NAMES=($(cd "$RECIPES" && ls -- *.sh | sed 's/\.sh$//'))
failed=""
for n in "${NAMES[@]}"; do
  # A subshell per recipe, so one recipe's fields never leak into the next. Not in an || list, which
  # would turn off set -e inside it; a failing recipe is noted and the rest still build.
  set +e
  ( build_one "$n" )
  rc=$?
  set -e
  [ "$rc" = 0 ] || failed="$failed $n"
done
[ -z "$failed" ] || { echo "FAIL: these recipes failed:$failed" >&2; exit 1; }
