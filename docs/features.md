# Feature Reference

This document summarizes Stack Pilot's operational entry points. For supported systems, exact PHP profile extension lists, configuration safety, and licensing, see the project [README](../README.md).

## Entry points

| Script | Purpose |
| --- | --- |
| `install.sh` | Interactive installation, dependency preflight, resumable component builds, and final health checks |
| `vhost.sh` | Add, remove, and list virtual hosts; assign PHP-FPM; request, renew, and inspect certificates |
| `addons.sh` | Install compatible PECL and additional extensions for an installed PHP version |
| `service.sh` | Start, stop, restart, reload, inspect services, and switch the default CLI PHP version |
| `backup.sh` | Back up websites, MySQL/MariaDB, Redis, or all supported data and clean expired backups |
| `upgrade.sh` | Rebuild selected installed components with snapshots, health checks, and automatic rollback |
| `reset-password.sh` | Safely reset MySQL, MariaDB, or Redis credentials and update private configuration |
| `uninstall.sh` | Selectively uninstall components or uninstall all, with protected data deletion |

## Installation workflow

The installer can select Nginx, multiple PHP versions, one database engine, Redis, Memcached, Certbot, and Composer. Nginx, MySQL, MariaDB, and Redis use curated version lists. Directory settings come from the private `options.conf`; component choices, versions, ports, passwords, profiles, extensions, firewall rules, and security hardening are handled by the wizard.

Before installation, it checks:

- supported distribution and major version;
- package-manager readiness and active `apt`/`dpkg` locks;
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

## Security and firewall behavior

- Redis and Memcached bind to `127.0.0.1` by default.
- Database, Redis, and Memcached ports are not exposed through the firewall by default.
- Web firewall ports are opened only when explicitly selected.
- Nginx virtual hosts deny hidden-file access by default.
- PHP disables `expose_php` and `display_errors` by default and supports a configurable `disable_functions` list.
- Runtime secrets are stored in ignored mode-`600` files, never in `options.example.conf`.

## Backup, upgrade, and uninstall safety

Backup output is published atomically only after successful creation. Database passwords are not placed in process arguments. Upgrades snapshot the existing installation and restore it if rebuild or service health checks fail.

Uninstallation removes only validated managed paths. Application data, websites, certificates, logs, source packages, and backups are preserved by default. Explicit business-data removal requires additional confirmation, and shared roots such as `/`, `/usr/local`, and `/data` are always rejected as deletion targets.

## Source and release hygiene

Official source URLs and optional SHA256 values are centralized in `versions.conf`. Downloaded archives are cached under `src/`, which is excluded from Git and release packages.

Public releases include `options.example.conf` with empty secrets. Private `options.conf`, `.state/`, logs, backups, certificates, archives, editor metadata, and internal development records are excluded.
