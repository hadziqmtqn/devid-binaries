# devid-binaries

Prebuilt binaries for **[Devid](https://devid.bekenweb.com)**, a local development environment for Laravel, PHP and Node.js on Macs, Intel or Apple silicon:
- `devid` itself (the CLI, TUI and daemon) and the Devid desktop app;
- static PHP 8.3 / 8.4 / 8.5 (php + php-fpm, with Xdebug and pcov as loadable `.so` files);
- a catalog of extra PHP extensions built against them;
- nginx, and the official Caddy and Mailpit builds, mirrored unmodified.

Devid's source is public in [`hadziqmtqn/devid`](https://github.com/hadziqmtqn/devid), under the GNU AGPL v3. This repository holds the build scripts for PHP and the web servers, and every release. Bug reports and feature requests go to [`devid`'s issues](https://github.com/hadziqmtqn/devid/issues/new/choose).

**Using Devid:** the [guide](https://devid.bekenweb.com/docs) covers install options, sites, Node.js apps and dev servers, PHP and extensions, web servers, sharing a site, the desktop app, the TUI, HTTPS, updates, troubleshooting and uninstall.

> **Notice: open-source personal project, provided as is, without warranty.**
> - The builds are **ad-hoc signed and not notarized**. They are meant to be downloaded by Devid itself (no Gatekeeper quarantine). If you download one by hand in a browser, macOS will block it until you remove the quarantine attribute.
> - Tested platforms: **Intel macOS 14** by hand. Apple silicon (arm64) is tested on GitHub's runners only: each build runs its checks natively there, and each `devid` release serves a test site with the real PHP and nginx before it is published. The minimum macOS version targeted is 12.0.
> - `devid setup` asks for your password once and **changes the system**. It adds `/etc/resolver/test`, trusts Devid's certificate authority in the System keychain, and forwards ports 80 and 443 to 8088 and 8443 with a pf anchor. `devid uninstall` undoes all of it.
> - Bug reports and feature requests are welcome in [`devid`'s issues](https://github.com/hadziqmtqn/devid/issues/new/choose), but no support is promised. Use at your own risk.

## Install Devid

With the desktop app:

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh -s -- --gui
```

Without it (the CLI and TUI only):

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh
```

- **One command:** `install.sh` downloads `devid` and runs `devid setup` with the options after `--`, for example `--gui --php 8.3 --server caddy`. Setup installs the daemon, PHP and nginx, and with `--gui` the app as well. Every step and option: [Install](https://devid.bekenweb.com/docs/install) in the guide.
- **Adding the app later:** run `devid setup --gui` in a new terminal, since the first one does not yet have `devid` on its PATH.
- **The desktop app:** `Devid-darwin-x86_64.zip` in the [`devid-latest`](https://github.com/hadziqmtqn/devid-binaries/releases/tag/devid-latest) release (from v0.7.0).
  - It is a window on Devid's daemon, so it needs `devid` and `devid setup`.
  - `--gui` installs it into `~/Applications` without a Gatekeeper prompt. A browser download is quarantined; after unzipping it, run `xattr -dr com.apple.quarantine Devid.app`.
- **Updates:** `devid self-update` updates `devid` and the app.
- **Releases:**
  - `devid-v<version>` (one per version) and `devid-latest` (always the newest) hold `devid-darwin-x86_64`, `install.sh`, `devid-version.txt`, `Devid-darwin-x86_64.zip` and `checksums.txt`.
  - The newest stable `devid-v<version>` is the release marked **Latest**, which `devid self-update` reads. A version with a suffix (`devid-v0.11.0-rc.1`) is a pre-release for testing, installed by hand.
  - The dated releases (`2026.11.05-7`) hold PHP, the web servers and the extension catalog. `runtime-latest` always has the newest one's `manifest.json`, which Devid reads.

## What is in a release

| Asset | Contents |
|---|---|
| `php-<version>-<os>-<arch>.tar.gz` | `php`, `php-fpm`, `modules/xdebug.so`, `modules/pcov.so`, `LICENSES/`, `BUILDINFO` |
| `nginx-<version>-<os>-<arch>.tar.gz` | `nginx` (OpenSSL, zlib and PCRE2 linked statically), `LICENSES/`, `BUILDINFO` |
| `ext-<name>-<version>-php<minor>-<os>-<arch>.tar.gz` | one PHP extension built for that PHP release: `<name>.so`, `ext.json` (type, PHP API, license, source and the environment it needs), `LICENSES/`, `BUILDINFO`; imagick also has `etc/` (`policy.xml`, and `type.xml` with the fonts of macOS or of Debian and Ubuntu) |
| `caddy-<version>-<os>-<arch>.tar.gz` | the **official** Caddy build, unmodified and checked against Caddy's published SHA-512, plus its license and `BUILDINFO` |
| `mailpit-<version>-<os>-<arch>.tar.gz` | the **official** Mailpit build (Devid's mail catcher), unmodified and checked against the SHA-256 GitHub records for the release asset, since Mailpit publishes no checksums; plus its license and `BUILDINFO` |
| `manifest.json` | every asset with its version, URL, SHA-256 and size (read by Devid) |
| `checksums.txt` | `shasum -a 256` format |

`<os>-<arch>` is one of:
- `darwin-x86_64` (Intel Macs) or `darwin-arm64` (Apple silicon), each built natively on its own GitHub runner;
- `linux-x86_64`, built on Ubuntu for Devid's Linux port (Devid D-057, in progress: no Devid release uses these builds yet). PHP and the extensions are built with static-php-cli's zig toolchain for glibc 2.17 and later, so they run on Ubuntu 22.04 and later and Debian 12 and later, and they load `.so` files. nginx is fully static (musl).

In `manifest.json`, macOS builds are under the arch keys `x86_64` and `arm64`, and Linux builds under `linux-x86_64`.

The PHP builds include these extensions: bcmath, ctype, curl, dom, exif, fileinfo, filter, gd, iconv, intl, mbstring, mysqli, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, simplexml, soap, sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, zlib.

### Extension catalog

| Extension | Version | Notes |
|---|---|---|
| apcu | 5.1.28 | |
| igbinary | 3.2.16; 3.2.17RC1 for PHP 8.5 | 3.2.17RC1 is the only release that supports PHP 8.5 |
| memcached | 3.4.0 | libmemcached built in; PHP and JSON serializers and the session handler, without the igbinary and msgpack serializers (no load-order dependency) |
| mongodb | 2.5.6 | carries its own static OpenSSL; TLS to a server with a Devid certificate needs `tlsCAFile` |
| msgpack | 3.0.1 | |
| swoole | 6.2.4 | for the CLI (Laravel Octane); TLS (its own static OpenSSL), HTTP/2, brotli, c-ares and the coroutine curl hook |
| ldap | same as PHP | from php-src, with OpenLDAP built in; uses PHP's own OpenSSL |
| imagick | 3.8.1 | ImageMagick 7.1.2-35 built in: JPEG, PNG, GIF, WebP, AVIF, JPEG XL, TIFF, SVG; HEIC read only; no PDF reading (no Ghostscript). Carries a fix for SVG gradient and pattern fills ([ImageMagick#9093](https://github.com/ImageMagick/ImageMagick/issues/9093)); SVG gradients in `objectBoundingBox` units are not supported by ImageMagick's renderer. Needs `MAGICK_CONFIGURE_PATH` pointing at its `etc/`. |

Each extension is a recipe in `extensions/<name>.sh`: the upstream release with a pinned SHA-256, its configure options and a smoke test.

**Adding or updating one** is a pull request with its recipe:
- `.github/workflows/catalog.yml` builds and tests the changed recipes for PHP 8.3, 8.4 and 8.5 with `build-ext.sh`'s checks, publishing nothing. It reads the release cache but never writes it, and it uses the PHP in that cache (`REUSE_PHP=1`) instead of building PHP again, unless the pull request changes how PHP is built or a manual run sets `build_php`.
- Once the PR is merged, the same workflow starts "Build and release", so the extension ships without a Devid release.
- `workflow_dispatch` builds named recipes on demand.

**The weekly upstream check** also runs `scripts/upstream.py --catalog`. Its job summary lists newer stable PECL releases of the recipes, a newer ImageMagick (whose SVG patch must then be checked), and the most downloaded PIE extensions for macOS and NTS PHP that are not in the catalog. It changes nothing by itself.

## Database servers

MySQL, PostgreSQL and MongoDB for every platform Devid supports (Devid D-058). **No Devid release installs or runs them yet**: they are a separate release track, and nothing in the runtime releases or `runtime-latest` changes.

| Asset | Series | Contents |
|---|---|---|
| `mysql-<version>-<os>-<arch>.tar.gz` | 8.4 LTS, 9.7 LTS | the **official** MySQL Community Server build, checked against the SHA-256 pinned in `db/versions.json`: `bin/` (mysqld and the clients), `lib/`, `share/`, `docs/`, licenses and `BUILDINFO`. Left out: mysqld-debug, the debug plugins, the MeCab dictionary, static libraries, headers and man pages. The files kept are not modified. |
| `postgresql-<version>-<os>-<arch>.tar.gz` | 15 to 19 | built from source here: `bin/`, `lib/` (libpq and the contrib modules), `share/`, `include/`, licenses and `BUILDINFO`. Relocatable. OpenSSL 3.5 is linked statically; no ICU, uuid-ossp or LLVM JIT. |
| `mongodb-<version>-<os>-<arch>.tar.gz` | 7.0, 8.0, 9.0 | the **official** MongoDB Community Server `mongod`, unmodified and checked against MongoDB's `full.json`, plus its licenses (SSPL) and `BUILDINFO` |
| `mongosh-<version>-<os>-<arch>.tar.gz` | | the **official** mongosh build, unmodified and checked against GitHub's SHA-256 digest of the asset |

- **Releases:** `db-YYYY.MM.DD-N` holds the archives, `manifest.json` and `checksums.txt`; `db-latest` always has the newest one's `manifest.json`. Its `mysql`, `postgresql` and `mongodb` entries are keyed by series (`"9.7"`, `"17"`, `"9.0"`), each with a `version` and an `arch` map that uses the same keys as the runtime manifest (`x86_64`, `arm64`, `linux-x86_64`).
- **Platforms:**
  - MySQL's macOS builds need macOS 14 or later, and so do MongoDB 8.0 and 9.0. PostgreSQL targets macOS 12.
  - Oracle stopped building MySQL for Intel Macs after 8.4.11 and 9.7.4, so MySQL is pinned per platform in `db/versions.json`: Intel Macs keep their last build while the others move on. Each `arch` entry in the manifest has its own `version`.
  - On Linux (Ubuntu 22.04 and later, Debian 12 and later, Arch):
    - **MySQL** is Oracle's build for glibc 2.28. `scripts/db-linux-libs.sh` builds libaio and libnuma (for mysqld; Ubuntu 24.04 has libaio only as `libaio.so.1t64`) and ncurses 6 (for the `mysql` client; Arch has only `libncursesw`) into `lib/private`, where the binaries' runpath looks first.
    - **PostgreSQL** is built with static-php-cli's zig toolchain for glibc 2.17 and needs only glibc.
    - **MongoDB** is its Ubuntu 22.04 build. It links OpenSSL 3, which Arch replaced with OpenSSL 4, so the archive carries OpenSSL 3.5's `libssl.so.3` and `libcrypto.so.3` in `lib/`: **run `mongod` with `LD_LIBRARY_PATH=<archive>/lib`**. libcurl 4 comes from the system, and the CPU needs AVX.
    - The bundled libraries are built with zig for glibc 2.17 and need only glibc.
- **Checks:** every archive is unpacked under a new path on its own platform's GitHub runner, and every Linux archive again in Arch, Debian 12 and Ubuntu 22.04 containers. A server is created, started on `127.0.0.1` and a spare port, queried with the bundled client (mongosh for MongoDB) and stopped (`scripts/db-smoke.sh`). On Linux it also checks with `ldd` that the bundled libraries are the ones loaded. The PostgreSQL build also fails if a file links a library from outside the archive and the system or keeps a link into the build machine, or, on Linux, if it needs a glibc newer than 2.17 or does not start on QEMU's Nehalem CPU.
- **Updates:** a version change is a pull request to `db/versions.json`. `.github/workflows/db-release.yml` builds and smoke-tests everything on the pull request, publishing nothing, and publishes a release once it is merged. Every Monday, `scripts/db.py check` reports newer upstream releases and series in the job summary, and changes nothing. For MySQL, compare the MD5 of each new archive with Oracle's download page before pinning its SHA-256.

## How they are built

- `scripts/build-php.sh` uses [static-php-cli](https://github.com/crazywhalecc/static-php-cli) (version pinned, archive SHA-256-checked before it runs).
- `scripts/build-ext.sh` builds the extension catalog in the same job as each PHP version, against that version's build root, from the recipes in `extensions/`.
- `scripts/build-nginx.sh` builds nginx stable against static OpenSSL and zlib.
- `scripts/mirror-caddy.sh` downloads the official Caddy release and verifies its SHA-512 (no rebuild).
- `scripts/mirror-mailpit.sh` downloads the official Mailpit release and verifies it against GitHub's SHA-256 digest of the asset (no rebuild).
- `scripts/manifest.py` writes `manifest.json` and `checksums.txt`.
- `scripts/mirror-mysql.sh`, `scripts/mirror-mongodb.sh`, `scripts/mirror-mongosh.sh` and `scripts/build-postgres.sh` make the database archives, and `scripts/db.py` their manifest (see [Database servers](#database-servers)).
- `.github/workflows/release.yml` builds on GitHub's `macos-15-intel` (x86_64), `macos-15` (arm64) and `ubuntu-24.04` (Linux x86_64) runners and publishes the release.

Every build fails if a binary links anything from `/usr/local` or `/opt/homebrew` (Homebrew), if Xdebug does not load, or if a required extension is missing. Every extension build also fails if:
- the `.so` links a library outside `/usr/lib` and `/System`, or keeps an rpath into the build machine;
- one of its undefined symbols is in neither PHP's binary nor a linked system library;
- it does not load in `php` and `php-fpm`, with and without Xdebug;
- its smoke test fails.

On Linux, `scripts/check-linux.sh` replaces the macOS link checks: every binary and `.so` may need only glibc's own libraries, no glibc symbol newer than 2.17 and no rpath, and nginx must be fully static. PHP, php-fpm and nginx must also run on an older CPU (QEMU's Nehalem), since a build for the build machine's CPU once crashed on older ones, and each extension's smoke test runs there too. The Linux load checks set `LD_BIND_NOW`, so a missing symbol, or one only in another glibc version, fails the load at once. Every Linux extension is linked with `-z nodelete`, so the exit handlers of the libraries inside it still run after PHP unloads it, and with `-Bsymbolic`, so it uses its own copies of those libraries rather than PHP's.

## Updates

`.github/workflows/check-upstream.yml` runs every Monday (08:00 Asia/Jakarta). It compares the newest PHP 8.3/8.4/8.5 (php.net), nginx stable (even minor), Caddy and Mailpit with `runtime-latest`'s `manifest.json`, and starts a new build when anything is newer. The build scripts pick those same newest versions unless `NGINX_VER` / `CADDY_VER` / `MAILPIT_VER` are pinned. On a Mac with Devid, `devid update` then installs the new versions.

## Licenses

The [MIT license](LICENSE) covers only the build scripts, workflows and docs in this repository.

- **Devid:** `devid` and the desktop app are under the [GNU AGPL v3](https://github.com/hadziqmtqn/devid/blob/main/LICENSE). The source of each `devid-v<version>` release is the `v<version>` tag in [`hadziqmtqn/devid`](https://github.com/hadziqmtqn/devid).
- **Everything else:** each archive carries the licenses of everything compiled into it in `LICENSES/`. This includes PHP (PHP License 3.01), OpenSSL (Apache-2.0), ICU, libxml2, libpq, nginx (BSD-2-Clause), PCRE2 (BSD-3-Clause), Mailpit (MIT) and the other bundled libraries.
- **Databases:** MySQL Community Server is under the GPL v2 (with Oracle's FOSS exception), PostgreSQL under the PostgreSQL License, MongoDB Community Server under the SSPL v1 and mongosh under Apache-2.0. libaio and libnuma, bundled with MySQL on Linux, are under the LGPL v2.1, ncurses under the MIT (X11) license, and OpenSSL, bundled with MongoDB on Linux, under Apache-2.0. Each archive's `LICENSES/` has the texts.
