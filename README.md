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
- Backups and restores with per-project schedules and optional Google Drive/OneDrive copies
- Multiple domains per project
- Laravel Reverb support
- Optional Roundcube webmail and docker-mailserver management
- Optional Apache Guacamole proxy and managed VNC server
- Per-project access restrictions through Nginx
- RAM/CPU-based tuning when projects are created or updated
- Project ownership and permission repair on create/update
- Automatic Laravel scheduler cron entries for Laravel projects
- Optional production vLLM platform with a private multi-model runtime, OpenAI-compatible Gateway, administration panel, authenticated chat portal, GPU-aware capacity controls, API keys, quotas, IP allowlists, usage accounting, hardware-change detection, portable backup/restore, and isolated private coding-agent/IDE access

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

Back up all projects immediately (ignores their automatic intervals):

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

Inspect and control the AI platform non-interactively:

```bash
sudo /root/laravel-server-manager.sh ai-status
sudo /root/laravel-server-manager.sh ai-hardware
sudo /root/laravel-server-manager.sh ai-gpu-info
sudo /root/laravel-server-manager.sh ai-models
sudo /root/laravel-server-manager.sh ai-start
sudo /root/laravel-server-manager.sh ai-stop
sudo /root/laravel-server-manager.sh ai-restart
sudo /root/laravel-server-manager.sh ai-diagnostics
sudo /root/laravel-server-manager.sh ai-backup
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
| `/opt/vllm-ai-platform` | AI services, configuration, database, cache, model registry and weights |
| `/var/backups/vllm-ai-platform` | Restricted AI configuration/database backups |

## vLLM / AI Platform

Choose `22) Manage vLLM / AI Platform` to install or operate the optional subsystem. On a normal VPS it reuses the existing Nginx/Certbot stack and `laravel-shared` network; it does not publish PostgreSQL, Redis, controller, or vLLM ports on the host. The public HTTPS domain routes `/v1/` to the authenticated Gateway and the remaining paths to the optional administration/chat application.

When a Vast.ai or similar CUDA container has no Docker daemon, the same manager can install an isolated native runtime instead. Native mode keeps the provider Jupyter environment unchanged, uses a dedicated platform virtual environment, a separate vLLM virtual environment, SQLite plus loopback-only Redis, and loopback-only HTTP/model listeners. Start it directly with `./laravel-server-manager.sh ai-install-native` or accept the native fallback offered by the normal installer.

Native installations can be published through `21) External domain / Cloudflare Tunnel` in the AI Platform menu (or `./laravel-server-manager.sh ai-external`). The workflow stores the remotely-managed tunnel connector token in a protected file, runs `cloudflared` under the platform Supervisor, enables secure cookies/CORS for the chosen panel hostname, optionally publishes a separate API hostname, reports public health, exposes logs, and can return the platform to private SSH-only access. Cloudflare Published application routes must map the panel hostname to `http://localhost:18080` and the optional API hostname to `http://localhost:8000`; Jupyter and raw model ports are never included.

The AI assets are kept in the maintainable [`ai-platform`](./ai-platform) directory rather than embedded in the Bash script. Keep that directory beside `laravel-server-manager.sh` when copying the manager to a server. Full architecture, GPU requirements, first-install, model operations, API integration, upgrades, migration, backup/restore, rollback, security, and troubleshooting instructions are in the [AI Platform operations guide](./ai-platform/README.md). Private Codex-compatible, VS Code and Continue setup is in the [coding-agent and IDE guide](./ai-platform/CODING-AGENTS.md). Existing provider-managed Jupyter/JupyterLab environments—including Vast.ai Jupyter CUDA images—are detected, preserved and exposed through read-only diagnostics; secure Gateway test notebooks can be generated without embedded credentials. See the [Jupyter integration guide](./ai-platform/JUPYTER.md).

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

Use `18) Backup settings` to configure each project independently:

- The number of days local backups are retained (14 by default).
- How many hours must pass between automatic backups, using a 1-to-24-hour daily cycle (24 by default).
- Optional replication of manual backups, automatic backups, or both to Google Drive or OneDrive through `rclone`.
- Interactive navigation and folder creation when selecting the destination in the configured cloud account.

The manager checks for due backups hourly at minute 30. It prevents overlapping scheduled runs and records successful runs in `/var/lib/laravel-manager/backup-state`. When cloud copies are enabled, each project can replicate manual backups only, automatic backups only, or both. The same per-project retention period is applied to local and cloud copies.

When cloud copies are enabled, the manager compares the installed rclone version with the official stable-release manifest. It runs rclone's official HTTPS installer only when rclone is missing or outdated, and verifies the resulting version before opening the account-configuration wizard. It does not install the outdated Ubuntu repository package. OAuth credentials remain in rclone's root-user configuration; they are not written to `.project-meta`.

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
