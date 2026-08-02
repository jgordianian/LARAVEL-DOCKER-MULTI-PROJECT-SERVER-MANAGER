# Laravel Server Manager (Docker, Multi-Project) for Ubuntu 22.04

`laravel-server-manager.sh` is a single Bash script that provisions a Docker-based reverse proxy (Nginx + Certbot) and lets you create, update, backup, restore, list, and delete multiple PHP projects (Laravel, WordPress, or any PHP app) and Node game projects on the same Ubuntu Server 22.04 host.

It creates one shared reverse proxy stack in `/opt/laravel-reverse-proxy` and one Docker Compose stack per project in `/var/www/projects/<project>`.

## What it sets up

- Docker Engine (via Ubuntu packages) and Docker Compose v2 (plugin) when missing
- Shared reverse proxy:
  - Nginx container: `laravel-reverse-proxy` (ports 80/443)
  - Certbot container: `laravel-certbot` (used for issuance/renewal)
- Per-project stack:
  - PHP-FPM container: `<project>-php`
  - MariaDB container: `<project>-db`
  - Redis container: `<project>-redis`
  - or Node container for `node` profile projects: `<project>-node`
- Composer, Node.js, and npm available inside each PHP container
- Default PHP upload limit set to 5 GB, with matching Nginx body size and 600-second PHP/FastCGI upload timeouts
- PHP extensions enabled in the image (high-level): `curl`, `pdo_mysql`, `mysqli`, `opcache`, `zip`, `mbstring`, `redis`, `gd`, `intl`, `bcmath`, `exif`, `pcntl`
- Project profiles for Laravel, generic PHP, ThinkPHP/FastAdmin apps, and Node games/apps
- Nginx virtual hosts per project, including optional additional project domains/aliases
- Lets Encrypt certificates (HTTP-01 webroot challenge)
- Daily cron jobs for SSL renewal and backups

## Requirements

- Ubuntu Server 22.04 LTS
- Root access (the script must run as root)
- DNS pointing to your server IP
- Open firewall ports: 80 and 443

## Install / Run

1. Copy the script to your server, for example:

   - `/root/laravel-server-manager.sh`

2. Make it executable:

   - `chmod +x /root/laravel-server-manager.sh`

3. Run it as root:

   - `sudo /root/laravel-server-manager.sh`

The script is interactive and shows a menu.

## Menu options

- `1) Create new project` - creates a new project stack + vhost + SSL cert
- `2) Delete existing project` - removes containers/volumes/vhost/project files/backups
- `3) List projects` - shows known projects and their saved metadata
- `4) Manual project backup` - creates a backup archive for one project
- `5) Restore project from backup` - restores files and DB when the profile has a database
- `6) Update project` - regenerates config and rebuilds containers
- `7) Run backup for all projects now` - runs backups for all projects
- `8) Manage phpMyAdmin` - enables/disables phpMyAdmin and controls exposure
- `9) Change project domain` - change the primary project domain, add/remove extra project domains, list all domains, and issue SSL certs
- `10) Setup email server (docker-mailserver)` - provisions a basic mail server stack and prints DNS instructions
- `11) Setup webmail (Roundcube)` - provisions Roundcube webmail behind the reverse proxy, with optional alias domains
- `12) Manage email domains/mailboxes` - add domains, change the mail host, add/delete mailboxes, reset mailbox passwords, manage DKIM, print/audit DNS help, and repair the Postfix postscreen cache
- `13) Modify webmail (Roundcube)` - change the current webmail domain list and/or mail host
- `14) Manage Reverb` - enable/disable Reverb, change its domain/port, and control local/public exposure
- `15) Reset database passwords` - rotate the project DB user password, MariaDB root password, or both
- `16) Manage Guacamole (stack + proxy)` - provision the shared Apache Guacamole stack, expose or remove `/guacamole/` on an existing project, and control the upstream host:port
- `17) Manage VNC Server (TigerVNC)` - install and control a managed TigerVNC server on the Ubuntu host
- `18) Backup settings` - configure per-project backup retention days
- `19) Manage project UFW` - configure project-specific UFW rules for direct project ports
- `20) Project access settings` - restrict normal project website access by IP/CIDR in Nginx
- `21) Manage webmail password changes` - enable/disable Roundcube password changes, force first-login password changes, and list/clear forced users

