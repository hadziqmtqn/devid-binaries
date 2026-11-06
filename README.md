# devid-binaries

Prebuilt binaries for **Devid**, a personal local PHP development tool for macOS:
- `devid` itself (the CLI, TUI and daemon) and the Devid desktop app;
- static PHP 8.3 / 8.4 / 8.5 (php + php-fpm, with Xdebug and pcov as loadable `.so` files);
- a catalog of extra PHP extensions built against them;
- nginx.

Devid's source is kept in a private repository; this one holds the build scripts for PHP and the web servers, and every release.

**Using Devid:** the [guide](GUIDE.md) covers install options, sites, PHP and extensions, web servers, the desktop app, the TUI, HTTPS, updates, troubleshooting and uninstall.

> **Notice: personal project, provided as-is, without warranty.**
> - The builds are **ad-hoc signed and not notarized**. They are meant to be downloaded by Devid itself (no Gatekeeper quarantine). If you download one by hand in a browser, macOS will block it until you remove the quarantine attribute.
> - Tested platform: **Intel macOS 14**, x86_64 only. The minimum macOS version targeted is 12.0.
> - `devid setup` asks for your password once and **changes the system**. It adds `/etc/resolver/test`, trusts Devid's certificate authority in the System keychain, and forwards ports 80 and 443 to 8088 and 8443 with a pf anchor. `devid uninstall` undoes all of it.
> - No support is promised. Use at your own risk.

## Install Devid

With the desktop app:

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh -s -- --gui
```

Without it (the CLI and TUI only):

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh
```

- **One command:** `install.sh` downloads `devid` and runs `devid setup` with the options after `--`, for example `--gui --php 8.3 --server caddy`. Setup installs the daemon, PHP and nginx, and with `--gui` the app as well. Every step and option: [Install](GUIDE.md#install) in the guide.
- **Adding the app later:** run `devid setup --gui` in a new terminal, since the first one does not yet have `devid` on its PATH.
- **The desktop app:** `Devid-darwin-x86_64.zip` in the [`devid-latest`](https://github.com/hadziqmtqn/devid-binaries/releases/tag/devid-latest) release (from v0.7.0).
  - It is a window on Devid's daemon, so it needs `devid` and `devid setup`.
  - `--gui` installs it into `~/Applications` without a Gatekeeper prompt. A browser download is quarantined; after unzipping it, run `xattr -dr com.apple.quarantine Devid.app`.
- **Updates:** `devid self-update` updates `devid` and the app.
- **Releases:**
  - `devid-v<version>` (one per version) and `devid-latest` (always the newest) hold `devid-darwin-x86_64`, `install.sh`, `devid-version.txt`, `Devid-darwin-x86_64.zip` and `checksums.txt`.
  - The other releases hold PHP, the web servers and the extension catalog.

## What is in a release

| Asset | Contents |
|---|---|
| `php-<version>-darwin-x86_64.tar.gz` | `php`, `php-fpm`, `modules/xdebug.so`, `modules/pcov.so`, `LICENSES/`, `BUILDINFO` |
| `nginx-<version>-darwin-x86_64.tar.gz` | `nginx` (OpenSSL, zlib and PCRE2 linked statically), `LICENSES/`, `BUILDINFO` |
| `ext-<name>-<version>-php<minor>-darwin-x86_64.tar.gz` | one PHP extension built for that PHP release: `<name>.so`, `ext.json` (type, PHP API, license, source and the environment it needs), `LICENSES/`, `BUILDINFO`; imagick also has `etc/` (`policy.xml`, `type.xml`) |
| `caddy-<version>-darwin-x86_64.tar.gz` | the **official** Caddy macOS build, unmodified and checked against Caddy's published SHA-512, plus its license and `BUILDINFO` |
| `manifest.json` | every asset with its version, URL, SHA-256 and size (read by Devid) |
| `checksums.txt` | `shasum -a 256` format |

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
- `.github/workflows/catalog.yml` builds and tests the changed recipes for PHP 8.3, 8.4 and 8.5 with `build-ext.sh`'s checks, publishing nothing. It reads the release cache but never writes it.
- Once the PR is merged, the same workflow starts "Build and release", so the extension ships without a Devid release.
- `workflow_dispatch` builds named recipes on demand.

**The weekly upstream check** also runs `scripts/upstream.py --catalog`. Its job summary lists newer stable PECL releases of the recipes, a newer ImageMagick (whose SVG patch must then be checked), and the most downloaded PIE extensions for macOS and NTS PHP that are not in the catalog. It changes nothing by itself.

## How they are built

- `scripts/build-php.sh` uses [static-php-cli](https://github.com/crazywhalecc/static-php-cli) (version pinned, archive SHA-256-checked before it runs).
- `scripts/build-ext.sh` builds the extension catalog in the same job as each PHP version, against that version's build root, from the recipes in `extensions/`.
- `scripts/build-nginx.sh` builds nginx stable against static OpenSSL and zlib.
- `scripts/mirror-caddy.sh` downloads the official Caddy release and verifies its SHA-512 (no rebuild).
- `scripts/manifest.py` writes `manifest.json` and `checksums.txt`.
- `.github/workflows/release.yml` runs everything on GitHub's `macos-15-intel` runners and publishes the release.

Every build fails if a binary links anything from `/usr/local` (Homebrew), if Xdebug does not load, or if a required extension is missing. Every extension build also fails if:
- the `.so` links a library outside `/usr/lib` and `/System`, or keeps an rpath into the build machine;
- one of its undefined symbols is in neither PHP's binary nor a linked system library;
- it does not load in `php` and `php-fpm`, with and without Xdebug;
- its smoke test fails.

## Updates

`.github/workflows/check-upstream.yml` runs every Monday (08:00 Asia/Jakarta). It compares the newest PHP 8.3/8.4/8.5 (php.net), nginx stable (even minor) and Caddy with the latest release's `manifest.json`, and starts a new build when anything is newer. The build scripts pick those same newest versions unless `NGINX_VER` / `CADDY_VER` are pinned. On a Mac with Devid, `devid update` then installs the new versions.

## Licenses

The [MIT license](LICENSE) covers only the build scripts, workflows and docs in this repository. The binaries in each release are distributed under their upstream licenses, included in that archive's `LICENSES/` folder.

Each archive carries the licenses of everything compiled into it in `LICENSES/`. This includes PHP (PHP License 3.01), OpenSSL (Apache-2.0), ICU, libxml2, libpq, nginx (BSD-2-Clause), PCRE2 (BSD-3-Clause) and the other bundled libraries.
