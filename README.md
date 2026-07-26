# Stack Pilot

Stack Pilot is an interactive Bash installer and operations toolkit for an Nginx, PHP, and database stack. It supports side-by-side PHP versions, curated versions of the main services, dependency preflight checks, virtual hosts, TLS certificates, backups, upgrades, password resets, service operations, and safe selective uninstallation.

phpMyAdmin is intentionally not included.

## Supported operating systems

Distributions are grouped into families that share a package manager and a package-naming scheme. Everything below the detection layer keys off the family, not the individual distribution.

| Distribution | Supported major versions | Package manager | Repository strategy |
| --- | --- | --- | --- |
| Ubuntu | 22–26 | `apt-get` | Version-aware package names, including `t64`, PCRE2, and newer FreeType transitions |
| Debian | 11–13 | `apt-get` | Version-aware package names for PCRE, FreeType, and `libaio` transitions |
| CentOS Stream | 7–10 | `dnf`/`yum` | Base/Extras on 7, PowerTools on 8, CRB on 9–10, plus EPEL when selected extensions need it |
| Rocky Linux | 8–10 | `dnf`/`yum` | PowerTools on 8, CRB on 9–10, plus EPEL; both repository spellings are tried |
| AlmaLinux | 8–10 | `dnf`/`yum` | Same as Rocky Linux |
| RHEL | 8–10 | `dnf`/`yum` | `codeready-builder-for-rhel-<major>-<arch>-rpms`, plus the published EPEL release RPM when the package is not already available |
| Oracle Linux | 8–10 | `dnf`/`yum` | `ol<major>_codeready_builder` and `oracle-epel-release-el<major>` |
| Amazon Linux | 2023 | `dnf` | Base repositories only; AL2023 has neither CRB nor EPEL, and follows EL9 package naming |
| openSUSE Leap | 15–16 | `zypper` | Configured repositories; SUSE `-devel` package names |
| SLES | 15–16 | `zypper` | Configured repositories; PackageHub may be required for some `-devel` packages |
| openSUSE Tumbleweed | rolling | `zypper` | Configured repositories; the snapshot `VERSION_ID` is not range-checked |

Amazon Linux 2 is EL7-based and out of scope; use Amazon Linux 2023.

A distribution that is not listed but declares a known `ID_LIKE` (for example openEuler, Anolis OS, Kylin, Linux Mint, or Raspbian) is accepted through its family with a warning that the exact release is untested. Its package names still pass through the dependency preflight, so a mismatch is reported by name before any source build starts rather than failing mid-compile.

The package maps for RHEL, Oracle Linux, Amazon Linux 2023, and the SUSE family follow each vendor's documented `-devel` package names and are covered by unit tests, but they have not been exercised on live hosts of every listed release. Run `preflight_system_dependencies` on a target host before treating a combination as validated; it lists every unresolved package with the feature that needs it.

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

### Unattended installation

```bash
./install.sh --unattended
```

Every answer is taken from `options.conf` instead of a prompt, so the file written by a finished install reproduces that install on another host or from CI. Values that a prompt would normally have validated are checked up front, and the run stops naming the option rather than failing later inside a build: unsupported components, two database engines at once, an invalid time zone or service account, out-of-range ports or pool sizes, and passwords that would break the configuration files they are written into. An empty database password is generated exactly as in the wizard and recorded in `install.txt`.

Add `LNMP_DRY_RUN=1` to validate and report without installing anything.

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
| fail2ban | Distribution-supported package | Optional; only the jail file for this stack is managed |

The Composer installer is fetched fresh on every run rather than served from the download cache, because it is verified against a signature that is also fetched fresh. A cached installer from an earlier release could never match the current signature again, which turned an upstream update into a permanent checksum failure.

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

A PECL extension that fails to build is a warning inside thousands of lines of compiler output, so the failures are collected, listed again at the end of the run, and recorded in `install.txt`. Otherwise the first sign of a missing extension is a "class not found" error in production.

### PHP runtime settings

The time zone chosen in the wizard is written to PHP as `date.timezone` and applied to the system clock with `timedatectl` where available. Exporting `TZ` only affects the installer process, so without this a site would silently run in UTC no matter what was configured. Set `LNMP_SET_SYSTEM_TIMEZONE=n` to leave the host clock alone.

`php_pm`, the pool sizes, and the `memory_limit`/`upload_max_filesize`/`post_max_size`/`max_execution_time` values are validated wherever they are written into `php-fpm.d/www.conf`, not only at the wizard prompt, because `options.conf` can set them directly. An unusable process-manager name or size unit stops php-fpm from starting at all, and a value containing a newline would append further `php_admin_value` directives to the pool. For `pm=dynamic` the ordering `min_spare ≤ start_servers ≤ max_spare ≤ max_children` is checked as well.

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

Certificates are requested with `--cert-name` and `--keep-until-expiring`, so repeating the wizard for an unchanged site reuses the existing certificate instead of consuming Let's Encrypt's limit of 5 duplicate certificates per week. When a certificate cannot be issued, the site is left serving working HTTP rather than being switched to a TLS configuration that points at files which do not exist.

Adding a virtual host that already exists asks for confirmation first and warns when the existing configuration serves HTTPS, because replacing it also replaces the TLS server block. A newly created site is handed to the service account so PHP-FPM can write uploads, Laravel `storage`, and ThinkPHP `runtime`. Ownership applies to the site directory rather than only the document root, because a Laravel or ThinkPHP document root is `<site>/public` while the directories the framework writes to are siblings of it. An existing site is left untouched, since it may already hold a deployed application.