## Non-interactive commands

- Backup all projects:
  - `sudo /root/laravel-server-manager.sh backup-all`
- (Re)install cron jobs:
  - `sudo /root/laravel-server-manager.sh setup-cron`
- Open the VNC manager directly:
  - `sudo /root/laravel-server-manager.sh manage-vnc`

## Project domain handling

The script uses the domain **exactly as you type it**.

- If you type `example.com`, it will request a certificate only for `example.com` and configure Nginx `server_name example.com;`.
- If you type `www.example.com`, it will request a certificate only for `www.example.com` and configure Nginx `server_name www.example.com;`.

It does not automatically add or redirect between `www` and apex.

### Multiple domains for one project

Menu option `9) Change project domain` can also attach more than one domain to the same project. This lets a single project answer on two or more URLs, for example:

- `example.com`
- `www.example.com`
- `app.otherdomain.com`

Available actions:

- `change-primary` - replace the saved primary domain in `.project-meta`
- `add-domain` - add an extra domain/alias and issue its own Let's Encrypt certificate
- `remove-domain` - remove an extra domain/alias from Nginx and optionally remove its certificate files
- `list` - show the primary domain and all configured project domains

The primary domain remains stored as:

```bash
DOMAIN=example.com
```

The full domain list is stored as:

```bash
PROJECT_DOMAINS=example.com,www.example.com,app.otherdomain.com
```

The primary domain uses the normal project vhost file:

- `/opt/laravel-reverse-proxy/nginx/conf.d/<project>.conf`

Additional domains use separate alias vhost files:

- `/opt/laravel-reverse-proxy/nginx/conf.d/<project>-alias-<domain>.conf`

Each domain needs its own DNS `A/AAAA` record pointing to the server IP before certificate issuance. When you run `6) Update project`, the script regenerates proxy configs for all saved project domains, not just the primary one.

## Where to upload website files

For a project named `myproject`, the project root is:

- `/var/www/projects/myproject/`

Nginx serves this document root by default:

- `/var/www/projects/myproject/public/`

This is what Nginx serves and what PHP-FPM executes as the document root.

For a Node profile project, Nginx does not serve files directly. It reverse-proxies the project container:

- HTTP app traffic -> `<project>-node:8080`
- WebSocket traffic under `/ws/` -> `<project>-node:3533`

### Node game apps

Use this profile for the fish game.

When creating the project, select:

- `App profile`: `node`

Upload the game files into:

- `/var/www/projects/<project>/`

The expected layout is:

- `/var/www/projects/<project>/server.js`
- `/var/www/projects/<project>/package.json`
- `/var/www/projects/<project>/index.html`
- `/var/www/projects/<project>/data/users.txt` (created automatically by the game server if missing)

The generated container runs `npm install --omit=dev` and then `node server.js`. The generated Nginx config supports HTTPS and WebSocket upgrade headers, so the game can use `wss://your-domain/ws/` in production.

### Laravel apps

Upload the full Laravel application into:

- `/var/www/projects/<project>/`

The expected layout is:

- `/var/www/projects/<project>/artisan`
- `/var/www/projects/<project>/public/index.php`

Do not upload the whole Laravel app into `/var/www/projects/<project>/public/`, or you will end up with `public/public/index.php` and Nginx can return `403 Forbidden` until the project config is regenerated.

If you already uploaded a Laravel app one level too deep, the current script can detect that nested layout when you run `6) Update project` and regenerate the proxy config for it.

