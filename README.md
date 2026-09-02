# Laravel Docker Multi-Project Server Manager

A single Bash script for hosting multiple Laravel, PHP, WordPress, ThinkPHP/FastAdmin, and Node projects on one Ubuntu server with Docker.

The script creates one shared Nginx reverse proxy with Certbot, then creates one Docker Compose stack per project.

## Features

- Multi-project hosting on one server
- Shared Nginx reverse proxy on ports `80` and `443`
- Automatic Let's Encrypt certificates
- Per-project Docker Compose stacks
- Laravel, generic PHP/WordPress, ThinkPHP/FastAdmin, and Node profiles
- MariaDB, Redis, PHP-FPM, Composer, Node.js, and npm for PHP projects
- Optional phpMyAdmin per project
- Backups and restores
- Multiple domains per project
- Laravel Reverb support
- Optional Roundcube webmail and docker-mailserver management
- Optional Apache Guacamole proxy and managed VNC server
- Per-project access restrictions through Nginx
- RAM/CPU-based tuning when projects are created or updated
- Project ownership and permission repair on create/update
- Automatic Laravel scheduler cron entries for Laravel projects

## Requirements

- Ubuntu Server 22.04 LTS
- Root access
- DNS records pointing to the server
- Firewall ports `80` and `443` open
- A valid email address for Let's Encrypt

## Quick Start

Copy the script to your server:

```bash
scp laravel-server-manager.sh root@SERVER_IP:/root/
```

Make it executable:

```bash
chmod 700 /root/laravel-server-manager.sh
```

Run it:

```bash
sudo /root/laravel-server-manager.sh
```

Choose `1) Create new project` from the menu.

## Common Commands

Run the interactive menu:

```bash
sudo /root/laravel-server-manager.sh
```

Back up all projects:

```bash
sudo /root/laravel-server-manager.sh backup-all
```

Install or refresh cron jobs for SSL renewal, backups, and Laravel schedulers:

```bash
sudo /root/laravel-server-manager.sh setup-cron
```

Check RAM/CPU tuning without changing projects:

```bash
sudo /root/laravel-server-manager.sh capacity-check laravel
sudo /root/laravel-server-manager.sh capacity-check node
```

Open the VNC manager directly:

```bash
sudo /root/laravel-server-manager.sh manage-vnc
```

## Project Profiles

| Profile | Use for | Managed services |
| --- | --- | --- |
| `laravel` | Laravel apps | PHP-FPM, MariaDB, Redis, queue worker, scheduler cron |
| `generic` | WordPress or plain PHP apps | PHP-FPM, MariaDB, Redis |
| `thinkphp` | ThinkPHP/FastAdmin apps | PHP-FPM, MariaDB, Redis |
| `node` | Node apps or games | Node container |

## Important Paths

| Path | Purpose |
| --- | --- |
| `/root/laravel-server-manager.sh` | Recommended script location |
| `/opt/laravel-reverse-proxy` | Shared Nginx and Certbot stack |
| `/var/www/projects/<project>` | Project files and Compose stack |
| `/var/www/projects/<project>/.project-meta` | Saved project settings |
| `/var/backups/laravel-projects/<project>` | Project backups |

## Project Layout

Laravel apps should live in:

```text
/var/www/projects/<project>/
  artisan
  public/index.php
```

WordPress or plain PHP apps should usually live in:

```text
/var/www/projects/<project>/public/
  index.php
```

Node apps should live in:

```text
/var/www/projects/<project>/
  package.json
  server.js
```

For Node projects, HTTP traffic is proxied to port `8080` and WebSocket traffic under `/ws/` is proxied to port `3533`.

## Capacity Tuning

When a project is created or updated, the script checks the server's total RAM and CPU cores and asks how tuning should be applied:

- `auto`: choose values automatically from server RAM/CPU.
- `preset`: choose `conservative`, `balanced`, `performance`, or `maximum`.
- `custom`: enter exact PHP/MariaDB/Redis values.

Generated settings include:

- PHP-FPM process counts
- OPcache memory
- MariaDB buffer size and connection count
- Redis maxmemory

The script does not use disk/storage capacity for this decision. It also does not subtract capacity for other projects. Each project is tuned against the full server capacity, and Docker CPU/RAM hard limits are not applied.

The tuning mode, detected capacity, and applied values are stored in `.project-meta`.

## Permissions

When a project is created or updated, the script normalizes ownership and permissions for the project directory.

- App code is owned by `root:root` and kept readable by the containers.
- `.project-meta` is restricted to root.
- `.env` files are readable by the PHP runtime group but not world-readable.
- Laravel/WordPress writable paths such as `storage`, `bootstrap/cache`, and `public/wp-content` are owned by the PHP runtime user.
- Node project `data` is kept writable by the Node container.

## Typical Workflow

1. Point your domain's DNS `A` or `AAAA` record to the server.
2. Run the script as root.
3. Create a project from the menu.
4. Upload your app files to `/var/www/projects/<project>`.
5. Run `6) Update project` if you changed the app layout or want to regenerate configs.
6. Use `4) Manual project backup` before risky changes.

## Backups

The script can create manual backups per project and automatic backups for all projects.

By default, project backups are stored in:

```text
/var/backups/laravel-projects/<project>/
```

Retention can be managed from the menu with `18) Backup settings`.

## Security Notes

- Run this only on a server you control.
- Keep `/root/laravel-server-manager.sh` readable only by trusted admins.
- Project metadata contains database credentials.
- phpMyAdmin is bound to `127.0.0.1` by default. Public exposure is optional and should be used carefully.
- The default reverse proxy blocks direct access by server IP on ports `80` and `443`.
- Always review generated Docker Compose files before adapting this script for shared or untrusted environments.

## Troubleshooting

Check generated project files:

```bash
cd /var/www/projects/<project>
docker compose ps
docker compose logs
```

Check a Laravel project's scheduler log:

```bash
tail -f /var/log/laravel-scheduler-<project>.log
```

Check the reverse proxy:

```bash
cd /opt/laravel-reverse-proxy
docker compose ps
docker compose logs reverse-proxy
docker compose exec reverse-proxy nginx -t
```

Regenerate one project:

```bash
sudo /root/laravel-server-manager.sh
# choose: 6) Update project
```

## Notes

This script is intentionally practical and opinionated. It is useful for small servers, demos, client projects, and self-managed deployments where a full orchestration platform would be overkill.
