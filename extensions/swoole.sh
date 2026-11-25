# swoole: coroutine runtime and servers for the CLI (Laravel Octane with Swoole; Sail). C++, with TLS
# (the build root's OpenSSL, linked in), HTTP/2, brotli, async DNS (c-ares) and the coroutine curl
# hook. It does not change how php-fpm serves .test sites.
# PHP 8.6 (Devid D-062): not until a release supports it.
[ "$PHP_VER" != 8.6 ] || SKIP="no release supports PHP 8.6 yet; swoole 6.2 and 6.3 declare PHP 8.2 to 8.5"
VERSION=6.2.4
URL="https://pecl.php.net/get/swoole-$VERSION.tgz"
SHA256=cb41348708cb3a360672cd4ffe84b9a6b4efee61773be7d76a11c39949b95334
LICENSE=Apache-2.0
LICENSE_FILES=(LICENSE)
SPC_LICENSES=openssl,nghttp2,libcares,brotli,curl,zlib
ARGS=(--enable-swoole --enable-sockets --enable-mysqlnd --enable-cares --enable-swoole-curl
  --enable-brotli --with-brotli-dir="$BR" --with-openssl-dir="$BR" --with-nghttp2-dir="$BR")
prepare() {
  spc_libs zlib,openssl,brotli,nghttp2,libcares,curl
  # configure's link checks need the static libraries' dependencies (LIBS). The .so also needs brotli,
  # which swoole's build does not add itself (LDFLAGS), plus on macOS the frameworks the static libcurl
  # uses for proxy settings, and on Linux zig's own libc++, linked in: libtool links the .so with
  # zig c++ but leaves out its runtime (macOS links the system's libc++).
  local platform="-lc++"
  [ "$OS" = linux ] || platform="-framework CoreFoundation -framework SystemConfiguration"
  ARGS+=("LIBS=$(pkg-config --static --libs libcurl libcares libbrotlienc libbrotlidec libnghttp2 openssl zlib)"
    "LDFLAGS=-L$BR/lib -lbrotlienc -lbrotlidec -lbrotlicommon $platform")
}
SMOKE='check(version_compare(swoole_version(), "6.0", ">="), "version");
$got = [];
Swoole\Coroutine\run(function () use (&$got) {
    $ch = new Swoole\Coroutine\Channel(1);
    Swoole\Coroutine::create(function () use ($ch) { Swoole\Coroutine::sleep(0.01); $ch->push("done"); });
    $got[] = $ch->pop();
});
check($got === ["done"], "coroutine and channel");'