The generated Laravel PHP container runs a Supervisor-managed queue worker. By default it uses Redis, queue `default`, `--sleep=1`, `--tries=5`, `--timeout=120`, and `--max-time=3600`. If the project code uses a `webhooks` queue, the manager generates `--queue=webhooks,default`.

Queue worker settings are saved in `.project-meta` and can be overridden before running `6) Update project`:

```bash
LARAVEL_QUEUE_CONNECTION=redis
LARAVEL_QUEUE_NAMES=webhooks,default
LARAVEL_QUEUE_SLEEP=1
LARAVEL_QUEUE_TRIES=5
LARAVEL_QUEUE_TIMEOUT=120
LARAVEL_QUEUE_MAX_TIME=3600
```

### ThinkPHP / FastAdmin apps

When creating a project for a ThinkPHP/FastAdmin app, select:

- `App profile`: `thinkphp`

The generated stack changes from the Laravel defaults:

- PHP image: `php:8.0-fpm-alpine`
- No Laravel queue worker is generated
- PHP extensions include `curl`, `pdo_mysql`, `mysqli`, `redis`, `gd`, `mbstring`, `intl`, `zip`, `bcmath`, `exif`, and `pcntl`
- MariaDB SQL mode includes `NO_ENGINE_SUBSTITUTION` for legacy zero-date/table imports
- Redis is started with the expected password `Yunbao123`
- Nginx supports ThinkPHP/FastAdmin entry URLs like `/admin_xxx.php/index/login`

Upload the full app into:

- `/var/www/projects/<project>/`

The expected layout is:

- `/var/www/projects/<project>/composer.json`
- `/var/www/projects/<project>/public/index.php`
- `/var/www/projects/<project>/public/admin_*.php`

Use a ThinkPHP `.env` like:

```ini
[app]
debug = false
trace = false

[database]
type = mysql
hostname = mariadb
database = xianxian
username = YOUR_DB_USER
password = YOUR_DB_PASSWORD
hostport = 3306
charset = utf8mb4
prefix = b_
debug = false

[redis]
host = redis
port = 6379
password = Yunbao123
```

Import the database after the project container is created:

```bash
docker exec -i <project>-db sh -c "exec mariadb -u root -p'<root-password>' '<db-name>'" < /var/www/projects/<project>/xianxian.sql
```

### WordPress (Duplicator) example

Upload these into:

- `/var/www/projects/<project>/public/`

Files typically include:

- `installer.php`
- the archive file (`.zip` or `.daf`)

Then open:

- `https://your-domain/installer.php`

Duplicator database connection settings inside Docker:

- Host: `mariadb`
- Port: `3306`
- Database/User/Password: use the values you entered when creating the project

Note: `127.0.0.1` will not work from inside the PHP container (it points to the container itself, not the DB container).

## phpMyAdmin (optional)

The script can run phpMyAdmin per project. By default it is bound to **localhost only** for safety, but you can optionally expose it publicly from the menu (not recommended).

Generated phpMyAdmin containers default to:

- `UPLOAD_LIMIT=5G`
- `MEMORY_LIMIT=1G`
- `MAX_EXECUTION_TIME=0` (no phpMyAdmin/PHP execution timeout)

- URL on the server: `http://127.0.0.1:<port>/`

To access it from your computer, use an SSH tunnel:

- `ssh -L 8080:127.0.0.1:<port> root@YOUR_SERVER_IP`
- Open: `http://127.0.0.1:8080/`

In phpMyAdmin:

- Server: `mariadb`
- Username/password: use your project DB user/password (or root if you prefer)

If you choose to expose phpMyAdmin publicly, restrict it with a firewall (example with UFW):

- Allow only your IP:
  - `sudo ufw allow from YOUR_PUBLIC_IP to any port <port> proto tcp`
- Or close it again:
  - `sudo ufw delete allow from YOUR_PUBLIC_IP to any port <port> proto tcp`

## Project UFW settings

Use menu option `19) Manage project UFW` to manage firewall rules tied to a specific project.

