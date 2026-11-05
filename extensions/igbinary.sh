# igbinary: a compact replacement for PHP's serializer (Laravel's Redis and cache serializer option;
# Sail). No C library. 3.2.16 is the last stable release. Support for PHP 8.5 exists only in
# 3.2.17RC1 (a pre-release on GitHub, the newest on PECL and PIE), so PHP 8.5 gets that one.
if [ "$PHP_VER" = 8.5 ]; then
  VERSION=3.2.17RC1 SHA256=91da821443db125282a6aea039f24588dd28ff5d71e8187f6ecc41165bceafbc
else
  VERSION=3.2.16 SHA256=8bf25d465abc7973d9e2c9a3039a5f8eea635b23bc1477017ff3999ff95836da
fi
URL="https://pecl.php.net/get/igbinary-$VERSION.tgz"
LICENSE=BSD-3-Clause
LICENSE_FILES=(COPYING)
SMOKE='$v = ["a" => 1, "b" => [true, null, 1.5, "x"]];
check(igbinary_unserialize(igbinary_serialize($v)) === $v, "serialize round trip");'
