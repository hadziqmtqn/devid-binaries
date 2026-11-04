# apcu: in-memory user cache (Symfony, Drupal, Yii, CakePHP). No C library. Devid E1: passed.
VERSION=5.1.28
URL="https://pecl.php.net/get/apcu-$VERSION.tgz"
SHA256=ca9c1820810a168786f8048a4c3f8c9e3fd941407ad1553259fb2e30b5f057bf
LICENSE=PHP-3.01
LICENSE_FILES=(LICENSE NOTICE)
INI=(-d apc.enable_cli=1)
SMOKE='apcu_store("k", 41); apcu_inc("k"); check(apcu_fetch("k") === 42, "store, inc, fetch");'
