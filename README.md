# devid-binaries

Prebuilt binaries for **Devid**, a personal local PHP development tool for macOS: static PHP 8.3 / 8.4 / 8.5 (php + php-fpm, with Xdebug and pcov as loadable `.so` files) and nginx.

> **Notice: personal project, provided as-is, without warranty.**
> - The builds are **ad-hoc signed and not notarized**. They are meant to be downloaded by Devid itself (no Gatekeeper quarantine). If you download one by hand in a browser, macOS will block it until you remove the quarantine attribute.
> - Tested platform: **Intel macOS 14**, x86_64 only. The minimum macOS version targeted is 12.0.
> - No support is promised. Use at your own risk.

## What is in a release

| Asset | Contents |
|---|---|
| `php-<version>-darwin-x86_64.tar.gz` | `php`, `php-fpm`, `modules/xdebug.so`, `modules/pcov.so`, `LICENSES/`, `BUILDINFO` |
| `nginx-<version>-darwin-x86_64.tar.gz` | `nginx` (OpenSSL, zlib and PCRE2 linked statically), `LICENSES/`, `BUILDINFO` |
| `caddy-<version>-darwin-x86_64.tar.gz` | the **official** Caddy macOS build, unmodified and checked against Caddy's published SHA-512, plus its license and `BUILDINFO` |
| `manifest.json` | every asset with its version, URL, SHA-256 and size (read by Devid) |
| `checksums.txt` | `shasum -a 256` format |

The PHP builds include these extensions: bcmath, ctype, curl, dom, exif, fileinfo, filter, gd, iconv, intl, mbstring, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, redis, session, simplexml, sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, zlib.

## How they are built

- `scripts/build-php.sh` uses [static-php-cli](https://github.com/crazywhalecc/static-php-cli) (version pinned, archive SHA-256-checked before it runs).
- `scripts/build-nginx.sh` builds nginx stable against static OpenSSL and zlib.
- `scripts/mirror-caddy.sh` downloads the official Caddy release and verifies its SHA-512 (no rebuild).
- `scripts/manifest.py` writes `manifest.json` and `checksums.txt`.
- `.github/workflows/release.yml` runs everything on GitHub's `macos-15-intel` runners and publishes the release.

Every build fails if a binary links anything from `/usr/local` (Homebrew), if Xdebug does not load, or if a required extension is missing.

## Updates

`.github/workflows/check-upstream.yml` runs every Monday (08:00 Asia/Jakarta). It compares the newest PHP 8.3/8.4/8.5 (php.net), nginx stable (even minor) and Caddy with the latest release's `manifest.json`, and starts a new build when anything is newer. The build scripts pick those same newest versions unless `NGINX_VER` / `CADDY_VER` are pinned. On a Mac with Devid, `devid update` then installs the new versions.

## Licenses

The [MIT license](LICENSE) covers only the build scripts, workflows and docs in this repository. The binaries in each release are distributed under their upstream licenses, included in that archive's `LICENSES/` folder.

Each archive carries the licenses of everything compiled into it in `LICENSES/`. This includes PHP (PHP License 3.01), OpenSSL (Apache-2.0), ICU, libxml2, libpq, nginx (BSD-2-Clause), PCRE2 (BSD-3-Clause) and the other bundled libraries.
