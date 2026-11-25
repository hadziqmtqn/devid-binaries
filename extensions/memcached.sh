# memcached: Memcached client (cache drivers in Laravel, CodeIgniter 4 and Symfony; Sail), with
# libmemcached built static by spc. Built without the igbinary and msgpack serializers: those would
# make it load only after those extensions. PHP's serializer and JSON remain.
# PHP 8.6 (Devid D-062): not until a release supports it.
[ "$PHP_VER" != 8.6 ] || SKIP="3.4.0 predates PHP 8.6, which passes the session save_path as a zend_string; the fix (php-memcached-dev/php-memcached@3c73b4f0) is not released yet"
VERSION=3.4.0
URL="https://pecl.php.net/get/memcached-$VERSION.tgz"
SHA256=c163434eb0da97c8f45c7ad41d979d381f8b81c49402b1b90b063987fb37972e
LICENSE=PHP-3.01
LICENSE_FILES=(LICENSE fastlz/LICENSE)   # memcached bundles fastlz (MIT)
SPC_LICENSES=libmemcached
ARGS=(--with-libmemcached-dir="$BR" --with-zlib-dir="$BR" --enable-memcached-session --enable-memcached-json
  --disable-memcached-sasl --disable-memcached-igbinary --disable-memcached-msgpack)
prepare() {
  spc_libs libmemcached
  # A static libmemcached needs its own dependencies for configure's link checks (LIBS) and for
  # the .so itself (LDFLAGS): its .pc lists neither libhashkit nor the C++ runtime.
  ARGS+=("LIBS=$(pkg-config --static --libs libmemcached)" "LDFLAGS=-L$BR/lib -lhashkit -lc++")
}
SMOKE='$m = new Memcached();
check(Memcached::HAVE_JSON && Memcached::HAVE_SESSION, "json serializer and session handler");
check($m->setOption(Memcached::OPT_COMPRESSION, true), "options");
check($m->set("k", 1) === false, "no server: fails cleanly");'