Normal websites are published through the shared reverse proxy on ports `80` and `443`, so UFW cannot allow or deny individual project domains separately at the firewall layer. Per-project UFW settings apply to direct project ports. Currently, the script manages the project's phpMyAdmin port.

Available actions:

- `status` - show the project phpMyAdmin bind/port, saved UFW settings, and matching UFW rules
- `restrict-phpmyadmin` - allow only specific IP/CIDR sources to the project's phpMyAdmin port and deny other traffic to that port
- `clear-phpmyadmin-rules` - remove the saved phpMyAdmin UFW rules for that project
- `show-ufw` - show the full numbered UFW ruleset

The source list accepts comma-separated IPv4/IPv6 addresses or CIDR ranges, for example:

- `203.0.113.10`
- `203.0.113.0/24`
- `2001:db8::10/128`

The settings are saved in the project's `.project-meta` file:

- `UFW_PMA_ALLOWED_SOURCES`
- `UFW_PMA_RESTRICTED`
- `UFW_PMA_PORT`

If phpMyAdmin is still bound to `127.0.0.1`, UFW rules can be saved but they will not make phpMyAdmin publicly reachable. Use menu option `8) Manage phpMyAdmin` to change phpMyAdmin exposure when public access is really needed.

If UFW is missing, the menu installs it. When `restrict-phpmyadmin` is applied and UFW is inactive, the script allows SSH plus the shared web ports `80/tcp` and `443/tcp`, then enables UFW automatically so the phpMyAdmin restriction is enforced.

## Project access settings

Use menu option `20) Project access settings` to restrict a normal project website by source IP/CIDR.

This is implemented in the project's Nginx vhost, not UFW. It works for individual project domains even though all projects share ports `80` and `443` through the reverse proxy.

Available actions:

- `status` - show whether the project is public or restricted
- `restrict` - allow only specific IP/CIDR sources to the project website
- `clear` - remove the project access restriction and make the project public again

The source list accepts comma-separated IPv4/IPv6 addresses or CIDR ranges, for example:

- `203.0.113.10`
- `203.0.113.0/24`
- `2001:db8::10/128`

The settings are saved in the project's `.project-meta` file:

- `PROJECT_ACCESS_ALLOWED_SOURCES`
- `PROJECT_ACCESS_RESTRICTED`

When you apply or clear the setting, the script regenerates that project's Nginx vhost and restarts the shared reverse proxy. Lets Encrypt ACME challenge paths remain public so certificate issuance and renewal can still work.

## Backups

Backups are stored under:

- `/var/backups/laravel-projects/<project>/`

Backups include:

- A database dump (when the DB container exists)
- Project files (excluding common heavy folders like `vendor` and `node_modules`)
- A copy of `.project-meta`

### Backup retention

By default, each project keeps backup archives for 14 days.

Use menu option `18) Backup settings` to change retention for a specific project:

1. Select `18) Backup settings`
2. Enter the project short name
3. Enter the number of days to keep, for example `60`

The value must be a whole number from `1` to `3650`. It is saved as `BACKUP_RETENTION_DAYS` in the project's `.project-meta` file, so it survives project updates and other configuration regeneration.

Retention is applied whenever that project's next backup runs. To prune old files immediately after changing the setting, run a manual backup for that project.

### Run backups manually

- From the menu: "Manual project backup"
- Or from CLI:
  - `sudo /root/laravel-server-manager.sh backup-all`

## Cron jobs (daily)

The script installs/updates two root cron jobs:

- Backups: daily at `02:30` -> `/var/log/laravel-backup.log`
- SSL renew: daily at `03:00` (Certbot renew + Nginx restart)

If you want to (re)install cron jobs explicitly:

- `sudo /root/laravel-server-manager.sh setup-cron`

Verify:

- `sudo crontab -l | egrep 'backup-all|certbot renew'`

## Updating a project

Use menu option "Update project". This regenerates:

- `docker-compose.yml` and related project files
- the Nginx vhost for the project, including any saved `PROJECT_DOMAINS` aliases
- the PHP Supervisor config, including the Laravel queue worker

