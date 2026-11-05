# swoole: coroutine runtime and servers for the CLI (Laravel Octane with Swoole; Sail). C++, with TLS
# (the build root's OpenSSL, linked in), HTTP/2, brotli, async DNS (c-ares) and the coroutine curl
# hook. It does not change how php-fpm serves .test sites.
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
  # which swoole's build does not add itself, and the frameworks the static libcurl uses for macOS
  # proxy settings (LDFLAGS).
  ARGS+=("LIBS=$(pkg-config --static --libs libcurl libcares libbrotlienc libbrotlidec libnghttp2 openssl zlib)"
    "LDFLAGS=-L$BR/lib -lbrotlienc -lbrotlidec -lbrotlicommon -framework CoreFoundation -framework SystemConfiguration")
}
SMOKE='check(version_compare(swoole_version(), "6.0", ">="), "version");
$got = [];
Swoole\Coroutine\run(function () use (&$got) {
    $ch = new Swoole\Coroutine\Channel(1);
    Swoole\Coroutine::create(function () use ($ch) { Swoole\Coroutine::sleep(0.01); $ch->push("done"); });
    $got[] = $ch->pop();
});
check($got === ["done"], "coroutine and channel");'
