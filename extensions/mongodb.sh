# mongodb: MongoDB driver (mongodb/laravel-mongodb, Doctrine MongoDB ODM). Bundles libmongoc and
# libbson, and links the build root's static OpenSSL into the .so (its own copy, Devid E1).
VERSION=2.5.6
URL="https://pecl.php.net/get/mongodb-$VERSION.tgz"
SHA256=05f0293fbaff1881ed2f25b227c324c3b778d3753e274a5d96e59c7e028b538a
LICENSE=Apache-2.0
LICENSE_FILES=(LICENSE THIRD_PARTY_NOTICES)
SPC_LICENSES=openssl
ARGS=(--with-mongodb-ssl=openssl --with-mongodb-system-libs=no --with-mongodb-zlib=bundled
  --with-mongodb-sasl=no --with-mongodb-snappy=no --with-mongodb-zstd=no)
SMOKE='$d = MongoDB\BSON\Document::fromPHP(["a" => 1]);
check($d->toPHP()->a === 1, "BSON round trip");
new MongoDB\Driver\Manager("mongodb://127.0.0.1:1");
ob_start(); phpinfo(INFO_MODULES); $info = ob_get_clean();
check(str_contains($info, "libmongoc SSL library => OpenSSL"), "TLS through OpenSSL");'