Then it rebuilds the project containers and restarts the reverse proxy.

If you enabled the Guacamole proxy for the project, the saved `/guacamole/` reverse-proxy settings are preserved when you run `Update project`.

For Laravel projects, runtime refresh operations clear optimized caches, remove Livewire single-file component caches, reset PHP-FPM OPcache through the project HTTPS endpoint, send `php artisan queue:restart`, and restart the PHP container so OPcache and queue workers pick up the new code cleanly.

## Resetting database passwords

Use menu option `15) Reset database passwords` to rotate:

- the application DB user password
- the MariaDB root password
- or both in one run

The script will:

- connect to the project's MariaDB container with the current root password
- update the MariaDB account(s)
- regenerate the project's saved metadata and `docker-compose.yml`
- recreate the MariaDB container so healthchecks use the updated root password

If you change the application DB user password, you still need to update your app `.env` or other secret storage manually.

## Reverb (optional)

Menu option `14) Manage Reverb` manages Laravel Reverb for an existing project.

When enabled, the script will:

- add a `laravel-reverb` Supervisor program inside the PHP container
- run Reverb on an internal port (default `8080`)
- issue a Let's Encrypt certificate for a dedicated Reverb domain such as `ws.example.com`
- publish that Reverb endpoint through the shared reverse proxy with websocket headers
- support `status`, `enable`, `change-domain`, `change-port`, `exposure`, and `disable`

Typical flow:

- run menu option `14`
- choose `enable`
- enter a websocket domain such as `ws.example.com`
- choose exposure:
  - `local` -> only accessible from the server itself through Nginx
  - `public` -> accessible publicly on the configured Reverb domain
- rebuild the PHP container
- update your app with:
  - `composer require laravel/reverb`
  - `php artisan reverb:install`

Recommended DNS:

- `A/AAAA` for `ws.example.com` -> server IP

The script does not install the Laravel Reverb package into your app automatically. It prepares the container and proxy so your Laravel project can run it cleanly.

If you enable `local` exposure, the TLS certificate is still issued for the Reverb domain, but requests are restricted to localhost at the reverse proxy layer.

## Guacamole (optional)

Menu option `16) Manage Guacamole (stack + proxy)` manages Apache Guacamole for an existing project.

If you keep the default upstream `guacamole-web:8080`, the script can provision and maintain a shared Guacamole stack for you in:

- `/opt/apache-guacamole`

The managed stack includes:

- `guacd`
- `guacamole-web`
- the shared Docker network attachment to `laravel-shared`
- a generated JSON auth secret saved in `/opt/apache-guacamole/.guacamole-meta`

When you use the managed stack, the script will:

- create or update the shared Apache Guacamole containers
- store the Guacamole proxy settings in the project's `.project-meta`
- regenerate the project vhost with a `/guacamole/` reverse-proxy block
- preserve that block when you later run `6) Update project`
- update the project's `.env` with `GUACAMOLE_*` values when the file exists
- clear Laravel config cache and restart the project's PHP container after `.env` changes when possible
- restart only the shared reverse proxy stack after proxy changes

Available actions in menu option `16`:

- `status`
- `install-stack`
- `enable`
- `change-upstream`
- `disable`

Typical flow:

- run menu option `16`
- choose `enable`
- keep the default upstream `guacamole-web:8080`
- let the script provision the shared Guacamole stack
- use the generated `/guacamole/` URL from the selected project domain

Recommended URL for apps:

- `https://your-project-domain/guacamole`

If the project has an `.env`, the script will try to write:

```ini
GUACAMOLE_ENABLED=true
GUACAMOLE_BASE_URL=https://your-project-domain/guacamole
GUACAMOLE_JSON_SECRET_KEY=<generated-by-manager>
GUACAMOLE_EMBED_ALLOWED=true
```

The manager looks for the app env file in this order:

