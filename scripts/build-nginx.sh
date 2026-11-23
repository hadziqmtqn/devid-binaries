#!/bin/bash
# Build nginx with OpenSSL, zlib and PCRE2 linked statically, and package it for Devid: on macOS
# for the runner's arch, on Linux fully static with musl for x86_64 (Devid D-057, Phase 12 L1).
#   scripts/build-nginx.sh   -> dist/nginx-<ver>-<os>-<arch>.tar.gz (nginx + LICENSES/ + BUILDINFO)
set -euo pipefail

# Newest stable (even minor) from upstream unless pinned; the exact version lands in BUILDINFO and
# the manifest, and the build checks below gate what ships.
NGINX_VER="${NGINX_VER:-$(python3 "$(dirname "$0")/upstream.py" nginx)}"
PCRE2_VER="${PCRE2_VER:-10.49}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin or linux
BR="$WORK/buildroot"

unset PKG_CONFIG_PATH
if [ "$OS" = darwin ]; then
  export SDKROOT="$(xcrun --show-sdk-path)"
  export MACOSX_DEPLOYMENT_TARGET=12.0
  CC=cc LD_OPT="-L$BR/lib -lz" JOBS="$(sysctl -n hw.ncpu)"
else
  # spc's default Linux target is musl: nginx loads no modules, so it can be fully static and run
  # on any distro. GNU ld reads static archives in order, hence the group.
  unset SPC_TARGET
  CC=/usr/local/musl/bin/x86_64-linux-musl-gcc   # installed by `spc doctor --auto-fix`
  LD_OPT="-static -L$BR/lib -Wl,--start-group -lssl -lcrypto -lz -Wl,--end-group" JOBS="$(nproc)"
fi
mkdir -p "$WORK/nginx" "$DIST"

# Static OpenSSL + zlib from static-php-cli (the same libraries PHP uses).
"$(dirname "$0")/fetch-spc.sh" "$WORK"
(cd "$WORK" && ./spc doctor --auto-fix && ./spc download openssl,zlib --retry=3 && ./spc build:libs openssl,zlib)

cd "$WORK/nginx"
[ -f "nginx-$NGINX_VER.tar.gz" ] || curl -fsSLO "https://nginx.org/download/nginx-$NGINX_VER.tar.gz"
[ -f "pcre2-$PCRE2_VER.tar.gz" ] || curl -fsSLO "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.gz"
rm -rf "nginx-$NGINX_VER" "pcre2-$PCRE2_VER"
tar xzf "nginx-$NGINX_VER.tar.gz" && tar xzf "pcre2-$PCRE2_VER.tar.gz"

cd "nginx-$NGINX_VER"
# Runtime paths are relative to -p <prefix>; Devid passes -p, -c and -e.
./configure --with-cc="$CC" \
  --prefix=. --sbin-path=nginx --conf-path=conf/nginx.conf \
  --pid-path=run/nginx.pid --lock-path=run/nginx.lock \
  --error-log-path=log/error.log --http-log-path=log/access.log \
  --http-client-body-temp-path=tmp/body --http-proxy-temp-path=tmp/proxy \
  --http-fastcgi-temp-path=tmp/fastcgi --without-http_uwsgi_module --without-http_scgi_module \
  --with-http_ssl_module --with-http_v2_module --with-http_realip_module --with-http_gzip_static_module \
  --with-pcre="../pcre2-$PCRE2_VER" --with-pcre-jit \
  --with-cc-opt="-I$BR/include -Os" \
  --with-ld-opt="$LD_OPT" > ../configure.log
# nginx falls back to a hard-coded -L/usr/local/lib (Homebrew) when -lssl is not found; refuse that.
grep -q 'using system OpenSSL library' ../configure.log && ! grep -q 'OpenSSL library in /usr/local' ../configure.log
make -j"$JOBS" > ../make.log 2>&1

NAME="nginx-$NGINX_VER-$OS-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/LICENSES"
cp objs/nginx "$STAGE/nginx"
strip "$STAGE/nginx"
[ "$OS" = linux ] || codesign --force --sign - "$STAGE/nginx"   # ad-hoc (Devid D-010); arm64 runs only signed code
cp LICENSE "$STAGE/LICENSES/nginx.txt"
cp "../pcre2-$PCRE2_VER/LICENCE.md" "$STAGE/LICENSES/pcre2.md" 2>/dev/null || cp "../pcre2-$PCRE2_VER/LICENCE" "$STAGE/LICENSES/pcre2.txt"
(cd "$WORK" && ./spc dump-license --for-libs=openssl,zlib --without-php --dump-dir="$STAGE/LICENSES/libs")

# Capture first: `cmd | grep -q` under pipefail fails on SIGPIPE (see build-php.sh).
if [ "$OS" = darwin ]; then
  links="$(otool -L "$STAGE/nginx")"
  if grep -qE '/usr/local|/opt/homebrew' <<<"$links"; then
    echo "FAIL: links Homebrew (/usr/local or /opt/homebrew) libraries" >&2; echo "$links" >&2; exit 1
  fi
  min="macos_min $MACOSX_DEPLOYMENT_TARGET" host="$(sw_vers -productVersion)"
else
  "$ROOT/scripts/check-linux.sh" static "$STAGE/nginx"
  qemu="$(qemu-x86_64 -cpu Nehalem "$STAGE/nginx" -v 2>&1)" ||
    { echo "FAIL: nginx does not run on a Nehalem CPU: $qemu" >&2; exit 1; }
  min="libc musl, static" host="$(. /etc/os-release && echo "$PRETTY_NAME")"
fi
info="$("$STAGE/nginx" -V 2>&1)"
grep -q "nginx/$NGINX_VER" <<<"$info" || { echo "FAIL: nginx -V" >&2; exit 1; }

{
  echo "nginx $NGINX_VER"
  echo "arch $ARCH"
  echo "$min"
  echo "pcre2 $PCRE2_VER"
  "$STAGE/nginx" -V 2>&1 | grep -i 'built with'
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $host"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
