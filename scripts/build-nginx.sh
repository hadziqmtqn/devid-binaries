#!/bin/bash
# Build nginx for macOS with OpenSSL, zlib and PCRE2 linked statically, and package it for Devid.
#   scripts/build-nginx.sh   -> dist/nginx-<ver>-darwin-<arch>.tar.gz (nginx + LICENSES/ + BUILDINFO)
set -euo pipefail

NGINX_VER="${NGINX_VER:-1.30.6}"   # stable branch
PCRE2_VER="${PCRE2_VER:-10.49}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
DIST="${DIST:-$ROOT/dist}"
ARCH="$(uname -m)"
BR="$WORK/buildroot"

unset PKG_CONFIG_PATH
export SDKROOT="$(xcrun --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=12.0
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
./configure \
  --prefix=. --sbin-path=nginx --conf-path=conf/nginx.conf \
  --pid-path=run/nginx.pid --lock-path=run/nginx.lock \
  --error-log-path=log/error.log --http-log-path=log/access.log \
  --http-client-body-temp-path=tmp/body --http-proxy-temp-path=tmp/proxy \
  --http-fastcgi-temp-path=tmp/fastcgi --without-http_uwsgi_module --without-http_scgi_module \
  --with-http_ssl_module --with-http_v2_module --with-http_realip_module --with-http_gzip_static_module \
  --with-pcre="../pcre2-$PCRE2_VER" --with-pcre-jit \
  --with-cc-opt="-I$BR/include -Os" \
  --with-ld-opt="-L$BR/lib -lz" > ../configure.log
# nginx falls back to a hard-coded -L/usr/local/lib (Homebrew) when -lssl is not found; refuse that.
grep -q 'using system OpenSSL library' ../configure.log && ! grep -q 'OpenSSL library in /usr/local' ../configure.log
make -j"$(sysctl -n hw.ncpu)" > ../make.log 2>&1

NAME="nginx-$NGINX_VER-darwin-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/LICENSES"
cp objs/nginx "$STAGE/nginx"
strip "$STAGE/nginx"
cp LICENSE "$STAGE/LICENSES/nginx.txt"
cp "../pcre2-$PCRE2_VER/LICENCE.md" "$STAGE/LICENSES/pcre2.md" 2>/dev/null || cp "../pcre2-$PCRE2_VER/LICENCE" "$STAGE/LICENSES/pcre2.txt"
(cd "$WORK" && ./spc dump-license --for-libs=openssl,zlib --without-php --dump-dir="$STAGE/LICENSES/libs")

if otool -L "$STAGE/nginx" | grep -q /usr/local; then
  echo "FAIL: links Homebrew (/usr/local) libraries" >&2; otool -L "$STAGE/nginx"; exit 1
fi
"$STAGE/nginx" -V 2>&1 | grep -q "nginx/$NGINX_VER" || { echo "FAIL: nginx -V" >&2; exit 1; }

codesign --force --sign - "$STAGE/nginx"   # ad-hoc (Devid D-010)
{
  echo "nginx $NGINX_VER"
  echo "arch $ARCH"
  echo "macos_min $MACOSX_DEPLOYMENT_TARGET"
  echo "pcre2 $PCRE2_VER"
  "$STAGE/nginx" -V 2>&1 | grep -i 'built with'
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion)"
} > "$STAGE/BUILDINFO"

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" .
ls -lh "$DIST/$NAME.tar.gz"