- `/var/www/projects/<project>/.env`
- `/var/www/projects/<project>/public/.env`
- the first `.env` found recursively under `/var/www/projects/<project>/public/`

If you use a custom upstream instead of the managed stack, the script can still proxy `/guacamole/`, but you must supply the matching `GUACAMOLE_JSON_SECRET_KEY` to your app yourself.

Notes:

- The default upstream assumes the managed Guacamole web container hostname `guacamole-web` and port `8080`.
- The generated vhost resolves the Guacamole upstream through Docker DNS at request time. If the Guacamole container is down or the hostname is wrong, `/guacamole/` should return `502 Bad Gateway` without taking the whole reverse proxy offline.
- Your Guacamole web container must be attached to the shared Docker network `laravel-shared` for the reverse proxy to reach it by container hostname.
- If you disable the proxy, the saved upstream is kept in `.project-meta` so you can re-enable it later without retyping the host.

## Managed VNC Server (optional)

Menu option `17) Manage VNC Server (TigerVNC)` installs and controls a VNC server on the Ubuntu host.

This is a VNC **server** target, not a VNC viewer. Apache Guacamole provides the browser viewer. The managed VNC server gives Guacamole something to connect to when you want a VNC desktop on the server itself.

The installer uses Ubuntu packages:

- `tigervnc-standalone-server`
- `tigervnc-common`
- `xfce4`
- `xfce4-goodies`
- `dbus-x11`
- `xterm`

The manager creates:

- a Linux user for the VNC desktop, default `servicedesk-vnc`
- `~/.vnc/passwd` for that user's VNC password
- `~/.vnc/xstartup` to launch XFCE
- `/etc/systemd/system/servicedesk-vnc.service`
- `/opt/managed-vnc-server/.vnc-meta`

Available actions:

- `status`
- `install`
- `start`
- `stop`
- `restart`
- `remove`

Typical values:

- Display: `:1`
- Port: `5901`
- Geometry: `1366x768`
- Color depth: `24`
- Listen scope: `network` if Guacamole/guacd must reach it from Docker; `localhost` if you only use SSH tunneling or local access.

Use these values in Guacamole:

```text
Protocol: VNC
Host: server IP address or Docker host gateway
Port: 5901
Username: leave blank
Password: the VNC password configured during install
```

Security notes:

- VNC password authentication is not a substitute for network access control.
- If you choose `network` listen scope, restrict access to the VNC port with your firewall/security group.
- Do not expose VNC ports directly to the public internet unless you have a separate hardened access layer.

## Deleting a project

Use menu option "Delete existing project". The script removes:

- project containers
- project Docker volumes
- Nginx vhost file for the project
- the reverse-proxy projects symlink
- the project directory
- backups for the project

It attempts a "final backup" first; if the DB container does not exist, it will still proceed (backup without DB).

## Files and directories used

- Reverse proxy stack:
  - `/opt/laravel-reverse-proxy/docker-compose.yml`
  - `/opt/laravel-reverse-proxy/nginx/conf.d/`
  - `/opt/laravel-reverse-proxy/certbot/conf/` (Lets Encrypt data)
  - `/opt/laravel-reverse-proxy/certbot/www/` (ACME webroot)
  - `/opt/laravel-reverse-proxy/projects/` (symlinks to project dirs)
- Apache Guacamole stack:
  - `/opt/apache-guacamole/compose.yaml`
  - `/opt/apache-guacamole/.guacamole-meta`
- Projects:
  - `/var/www/projects/<project>/`
  - `/var/www/projects/<project>/public/` (web root)
  - `/var/www/projects/<project>/.project-meta` (stored variables for update/backup/restore, including `DOMAIN`, `PROJECT_DOMAINS`, `BACKUP_RETENTION_DAYS`, project UFW settings, and project access settings)
- Backups:
  - `/var/backups/laravel-projects/`

## Troubleshooting

### Reverse proxy container name conflict

If you see a "container name is already in use" error for `laravel-reverse-proxy`, remove the old container and recreate:

