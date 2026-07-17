# Stack Pilot

Stack Pilot is an interactive Bash installer and operations toolkit for an Nginx, PHP, and database stack. It supports side-by-side PHP versions, curated versions of the main services, dependency preflight checks, virtual hosts, TLS certificates, backups, upgrades, password resets, service operations, and safe selective uninstallation.

phpMyAdmin is intentionally not included.

## Supported operating systems

| Distribution | Supported major versions | Repository strategy |
| --- | --- | --- |
| CentOS | 7–10 | Base/Extras on 7, PowerTools on 8, CRB on 9–10, and EPEL when selected extensions need it |
| Ubuntu | 22–26 | Version-aware package names, including `t64`, PCRE2, and newer FreeType transitions |
| Debian | 11–13 | Version-aware package names for PCRE, FreeType, and `libaio` transitions |

CentOS 7/8 and end-of-life Ubuntu releases no longer receive normal upstream security updates. Stack Pilot does not silently replace repository configuration; configure an appropriate archive repository before installation when using an end-of-life system. Use a maintained operating system for production deployments.

## Quick start

```bash
chmod +x *.sh
./install.sh
```

On the first run, Stack Pilot creates a private `options.conf` from `options.example.conf` and sets its permissions to `600`. Edit the private file if you want to prepare settings before starting the wizard:

```bash
cp options.example.conf options.conf
chmod 600 options.conf
vi options.conf
./install.sh
```

Never commit `options.conf`: the installer writes database and Redis passwords to it. The file is excluded by `.gitignore`; only the password-free `options.example.conf` belongs in source control.

The installer uses standard ports by default and asks whether to change them. When enabled, it prompts only for the selected services, validates the `1–65535` range, and rejects duplicate ports.

## Interactive controls

- Up/Down: move through a menu.
- Left: return to the previous menu where back navigation is available.
- Space: select or clear an item in a multi-select menu.
- Enter: confirm the current selection.
- Non-interactive input: automatically uses a plain-text fallback for tests and automation.

## Components and versions

The maintained version lists are stored in `versions.conf`:

| Component | Install model | Curated versions |
| --- | --- | --- |
| Nginx | One selected version | 1.24.0, 1.26.3, 1.28.1 |
| PHP | Multiple versions side by side | 5.4–5.6, 7.0–7.4, 8.0–8.5 |
| MySQL | One selected version | 5.7.44, 8.0.42, 8.4.0 |
| MariaDB | One selected version | 10.6.22, 10.11.15, 11.4.9 |
| Redis | One selected version | 6.2.19, 7.2.10, 8.4.0 |
| Memcached | One instance | Current supported source configuration |
| Certbot | Distribution-supported package | Installed through the system package manager or supported fallback |
| Composer | Current official installer | Installed with an available PHP binary |

Nginx, MySQL, MariaDB, and Redis allow a version to be selected during installation or configured in `options.conf`. They currently use a single-instance model. Running multiple instances of one of these services would also require separate ports, data paths, sockets, PID files, configurations, and systemd unit names; Stack Pilot does not create that topology automatically.

PHP versions are isolated under paths such as `/usr/local/services/php/84` and use independent PHP-FPM services and ports. A virtual host can be assigned to any installed PHP version.

## PHP installation profiles

The profile controls the default extension set. Rare, workload-specific, and debugging extensions are not selected by default; use `Custom` when you need them.

### Minimal

For a small PHP-FPM runtime with common database and HTTP support.

- Built in: `opcache`, `mysqli`, `pdo_mysql`, `mbstring`, `curl`, `openssl`
- PECL/additional: none

### Recommended

The default for common Laravel, WordPress, and ThinkPHP applications.

- Built in: `opcache`, `mysqli`, `pdo_mysql`, `mbstring`, `curl`, `openssl`, `gd`, `zip`, `fileinfo`, `exif`, `intl`, `bcmath`, `sockets`, `pcntl`, `bz2`, `sodium`
- PECL/additional: `redis`, `imagick`

### Full

For broad compatibility with extensions commonly offered by hosting control panels. This increases dependency count, compile time, memory use, and failure surface.

- Built in: `opcache`, `mysqli`, `pdo_mysql`, `mbstring`, `curl`, `openssl`, `gd`, `zip`, `fileinfo`, `exif`, `intl`, `bcmath`, `sockets`, `pcntl`, `soap`, `ldap`, `imap`, `xsl`, `gettext`, `gmp`, `calendar`, `shmop`, `sysvsem`, `sysvshm`, `sysvmsg`, `ftp`, `bz2`, `sodium`, `readline`, `ffi`, `posix`, `dba`, `tidy`, `snmp`, `pgsql`, `pdo_pgsql`
- PECL/additional: `redis`, `memcached`, `imagick`, `swoole`, `mongodb`, `yaf`, `yar`, `apcu`, `igbinary`, `msgpack`, `yaml`, `uuid`, `ssh2`, `rdkafka`, `oauth`

### Custom

The wizard opens multi-select menus for all supported compiled and PECL/additional extensions. Press Left to return to the previous PHP menu.

Available compiled extensions include:

`opcache`, `mysqli`, `pdo_mysql`, `mbstring`, `curl`, `openssl`, `gd`, `zip`, `fileinfo`, `exif`, `intl`, `bcmath`, `sockets`, `pcntl`, `soap`, `ldap`, `imap`, `xsl`, `gettext`, `gmp`, `calendar`, `shmop`, `sysvsem`, `sysvshm`, `sysvmsg`, `ftp`, `bz2`, `sodium`, `readline`, `ffi`, `posix`, `dba`, `tidy`, `snmp`, `pgsql`, `pdo_pgsql`.

Available PECL/additional extensions include:

`redis`, `memcached`, `memcache`, `imagick`, `swoole`, `xdebug`, `mongodb`, `yaf`, `yar`, `protobuf`, `grpc`, `event`, `amqp`, `apcu`, `igbinary`, `msgpack`, `yaml`, `uuid`, `ssh2`, `rdkafka`, `oauth`, `ioncube`.

Some extensions are version-dependent. Stack Pilot selects compatible PECL package versions where supported and skips extensions that cannot be installed safely for the chosen PHP version. IMAP is skipped on PHP 8.4+ because PHP unbundled and deprecated it, and on current distributions that no longer provide its legacy c-client build dependency. `ioncube` remains a manual installation because its license and binary compatibility require explicit operator handling. `xdebug`, `grpc`, `protobuf`, `event`, `amqp`, and legacy `memcache` are available in Custom but are not enabled by the default profiles.

Install more extensions later with:

```bash
./addons.sh
```

## Dependency preflight

Every selected feature declares its required operating-system packages before the installation begins. Stack Pilot:

- detects the distribution, major version, architecture, and package manager;
- enables only the required supported development repositories;
- waits for active `apt`/`dpkg` locks instead of racing another package process;
- refreshes package metadata once per run;
- maps renamed dependency packages by operating-system version;
- checks package availability before compiling software;
- installs the complete dependency set for the selected components and PHP extensions;
- reports unresolved packages before any source build starts.

If a feature adds a new build dependency, its package mapping and availability check must be added to the preflight stage in the same change.

## Virtual hosts and TLS

```bash
./vhost.sh
```

Supported site templates use framework-appropriate terminology and routing:

- PHP front controller: missing routes fall back to `index.php`.
- Laravel: the web root points to `public` and uses Laravel's recommended Nginx `try_files` route.
- ThinkPHP: the web root normally points to `public` and enables its URL rewrite route.
- Static site: missing files return `404`.

These options define the web root, PHP handling, and Nginx routing; they are more than a generic “rewrite rule” switch.

Before requesting a Let's Encrypt HTTP-01 certificate, Stack Pilot checks every requested domain and alias for DNS resolution and verifies that a temporary challenge file is publicly readable through port 80. Certbot is not called when DNS, the virtual host, webroot routing, or public HTTP access fails.

## Operations

```bash
./service.sh          # start, stop, restart, reload, status, or switch CLI PHP
./backup.sh           # website, database, Redis, or complete backups
./upgrade.sh          # upgrade supported installed components with rollback
./reset-password.sh   # reset MySQL, MariaDB, or Redis credentials
./uninstall.sh        # selective uninstall or uninstall all
```

Switching the CLI PHP version updates managed links for `php`, `phpize`, `php-config`, `pecl`, and `pear`. It does not change the PHP-FPM version assigned to existing virtual hosts.

Backups are written to temporary `.part` files and published only after successful, non-empty output. Database credentials are passed through a temporary mode-`600` client file, and Redis runs `SAVE` before its data directory is archived.

Upgrades create configuration backups and installation-directory snapshots. A rebuilt component must pass its health check before the upgrade is accepted; a failure triggers an automatic restore of the previous installation.

The uninstaller supports selected components or all components. It preserves databases, Redis data, websites, certificates, logs, backups, and source caches unless deletion is explicitly selected. Destructive data removal requires the confirmation words shown by the wizard, and unsafe/shared root paths are rejected.

## Important paths

Defaults can be changed in the private `options.conf`.

| Purpose | Default |
| --- | --- |
| Programs | `/usr/local/services` |
| Service data | `/usr/local/data` |
| Websites | `/data/www` |
| Runtime files | `/data/pid`, `/data/sock` |
| Logs | `/data/logs` |
| Backups | `/data/backup` |
| Download cache | `src/` inside the project |
| Installer state | `.state/` inside the project |

## Tests

Run the complete local test suite and Bash syntax checks:

```bash
bash tests/run.sh
```

Release validation should also deploy a clean package and run the suite on supported CentOS, Debian, and Ubuntu hosts. Runtime secrets, state, downloaded archives, logs, backups, and certificates must not be included in the deployment package.

## Configuration files

- `options.example.conf`: public, password-free example defaults.
- `options.conf`: private runtime configuration generated on first use and ignored by Git.
- `versions.conf`: curated component versions, upstream download URLs, and optional SHA256 checksums.

## License

Stack Pilot's original source code is licensed under the [Apache License 2.0](LICENSE).

Nginx, PHP, MySQL, MariaDB, Redis, Memcached, Certbot, Composer, PECL extensions, libraries, and other software installed or downloaded by Stack Pilot remain governed by their respective upstream licenses. Stack Pilot does not relicense those third-party components. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
