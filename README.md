# Laravel Server Manager (Docker, Multi-Project) for Ubuntu 22.04

`laravel-server-manager.sh` is a single Bash script that provisions a Docker-based reverse proxy (Nginx + Certbot) and lets you create, update, backup, restore, list, and delete multiple PHP projects (Laravel, WordPress, or any PHP app) on the same Ubuntu Server 22.04 host.

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
- PHP extensions enabled in the image (high-level): `pdo_mysql`, `mysqli`, `opcache`, `zip`, `mbstring`, `redis`, `gd`, `intl`, `bcmath`, `exif`, `pcntl`
- Nginx virtual hosts per project (one file per project)
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
- `5) Restore project from backup` - restores files and DB from an archive
- `6) Update project` - regenerates config and rebuilds containers
- `7) Run backup for all projects now` - runs backups for all projects
- `8) Manage phpMyAdmin` - enables/disables phpMyAdmin and controls exposure
- `9) Change project domain` - updates Nginx + issues a new SSL cert for a new domain
- `10) Setup email server (docker-mailserver)` - provisions a basic mail server stack and prints DNS instructions
- `11) Setup webmail (Roundcube)` - provisions Roundcube webmail behind the reverse proxy
- `12) Manage email domains/mailboxes` - add mailboxes, generate/show DKIM, and print DNS help for additional domains

## Non-interactive commands

- Backup all projects:
  - `sudo /root/laravel-server-manager.sh backup-all`
- (Re)install cron jobs:
  - `sudo /root/laravel-server-manager.sh setup-cron`

## Domain handling (important)

The script uses the domain **exactly as you type it**.

- If you type `example.com`, it will request a certificate only for `example.com` and configure Nginx `server_name example.com;`.
- If you type `www.example.com`, it will request a certificate only for `www.example.com` and configure Nginx `server_name www.example.com;`.

It does not automatically add or redirect between `www` and apex.

## Where to upload website files

For a project named `myproject`, the public web root is:

- `/var/www/projects/myproject/public/`

This folder is what Nginx serves and what PHP-FPM executes as the document root.

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

## Backups

Backups are stored under:

- `/var/backups/laravel-projects/<project>/`

Backups include:

- A database dump (when the DB container exists)
- Project files (excluding common heavy folders like `vendor` and `node_modules`)
- A copy of `.project-meta`

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
- the Nginx vhost for the project

Then it rebuilds the project containers and restarts the reverse proxy.

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
- Projects:
  - `/var/www/projects/<project>/`
  - `/var/www/projects/<project>/public/` (web root)
  - `/var/www/projects/<project>/.project-meta` (stored variables for update/backup/restore)
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
- `DMARC` TXT (example): `v=DMARC1; p=none; rua=mailto:dmarc@example.com`

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

Use menu option `12) Manage email domains/mailboxes` to do the mailbox + DKIM steps from the server.

## Webmail (optional)

Menu option `11) Setup webmail (Roundcube)` creates a Roundcube stack in:

- `/opt/webmail-roundcube`

It will:

- Issue a Let's Encrypt certificate for your webmail domain (example: `webmail.example.com`)
- Start Roundcube and publish it via the existing Nginx reverse proxy

DNS record needed:

- `A/AAAA` for `webmail.example.com` -> server IP

Roundcube will connect to your mail host via IMAPS/SMTP submission:

- IMAP: `993` (SSL)
- SMTP: `587` (STARTTLS)

## Security notes

- Database and other secrets are stored in `/var/www/projects/<project>/.project-meta` so the script can automate backups/restores/updates.
  - Keep project directories restricted to trusted admins.
- If you enable phpMyAdmin, keep it restricted (this script binds it to localhost by default). Prefer SSH tunnels instead of exposing it publicly.
- Use a firewall (for example `ufw`) and only open required ports.

## Disclaimer

This script makes system-level changes (packages, Docker, cron, Nginx reverse proxy). Review it before running in production.
