# Feature Reference

This document summarizes Stack Pilot's operational entry points. For supported systems, exact PHP profile extension lists, configuration safety, and licensing, see the project [README](../README.md).

## Entry points

| Script | Purpose |
| --- | --- |
| `install.sh` | Interactive installation, dependency preflight, resumable component builds, and final health checks. `--unattended` takes every answer from `options.conf` |
| `status.sh` | Component versions, service state, listening ports, certificate expiry, disk usage, and whether rotation and renewal are scheduled |
| `vhost.sh` | Add, remove, and list virtual hosts; assign PHP-FPM; request, renew, and inspect certificates |
| `addons.sh` | Install compatible PECL and additional extensions for an installed PHP version |
| `service.sh` | Start, stop, restart, reload, inspect services, and switch the default CLI PHP version |
| `backup.sh` | Back up websites, a single site, MySQL/MariaDB, Redis, or all supported data and clean expired backups |
| `restore.sh` | Restore a website, a single site, the databases, or Redis, with a pre-restore archive of the current state |
| `upgrade.sh` | Rebuild selected installed components with snapshots, health checks, and automatic rollback |
| `reset-password.sh` | Safely reset MySQL, MariaDB, or Redis credentials and update private configuration |
| `uninstall.sh` | Selectively uninstall components or uninstall all, with protected data deletion |

## Installation workflow

The installer can select Nginx, multiple PHP versions, one database engine, Redis, Memcached, Certbot, Composer, and fail2ban. Nginx, MySQL, MariaDB, and Redis use curated version lists. Directory settings come from the private `options.conf`; component choices, versions, ports, passwords, profiles, extensions, firewall rules, and security hardening are handled by the wizard. `--unattended` skips the wizard and reads every answer from `options.conf` instead, validating each one before anything is installed.

Before installation, it checks:

- supported distribution family and major version, including `ID_LIKE` derivatives;
- package-manager readiness and active `apt`/`dpkg` or libzypp locks;
- dependency package availability for the selected components and extensions;
- disk space, memory, and swap visibility;
- selected port validity, conflicts, and existing listeners;
- legacy PHP compatibility risks;
- already installed components and cached source packages.

Completed steps use `.state/*.done` markers, allowing a repeated run to skip healthy completed work. Upgrade operations explicitly bypass this normal skip behavior.

## PHP multi-version layout

PHP 5.4 through PHP 8.5 can be selected. Each version has its own installation directory, PHP-FPM configuration, systemd unit, log, and FPM port. The CLI default is managed independently from virtual-host PHP assignments.

Profiles are:

- `minimal`: core PHP-FPM, MySQL drivers, strings, HTTP, TLS, and OPcache.
- `web`: the recommended application set plus common image, archive, internationalization, process, Redis, and ImageMagick support.
- `full`: the broad hosting-panel compatibility set.
- `custom`: manual multi-select menus for compiled and PECL/additional extensions.

Unsupported extensions are skipped according to the selected PHP version. PECL packages use a compatibility matrix for legacy PHP releases.

## Virtual-host routing

Available templates are PHP front controller, Laravel, ThinkPHP, and static site. Each template defines an appropriate web root, PHP handling, and `try_files` behavior. A site can be reassigned to another installed PHP-FPM version.

Certificate requests use Certbot's webroot authenticator. DNS resolution and public HTTP-01 reachability are checked for the primary domain and every alias before contacting the certificate authority. Renewal uses a systemd timer when possible and falls back to cron.

`client_max_body_size` follows `php_post_max_size` unless overridden, because Nginx rejects an oversized body with `413` before PHP is reached and its own default is `1m`. Security response headers are added to every generated server block, with HSTS on HTTPS blocks only. Optional per-IP `limit_req`/`limit_conn` zones and HTTP/3 are available through `options.conf`; a site is only rendered with rate-limit directives once the matching zone actually exists in the http block, because otherwise `nginx -t` would reject it.

Ownership of a new site is applied to the site directory rather than only to the document root, so a Laravel or ThinkPHP layout whose document root is `<site>/public` still leaves `storage/`, `bootstrap/cache/`, and `runtime/` writable by PHP-FPM.

## Security and firewall behavior