- `sudo docker rm -f laravel-reverse-proxy laravel-certbot 2>/dev/null || true`
- `cd /opt/laravel-reverse-proxy && sudo docker compose up -d --force-recreate --remove-orphans`

### Docker Compose v1 vs Docker Engine (Ubuntu 22)

Ubuntu packages may install legacy `docker-compose` (Python, v1.x). With newer Docker Engine versions this can fail.

The script prefers:

- `docker compose` (Compose v2 plugin)

If you still have issues, check versions:

- `docker version`
- `docker compose version`
- `docker-compose version` (legacy)

### Duplicator: DB connection refused

If Duplicator fails with host `127.0.0.1`, use:

- Host `mariadb`
- Port `3306`

### MySQL vs MariaDB warning in Duplicator

Duplicator may warn if the source was MySQL and the target is MariaDB. This is often fine for WordPress restores.

If you hit SQL import errors and need full compatibility, switch your DB image to MySQL 8.4 in the project `docker-compose.yml` and recreate the DB container/volume.

### Large SQL imports in phpMyAdmin

If browser imports time out on very large `.sql` files, first regenerate the project with the latest script so it rewrites:

- `docker-compose.yml` for phpMyAdmin `UPLOAD_LIMIT`, `MEMORY_LIMIT`, and `MAX_EXECUTION_TIME`
- `mariadb/my.cnf` for a larger `max_allowed_packet` and longer DB stream timeouts

Then rebuild the project from the menu with `6) Update project`.

For multi-hundred-MB or multi-GB dumps, importing directly into MariaDB is still more reliable than a browser upload. Example:

```bash
docker exec -i <project>-db sh -c "exec mariadb -u root -p'<root-password>' '<db-name>'" < /path/to/dump.sql
```

## Email server (optional)

Menu option `10) Setup email server (docker-mailserver)` creates a basic mail server stack in:

- `/opt/mailserver`

It will:

- Issue a Let's Encrypt certificate for your mail host (via the existing Certbot + webroot flow)
- Start `docker-mailserver` and create an initial mailbox
- Generate DKIM keys and print the TXT record you need to add to DNS

Minimum ports needed (provider + firewall):

- SMTP: `25` (inbound)
- Submission: `587` (recommended for clients)
- SMTPS (optional): `465`
- IMAP: `143` (optional)
- IMAPS: `993` (recommended)

DNS records you typically need:

- `A/AAAA` for your mail host (e.g. `mail.example.com`) -> server IP
- `MX` for your domain -> your mail host
- `PTR/rDNS` (set at your VPS/provider): server IP -> your mail host
- `SPF` TXT for your domain (example): `v=spf1 mx -all`
- `DKIM` TXT (generated by the script)
- `DMARC` TXT (recommended): `v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@example.com`

Notes:

- Many VPS providers block port `25` by default.
- Exposing a mail server publicly has real deliverability and security implications.

### Multiple domains (one mail server)

This project supports hosting multiple domains on a single `docker-mailserver` instance.

High-level steps for each additional domain (example `otherdomain.com`):

- Add `MX` for `otherdomain.com` pointing to your mail host (e.g. `mail.example.com`)
- Add `SPF` and `DMARC` for `otherdomain.com`
- Generate DKIM for `otherdomain.com` and add the TXT record
- Create mailboxes like `user@otherdomain.com`

Use menu option `12) Manage email domains/mailboxes` to onboard a new domain in one flow (`add-domain`), change the mail host (`change-mail-host`), create mailboxes, reset mailbox passwords, manage DKIM from the server, audit DNS records, and repair the Postfix postscreen cache when needed.

Recommended mail DNS values:

```dns
MX     @        10 mail.example.com
TXT    @        v=spf1 mx -all
TXT    _dmarc   v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@example.com
TXT    mail._domainkey   <DKIM value generated by the script>
```

