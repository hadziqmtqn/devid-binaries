# msgpack: MessagePack serializer (a Redis serializer option; Sail). No C library.
# PHP 8.6 (Devid D-062): not until a release supports it.
[ "$PHP_VER" != 8.6 ] || SKIP="3.0.1 predates PHP 8.6, which made unserialize_callback_func a zend_string; the fix (msgpack/msgpack-php@cf19b26b) is not released yet"
VERSION=3.0.1
URL="https://pecl.php.net/get/msgpack-$VERSION.tgz"
SHA256=e30be355ab79aaea4568692fbd6073fd7c7f50ea8d3cf12edce40fc0c921d868
LICENSE=BSD-3-Clause
LICENSE_FILES=(LICENSE)
SMOKE='$v = ["a" => 1, "b" => [true, null, 1.5, "x"]];
check(msgpack_unpack(msgpack_pack($v)) === $v, "pack round trip");'
