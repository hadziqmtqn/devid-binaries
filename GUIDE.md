# Devid guide

Devid is a local PHP development environment for macOS. Every folder you link or park is served at `https://<name>.test` with a trusted certificate. Devid runs PHP 8.3, 8.4 and 8.5 side by side, and nginx, Caddy or Apache as the web server. It needs no Homebrew, no Docker and no virtual machine. You use it from the command line, from a terminal UI (TUI) or from the desktop app.

> Devid is a personal project, provided as is, without warranty. It runs on Intel Macs only and is tested on macOS 14. Read the [notice in the README](README.md) before you install it: `devid setup` changes system settings.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [First steps](#first-steps)
- [Sites](#sites)
- [PHP](#php)
- [PHP extensions](#php-extensions)
- [Web servers and services](#web-servers-and-services)
- [The desktop app](#the-desktop-app)
- [The TUI](#the-tui)
- [HTTPS](#https)
- [Updates](#updates)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Files](#files)

## Requirements

- macOS 12 or newer, on an Intel Mac (x86_64).
- An administrator password, needed once during setup.
- Nothing else running on ports 80 and 443 for `127.0.0.1`. If Laravel Valet is installed, stop it first with `valet stop` and `valet stop dnsmasq`.

## Install

With the desktop app:

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh -s -- --gui
```

Without it (the CLI and TUI only):

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh
```

The script downloads `devid`, checks its sha256 and starts `devid setup`. The script itself never uses sudo. Setup lists every step as it runs it:

1. Copies `devid` to `~/.devid/bin`, and adds the `php` and `composer` commands there.
2. Puts `~/.devid/bin` first on your `PATH` in `~/.zshrc`.
3. Runs the Devid daemon as a LaunchAgent, so it starts at every login.
4. Downloads `composer.phar` and checks it.
5. Asks for your password **once** for the system setup:
   - `.test` DNS (`/etc/resolver/test`);
   - ports 80/443 redirected to Devid (a pf rule);
   - trust for the Devid certificate authority.
6. Downloads PHP 8.5 and nginx (both sha256-checked), unless PHP or the web server is already installed.
7. With `--gui`, installs Devid.app into `~/Applications` (sha256-checked).

To see the steps without changing anything, run `devid setup --dry-run`. To install a specific version of Devid, run `DEVID_VERSION=0.7.0 sh install.sh`.

To choose PHP versions and the web server, pass options to setup. With the install script, put them after `sh -s --`:

```sh
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh -s -- --php 8.3 --server caddy
devid setup --php 8.3 --php 8.4     # several versions; the first becomes the default
devid setup --server apache         # nginx, caddy or apache
devid setup --no-php --no-server    # only the system parts; install PHP and a server later
```

You can add or switch PHP versions and web servers at any time later (see [PHP](#php) and [Web servers and services](#web-servers-and-services)).

Open a new terminal after setup so that `php` and `composer` come from Devid.

## First steps

```sh
devid park ~/Projects          # every subfolder becomes <folder>.test
devid doctor                   # check that everything works
```

Then open `https://<folder>.test` in your browser. If the folder has a `public/` subfolder (Laravel, Symfony), Devid serves that; otherwise it serves the folder itself.

## Sites

| Command | What it does |
|---|---|
| `devid park [path]` | Serves every subfolder of a folder (default: the current one) as `<subfolder>.test`. |
| `devid unpark [path]` | Stops serving a parked folder. |
| `devid link [name] [--path <dir>]` | Serves one folder (default: the current one) as `<name>.test` (default name: the folder name). |
| `devid unlink <name>` | Stops serving a linked site. |
| `devid ignore <name>` | Stops serving one site of a parked folder; its folder is not touched. `devid sites` lists ignored sites. |
| `devid unignore <name>` | Serves an ignored site again. |
| `devid sites` | Lists sites with their URL, PHP version and folder. |
| `devid isolate <version> [--site <name>]` | Pins a site (default: the one containing the current folder) to a PHP version. |
| `devid unisolate [--site <name>]` | Returns a site to the default PHP version. |

Every site gets HTTPS automatically; there is no separate `secure` step.

## PHP

```sh
devid php list                 # installed versions and whether php-fpm runs
devid php install 8.4          # add another version
devid php use 8.4              # make it the default
devid php ext 8.5 xdebug on    # turn Xdebug (or pcov) on/off for a version
devid php ext list 8.4         # bundled, Xdebug/pcov, and installed catalog extensions
```

- **The `php` command** follows the folder you are in. Inside an isolated site it uses that site's version; anywhere else it uses the default. `composer` works the same way.
- **Extensions:**
  - Every version includes:
    - bcmath, ctype, curl, dom, exif, fileinfo, gd, iconv, intl, mbstring, opcache, openssl, pcntl;
    - PDO with MySQL, PostgreSQL and SQLite, plus mysqli, pgsql and sqlite3;
    - readline (for `php -a` and `artisan tinker`), redis, soap, sockets, sodium, zip, and the XML extensions.
  - Xdebug and pcov are included but off by default. Xdebug starts in trigger mode on port 9003.
- **Extra extensions:** see [PHP extensions](#php-extensions).
- **php.ini:** each version has `~/.devid/php/<version>/etc/php.ini`. Devid writes it once and never overwrites it. After editing it, run `devid restart php-8.5`. The defaults are `memory_limit = 512M`, uploads up to 64 MB, errors displayed, and JIT off.
- **Processes:** php-fpm uses `pm = ondemand`, so idle versions use almost no memory.

## PHP extensions

```sh
devid php ext available 8.4                 # what the catalog offers for PHP 8.4
devid php ext install 8.4 imagick igbinary # one or more; php-fpm restarts once
devid php ext list 8.4                      # bundled, Xdebug/pcov, and installed catalog extensions
devid php ext remove 8.4 imagick
```

In the TUI: PHP page, `enter` on a version, then **Extensions…**: `space` ticks, `enter` on the Install button installs, `r` removes. In the desktop app: PHP, then **Extensions** on a version.

**The catalog** (PHP 8.3, 8.4 and 8.5): apcu, igbinary, imagick, ldap, memcached, mongodb, msgpack and swoole.
- Each comes only from Devid's releases. It is built in CI from its official source for that exact PHP release, and its checksum is verified before install. Nothing is compiled on your Mac.
- `install` checks that the extension loads in `php` and `php-fpm` before it restarts php-fpm. If it does not load, nothing changes and the sites keep running. Several extensions install in one go, with a single php-fpm restart.
- `devid update` updates them together with PHP. `devid doctor` reports one that no longer loads.

| Extension | Notes |
|---|---|
| apcu | Also on in the CLI (`apc.enable_cli=1`). |
| igbinary | Laravel's Redis and cache serializer option. PHP 8.5 gets 3.2.17RC1, the only igbinary release that supports it; 8.3 and 8.4 get the stable 3.2.16. |
| imagick | JPEG, PNG, GIF, WebP, AVIF, JPEG XL, TIFF and SVG; HEIC can be read but not written. PDF cannot be read (that needs Ghostscript). SVG gradients in `objectBoundingBox` units, SVG's default, are not drawn correctly ([ImageMagick#9093](https://github.com/ImageMagick/ImageMagick/issues/9093)). Text uses macOS fonts. |
| ldap | From PHP's own source, with OpenLDAP built in. |
| memcached | libmemcached built in. Serializers: PHP's and JSON, plus the session handler. The igbinary and msgpack serializers are left out, so memcached does not depend on loading those first. |
| mongodb | Carries its own OpenSSL. |
| msgpack | Redis serializer option. |
| swoole | For the CLI (`php artisan octane:start`). TLS, HTTP/2, brotli, async DNS and the coroutine curl hook. It does not change how php-fpm serves `.test` sites. |

TLS in mongodb and ldap trusts the macOS system certificates. For a server with a Devid `.test` certificate, pass `tlsCAFile` (mongodb) or `LDAP_OPT_X_TLS_CACERTFILE` (ldap) pointing at `~/.devid/ca/cacert.pem`.

### Which extensions can be added

| Kind | Examples | Can be added? |
|---|---|---|
| Bundled in Devid's PHP | bcmath, curl, gd, intl, mbstring, mysqli, pdo_pgsql, redis, soap, sodium, zip | Nothing to install (`devid php ext list`). |
| Shipped with Devid's PHP, off by default | Xdebug, pcov | `devid php ext <version> xdebug on` |
| Open source, no extra library | apcu, igbinary, msgpack, ds, uuid | Yes |
| Open source, with an open-source C library | imagick, memcached, mongodb, swoole, amqp, rdkafka, yaml | Yes. The library is built into the extension, so nothing else is installed. |
| In PHP's source but not in Devid's build | ldap, xsl, gmp, tidy | Yes, built from the same PHP source as the release. |

**Cannot be added, and why:**

| Reason | Examples |
|---|---|
| Needs a proprietary client library | oci8 / pdo_oci (Oracle Instant Client), sqlsrv / pdo_sqlsrv (Microsoft ODBC Driver) |
| Needs thread-safe PHP; Devid's PHP is non-thread-safe, as php-fpm uses it | parallel |
| The vendor no longer builds it for Intel Macs | ionCube Loader: its Intel loaders stop at PHP 8.3 |
| Closed source without a license to redistribute | vendor loaders whose license allows neither mirroring nor downloads from the vendor |
| Windows only, or no support for PHP 8.3 and newer | com_dotnet; Zend Guard Loader, pthreads |
| A closed-source agent with its own background service | New Relic, Datadog, Blackfire (not planned) |

**Asking for another extension:** open a [Feature request](https://github.com/hadziqmtqn/devid-binaries/issues/new/choose) in this repository. Each catalog extension is a reviewed recipe (`extensions/<name>.sh`): the official source pinned by checksum, its build options and a smoke test. The pull request builds and tests it for every PHP version, and a merge publishes it in a new release, with no Devid update needed.

## Web servers and services

One web server runs at a time. nginx is the default.

```sh
devid server list              # nginx, caddy, apache: installed, active, version
devid server install caddy     # nginx/caddy come from Devid's releases; apache uses macOS's /usr/sbin/httpd
devid server use caddy         # switch; the old server stops, the new one starts
```

Services are the web server and one php-fpm per PHP version, named `nginx`, `caddy`, `apache`, `php-8.4` and so on.

```sh
devid status                   # daemon, web server, PHP versions, ports
devid restart nginx
devid stop php-8.4             # stays stopped until `devid start php-8.4`
devid stop all                 # stop everything (a daemon restart, e.g. at login, brings it back)
devid start all
devid autostart off            # after login, nginx and PHP wait for `devid start all` (default: on)
devid login-item on            # open the Devid app's menu-bar icon at login (default: off)
devid logs                     # list logs
devid logs php85-fpm.log -n 50 --follow
devid logs nginx-error.log --clear
```

## The desktop app

Devid.app is a menu-bar icon with a window that has the same pages as the TUI: Sites, PHP, Server, Logs and Settings. It is optional: your sites run without it.

```sh
# at the first install, in one command (no sudo for the app itself):
curl -fsSL https://github.com/hadziqmtqn/devid-binaries/releases/download/devid-latest/install.sh | sh -s -- --gui
# or later, in a new terminal:
devid setup --gui              # install it into ~/Applications; open it from Spotlight
devid login-item on            # show its menu-bar icon after every login (default: off)
```

Without `--gui`, Devid installs no app.

- **Gatekeeper:** the app is ad-hoc signed and not notarized. Installed by `devid setup --gui`, it opens without a prompt. If you download `Devid-darwin-x86_64.zip` in a browser instead, run `xattr -dr com.apple.quarantine Devid.app` after unzipping it.
- **Menu bar:** the icon shows whether Devid runs, and a dot when updates are available. Its menu starts, stops and restarts everything, and opens the window or Settings.
- **Dock:** the app is in the Dock and in Cmd+Tab only while its window is open. At other times it is a menu-bar icon (under 10 MB, no CPU at idle).
- **Updates:** `devid self-update` updates the app together with devid once the app is installed. An open window keeps the old version until you close it.
- **Removal:** `devid uninstall` removes the app.

## The TUI

Run `devid` with no arguments, or run `devid tui`. The TUI has five pages: Sites, PHP, Server, Logs and Settings. Every action in it is also a CLI command.

| Where | Keys |
|---|---|
| Everywhere | `↑ ↓` or `j k` move · `tab` switch sidebar/page · `1`–`5` jump to a page · `r` refresh · `?` help · `q` quit |
| Sites | `enter` actions (open in browser, open in Terminal, copy URL, PHP version, remove, unlink) · `a` link a folder · `p` park a folder · `U` unpark · `I` serve an ignored site again |
| PHP | `enter` actions (extensions, make default, Xdebug, pcov, edit php.ini, restart, install) · `u` check for updates · `U` update |
| PHP → Extensions… | `space` tick catalog extensions · `tab` to the Install button · `enter` install the ticked ones (after a confirmation, with an `installing 2/3 imagick… 52%` line) · `r` remove one (after a confirmation) · `x` Xdebug · `c` pcov |
| Server | `enter` actions (use, install, restart, stop/start, view config) · `S` stop all · `A` start all |
| Logs | `f` follow · `c` clear |
| Settings | `d` health check · `u` check for updates · `U` update PHP/nginx · `D` update devid · `s` setup · `X` uninstall · `a` serve sites at login |

Destructive actions ask for confirmation first. Colors come from your terminal theme, and every state also has a symbol and a word. Set `NO_COLOR=1` for a monochrome UI.

## HTTPS

HTTPS needs no manual steps:

- **On first start:** the daemon creates a local certificate authority, "Devid Local CA". It is name-constrained to `.test`, so it cannot be used for any other domain.
- **During setup:** `devid setup` adds the CA to the System keychain.
- **Per site:** each site gets a certificate when it is linked or parked. Devid renews it 30 days before it expires.
- **Browsers:** browsers that use the macOS keychain (Safari, Chrome, Brave) trust these certificates.
- **Devid's PHP and Composer:** they use `~/.devid/ca/cacert.pem` (the macOS bundle plus the Devid CA), so HTTP calls from one `.test` site to another work.

Some tools use their own certificate store:

| Tool | What to do |
|---|---|
| Firefox | Usually reads the macOS keychain (`security.enterprise_roots.enabled`). If it warns, import `~/.devid/ca/devid-ca.crt` under Settings → Privacy & Security → Certificates. |
| Node.js | `export NODE_EXTRA_CA_CERTS="$HOME/.devid/ca/devid-ca.crt"` |
| Python (requests) | `export REQUESTS_CA_BUNDLE="$HOME/.devid/ca/cacert.pem"` |

## Updates

```sh
devid self-update --check      # is there a newer devid?
devid self-update              # install it (restarts the daemon, and updates the app if installed)
devid update --check           # newer PHP, nginx, Caddy or catalog extensions?
devid update                   # install them
```

Each download is checked against its sha256 before Devid uses it. The daemon also checks for updates every 20 minutes (`update_check_minutes` in `config.toml`; 0 turns it off) and shows them in `devid status`, the TUI and the app. It never installs them by itself. In the TUI, the same actions are on the Settings page.

## Troubleshooting

Start with `devid doctor`. It checks every part of the installation and prints a fix for each problem:

- `PATH`;
- the LaunchAgent;
- the daemon, DNS, the web server and PHP;
- the system setup;
- `.test` resolving;
- the CA;
- Valet.

| Symptom | Fix |
|---|---|
| `php` is still Homebrew's or another one | Open a new terminal (or `exec zsh`). `~/.devid/bin` must come first on `PATH`. |
| "daemon is not running" | Run `devid setup` again. It is safe to repeat. Logs: `~/.devid/log/daemon.log`. |
| `.test` does not resolve, or ports 80/443 do not answer | Run `devid helper status`, then `devid helper install`. |
| A site shows the wrong PHP version | Run `devid sites` to see each site's version, then `devid isolate <version>` inside the project. |
| The certificate is not trusted | Run `devid helper install` to trust the CA again, then restart the browser. |

**Reporting a bug:** open a [Bug report](https://github.com/hadziqmtqn/devid-binaries/issues/new/choose) with your `devid --version`, macOS version and `devid doctor` output.

## Uninstall

```sh
devid uninstall --dry-run      # show what would change
devid uninstall                # undo setup; keeps ~/.devid (PHP, config, CA, certificates)
devid uninstall --purge        # also delete ~/.devid
```

Uninstall undoes the system setup (with sudo), removes the LaunchAgents, the `PATH` line and Devid.app, and deletes `~/.devid/bin`.

## Files

Everything lives in `~/.devid`:

| Path | Contents |
|---|---|
| `bin/` | `devid`, plus `php` and `composer` (hard links to `devid`) |
| `config.toml` | Settings: `.test` domain, web server, default PHP, ports (8088/8443 behind pf, DNS 53535), parked folders, links, isolated and ignored sites, `autostart`, and `update_check_minutes`. Prefer the commands to editing it. |
| `php/<version>/` | PHP binaries, `etc/php.ini` (yours to edit), `etc/conf.d/` (switches for Xdebug, pcov and catalog extensions) |
| `php-ext/<version>/` | Catalog extensions (`devid php ext install`), one folder each |
| `nginx/`, `caddy/`, `apache/` | Web server binaries and generated configs (rewritten by Devid) |
| `ca/`, `certs/` | The local CA, the CA bundle and per-site certificates |
| `log/` | Daemon, php-fpm and web server logs |
| `run/` | The daemon socket and pid files |
