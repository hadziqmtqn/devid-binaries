# ldap: from this PHP's own php-src, with OpenLDAP built static by spc (LdapRecord, Symfony Ldap).
# Only libldap and liblber go into the .so; OpenSSL and zlib bind to PHP's copies (Devid E1).
URL=php-src
LICENSE=PHP-3.01
LICENSE_FILES=("$WORK/source/php-src/LICENSE")
SPC_LICENSES=ldap
ARGS=(--with-ldap="$BR")
prepare() {
  spc_libs ldap
  # A static libldap needs its own dependencies for configure's link checks.
  ARGS+=("LIBS=$(pkg-config --static --libs ldap)")
}
SMOKE='$c = ldap_connect("ldaps://127.0.0.1:1");
check($c instanceof LDAP\Connection, "ldap_connect");
check(ldap_get_option($c, LDAP_OPT_X_TLS_PACKAGE, $tls) && $tls === "OpenSSL", "TLS through OpenSSL");'