If using Cloudflare, keep mail host records and MX targets as **DNS only**. Do not proxy SMTP/IMAP hostnames through Cloudflare.

## Webmail (optional)

Menu option `11) Setup webmail (Roundcube)` creates a Roundcube stack in:

- `/opt/webmail-roundcube`

It will:

- Issue a Let's Encrypt certificate for your primary webmail domain and any alias webmail domains
- Start Roundcube and publish it via the existing Nginx reverse proxy
- Connect Roundcube to the mail server over the internal Docker network
- Accept full email addresses for login so one Roundcube instance can be used across multiple mail domains

DNS records needed:

- `A/AAAA` for the primary webmail domain -> server IP
- `A/AAAA` for every alias webmail domain -> server IP

Roundcube will connect to your mail host via IMAPS/SMTP submission:

- IMAP: `993` (SSL)
- SMTP: `587` (STARTTLS)

Login format:

- Use the full email address, for example `user@example.com`
- The same Roundcube site can be used for multiple domains on the same mail server
- One Roundcube instance can also answer on multiple webmail URLs, for example `webmail.faceyogard.com` and `webmail.johngor.com`

Setup notes:

- During setup or modification, enter webmail domains as a comma-separated list
- The first domain is treated as the primary URL
- Additional domains are configured as aliases that point to the same Roundcube instance

If you later need to change the webmail domain list or point Roundcube to a different mail host, use menu option `13) Modify webmail (Roundcube)`.

### Webmail password changes

Menu option `21) Manage webmail password changes` enables the Roundcube password plugin and an internal helper container:

- Roundcube plugin: `password`
- Internal helper container: `roundcube-password-helper`
- Helper path: `/opt/webmail-roundcube/password-helper/password-helper.py`
- Roundcube config: `/opt/webmail-roundcube/data/config/password-change.inc.php`
- Forced-change state file: `/opt/webmail-roundcube/data/config/force-password-change-users.txt`

The helper updates docker-mailserver accounts in:

- `/opt/mailserver/docker-data/dms/config/postfix-accounts.cf`

No public port is exposed for the helper. It is reachable only inside the shared Docker network.

Available actions:

- `status` - show Roundcube/helper status and users currently forced to change password
- `enable` - enable password changes from Roundcube settings
- `disable` - disable the Roundcube password plugin/helper
- `list-forced` - list users marked for forced password change
- `force-user` - require one mailbox to change password at next Roundcube login
- `clear-user` - remove the forced-change marker for one mailbox
- `force-all` - require all mailboxes to change password at next Roundcube login
- `clear-all` - clear all forced-change markers

When password changes are enabled:

- Users can change their password from Roundcube settings.
- New mailboxes created through menu option `12) Manage email domains/mailboxes` -> `add-mailbox` are automatically marked to change password on first Roundcube login.
- Password resets through menu option `12` -> `reset-password` ask whether to force a password change on the next Roundcube login.
- After a successful password change, the forced-change marker is cleared automatically.
- Dovecot is reloaded so the new password works immediately.
- The script configures fail2ban to ignore the shared Docker subnet so failed webmail login attempts do not ban the Roundcube container from reaching IMAP.

This first-login enforcement applies to users signing in through Roundcube. Direct IMAP/SMTP clients such as Outlook, Apple Mail, and mobile mail apps will not show Roundcube's password-change screen.

## Security notes

- Database and other secrets are stored in `/var/www/projects/<project>/.project-meta` so the script can automate backups/restores/updates.
  - Keep project directories restricted to trusted admins.
- If you enable phpMyAdmin, keep it restricted (this script binds it to localhost by default). Prefer SSH tunnels instead of exposing it publicly.
- If you enable webmail password changes, protect `/opt/webmail-roundcube/.password-helper-token` and the mailserver config directory. The helper token is internal but should still be treated as sensitive.
- Use a firewall (for example `ufw`) and only open required ports.

## Disclaimer

This script makes system-level changes (packages, Docker, cron, Nginx reverse proxy). Review it before running in production.