- Redis and Memcached bind to `127.0.0.1` by default. A non-loopback Memcached bind address is reported as a warning because Memcached has no authentication.
- Database, Redis, and Memcached ports are not exposed through the firewall by default.
- Web firewall ports are opened only when explicitly selected.
- With `manage_firewall=y`, the active SSH ports are allowed before any other rule and the firewall is then enabled. SSH ports are taken from `SSH_CONNECTION`, `sshd -T`, and `sshd_config`, falling back to `22`. Adding rules without enabling the firewall would look like protection while enforcing nothing, and enabling it without allowing SSH first would drop the administrator's own session.
- The pid and socket directories are mode `0755`. Services that run as a non-root user are granted access to their own runtime directory individually, so a local account cannot pre-create `mysql.sock` and intercept credentials from local clients.
- Bind addresses, memory sizes, and ports are validated wherever they are interpolated into a systemd unit or service configuration, not only at the wizard prompt, because `options.conf` can set them directly.
- Passwords typed into the installer are not echoed and do not remain in the terminal scrollback.
- Nginx virtual hosts deny hidden-file access by default.
- PHP disables `expose_php` and `display_errors` by default and supports a configurable `disable_functions` list. `open_basedir` is written only when `php_open_basedir` is set; an empty directive would clear a restriction configured elsewhere, because this file is loaded last.
- Redis passwords are restricted to characters that survive `requirepass` and a systemd `EnvironmentFile`, at both install and reset time, so a stray space or `#` cannot silently stop the server on its next restart.
- After the database root password is set, it is verified by authenticating with it. MariaDB 10.4+ creates `root@localhost` with the `unix_socket` plugin, where `ALTER USER` can report success while password authentication still fails.
- Passwords are never passed on the command line, and generated credentials are printed to the terminal rather than to stdout, so redirecting a run does not write them to a file.
- Menu actions run so that a single failure returns to the menu instead of terminating the tool, and every prompt loop is bounded so a closed stdin or an invalid configured default cannot spin forever.
- Runtime secrets are stored in ignored mode-`600` files, never in `options.example.conf`. Backups and pre-upgrade snapshots are written at mode `600` inside a mode-`700` directory with an explicit `chmod`, not by relying on the caller's umask, because they contain `options.conf`, `install.txt`, and `redis.conf` in plaintext.
- The service user and group, PHP-FPM pool settings, PHP size limits, the time zone, log-rotation settings, and fail2ban timings are validated wherever they are interpolated into a configuration file. Validation happens before rendering starts rather than at each point of use: these values are substituted inside `$( )` within heredocs, where an abort would end only the substitution and leave a truncated directive behind.
- The Composer installer is never cached, so it always matches the signature downloaded alongside it.
- fail2ban jails, when the component is selected, cover SSH and Nginx using filters that ship with fail2ban. Uninstalling removes only the jail file this installer wrote.

## Backup, restore, upgrade, and uninstall safety

Backup output is published atomically only after successful creation. Database passwords are not placed in process arguments. Database dumps include routines, events, and triggers and run in a single transaction, so nothing is silently missing on restore and a live site is not locked for the length of the dump. Redis is archived after a non-blocking `BGSAVE`. `backup_keep_days` uses an exact day boundary, and `0` disables retention instead of deleting every backup.

Restores name the source file and the target before anything is overwritten, archive the current state first, and refuse any archive outside the backup directory or containing an absolute or traversing path.

Upgrades snapshot the existing installation and restore it if rebuild or service health checks fail. Directories left by a failed upgrade are pruned to the newest `upgrade_keep_failed` copies.

Log rotation is configured for the components that were installed, validated with `logrotate -d`, and removed again if it is rejected, because a single malformed file stops logrotate from processing every other configuration on the host.

Uninstallation removes only validated managed paths. Application data, websites, certificates, logs, source packages, and backups are preserved by default. Explicit business-data removal requires additional confirmation, and shared roots such as `/`, `/usr/local`, and `/data` are always rejected as deletion targets.

## Source and release hygiene

Official source URLs and optional SHA256 values are centralized in `versions.conf`. Downloaded archives are cached under `src/`, which is excluded from Git and release packages.

Public releases include `options.example.conf` with empty secrets. Private `options.conf`, `.state/`, logs, backups, certificates, archives, editor metadata, and internal development records are excluded.