### Request size, headers, and rate limiting

Nginx rejects an oversized request body with `413` before PHP ever runs, and its built-in default is `1m`. `client_max_body_size` therefore follows `php_post_max_size` unless `nginx_client_max_body_size` overrides it, so the two sides of the stack cannot disagree about the upload limit.

Generated virtual hosts send `X-Content-Type-Options`, `X-Frame-Options`, and `Referrer-Policy`, plus `Strict-Transport-Security` on HTTPS server blocks only. Set `nginx_security_headers=n` to omit them, or `nginx_hsts_max_age=0` to drop HSTS alone.

`nginx_rate_limit=y` declares per-IP `limit_req` and `limit_conn` zones in the http block and applies them to each site. The zones are written at install time, so switching the option on afterwards needs an installer run before newly added sites can use it; a site rendered without the zone present would otherwise fail `nginx -t`.

`nginx_http3=y` builds Nginx with `--with-http_v3_module`, adds a `listen … quic` line and an `Alt-Svc` header, and opens UDP on the HTTPS port when the firewall is managed. It requires Nginx 1.25.0 or newer and is refused before the build otherwise. Brotli is not included: it needs a third-party module fetched from source at build time, which is out of scope here; `gzip` is configured with a content-type list instead.

### fail2ban

Adding `fail2ban` to the component list installs it and writes `/etc/fail2ban/jail.d/stack-pilot.local` with the `sshd`, `nginx-http-auth`, and `nginx-botsearch` jails pointed at this installation's log paths, plus `nginx-limit-req` when rate limiting is enabled. All of these filters ship with fail2ban itself. Uninstalling removes only that file; fail2ban and any jails you added stay, because they may protect services unrelated to this stack.

## Operations

```bash
./status.sh           # versions, service state, ports, certificate expiry, disk usage
./service.sh          # start, stop, restart, reload, status, or switch CLI PHP
./backup.sh           # website, one site, database, Redis, or complete backups
./restore.sh          # restore a website, one site, the databases, or Redis
./upgrade.sh          # upgrade supported installed components with rollback
./reset-password.sh   # reset MySQL, MariaDB, or Redis credentials
./uninstall.sh        # selective uninstall or uninstall all
```

`status.sh` answers "what is actually running here?" in one place: installed versions, whether each service is running, whether its port is listening, certificate expiry read directly from the certificate files, disk usage of the web root, logs, backups, and source cache, and whether log rotation and certificate renewal are actually scheduled. It reports a state it cannot determine as unknown rather than guessing, and never fails because something is missing.

Switching the CLI PHP version updates managed links for `php`, `phpize`, `php-config`, `pecl`, and `pear`. It does not change the PHP-FPM version assigned to existing virtual hosts.

Backups are written to temporary `.part` files and published only after successful, non-empty output, at mode `600` inside a mode-`700` directory, because they contain database dumps and site data. Database credentials are passed through a temporary mode-`600` client file. Database dumps include routines, events, and triggers and run in a single transaction, so stored procedures and scheduled events are not silently missing from a restore and a live site is not locked for the length of the dump. Redis is archived after a non-blocking `BGSAVE` rather than a `SAVE` that would stall every client. `backup_keep_days` removes artifacts older than exactly that many days; `0` disables retention rather than deleting everything.

`restore.sh` is the other half: it lists the available backups, shows exactly which file will be written where, archives the current state before overwriting it, and refuses any archive that lies outside the backup directory or names an absolute or traversing path. Redis is stopped for the swap because it only loads its dump at startup.

Upgrades create configuration backups and installation-directory snapshots. A rebuilt component must pass its health check before the upgrade is accepted; a failure triggers an automatic restore of the previous installation. Because those archives contain `options.conf` and `redis.conf` in plaintext, `upgrade.sh` writes them privately. Directories left behind by a failed upgrade are pruned to the newest `upgrade_keep_failed` copies instead of accumulating a full tree per failure.

### Log rotation

Installation writes `/etc/logrotate.d/stack-pilot` covering Nginx, PHP-FPM, and the data services that are actually installed. Nginx and PHP-FPM are signalled with `SIGUSR1` to reopen their files; MySQL, MariaDB, Redis, and Memcached hold their log open and are truncated in place instead. The generated file is validated with `logrotate -d` and removed again if it is rejected, since one malformed file stops logrotate from processing every other configuration on the host. Set `manage_logrotate=n` to opt out, or tune `logrotate_interval` and `logrotate_keep`.

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

Release validation should also deploy a clean package and run the suite on at least one host per supported family: an APT host (Debian or Ubuntu), an RPM host (CentOS Stream, Rocky, AlmaLinux, RHEL, Oracle Linux, or Amazon Linux 2023), and a `zypper` host (openSUSE Leap or SLES). Runtime secrets, state, downloaded archives, logs, backups, and certificates must not be included in the deployment package.

## Configuration files

- `options.example.conf`: public, password-free example defaults.
- `options.conf`: private runtime configuration generated on first use and ignored by Git.
- `versions.conf`: curated component versions, upstream download URLs, and optional SHA256 checksums.

## License

Stack Pilot's original source code is licensed under the [Apache License 2.0](LICENSE).

Nginx, PHP, MySQL, MariaDB, Redis, Memcached, Certbot, Composer, PECL extensions, libraries, and other software installed or downloaded by Stack Pilot remain governed by their respective upstream licenses. Stack Pilot does not relicense those third-party components. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
