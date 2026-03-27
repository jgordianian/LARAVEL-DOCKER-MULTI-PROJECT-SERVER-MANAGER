#!/bin/bash

set -euo pipefail

PROXY_BASE="/opt/laravel-reverse-proxy"
PROXY_CONF_DIR="${PROXY_BASE}/nginx/conf.d"
PROXY_CERTBOT_CONF="${PROXY_BASE}/certbot/conf"
PROXY_CERTBOT_WWW="${PROXY_BASE}/certbot/www"
PROXY_PROJECTS_DIR="${PROXY_BASE}/projects"
PROJECTS_BASE="/var/www/projects"
BACKUPS_BASE="/var/backups/laravel-projects"
SHARED_NETWORK="laravel-shared"
PROXY_COMPOSE="${PROXY_BASE}/docker-compose.yml"
SCRIPT_PATH="$(readlink -f "$0")"
MAIL_BASE="/opt/mailserver"
MAIL_COMPOSE="${MAIL_BASE}/compose.yaml"
MAIL_ENV_FILE="${MAIL_BASE}/mailserver.env"
WEBMAIL_BASE="/opt/webmail-roundcube"
WEBMAIL_COMPOSE="${WEBMAIL_BASE}/compose.yaml"
WEBMAIL_META_FILE="${WEBMAIL_BASE}/.webmail-meta"

# Values loaded from "${app_dir}/.project-meta" (declared to keep shellcheck happy)
PROJECT_NAME=""
DOMAIN=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_ROOT_PASSWORD=""
PHP_CONTAINER=""
DB_CONTAINER=""
REDIS_CONTAINER=""
APP_DIR=""
PMA_PORT=""
PMA_BIND_IP=""
REVERB_ENABLED=""
REVERB_DOMAIN=""
REVERB_PORT=""
REVERB_EXPOSURE=""

banner() {
  echo "=============================================================="
  echo "        LARAVEL DOCKER MULTI-PROJECT SERVER MANAGER"
  echo "=============================================================="
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
  fi
}

require_nonempty() {
  local var_name="$1"
  local var_value="${2:-}"

  if [ -z "$var_value" ]; then
    echo "Missing required value: ${var_name}"
    exit 1
  fi
}

docker_container_exists() {
  local container_name="${1:-}"
  [ -n "$container_name" ] || return 1
  docker container inspect "$container_name" >/dev/null 2>&1
}

pma_default_port() {
  local project_name="${1:-}"
  local sum port
  sum="$(printf '%s' "$project_name" | cksum | awk '{print $1}')"
  port=$((8200 + (sum % 700)))
  echo "$port"
}

tcp_port_in_use() {
  local port="${1:-}"
  [ -n "$port" ] || return 1

  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null \
      | awk '{print $4}' \
      | sed 's/.*://' \
      | grep -qx "$port"
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null \
      | awk '{print $4}' \
      | sed 's/.*://' \
      | grep -qx "$port"
    return $?
  fi

  return 1
}

validate_port_number() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

set_project_meta_var() {
  local meta_file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped="$(printf %q "$value")"

  if [ ! -f "$meta_file" ]; then
    echo "${key}=${escaped}" > "$meta_file"
    return 0
  fi

  if grep -q "^${key}=" "$meta_file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$meta_file"
  else
    echo "${key}=${escaped}" >> "$meta_file"
  fi
}

set_phpmyadmin_portspec_in_compose() {
  local compose_file="$1"
  local bind_ip="$2"
  local port="$3"

  if ! grep -q "^[[:space:]]*phpmyadmin:" "$compose_file" 2>/dev/null; then
    return 1
  fi

  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) return 1 ;;
  esac

  # Replace the port mapping line inside the phpMyAdmin service block.
  # Keeps the mapping quoted and supports existing values.
  sed -i \
    "/^[[:space:]]*phpmyadmin:/,/^[^[:space:]]/ s|^[[:space:]]*-[[:space:]]*\"[^\"]*:80\"|      - \"${bind_ip}:${port}:80\"|" \
    "$compose_file"
  return 0
}

dc() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return 0
  fi

  echo "Docker Compose is not installed."
  exit 1
}

recreate_phpmyadmin() {
  local app_dir="$1"
  local pma_container="$2"

  cd "$app_dir"
  dc stop phpmyadmin >/dev/null 2>&1 || true
  dc rm -f phpmyadmin >/dev/null 2>&1 || true
  docker rm -f "$pma_container" >/dev/null 2>&1 || true
  dc up -d phpmyadmin
}

compose_cmd_for_cron() {
  local docker_bin
  docker_bin="$(command -v docker 2>/dev/null || echo docker)"

  if "$docker_bin" compose version >/dev/null 2>&1; then
    echo "$docker_bin compose"
    return 0
  fi

  command -v docker-compose 2>/dev/null || echo docker-compose
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

prompt() {
  local out_var="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value=""

  if is_interactive; then
    read -r -e -p "$prompt_text" value
  else
    read -r value
  fi

  if [ -z "$value" ] && [ -n "$default_value" ]; then
    value="$default_value"
  fi

  printf -v "$out_var" '%s' "$value"
}

prompt_secret() {
  local out_var="$1"
  local prompt_text="$2"
  local value=""

  read -r -s -p "$prompt_text" value
  echo ""
  printf -v "$out_var" '%s' "$value"
}

slug_to_name() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '_' '-' \
    | tr -cs 'a-z0-9-' '-' \
    | sed 's/^-*//; s/-*$//; s/--*/-/g'
}

project_dir() {
  local project_name
  project_name="$(slug_to_name "$1")"
  echo "${PROJECTS_BASE}/${project_name}"
}

resolve_project_dir() {
  local project_name="$1"
  local link="${PROXY_PROJECTS_DIR}/${project_name}"
  local resolved=""

  if [ -e "$link" ]; then
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
  fi

  if [ -n "$resolved" ]; then
    echo "$resolved"
    return 0
  fi

  echo "${PROJECTS_BASE}/${project_name}"
}

print_existing_projects() {
  if [ -d "$PROXY_PROJECTS_DIR" ] && [ -n "$(ls -A "$PROXY_PROJECTS_DIR" 2>/dev/null)" ]; then
    ls "$PROXY_PROJECTS_DIR" 2>/dev/null
    return 0
  fi

  if [ -d "$PROJECTS_BASE" ] && [ -n "$(ls -A "$PROJECTS_BASE" 2>/dev/null)" ]; then
    ls "$PROJECTS_BASE" 2>/dev/null
    return 0
  fi

  echo "No projects found."
}

proxy_up() {
  mkdir -p "$PROXY_CONF_DIR" "$PROXY_CERTBOT_CONF" "$PROXY_CERTBOT_WWW" "$PROXY_PROJECTS_DIR"

  cat > "$PROXY_COMPOSE" <<EOF
version: "3.9"
services:
  reverse-proxy:
    image: nginx:stable-alpine
    container_name: laravel-reverse-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${PROXY_CONF_DIR}:/etc/nginx/conf.d
      - ${PROXY_CERTBOT_CONF}:/etc/letsencrypt
      - ${PROXY_CERTBOT_WWW}:/var/www/certbot
      - ${PROJECTS_BASE}:/projects:ro
    healthcheck:
      test: ["CMD-SHELL", "nginx -t >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - ${SHARED_NETWORK}

  certbot:
    image: certbot/certbot
    container_name: laravel-certbot
    volumes:
      - ${PROXY_CERTBOT_CONF}:/etc/letsencrypt
      - ${PROXY_CERTBOT_WWW}:/var/www/certbot

networks:
  ${SHARED_NETWORK}:
    external: true
EOF

  dc -f "$PROXY_COMPOSE" up -d
}

install_base() {
  echo "Installing base dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update -y
  apt-get install -y docker.io curl tar gzip coreutils procps rsync cron

  if ! docker compose version >/dev/null 2>&1; then
    local arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) arch="x86_64" ;;
      aarch64|arm64) arch="aarch64" ;;
      *) echo "Unsupported architecture for Docker Compose v2: ${arch}"; arch="" ;;
    esac

    if [ -n "$arch" ]; then
      mkdir -p /usr/local/lib/docker/cli-plugins
      if curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; then
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
      fi
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y software-properties-common
    add-apt-repository -y universe >/dev/null 2>&1 || true
    apt-get update -y
    apt-get install -y docker-compose
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "Failed to install Docker Compose."
    exit 1
  fi
  systemctl enable --now docker
  systemctl enable --now cron

  mkdir -p "$PROJECTS_BASE" "$BACKUPS_BASE"

  if ! docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
    echo "Creating shared Docker network ${SHARED_NETWORK}..."
    docker network create "$SHARED_NETWORK"
  fi

  proxy_up
  ensure_cron_jobs
}

detect_tuning() {
  RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
  echo "Detected memory: ${RAM_MB} MB"

  if [ "$RAM_MB" -le 2048 ]; then
    PROFILE_NAME="LOW MEMORY"
    PHP_FPM_CHILDREN=5
    OPCACHE_MEMORY=128
    REDIS_MEMORY="256mb"
    MYSQL_BUFFER="128M"
  elif [ "$RAM_MB" -le 4096 ]; then
    PROFILE_NAME="BALANCED"
    PHP_FPM_CHILDREN=10
    OPCACHE_MEMORY=192
    REDIS_MEMORY="512mb"
    MYSQL_BUFFER="256M"
  else
    PROFILE_NAME="HIGH PERFORMANCE"
    PHP_FPM_CHILDREN=20
    OPCACHE_MEMORY=256
    REDIS_MEMORY="1gb"
    MYSQL_BUFFER="512M"
  fi

  echo "Applied profile: ${PROFILE_NAME}"
}

ensure_project_exists() {
  local project_name="$1"
  local app_dir="${2:-$(resolve_project_dir "$project_name")}"

  if [ ! -d "$app_dir" ]; then
    echo "Project ${project_name} does not exist at ${app_dir}"
    exit 1
  fi

  if [ ! -f "${app_dir}/docker-compose.yml" ]; then
    echo "docker-compose.yml not found in ${app_dir}"
    exit 1
  fi
}

write_project_files() {
  local app_dir="$1"
  local project_name="$2"
  local domain="$3"
  local db_name="$4"
  local db_user="$5"
  local db_password="$6"
  local db_root_password="$7"
  local pma_port="${8:-}"
  local pma_bind_ip="${9:-}"
  local reverb_enabled="${10:-no}"
  local reverb_domain="${11:-}"
  local reverb_port="${12:-8080}"
  local reverb_exposure="${13:-local}"

  local php_container="${project_name}-php"
  local db_container="${project_name}-db"
  local redis_container="${project_name}-redis"
  local pma_container="${project_name}-phpmyadmin"

  if [ -z "$pma_port" ]; then
    pma_port="$(pma_default_port "$project_name")"
  fi

  if [ -z "$pma_bind_ip" ]; then
    pma_bind_ip="127.0.0.1"
  fi

  mkdir -p "${app_dir}/php" "${app_dir}/mariadb"

  cat > "${app_dir}/mariadb/my.cnf" <<EOF
[mysqld]
innodb_buffer_pool_size=${MYSQL_BUFFER}
innodb_log_file_size=128M
max_connections=100
EOF

  cat > "${app_dir}/php/supervisord.conf" <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:laravel-worker]
command=/bin/sh -c "while [ ! -f /var/www/artisan ]; do echo 'Waiting for /var/www/artisan...'; sleep 10; done; php /var/www/artisan queue:work --sleep=3 --tries=3 --timeout=90"
autostart=true
autorestart=true
priority=20
startsecs=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

  if [ "${reverb_enabled}" = "yes" ]; then
    cat >> "${app_dir}/php/supervisord.conf" <<EOF

[program:laravel-reverb]
command=/bin/sh -c "while [ ! -f /var/www/artisan ]; do echo 'Waiting for /var/www/artisan...'; sleep 10; done; php /var/www/artisan reverb:start --host=0.0.0.0 --port=${reverb_port}"
autostart=true
autorestart=true
priority=30
startsecs=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
  fi

  cat > "${app_dir}/php/Dockerfile" <<EOF
FROM composer:2 AS composer-bin

FROM php:8.3-fpm-alpine

RUN set -eux; \
    apk add --no-cache \
      curl \
      git \
      supervisor \
      zip \
      unzip \
      freetype \
      libjpeg-turbo \
      libpng \
      icu-libs \
      libzip; \
    apk add --no-cache --virtual .build-deps \
      \$PHPIZE_DEPS \
      freetype-dev \
      libjpeg-turbo-dev \
      libpng-dev \
      icu-dev \
      libzip-dev \
      oniguruma-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      bcmath \
      exif \
      gd \
      intl \
      mbstring \
      mysqli \
      opcache \
      pcntl \
      pdo \
      pdo_mysql \
      zip; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    apk del .build-deps

COPY supervisord.conf /etc/supervisord.conf
COPY --from=composer-bin /usr/bin/composer /usr/local/bin/composer

RUN echo "opcache.enable=1" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.memory_consumption=${OPCACHE_MEMORY}" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.interned_strings_buffer=16" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.max_accelerated_files=20000" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.validate_timestamps=0" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.revalidate_freq=0" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "opcache.fast_shutdown=1" >> /usr/local/etc/php/conf.d/opcache.ini

RUN echo "pm = dynamic" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.max_children=${PHP_FPM_CHILDREN}" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.start_servers=2" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.min_spare_servers=2" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.max_spare_servers=5" >> /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www

CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
EOF

  cat > "${app_dir}/docker-compose.yml" <<EOF
version: "3.9"
services:
  php:
    build: ./php
    container_name: ${php_container}
    restart: unless-stopped
    volumes:
      - ./:/var/www
      - ${PROJECTS_BASE}:/projects
    healthcheck:
      test: ["CMD-SHELL", "php -v >/dev/null 2>&1 && pgrep php-fpm >/dev/null && pgrep supervisord >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - internal
      - ${SHARED_NETWORK}

  mariadb:
    image: mariadb:11
    container_name: ${db_container}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${db_root_password}
      MYSQL_DATABASE: ${db_name}
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_password}
    volumes:
      - dbdata:/var/lib/mysql
      - ./mariadb/my.cnf:/etc/mysql/conf.d/custom.cnf:ro
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h localhost -p${db_root_password} || mysqladmin ping -h localhost -p${db_root_password}"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks:
      - internal

  redis:
    image: redis:alpine
    container_name: ${redis_container}
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory ${REDIS_MEMORY} --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks:
      - internal

  phpmyadmin:
    image: phpmyadmin:5-apache
    container_name: ${pma_container}
    restart: unless-stopped
    profiles:
      - pma
    environment:
      PMA_HOST: mariadb
      PMA_PORT: 3306
      PMA_ARBITRARY: 0
      UPLOAD_LIMIT: 256M
    ports:
      - "${pma_bind_ip}:${pma_port}:80"
    depends_on:
      - mariadb
    networks:
      - internal

networks:
  internal:
  ${SHARED_NETWORK}:
    external: true

volumes:
  dbdata:
EOF

  {
    printf 'PROJECT_NAME=%q\n' "$project_name"
    printf 'DOMAIN=%q\n' "$domain"
    printf 'DB_NAME=%q\n' "$db_name"
    printf 'DB_USER=%q\n' "$db_user"
    printf 'DB_PASSWORD=%q\n' "$db_password"
    printf 'DB_ROOT_PASSWORD=%q\n' "$db_root_password"
    printf 'PHP_CONTAINER=%q\n' "$php_container"
    printf 'DB_CONTAINER=%q\n' "$db_container"
    printf 'REDIS_CONTAINER=%q\n' "$redis_container"
    printf 'APP_DIR=%q\n' "$app_dir"
    printf 'PMA_PORT=%q\n' "$pma_port"
    printf 'PMA_BIND_IP=%q\n' "$pma_bind_ip"
    printf 'REVERB_ENABLED=%q\n' "$reverb_enabled"
    printf 'REVERB_DOMAIN=%q\n' "$reverb_domain"
    printf 'REVERB_PORT=%q\n' "$reverb_port"
    printf 'REVERB_EXPOSURE=%q\n' "$reverb_exposure"
  } > "${app_dir}/.project-meta"
}

write_proxy_config_http() {
  local project_name="$1"
  local domain="$2"
  local php_container="${project_name}-php"

  cat > "${PROXY_CONF_DIR}/${project_name}.conf" <<EOF
server {
    listen 80;
    server_name ${domain};

    root /projects/${project_name}/public;
    index index.php index.html;
    client_max_body_size 100M;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass ${php_container}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /projects/${project_name}/public\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT /projects/${project_name}/public;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
}

write_proxy_config_https() {
  local project_name="$1"
  local domain="$2"
  local php_container="${project_name}-php"

  cat > "${PROXY_CONF_DIR}/${project_name}.conf" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    root /projects/${project_name}/public;
    index index.php index.html;
    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass ${php_container}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /projects/${project_name}/public\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT /projects/${project_name}/public;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
}

write_reverb_proxy_config_http() {
  local project_name="$1"
  local reverb_domain="$2"

  cat > "${PROXY_CONF_DIR}/reverb-${project_name}.conf" <<EOF
server {
    listen 80;
    server_name ${reverb_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

write_reverb_proxy_config_https() {
  local project_name="$1"
  local reverb_domain="$2"
  local php_container="${project_name}-php"
  local reverb_port="$3"
  local reverb_exposure="${4:-local}"
  local access_block=""

  if [ "$reverb_exposure" = "local" ]; then
    access_block=$'        allow 127.0.0.1;\n        allow ::1;\n        deny all;\n'
  fi

  cat > "${PROXY_CONF_DIR}/reverb-${project_name}.conf" <<EOF
server {
    listen 80;
    server_name ${reverb_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${reverb_domain};

    ssl_certificate /etc/letsencrypt/live/${reverb_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reverb_domain}/privkey.pem;

    client_max_body_size 20M;

    location / {
${access_block}        proxy_pass http://${php_container}:${reverb_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
}

remove_reverb_proxy_config() {
  local project_name="$1"
  rm -f "${PROXY_CONF_DIR}/reverb-${project_name}.conf" || true
}

setup_ssl_renew_cron() {
  local compose_cmd
  compose_cmd="$(compose_cmd_for_cron)"
  local cron_line="0 3 * * * cd ${PROXY_BASE} && ${compose_cmd} run --rm certbot renew && ${compose_cmd} restart reverse-proxy"
  (crontab -l 2>/dev/null || true) \
    | awk -v add="$cron_line" 'index($0,"certbot renew &&")==0 {print} END{print add}' \
    | crontab -
}

setup_backup_cron() {
  local cron_cmd="/bin/bash ${SCRIPT_PATH}"
  local cron_line="30 2 * * * ${cron_cmd} backup-all >/var/log/laravel-backup.log 2>&1"
  (crontab -l 2>/dev/null || true) \
    | awk -v add="$cron_line" 'index($0," backup-all >/var/log/laravel-backup.log")==0 {print} END{print add}' \
    | crontab -
}

ensure_cron_jobs() {
  setup_ssl_renew_cron
  setup_backup_cron
}

normalize_domain() {
  local domain="$1"
  domain="${domain,,}"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%.}"
  domain="${domain//[$'\t\r\n ']/}"
  printf '%s' "$domain"
}

safe_domain_name() {
  local domain="$1"
  printf '%s' "$domain" | tr -cs 'a-zA-Z0-9.-' '-' | tr '[:upper:]' '[:lower:]'
}

normalize_domain_csv() {
  local input="$1"
  local part normalized result=""
  local -A seen=()

  input="${input//;/,}"
  IFS=',' read -r -a parts <<< "$input"

  for part in "${parts[@]}"; do
    normalized="$(normalize_domain "$part")"
    [ -n "$normalized" ] || continue
    if [ -z "${seen[$normalized]+x}" ]; then
      seen[$normalized]=1
      if [ -z "$result" ]; then
        result="$normalized"
      else
        result="${result},${normalized}"
      fi
    fi
  done

  printf '%s' "$result"
}

validate_domain_csv() {
  local input="$1"
  local part

  [ -n "$input" ] || return 1
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || return 1
    validate_domain "$part" || return 1
  done
}

csv_first_value() {
  local input="$1"
  printf '%s' "${input%%,*}"
}

csv_contains_value() {
  local csv="$1"
  local needle="$2"
  local part

  IFS=',' read -r -a parts <<< "$csv"
  for part in "${parts[@]}"; do
    [ "$part" = "$needle" ] && return 0
  done
  return 1
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

ensure_proxy_stack() {
  if [ ! -f "$PROXY_COMPOSE" ]; then
    install_base
    return 0
  fi

  proxy_up
  ensure_cron_jobs
}

write_acme_only_vhost() {
  local domain="$1"
  local safe_name
  safe_name="$(safe_domain_name "$domain")"

  cat > "${PROXY_CONF_DIR}/acme-${safe_name}.conf" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 "OK\n";
    }
}
EOF
}

write_roundcube_proxy_config_https() {
  local domain="$1"
  local upstream_name="roundcube-webmail"
  local safe_name
  safe_name="$(safe_domain_name "$domain")"

  cat > "${PROXY_CONF_DIR}/webmail-${safe_name}.conf" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    client_max_body_size 50M;

    location / {
        proxy_pass http://${upstream_name}:80;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection \"\";
    }
}
EOF
}

write_webmail_meta() {
  local webmail_domain="$1"
  local webmail_domains="$2"
  local mail_host="$3"

  mkdir -p "$WEBMAIL_BASE"
  {
    printf 'WEBMAIL_PRIMARY_DOMAIN=%q\n' "$webmail_domain"
    printf 'WEBMAIL_DOMAIN=%q\n' "$webmail_domain"
    printf 'WEBMAIL_DOMAINS=%q\n' "$webmail_domains"
    printf 'MAIL_HOST=%q\n' "$mail_host"
  } > "$WEBMAIL_META_FILE"
}

remove_webmail_proxy_configs() {
  local domain="$1"
  local safe_name

  safe_name="$(safe_domain_name "$domain")"
  rm -f "${PROXY_CONF_DIR}/webmail-${safe_name}.conf" || true
  rm -f "${PROXY_CONF_DIR}/acme-${safe_name}.conf" || true
}

print_webmail_dns_targets() {
  local webmail_domains="$1"
  local domain

  IFS=',' read -r -a domains <<< "$webmail_domains"
  for domain in "${domains[@]}"; do
    echo "  ${domain} -> YOUR_SERVER_IP"
  done
}

write_roundcube_proxy_configs() {
  local webmail_domains="$1"
  local domain

  IFS=',' read -r -a domains <<< "$webmail_domains"
  for domain in "${domains[@]}"; do
    write_roundcube_proxy_config_https "$domain"
  done
}

write_roundcube_compose() {
  local webmail_domain="$1"
  local webmail_domains="$2"
  local mail_host="$3"

  mkdir -p "${WEBMAIL_BASE}/data/db" "${WEBMAIL_BASE}/data/config" "${WEBMAIL_BASE}/data/temp"
  chown -R 33:33 "${WEBMAIL_BASE}/data" >/dev/null 2>&1 || true

  cat > "$WEBMAIL_COMPOSE" <<EOF
services:
  roundcube:
    image: roundcube/roundcubemail:latest
    container_name: roundcube-webmail
    restart: unless-stopped
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: "ssl://${mail_host}"
      ROUNDCUBEMAIL_DEFAULT_PORT: 993
      ROUNDCUBEMAIL_SMTP_SERVER: "tls://${mail_host}"
      ROUNDCUBEMAIL_SMTP_PORT: 587
      ROUNDCUBEMAIL_DB_TYPE: sqlite
      ROUNDCUBEMAIL_UPLOAD_MAX_FILESIZE: 25M
    volumes:
      - ./data/db:/var/roundcube/db
      - ./data/config:/var/roundcube/config
      - ./data/temp:/tmp/roundcube-temp
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - roundcube-webmail

networks:
  ${SHARED_NETWORK}:
    external: true
EOF

  write_webmail_meta "$webmail_domain" "$webmail_domains" "$mail_host"
}

issue_webmail_certificate() {
  local webmail_domain="$1"
  local cert_email="$2"

  echo "Issuing Let's Encrypt certificate for ${webmail_domain}..."
  write_acme_only_vhost "$webmail_domain"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  if ! dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$cert_email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$webmail_domain"; then
    echo "Failed to issue certificate for ${webmail_domain}."
    return 1
  fi

  rm -f "${PROXY_CONF_DIR}/acme-$(safe_domain_name "$webmail_domain").conf" || true

  return 0
}

issue_reverb_certificate() {
  local reverb_domain="$1"
  local cert_email="$2"

  echo "Issuing Let's Encrypt certificate for ${reverb_domain}..."
  write_acme_only_vhost "$reverb_domain"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  if ! dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$cert_email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$reverb_domain"; then
    echo "Failed to issue certificate for ${reverb_domain}."
    return 1
  fi

  rm -f "${PROXY_CONF_DIR}/acme-$(safe_domain_name "$reverb_domain").conf" || true
  return 0
}

issue_webmail_certificates() {
  local webmail_domains="$1"
  local cert_email="$2"
  local domain

  IFS=',' read -r -a domains <<< "$webmail_domains"
  for domain in "${domains[@]}"; do
    issue_webmail_certificate "$domain" "$cert_email" || return 1
  done
}

issue_mail_host_certificate() {
  local mail_host="$1"
  local cert_email="$2"

  echo "Issuing Let's Encrypt certificate for ${mail_host}..."
  write_acme_only_vhost "$mail_host"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  if ! dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$cert_email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$mail_host"; then
    echo "Failed to issue certificate for ${mail_host}."
    return 1
  fi

  rm -f "${PROXY_CONF_DIR}/acme-$(safe_domain_name "$mail_host").conf" || true
  return 0
}

sync_webmail_mail_host_if_needed() {
  local old_mail_host="$1"
  local new_mail_host="$2"
  local current_webmail_domains current_webmail_domain current_mail_host

  [ -f "$WEBMAIL_COMPOSE" ] || return 0

  current_webmail_domains=""
  current_webmail_domain=""
  current_mail_host=""

  if [ -f "$WEBMAIL_META_FILE" ]; then
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$WEBMAIL_META_FILE"
    current_webmail_domain="${WEBMAIL_PRIMARY_DOMAIN:-${WEBMAIL_DOMAIN:-}}"
    current_webmail_domains="${WEBMAIL_DOMAINS:-}"
    current_mail_host="${MAIL_HOST:-}"
  fi

  if [ -z "$current_mail_host" ]; then
    current_mail_host="$(awk -F'"' '/ROUNDCUBEMAIL_DEFAULT_HOST:/ {print $2}' "$WEBMAIL_COMPOSE" | sed 's/^ssl:\/\///' | head -n 1)"
  fi
  if [ "$current_mail_host" != "$old_mail_host" ]; then
    return 0
  fi

  if [ -z "$current_webmail_domains" ]; then
    current_webmail_domains="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | sort -u | paste -sd ',' -)"
  fi
  if [ -z "$current_webmail_domain" ] && [ -n "$current_webmail_domains" ]; then
    current_webmail_domain="$(csv_first_value "$current_webmail_domains")"
  fi
  if [ -z "$current_webmail_domain" ]; then
    current_webmail_domain="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | head -n 1)"
  fi
  if [ -z "$current_webmail_domains" ] && [ -n "$current_webmail_domain" ]; then
    current_webmail_domains="$current_webmail_domain"
  fi

  if [ -z "$current_webmail_domain" ] || [ -z "$current_webmail_domains" ]; then
    return 0
  fi

  echo "Updating Roundcube to use the new mail host..."
  write_roundcube_compose "$current_webmail_domain" "$current_webmail_domains" "$new_mail_host"
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate
}

setup_mailserver() {
  local mail_domain mail_host admin_user admin_email admin_password proceed remove_old_cert

  echo ""
  echo "Email server setup (docker-mailserver)"
  echo ""
  echo "Important:"
  echo "  - Many VPS providers block port 25 by default."
  echo "  - Running a public mail server requires correct DNS (SPF/DKIM/DMARC) and rDNS (PTR)."
  echo "  - If you misconfigure it, your mail may go to spam or be rejected."
  echo ""

  prompt mail_domain "Mail domain (e.g. example.com): "
  mail_domain="$(normalize_domain "$mail_domain")"
  if ! validate_domain "$mail_domain"; then
    echo "Invalid domain: ${mail_domain}"
    exit 1
  fi

  prompt mail_host "Mail host/FQDN (e.g. mail.example.com): "
  mail_host="$(normalize_domain "$mail_host")"
  if ! validate_domain "$mail_host"; then
    echo "Invalid host: ${mail_host}"
    exit 1
  fi

  prompt admin_user "Initial mailbox user [postmaster]: " "postmaster"
  admin_user="${admin_user,,}"
  admin_user="${admin_user//[$'\t\r\n ']/}"
  if [[ ! "$admin_user" =~ ^[a-z0-9._-]+$ ]]; then
    echo "Invalid mailbox user: ${admin_user}"
    exit 1
  fi
  admin_email="${admin_user}@${mail_domain}"

  prompt_secret admin_password "Initial mailbox password: "
  if [ -z "$admin_password" ]; then
    echo "Password is required."
    exit 1
  fi

  echo ""
  echo "DNS records you need (create these BEFORE expecting mail to work):"
  echo "--------------------------------------------------------------"
  echo "A/AAAA:"
  echo "  ${mail_host} -> YOUR_SERVER_IP"
  echo ""
  echo "MX (for ${mail_domain}):"
  echo "  ${mail_domain} MX 10 ${mail_host}"
  echo ""
  echo "PTR / rDNS (set at your VPS/provider):"
  echo "  YOUR_SERVER_IP PTR ${mail_host}"
  echo ""
  echo "SPF (TXT for ${mail_domain}):"
  echo "  v=spf1 mx -all"
  echo ""
  echo "DKIM + DMARC:"
  echo "  The script will generate DKIM keys and show you the TXT record to add."
  echo "  Example DMARC (TXT for _dmarc.${mail_domain}):"
  echo "    v=DMARC1; p=none; rua=mailto:dmarc@${mail_domain}"
  echo "--------------------------------------------------------------"
  echo ""
  echo "Multi-domain note:"
  echo "  You can host multiple email domains on this ONE mail server."
  echo "  For each additional domain, you will add its MX record pointing to ${mail_host}"
  echo "  and create mailboxes like user@otherdomain.com."
  echo "  Mail clients should always connect using the mail host: ${mail_host}"
  echo ""

  read -r -p "Ready to proceed and create the email server containers? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  install_base
  ensure_proxy_stack

  echo "Issuing Let's Encrypt certificate for ${mail_host}..."
  write_acme_only_vhost "$mail_host"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  if ! dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "admin@${mail_domain}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$mail_host"; then
    echo "Failed to issue certificate for ${mail_host}."
    exit 1
  fi

  echo "Creating mailserver stack in ${MAIL_BASE}..."
  mkdir -p "${MAIL_BASE}/docker-data/dms/mail-data" \
    "${MAIL_BASE}/docker-data/dms/mail-state" \
    "${MAIL_BASE}/docker-data/dms/mail-logs" \
    "${MAIL_BASE}/docker-data/dms/config"

  cat > "$MAIL_ENV_FILE" <<EOF
OVERRIDE_HOSTNAME=${mail_host}
SSL_TYPE=letsencrypt
SSL_CERT_PATH=/etc/letsencrypt/live/${mail_host}/fullchain.pem
SSL_KEY_PATH=/etc/letsencrypt/live/${mail_host}/privkey.pem

ENABLE_FAIL2BAN=1
ENABLE_CLAMAV=0
ENABLE_SPAMASSASSIN=0
ENABLE_POSTGREY=0

POSTMASTER_ADDRESS=postmaster@${mail_domain}
LOG_LEVEL=info
EOF

  cat > "$MAIL_COMPOSE" <<EOF
services:
  mailserver:
    image: ghcr.io/docker-mailserver/docker-mailserver:latest
    container_name: mailserver
    hostname: ${mail_host%%.*}
    domainname: ${mail_domain}
    env_file:
      - ./mailserver.env
    ports:
      - "25:25"
      - "465:465"
      - "587:587"
      - "143:143"
      - "993:993"
    volumes:
      - ./docker-data/dms/mail-data/:/var/mail/
      - ./docker-data/dms/mail-state/:/var/mail-state/
      - ./docker-data/dms/mail-logs/:/var/log/mail/
      - ./docker-data/dms/config/:/tmp/docker-mailserver/
      - ${PROXY_CERTBOT_CONF}:/etc/letsencrypt:ro
      - /etc/localtime:/etc/localtime:ro
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - ${mail_host}
    restart: unless-stopped
    stop_grace_period: 1m
    cap_add:
      - NET_ADMIN

networks:
  ${SHARED_NETWORK}:
    external: true
EOF

  echo "Starting mailserver..."
  dc -f "$MAIL_COMPOSE" up -d

  echo "Creating initial mailbox: ${admin_email}"
  docker exec -i mailserver setup email add "$admin_email" "$admin_password" >/dev/null 2>&1 || {
    echo "Warning: failed to create mailbox automatically."
    echo "You can create it manually with:"
    echo "  docker exec -it mailserver setup email add ${admin_email}"
  }

  echo "Generating DKIM keys..."
  docker exec -i mailserver setup config dkim >/dev/null 2>&1 || true
  dc -f "$MAIL_COMPOSE" restart mailserver || true

  local dkim_txt="${MAIL_BASE}/docker-data/dms/config/opendkim/keys/${mail_domain}/mail.txt"
  echo ""
  echo "=============================================================="
  echo "MAILSERVER READY"
  echo "Host: ${mail_host}"
  echo "Domain: ${mail_domain}"
  echo "Mailbox: ${admin_email}"
  echo ""
  echo "Ports opened by the container: 25, 465, 587, 143, 993"
  echo ""
  if [ -f "$dkim_txt" ]; then
    echo "DKIM TXT record (add this in your DNS):"
    echo "--------------------------------------------------------------"
    sed -e 's/[[:space:]]*$//' "$dkim_txt" || true
    echo "--------------------------------------------------------------"
  else
    echo "DKIM record file not found yet."
    echo "Check: ${dkim_txt}"
  fi
  echo ""
  echo "Next steps:"
  echo "  1) Confirm DNS A/AAAA, MX, SPF, PTR are correct"
  echo "  2) Add DKIM and DMARC"
  echo "  3) Test SMTP submission on port 587 and IMAPS on 993"
  echo "=============================================================="
}

ensure_mailserver_running() {
  if ! docker_container_exists "mailserver"; then
    echo "Mailserver container not found."
    echo "Run option 10 first: Setup email server (docker-mailserver)."
    exit 1
  fi
}

print_mail_dns_instructions() {
  local domain="$1"
  local mail_host="$2"

  echo "DNS checklist for ${domain}:"
  echo "--------------------------------------------------------------"
  echo "MX:"
  echo "  ${domain} MX 10 ${mail_host}"
  echo ""
  echo "SPF (TXT for ${domain}):"
  echo "  v=spf1 mx -all"
  echo ""
  echo "DMARC (TXT for _dmarc.${domain}):"
  echo "  v=DMARC1; p=none; rua=mailto:dmarc@${domain}"
  echo ""
  echo "DKIM:"
  echo "  Add the TXT record from:"
  echo "    ${MAIL_BASE}/docker-data/dms/config/opendkim/keys/${domain}/mail.txt"
  echo "--------------------------------------------------------------"
}

add_mail_domain() {
  local domain mail_host guessed_host dkim_file proceed

  ensure_mailserver_running

  prompt domain "Domain to add (e.g. example.com): "
  domain="$(normalize_domain "$domain")"
  if ! validate_domain "$domain"; then
    echo "Invalid domain: ${domain}"
    exit 1
  fi

  guessed_host=""
  if [ -f "$MAIL_ENV_FILE" ]; then
    guessed_host="$(awk -F= '/^OVERRIDE_HOSTNAME=/{print $2}' "$MAIL_ENV_FILE" | head -n 1)"
  fi

  if [ -n "$guessed_host" ]; then
    mail_host="$guessed_host"
  else
    prompt mail_host "Mail host/FQDN (e.g. mail.example.com): "
    mail_host="$(normalize_domain "$mail_host")"
    if ! validate_domain "$mail_host"; then
      echo "Invalid host: ${mail_host}"
      exit 1
    fi
  fi

  echo ""
  print_mail_dns_instructions "$domain" "$mail_host"
  echo ""
  read -r -p "Generate DKIM now for ${domain}? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Skipped DKIM generation."
    return 0
  fi

  echo "Generating DKIM keys for ${domain}..."
  docker exec -i mailserver setup config dkim domain "$domain" || true
  dkim_file="${MAIL_BASE}/docker-data/dms/config/opendkim/keys/${domain}/mail.txt"

  echo ""
  if [ -f "$dkim_file" ]; then
    echo "DKIM TXT record for ${domain}:"
    echo "--------------------------------------------------------------"
    sed -e 's/[[:space:]]*$//' "$dkim_file" || true
    echo "--------------------------------------------------------------"
  else
    echo "DKIM record file not found yet."
    echo "Check: ${dkim_file}"
  fi

  echo ""
  echo "Next steps for ${domain}:"
  echo "  1) Add the MX/SPF/DMARC records shown above"
  echo "  2) Add the DKIM TXT record"
  echo "  3) Create mailbox(es) like user@${domain}"
}

change_mail_host() {
  local old_mail_host new_mail_host cert_email remove_old new_mail_domain current_postmaster

  ensure_mailserver_running

  if [ ! -f "$MAIL_ENV_FILE" ] || [ ! -f "$MAIL_COMPOSE" ]; then
    echo "Mailserver config files not found."
    echo "Run option 10 first: Setup email server (docker-mailserver)."
    exit 1
  fi

  old_mail_host="$(awk -F= '/^OVERRIDE_HOSTNAME=/{print $2}' "$MAIL_ENV_FILE" | head -n 1)"
  if [ -z "$old_mail_host" ]; then
    echo "Current mail host not found in ${MAIL_ENV_FILE}."
    exit 1
  fi

  current_postmaster="$(awk -F= '/^POSTMASTER_ADDRESS=/{print $2}' "$MAIL_ENV_FILE" | head -n 1)"

  echo "Current mail host: ${old_mail_host}"
  prompt new_mail_host "New mail host/FQDN (e.g. mail.example.com): "
  new_mail_host="$(normalize_domain "$new_mail_host")"
  if ! validate_domain "$new_mail_host"; then
    echo "Invalid host: ${new_mail_host}"
    exit 1
  fi

  if [ "$new_mail_host" = "$old_mail_host" ]; then
    echo "New mail host is the same as the current mail host."
    exit 0
  fi

  new_mail_domain="${new_mail_host#*.}"
  prompt cert_email "Email for Let's Encrypt [${current_postmaster:-admin@${new_mail_domain}}]: " "${current_postmaster:-admin@${new_mail_domain}}"
  if [ -z "$cert_email" ]; then
    echo "Email is required."
    exit 1
  fi

  echo ""
  echo "You must update DNS after this change:"
  echo "  A/AAAA: ${new_mail_host} -> YOUR_SERVER_IP"
  echo "  PTR/rDNS: YOUR_SERVER_IP -> ${new_mail_host}"
  echo "  Update MX for every hosted mail domain to point to ${new_mail_host}"
  echo "  Update SPF/DMARC where needed if they mention the old host"
  echo ""

  if ! issue_mail_host_certificate "$new_mail_host" "$cert_email"; then
    exit 1
  fi

  sed -i "s|^OVERRIDE_HOSTNAME=.*|OVERRIDE_HOSTNAME=${new_mail_host}|" "$MAIL_ENV_FILE"
  sed -i "s|^SSL_CERT_PATH=.*|SSL_CERT_PATH=/etc/letsencrypt/live/${new_mail_host}/fullchain.pem|" "$MAIL_ENV_FILE"
  sed -i "s|^SSL_KEY_PATH=.*|SSL_KEY_PATH=/etc/letsencrypt/live/${new_mail_host}/privkey.pem|" "$MAIL_ENV_FILE"
  sed -i "s|^[[:space:]]*hostname: .*|    hostname: ${new_mail_host%%.*}|" "$MAIL_COMPOSE"
  sed -i "s|^[[:space:]]*domainname: .*|    domainname: ${new_mail_domain}|" "$MAIL_COMPOSE"
  sed -i "/^[[:space:]]*aliases:/ {n; s|^.*$|          - ${new_mail_host}|;}" "$MAIL_COMPOSE"

  echo "Recreating mailserver with the new mail host..."
  dc -f "$MAIL_COMPOSE" up -d --force-recreate

  sync_webmail_mail_host_if_needed "$old_mail_host" "$new_mail_host"

  echo ""
  prompt remove_old "Remove old certificate files for ${old_mail_host}? (yes/no): " "no"
  if [ "${remove_old,,}" = "yes" ]; then
    rm -rf "${PROXY_CERTBOT_CONF}/live/${old_mail_host}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/archive/${old_mail_host}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/renewal/${old_mail_host}.conf" || true
    echo "Old certificate files removed."
  fi

  echo ""
  echo "MAIL HOST UPDATED"
  echo "Old host: ${old_mail_host}"
  echo "New host: ${new_mail_host}"
  echo "Reminder: update MX records for all hosted mail domains."
}

manage_mailserver() {
  local action email_addr email_password domain_list mail_host guessed_host dkim_file confirm_delete

  echo ""
  echo "Manage email server (docker-mailserver)"
  echo ""
  echo "Tip: For multiple domains, keep one mail host (e.g. mail.example.com) and"
  echo "set each domain's MX to that host."
  echo ""

  ensure_mailserver_running

  prompt action "Action [status/add-domain/change-mail-host/add-mailbox/delete-mailbox/reset-password/list-mailboxes/gen-dkim/show-dkim/dns-help]: " "status"

  case "${action,,}" in
    status)
      docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || $1=="mailserver"'
      ;;
    add-domain)
      add_mail_domain
      ;;
    change-mail-host)
      change_mail_host
      ;;
    add-mailbox)
      prompt email_addr "New mailbox address (e.g. user@example.com): "
      email_addr="${email_addr//[$'\t\r\n ']/}"
      if [[ ! "$email_addr" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Invalid email address: ${email_addr}"
        exit 1
      fi
      prompt_secret email_password "Mailbox password: "
      if [ -z "$email_password" ]; then
        echo "Password is required."
        exit 1
      fi
      echo "Creating mailbox: ${email_addr}"
      docker exec -i mailserver setup email add "$email_addr" "$email_password"
      echo "Mailbox created."
      ;;
    delete-mailbox)
      prompt email_addr "Mailbox address to delete (e.g. user@example.com): "
      email_addr="${email_addr//[$'\t\r\n ']/}"
      if [[ ! "$email_addr" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Invalid email address: ${email_addr}"
        exit 1
      fi
      echo ""
      echo "This will permanently delete the mailbox and its stored emails:"
      echo "  ${email_addr}"
      echo ""
      read -r -p "Type DELETE to confirm: " confirm_delete
      if [ "$confirm_delete" != "DELETE" ]; then
        echo "Cancelled."
        exit 0
      fi
      docker exec -i mailserver setup email del "$email_addr"
      echo "Mailbox deleted."
      ;;
    reset-password)
      prompt email_addr "Mailbox address to reset password for (e.g. user@example.com): "
      email_addr="${email_addr//[$'\t\r\n ']/}"
      if [[ ! "$email_addr" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Invalid email address: ${email_addr}"
        exit 1
      fi
      prompt_secret email_password "New mailbox password: "
      if [ -z "$email_password" ]; then
        echo "Password is required."
        exit 1
      fi
      echo "Resetting password for: ${email_addr}"
      if docker exec -i mailserver setup email update "$email_addr" "$email_password"; then
        echo "Password updated."
      elif docker exec -i mailserver setup email add "$email_addr" "$email_password"; then
        echo "Password updated."
        echo "Note: Your docker-mailserver setup tool did not accept 'update'."
        echo "This used 'add' as a fallback (some versions treat it as a password reset)."
      else
        echo "Failed to reset password."
        echo "Try inside the container:"
        echo "  docker exec -it mailserver setup email help"
        exit 1
      fi
      ;;
    list-mailboxes)
      docker exec -i mailserver setup email list || true
      ;;
    gen-dkim)
      prompt domain_list "Domain(s) to generate DKIM for (comma-separated): "
      domain_list="${domain_list//[$'\t\r\n ']/}"
      if [ -z "$domain_list" ]; then
        echo "Domain list is required."
        exit 1
      fi
      echo "Generating DKIM keys for: ${domain_list}"
      docker exec -i mailserver setup config dkim domain "$domain_list" || true
      echo "DKIM generation done."
      echo "Use 'show-dkim' to print the TXT record."
      ;;
    show-dkim)
      prompt domain_list "Domain to show DKIM for (e.g. example.com): "
      domain_list="$(normalize_domain "$domain_list")"
      if ! validate_domain "$domain_list"; then
        echo "Invalid domain: ${domain_list}"
        exit 1
      fi
      dkim_file="${MAIL_BASE}/docker-data/dms/config/opendkim/keys/${domain_list}/mail.txt"
      if [ ! -f "$dkim_file" ]; then
        echo "DKIM file not found: ${dkim_file}"
        echo "Run 'gen-dkim' first (and ensure a mailbox exists for that domain)."
        exit 1
      fi
      echo "DKIM TXT record for ${domain_list}:"
      echo "--------------------------------------------------------------"
      sed -e 's/[[:space:]]*$//' "$dkim_file" || true
      echo "--------------------------------------------------------------"
      ;;
    dns-help)
      prompt domain_list "Domain (e.g. example.com): "
      domain_list="$(normalize_domain "$domain_list")"
      if ! validate_domain "$domain_list"; then
        echo "Invalid domain: ${domain_list}"
        exit 1
      fi

      guessed_host=""
      if [ -f "$MAIL_ENV_FILE" ]; then
        guessed_host="$(awk -F= '/^OVERRIDE_HOSTNAME=/{print $2}' "$MAIL_ENV_FILE" | head -n 1)"
      fi
      if [ -z "$guessed_host" ]; then
        prompt mail_host "Mail host/FQDN (e.g. mail.example.com): "
        mail_host="$(normalize_domain "$mail_host")"
        if ! validate_domain "$mail_host"; then
          echo "Invalid host: ${mail_host}"
          exit 1
        fi
      else
        mail_host="$guessed_host"
      fi

      print_mail_dns_instructions "$domain_list" "$mail_host"
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

setup_webmail_roundcube() {
  local webmail_domains webmail_domain alias_domains mail_host mail_domain proceed

  echo ""
  echo "Webmail setup (Roundcube)"
  echo ""
  echo "This will create a Roundcube container and publish it via the existing reverse proxy."
  echo "You will need a dedicated domain like: webmail.example.com"
  echo ""

  prompt webmail_domain "Primary webmail domain (e.g. webmail.example.com): "
  webmail_domain="$(normalize_domain "$webmail_domain")"
  if ! validate_domain "$webmail_domain"; then
    echo "Invalid domain: ${webmail_domain}"
    exit 1
  fi

  prompt alias_domains "Additional webmail alias domains (comma-separated, optional): "
  alias_domains="$(normalize_domain_csv "$alias_domains")"
  if [ -n "$alias_domains" ] && ! validate_domain_csv "$alias_domains"; then
    echo "Invalid alias domain list: ${alias_domains}"
    exit 1
  fi
  webmail_domains="$webmail_domain"
  if [ -n "$alias_domains" ]; then
    webmail_domains="$(normalize_domain_csv "${webmail_domains},${alias_domains}")"
  fi

  prompt mail_host "IMAP/SMTP host (e.g. mail.example.com): "
  mail_host="$(normalize_domain "$mail_host")"
  if ! validate_domain "$mail_host"; then
    echo "Invalid host: ${mail_host}"
    exit 1
  fi

  mail_domain="${mail_host#*.}"

  echo ""
  echo "DNS records you need:"
  echo "--------------------------------------------------------------"
  echo "A/AAAA:"
  print_webmail_dns_targets "$webmail_domains"
  echo "--------------------------------------------------------------"
  echo ""

  read -r -p "Ready to proceed and create the webmail container? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  install_base
  ensure_proxy_stack

  if ! issue_webmail_certificates "$webmail_domains" "admin@${mail_domain}"; then
    exit 1
  fi

  echo "Creating Roundcube stack in ${WEBMAIL_BASE}..."
  write_roundcube_compose "$webmail_domain" "$webmail_domains" "$mail_host"

  echo "Starting Roundcube..."
  dc -f "$WEBMAIL_COMPOSE" up -d

  echo "Publishing webmail via reverse proxy..."
  write_roundcube_proxy_configs "$webmail_domains"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  echo ""
  echo "=============================================================="
  echo "WEBMAIL READY"
  echo "Primary URL: https://${webmail_domain}"
  if [ "$webmail_domains" != "$webmail_domain" ]; then
    echo "Aliases: ${webmail_domains#${webmail_domain},}"
  fi
  echo "IMAP: ${mail_host}:993 (SSL)"
  echo "SMTP: ${mail_host}:587 (STARTTLS)"
  echo "Login format: full email address (e.g. user@example.com)"
  echo "=============================================================="
}

modify_webmail_roundcube() {
  local current_webmail_domain current_webmail_domains current_mail_host webmail_domains webmail_domain mail_host mail_domain proceed remove_old old_domain removed_domains part

  echo ""
  echo "Modify webmail (Roundcube)"
  echo ""

  if [ ! -f "$WEBMAIL_COMPOSE" ]; then
    echo "Webmail stack not found."
    echo "Run option 11 first: Setup webmail (Roundcube)."
    exit 1
  fi

  current_webmail_domain=""
  current_webmail_domains=""
  current_mail_host=""

  if [ -f "$WEBMAIL_META_FILE" ]; then
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$WEBMAIL_META_FILE"
    current_webmail_domain="${WEBMAIL_PRIMARY_DOMAIN:-${WEBMAIL_DOMAIN:-}}"
    current_webmail_domains="${WEBMAIL_DOMAINS:-}"
    current_mail_host="${MAIL_HOST:-}"
  fi

  if [ -z "$current_webmail_domain" ]; then
    current_webmail_domain="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | head -n 1)"
  fi
  if [ -z "$current_webmail_domains" ]; then
    current_webmail_domains="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | sort -u | paste -sd ',' -)"
  fi
  if [ -z "$current_webmail_domains" ] && [ -n "$current_webmail_domain" ]; then
    current_webmail_domains="$current_webmail_domain"
  fi
  if [ -z "$current_mail_host" ]; then
    current_mail_host="$(awk -F'"' '/ROUNDCUBEMAIL_DEFAULT_HOST:/ {print $2}' "$WEBMAIL_COMPOSE" | sed 's/^ssl:\/\///' | head -n 1)"
  fi

  prompt webmail_domains "Webmail domains (comma-separated, first is primary) [${current_webmail_domains}]: " "${current_webmail_domains}"
  webmail_domains="$(normalize_domain_csv "$webmail_domains")"
  if ! validate_domain_csv "$webmail_domains"; then
    echo "Invalid domain list: ${webmail_domains}"
    exit 1
  fi
  webmail_domain="$(csv_first_value "$webmail_domains")"

  prompt mail_host "IMAP/SMTP host [${current_mail_host}]: " "${current_mail_host}"
  mail_host="$(normalize_domain "$mail_host")"
  if ! validate_domain "$mail_host"; then
    echo "Invalid host: ${mail_host}"
    exit 1
  fi

  if [ "$webmail_domains" = "$current_webmail_domains" ] && [ "$mail_host" = "$current_mail_host" ]; then
    echo "No changes detected."
    exit 0
  fi

  mail_domain="${mail_host#*.}"

  echo ""
  echo "Primary webmail URL: https://${webmail_domain}"
  echo "All webmail domains: ${webmail_domains}"
  echo "Mail host: ${mail_host}"
  echo "Login format: full email address (multi-domain ready)"
  echo ""

  read -r -p "Ready to apply these webmail changes? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  install_base
  ensure_proxy_stack

  if ! issue_webmail_certificates "$webmail_domains" "admin@${mail_domain}"; then
    exit 1
  fi

  echo "Rewriting Roundcube stack..."
  write_roundcube_compose "$webmail_domain" "$webmail_domains" "$mail_host"
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate

  removed_domains=""
  if [ -n "$current_webmail_domains" ]; then
    IFS=',' read -r -a old_domains <<< "$current_webmail_domains"
    for old_domain in "${old_domains[@]}"; do
      if ! csv_contains_value "$webmail_domains" "$old_domain"; then
        remove_webmail_proxy_configs "$old_domain"
        if [ -z "$removed_domains" ]; then
          removed_domains="$old_domain"
        else
          removed_domains="${removed_domains},${old_domain}"
        fi
      fi
    done
  fi

  write_roundcube_proxy_configs "$webmail_domains"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  if [ -n "$removed_domains" ]; then
    echo ""
    prompt remove_old "Remove old certificate files for removed webmail domains (${removed_domains})? (yes/no): " "no"
    if [ "${remove_old,,}" = "yes" ]; then
      IFS=',' read -r -a removed_parts <<< "$removed_domains"
      for part in "${removed_parts[@]}"; do
        rm -rf "${PROXY_CERTBOT_CONF}/live/${part}" || true
        rm -rf "${PROXY_CERTBOT_CONF}/archive/${part}" || true
        rm -rf "${PROXY_CERTBOT_CONF}/renewal/${part}.conf" || true
      done
      echo "Old certificate files removed."
    fi
  fi

  echo ""
  echo "=============================================================="
  echo "WEBMAIL UPDATED"
  echo "Primary URL: https://${webmail_domain}"
  if [ "$webmail_domains" != "$webmail_domain" ]; then
    echo "All webmail domains: ${webmail_domains}"
  fi
  echo "IMAP: ${mail_host}:993 (SSL)"
  echo "SMTP: ${mail_host}:587 (STARTTLS)"
  echo "Login format: full email address (e.g. user@example.com)"
  echo "=============================================================="
}

create_project() {
  local project_slug domain email db_name db_user db_password db_root_password app_dir project_name pma_port pma_bind_ip

  prompt project_slug "Project short name (e.g. ferretiq): "
  project_name="$(slug_to_name "$project_slug")"

  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  if [ "$project_slug" != "$project_name" ]; then
    echo "Normalized name: ${project_name}"
  fi

  prompt domain "Domain (e.g. example.com): "
  domain="$(normalize_domain "$domain")"

  if ! validate_domain "$domain"; then
    echo "Invalid domain: ${domain}"
    exit 1
  fi

  prompt email "Email for Let's Encrypt: "
  prompt db_name "Database name: "
  prompt db_user "Database user: "
  prompt_secret db_password "Database password: "
  prompt_secret db_root_password "MariaDB root password: "
  prompt app_dir "Project directory [${PROJECTS_BASE}/${project_name}]: " "${PROJECTS_BASE}/${project_name}"

  if [ -z "$email" ] || [ -z "$db_name" ] || [ -z "$db_user" ] || [ -z "$db_password" ] || [ -z "$db_root_password" ]; then
    echo "All fields are required."
    exit 1
  fi

  if [ -d "$app_dir" ] && [ -f "${app_dir}/docker-compose.yml" ]; then
    echo "A project already exists at ${app_dir}"
    exit 1
  fi

  install_base
  detect_tuning

  if [ -e "${PROXY_PROJECTS_DIR}/${project_name}" ]; then
    echo "A project already exists with the name: ${project_name}"
    exit 1
  fi

  echo "Creating project structure..."
  mkdir -p "$app_dir"
  ln -sfn "$app_dir" "${PROXY_PROJECTS_DIR}/${project_name}"

  pma_port="$(pma_default_port "$project_name")"
  pma_bind_ip="127.0.0.1"
  write_project_files "$app_dir" "$project_name" "$domain" "$db_name" "$db_user" "$db_password" "$db_root_password" "$pma_port" "$pma_bind_ip"
  write_proxy_config_http "$project_name" "$domain"

  echo "Starting project containers..."
  cd "$app_dir"
  dc up -d --build

  echo "Restarting reverse proxy..."
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  sleep 8

  echo "Requesting SSL certificate..."
  dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$domain"

  write_proxy_config_https "$project_name" "$domain"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  ensure_cron_jobs

  echo ""
  echo "=============================================================="
  echo "INSTALLATION COMPLETE"
  echo "Project: ${project_name}"
  echo "Domain: https://${domain}"
  echo "Project path: ${app_dir}"
  echo "Applied profile based on RAM: ${RAM_MB} MB"
  echo ""
  echo "CONFIGURE YOUR .env LIKE THIS:"
  echo "--------------------------------------------------------------"
  echo "APP_ENV=production"
  echo "APP_DEBUG=false"
  echo ""
  echo "DB_CONNECTION=mysql"
  echo "DB_HOST=mariadb"
  echo "DB_PORT=3306"
  echo "DB_DATABASE=${db_name}"
  echo "DB_USERNAME=${db_user}"
  echo "DB_PASSWORD=*****"
  echo ""
  echo "CACHE_STORE=redis"
  echo "CACHE_DRIVER=redis"
  echo "SESSION_DRIVER=redis"
  echo "QUEUE_CONNECTION=redis"
  echo "REDIS_HOST=redis"
  echo "REDIS_PORT=6379"
  echo "--------------------------------------------------------------"
  echo ""
  echo "The queue worker runs under Supervisor inside the PHP container."
  echo "Daily automatic backup scheduled at 02:30."
  echo "=============================================================="
}

change_project_domain() {
  local project_slug project_name app_dir old_domain new_domain email remove_old

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name to change domain: "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"
  detect_tuning

  if [ ! -f "${app_dir}/.project-meta" ]; then
    echo "Project metadata not found at ${app_dir}/.project-meta"
    echo "Run 'Update project' once to regenerate project files."
    exit 1
  fi

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"
  require_nonempty "DOMAIN" "${DOMAIN}"
  old_domain="${DOMAIN}"

  echo ""
  echo "Current domain: ${old_domain}"
  prompt new_domain "New domain (e.g. example.com): "
  new_domain="$(normalize_domain "$new_domain")"
  if ! validate_domain "$new_domain"; then
    echo "Invalid domain: ${new_domain}"
    exit 1
  fi

  if [ "$new_domain" = "$old_domain" ]; then
    echo "New domain is the same as the current domain."
    exit 0
  fi

  prompt email "Email for Let's Encrypt: "
  if [ -z "$email" ]; then
    echo "Email is required."
    exit 1
  fi

  ensure_proxy_stack

  echo "Switching to HTTP for certificate issuance..."
  write_proxy_config_http "$PROJECT_NAME" "$new_domain"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  echo "Requesting SSL certificate for ${new_domain}..."
  if ! dc -f "$PROXY_COMPOSE" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$new_domain"; then
    echo "Failed to issue certificate. Restoring previous HTTPS config..."
    write_proxy_config_https "$PROJECT_NAME" "$old_domain"
    dc -f "$PROXY_COMPOSE" restart reverse-proxy
    exit 1
  fi

  echo "Enabling HTTPS for ${new_domain}..."
  write_proxy_config_https "$PROJECT_NAME" "$new_domain"
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  set_project_meta_var "${app_dir}/.project-meta" "DOMAIN" "$new_domain"

  echo ""
  prompt remove_old "Remove old certificate files for ${old_domain}? (yes/no): " "no"
  if [ "${remove_old,,}" = "yes" ]; then
    rm -rf "${PROXY_CERTBOT_CONF}/live/${old_domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/archive/${old_domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/renewal/${old_domain}.conf" || true
    echo "Old certificate files removed."
  fi

  echo "Domain updated: https://${new_domain}"
}

delete_project() {
  local project_slug project_name app_dir domain reverb_domain
  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  read -r -p "Project short name to delete: " project_slug

  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"

  ensure_project_exists "$project_name" "$app_dir"

  domain=""
  if [ -f "${app_dir}/.project-meta" ]; then
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "${app_dir}/.project-meta"
    domain="${DOMAIN:-}"
    reverb_domain="${REVERB_DOMAIN:-}"
  fi

  echo ""
  echo "This will delete:"
  echo "  - Docker containers"
  echo "  - Docker volumes for the project"
  echo "  - Nginx configuration"
  echo "  - Reverse proxy symlink"
  echo "  - Project folder"
  echo "  - Existing project backups"
  echo ""
  read -r -p "Continue? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  echo "Creating a final backup before deleting..."
  if ! backup_project_internal "$project_name" "pre-delete"; then
    echo "Warning: pre-delete backup failed. Continuing with deletion..."
  fi

  echo "Stopping containers..."
  cd "$app_dir"
  dc down -v 2>/dev/null || true
  if [ -n "${PHP_CONTAINER:-}" ]; then docker rm -f "${PHP_CONTAINER}" 2>/dev/null || true; fi
  if [ -n "${DB_CONTAINER:-}" ]; then docker rm -f "${DB_CONTAINER}" 2>/dev/null || true; fi
  if [ -n "${REDIS_CONTAINER:-}" ]; then docker rm -f "${REDIS_CONTAINER}" 2>/dev/null || true; fi

  echo "Removing Nginx configuration..."
  rm -f "${PROXY_CONF_DIR}/${project_name}.conf"
  remove_reverb_proxy_config "$project_name"

  if [ -n "$domain" ]; then
    echo "Removing SSL certificates..."
    rm -rf "${PROXY_CERTBOT_CONF}/live/${domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/archive/${domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/renewal/${domain}.conf" || true
  fi
  if [ -n "$reverb_domain" ]; then
    rm -rf "${PROXY_CERTBOT_CONF}/live/${reverb_domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/archive/${reverb_domain}" || true
    rm -rf "${PROXY_CERTBOT_CONF}/renewal/${reverb_domain}.conf" || true
  fi

  echo "Removing project..."
  rm -rf "$app_dir"
  rm -f "${PROXY_PROJECTS_DIR}/${project_name}"

  echo "Removing project backups..."
  rm -rf "${BACKUPS_BASE:?}/${project_name:?}" || true

  echo "Restarting reverse proxy..."
  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  echo ""
  echo "Project deleted successfully."
}

list_projects() {
  echo ""
  echo "Installed projects:"
  echo "--------------------------------------------------------------"

  if [ -d "$PROXY_PROJECTS_DIR" ] && [ -n "$(ls -A "$PROXY_PROJECTS_DIR" 2>/dev/null)" ]; then
    for link in "$PROXY_PROJECTS_DIR"/*; do
      [ -e "$link" ] || continue
      local project_name dir
      project_name="$(basename "$link")"
      dir="$(resolve_project_dir "$project_name")"
      [ -d "$dir" ] || continue

      if [ -f "${dir}/.project-meta" ]; then
        # shellcheck disable=SC1090
        # shellcheck disable=SC1091
        source "${dir}/.project-meta"
        echo "Project: ${project_name}"
        echo "Domain : ${DOMAIN}"
        echo "Path   : ${APP_DIR}"
        echo "DB      : ${DB_NAME}"
        echo "--------------------------------------------------------------"
      else
        echo "Project: ${project_name}"
        echo "Path   : ${dir}"
        echo "--------------------------------------------------------------"
      fi
    done
    return
  fi

  if [ ! -d "$PROJECTS_BASE" ] || [ -z "$(ls -A "$PROJECTS_BASE" 2>/dev/null)" ]; then
    echo "No projects found."
    return
  fi

  for dir in "$PROJECTS_BASE"/*; do
    [ -d "$dir" ] || continue
    local project_name
    project_name="$(basename "$dir")"

    if [ -f "${dir}/.project-meta" ]; then
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${dir}/.project-meta"
      echo "Project: ${project_name}"
      echo "Domain : ${DOMAIN}"
      echo "Path   : ${APP_DIR}"
      echo "DB      : ${DB_NAME}"
      echo "--------------------------------------------------------------"
    else
      echo "Project: ${project_name}"
      echo "Path   : ${dir}"
      echo "--------------------------------------------------------------"
    fi
  done
}

backup_project_internal() {
  local project_name="$1"
  local suffix="${2:-manual}"
  local app_dir
  app_dir="$(resolve_project_dir "$project_name")"

  ensure_project_exists "$project_name" "$app_dir"

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "DB_CONTAINER" "${DB_CONTAINER}"
  require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
  require_nonempty "DB_NAME" "${DB_NAME}"

  local timestamp backup_dir tmp_sql archive_name archive_path
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUPS_BASE}/${project_name}/${timestamp}-${suffix}"
  tmp_sql="${backup_dir}/database.sql"
  archive_name="${project_name}-${timestamp}-${suffix}.tar.gz"
  archive_path="${BACKUPS_BASE}/${project_name}/${archive_name}"

  mkdir -p "$backup_dir"
  : > "$tmp_sql"

  echo "Exporting database..."
  if docker_container_exists "${DB_CONTAINER}"; then
    docker exec "${DB_CONTAINER}" sh -c \
      "exec mariadb-dump -u root -p'${DB_ROOT_PASSWORD}' '${DB_NAME}'" > "$tmp_sql"
  else
    echo "Warning: DB container does not exist (${DB_CONTAINER}). Backup without database."
  fi

  echo "Copying project files..."
  mkdir -p "${backup_dir}/project"
  rsync -a \
    --exclude vendor \
    --exclude node_modules \
    --exclude storage/logs \
    --exclude storage/framework/cache \
    --exclude storage/framework/sessions \
    --exclude storage/framework/views \
    --exclude .git \
    "${app_dir}/" "${backup_dir}/project/"

  cp "${app_dir}/.project-meta" "${backup_dir}/.project-meta"

  echo "Compressing backup..."
  tar -czf "$archive_path" -C "${backup_dir}" .

  rm -rf "$backup_dir"

  echo "Backup created: ${archive_path}"

  find "${BACKUPS_BASE}/${project_name}" -type f -name "*.tar.gz" -mtime +14 -delete || true
}

backup_project() {
  local project_slug project_name
  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  read -r -p "Project short name to back up: " project_slug
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi
  backup_project_internal "$project_name" "manual"
}

backup_all() {
  if [ -d "$PROXY_PROJECTS_DIR" ] && [ -n "$(ls -A "$PROXY_PROJECTS_DIR" 2>/dev/null)" ]; then
    for link in "$PROXY_PROJECTS_DIR"/*; do
      [ -e "$link" ] || continue
      backup_project_internal "$(basename "$link")" "auto"
    done
    return
  fi

  if [ ! -d "$PROJECTS_BASE" ] || [ -z "$(ls -A "$PROJECTS_BASE" 2>/dev/null)" ]; then
    echo "No projects to back up."
    return
  fi

  for dir in "$PROJECTS_BASE"/*; do
    [ -d "$dir" ] || continue
    backup_project_internal "$(basename "$dir")" "auto"
  done
}

restore_project() {
  local project_slug project_name backup_file app_dir
  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  read -r -p "Project short name to restore: " project_slug
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi
  app_dir="$(resolve_project_dir "$project_name")"

  ensure_project_exists "$project_name" "$app_dir"

  echo "Available backups:"
  ls -1 "${BACKUPS_BASE}/${project_name}"/*.tar.gz 2>/dev/null || {
    echo "No backups found."
    exit 1
  }

  echo ""
  read -r -p "Exact path of the backup to restore: " backup_file

  if [ ! -f "$backup_file" ]; then
    echo "File does not exist."
    exit 1
  fi

  local tmp_restore
  tmp_restore="$(mktemp -d)"

  echo "Extracting backup..."
  tar -xzf "$backup_file" -C "$tmp_restore"

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "DB_CONTAINER" "${DB_CONTAINER}"
  require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
  require_nonempty "DB_NAME" "${DB_NAME}"

  echo "Stopping project services..."
  cd "$app_dir"
  dc down || true

  echo "Restoring files..."
  rsync -a --delete "${tmp_restore}/project/" "${app_dir}/"

  echo "Starting services..."
  dc up -d --build

  sleep 10

  echo "Restoring database..."
  docker exec -i "${DB_CONTAINER}" sh -c \
    "exec mariadb -u root -p'${DB_ROOT_PASSWORD}' '${DB_NAME}'" < "${tmp_restore}/database.sql"

  dc -f "$PROXY_COMPOSE" restart reverse-proxy

  rm -rf "$tmp_restore"

  echo "Restore completed."
}

update_project() {
  local project_slug project_name app_dir pma_port pma_bind_ip reverb_enabled reverb_domain reverb_port reverb_exposure
  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name to update: "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi
  app_dir="$(resolve_project_dir "$project_name")"

  ensure_project_exists "$project_name" "$app_dir"

  detect_tuning

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"
  require_nonempty "DOMAIN" "${DOMAIN}"
  require_nonempty "DB_NAME" "${DB_NAME}"
  require_nonempty "DB_USER" "${DB_USER}"
  require_nonempty "DB_PASSWORD" "${DB_PASSWORD}"
  require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"

  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"
  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"

  echo "Regenerating project configuration..."
  write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure"
  write_proxy_config_https "$PROJECT_NAME" "$DOMAIN"
  if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
    write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
  else
    remove_reverb_proxy_config "$PROJECT_NAME"
  fi

  cd "$app_dir"
  dc up -d --build
  dc -f "$PROXY_COMPOSE" restart reverse-proxy
  ensure_cron_jobs

  echo "Project updated."
}

phpmyadmin_manage() {
  local project_slug project_name app_dir pma_container pma_port pma_bind_ip action new_port exposure confirm

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (phpMyAdmin): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"
  detect_tuning

  if [ ! -f "${app_dir}/.project-meta" ]; then
    echo "Project metadata not found at ${app_dir}/.project-meta"
    echo "Run 'Update project' once to regenerate project files."
    exit 1
  fi

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"

  pma_container="${PROJECT_NAME}-phpmyadmin"
  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"

  echo ""
  echo "phpMyAdmin"
  if docker_container_exists "$pma_container" && [ "$(docker inspect -f '{{.State.Running}}' "$pma_container" 2>/dev/null || echo false)" = "true" ]; then
    echo "Status : running"
  else
    echo "Status : stopped"
  fi
  if [ "$pma_bind_ip" = "0.0.0.0" ]; then
    echo "Port   : 0.0.0.0:${pma_port} (public)"
  else
    echo "Port   : 127.0.0.1:${pma_port} (localhost only)"
  fi
  echo ""
  echo "Access methods:"
  if [ "$pma_bind_ip" = "0.0.0.0" ]; then
    echo "  - Public: http://YOUR_SERVER_IP:${pma_port}/"
  else
    echo "  - On the server: http://127.0.0.1:${pma_port}/"
  fi
  echo "  - From your computer via SSH tunnel:"
  echo "      ssh -L 8080:127.0.0.1:${pma_port} root@YOUR_SERVER_IP"
  echo "    Then open: http://127.0.0.1:8080/"
  echo ""
  echo "Login tips:"
  echo "  - Server: mariadb"
  echo "  - Username/password: your DB user/pass (or root if you prefer)"
  echo ""

  prompt action "Action [enable/disable/expose/change-port/status]: " "status"

  case "${action,,}" in
    status)
      return 0
      ;;
    enable)
      if ! grep -q "^[[:space:]]*phpmyadmin:" "${app_dir}/docker-compose.yml"; then
        echo "phpMyAdmin service not found in docker-compose.yml."
        echo "Run 'Update project' once, then try again."
        exit 1
      fi

      prompt new_port "Port for phpMyAdmin [${pma_port}]: " "${pma_port}"
      if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "Invalid port: ${new_port}"
        exit 1
      fi

      prompt exposure "Exposure [local/public]: " "local"
      if [ "${exposure,,}" = "public" ]; then
        echo ""
        echo "WARNING: Exposing phpMyAdmin to the Internet is risky."
        echo "Only do this temporarily and restrict access with a firewall."
        echo ""
        read -r -p "Type YES to confirm: " confirm
        if [ "$confirm" != "YES" ]; then
          echo "Cancelled."
          exit 0
        fi
        pma_bind_ip="0.0.0.0"
      else
        pma_bind_ip="127.0.0.1"
      fi

      if tcp_port_in_use "$new_port"; then
        echo "Port already in use: ${new_port}"
        exit 1
      fi

      set_project_meta_var "${app_dir}/.project-meta" "PMA_PORT" "$new_port"
      set_project_meta_var "${app_dir}/.project-meta" "PMA_BIND_IP" "$pma_bind_ip"
      if ! set_phpmyadmin_portspec_in_compose "${app_dir}/docker-compose.yml" "$pma_bind_ip" "$new_port"; then
        echo "Failed to update phpMyAdmin bind/port in docker-compose.yml."
        exit 1
      fi

      recreate_phpmyadmin "$app_dir" "$pma_container"

      if [ "$pma_bind_ip" = "0.0.0.0" ]; then
        echo "phpMyAdmin enabled on http://YOUR_SERVER_IP:${new_port}/ (public)."
      else
        echo "phpMyAdmin enabled on http://127.0.0.1:${new_port}/ (localhost only)."
      fi
      ;;
    disable)
      cd "$app_dir"
      dc stop phpmyadmin 2>/dev/null || true
      dc rm -f phpmyadmin 2>/dev/null || true
      docker rm -f "$pma_container" 2>/dev/null || true
      echo "phpMyAdmin disabled."
      ;;
    expose)
      if ! grep -q "^[[:space:]]*phpmyadmin:" "${app_dir}/docker-compose.yml"; then
        echo "phpMyAdmin service not found in docker-compose.yml."
        echo "Run 'Update project' once, then try again."
        exit 1
      fi

      prompt exposure "Exposure [local/public]: " "$([ "$pma_bind_ip" = "0.0.0.0" ] && echo public || echo local)"
      if [ "${exposure,,}" = "public" ]; then
        echo ""
        echo "WARNING: Exposing phpMyAdmin to the Internet is risky."
        echo "Only do this temporarily and restrict access with a firewall."
        echo ""
        read -r -p "Type YES to confirm: " confirm
        if [ "$confirm" != "YES" ]; then
          echo "Cancelled."
          exit 0
        fi
        pma_bind_ip="0.0.0.0"
      else
        pma_bind_ip="127.0.0.1"
      fi

      set_project_meta_var "${app_dir}/.project-meta" "PMA_BIND_IP" "$pma_bind_ip"
      if ! set_phpmyadmin_portspec_in_compose "${app_dir}/docker-compose.yml" "$pma_bind_ip" "$pma_port"; then
        echo "Failed to update phpMyAdmin bind/port in docker-compose.yml."
        exit 1
      fi

      recreate_phpmyadmin "$app_dir" "$pma_container"

      if [ "$pma_bind_ip" = "0.0.0.0" ]; then
        echo "phpMyAdmin is now public on http://YOUR_SERVER_IP:${pma_port}/"
      else
        echo "phpMyAdmin is now localhost-only on http://127.0.0.1:${pma_port}/"
      fi
      ;;
    change-port)
      if ! grep -q "^[[:space:]]*phpmyadmin:" "${app_dir}/docker-compose.yml"; then
        echo "phpMyAdmin service not found in docker-compose.yml."
        echo "Run 'Update project' once, then try again."
        exit 1
      fi

      prompt new_port "New port for phpMyAdmin [${pma_port}]: " "${pma_port}"
      if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "Invalid port: ${new_port}"
        exit 1
      fi

      if tcp_port_in_use "$new_port"; then
        echo "Port already in use: ${new_port}"
        exit 1
      fi

      set_project_meta_var "${app_dir}/.project-meta" "PMA_PORT" "$new_port"
      set_phpmyadmin_portspec_in_compose "${app_dir}/docker-compose.yml" "${pma_bind_ip}" "$new_port" || true

      recreate_phpmyadmin "$app_dir" "$pma_container"
      if [ "$pma_bind_ip" = "0.0.0.0" ]; then
        echo "phpMyAdmin port updated to http://YOUR_SERVER_IP:${new_port}/ (public)."
      else
        echo "phpMyAdmin port updated to http://127.0.0.1:${new_port}/ (localhost only)."
      fi
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

manage_reverb() {
  local project_slug project_name app_dir action reverb_enabled reverb_domain reverb_port reverb_exposure cert_email remove_old suggested_domain
  local new_reverb_domain new_reverb_port new_reverb_exposure

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (Reverb): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"
  detect_tuning

  if [ ! -f "${app_dir}/.project-meta" ]; then
    echo "Project metadata not found at ${app_dir}/.project-meta"
    echo "Run 'Update project' once to regenerate project files."
    exit 1
  fi

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"
  require_nonempty "DOMAIN" "${DOMAIN}"
  require_nonempty "DB_NAME" "${DB_NAME}"
  require_nonempty "DB_USER" "${DB_USER}"
  require_nonempty "DB_PASSWORD" "${DB_PASSWORD}"
  require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"

  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"

  echo ""
  echo "Reverb"
  echo "Status : ${reverb_enabled}"
  if [ -n "$reverb_domain" ]; then
    echo "Domain : ${reverb_domain}"
  fi
  echo "Port   : ${reverb_port}"
  echo "Scope  : ${reverb_exposure}"
  echo ""

  prompt action "Action [status/enable/change-domain/change-port/exposure/disable]: " "status"

  case "${action,,}" in
    status)
      return 0
      ;;
    enable)
      suggested_domain="${DOMAIN}"
      if [[ "$suggested_domain" == www.* ]]; then
        suggested_domain="ws.${suggested_domain#www.}"
      else
        suggested_domain="ws.${suggested_domain}"
      fi
      if [ -n "$reverb_domain" ]; then
        suggested_domain="$reverb_domain"
      fi

      prompt reverb_domain "Reverb domain (e.g. ws.example.com) [${suggested_domain}]: " "${suggested_domain}"
      reverb_domain="$(normalize_domain "$reverb_domain")"
      if ! validate_domain "$reverb_domain"; then
        echo "Invalid domain: ${reverb_domain}"
        exit 1
      fi

      prompt reverb_port "Reverb port inside PHP container [${reverb_port}]: " "${reverb_port}"
      if ! validate_port_number "$reverb_port"; then
        echo "Invalid port: ${reverb_port}"
        exit 1
      fi

      prompt reverb_exposure "Exposure [local/public]: " "${reverb_exposure}"
      case "${reverb_exposure,,}" in
        local|public) reverb_exposure="${reverb_exposure,,}" ;;
        *) echo "Invalid exposure: ${reverb_exposure}"; exit 1 ;;
      esac

      prompt cert_email "Email for Let's Encrypt: "
      if [ -z "$cert_email" ]; then
        echo "Email is required."
        exit 1
      fi

      ensure_proxy_stack

      if ! issue_reverb_certificate "$reverb_domain" "$cert_email"; then
        exit 1
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$reverb_port" "$reverb_exposure"
      write_proxy_config_https "$PROJECT_NAME" "$DOMAIN"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      dc -f "$PROXY_COMPOSE" restart reverse-proxy

      echo ""
      echo "Reverb enabled: https://${reverb_domain}"
      echo "Exposure: ${reverb_exposure}"
      echo "Update your Laravel app if needed:"
      echo "  composer require laravel/reverb"
      echo "  php artisan reverb:install"
      echo "  REVERB_SERVER_HOST=0.0.0.0"
      echo "  REVERB_SERVER_PORT=${reverb_port}"
      ;;
    change-domain)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is not enabled."
        exit 1
      fi

      prompt new_reverb_domain "New Reverb domain [${reverb_domain}]: " "${reverb_domain}"
      new_reverb_domain="$(normalize_domain "$new_reverb_domain")"
      if ! validate_domain "$new_reverb_domain"; then
        echo "Invalid domain: ${new_reverb_domain}"
        exit 1
      fi

      if [ "$new_reverb_domain" = "$reverb_domain" ]; then
        echo "No changes detected."
        exit 0
      fi

      prompt cert_email "Email for Let's Encrypt: "
      if [ -z "$cert_email" ]; then
        echo "Email is required."
        exit 1
      fi

      ensure_proxy_stack
      if ! issue_reverb_certificate "$new_reverb_domain" "$cert_email"; then
        exit 1
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$new_reverb_domain" "$reverb_port" "$reverb_exposure"
      write_proxy_config_https "$PROJECT_NAME" "$DOMAIN"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$new_reverb_domain" "$reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      dc -f "$PROXY_COMPOSE" restart reverse-proxy

      prompt remove_old "Remove old certificate files for ${reverb_domain}? (yes/no): " "no"
      if [ "${remove_old,,}" = "yes" ]; then
        rm -rf "${PROXY_CERTBOT_CONF}/live/${reverb_domain}" || true
        rm -rf "${PROXY_CERTBOT_CONF}/archive/${reverb_domain}" || true
        rm -rf "${PROXY_CERTBOT_CONF}/renewal/${reverb_domain}.conf" || true
        echo "Old certificate files removed."
      fi

      echo "Reverb domain updated: https://${new_reverb_domain}"
      ;;
    change-port)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is not enabled."
        exit 1
      fi

      prompt new_reverb_port "New Reverb port [${reverb_port}]: " "${reverb_port}"
      if ! validate_port_number "$new_reverb_port"; then
        echo "Invalid port: ${new_reverb_port}"
        exit 1
      fi

      if [ "$new_reverb_port" = "$reverb_port" ]; then
        echo "No changes detected."
        exit 0
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$new_reverb_port" "$reverb_exposure"
      write_proxy_config_https "$PROJECT_NAME" "$DOMAIN"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$new_reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      dc -f "$PROXY_COMPOSE" restart reverse-proxy

      echo "Reverb port updated to ${new_reverb_port}."
      ;;
    exposure)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is not enabled."
        exit 1
      fi

      prompt new_reverb_exposure "Exposure [local/public]: " "${reverb_exposure}"
      case "${new_reverb_exposure,,}" in
        local|public) new_reverb_exposure="${new_reverb_exposure,,}" ;;
        *) echo "Invalid exposure: ${new_reverb_exposure}"; exit 1 ;;
      esac

      if [ "$new_reverb_exposure" = "$reverb_exposure" ]; then
        echo "No changes detected."
        exit 0
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$reverb_port" "$new_reverb_exposure"
      write_proxy_config_https "$PROJECT_NAME" "$DOMAIN"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$new_reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      dc -f "$PROXY_COMPOSE" restart reverse-proxy

      echo "Reverb exposure updated: ${new_reverb_exposure}."
      ;;
    disable)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is already disabled."
        exit 0
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "no" "" "${reverb_port}" "${reverb_exposure}"
      remove_reverb_proxy_config "$PROJECT_NAME"

      cd "$app_dir"
      dc up -d --build php
      dc -f "$PROXY_COMPOSE" restart reverse-proxy

      if [ -n "$reverb_domain" ]; then
        prompt remove_old "Remove old certificate files for ${reverb_domain}? (yes/no): " "no"
        if [ "${remove_old,,}" = "yes" ]; then
          rm -rf "${PROXY_CERTBOT_CONF}/live/${reverb_domain}" || true
          rm -rf "${PROXY_CERTBOT_CONF}/archive/${reverb_domain}" || true
          rm -rf "${PROXY_CERTBOT_CONF}/renewal/${reverb_domain}.conf" || true
          echo "Old certificate files removed."
        fi
      fi

      echo "Reverb disabled."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

menu() {
  echo ""
  echo "Select an option:"
  echo "1) Create new project"
  echo "2) Delete existing project"
  echo "3) List projects"
  echo "4) Manual project backup"
  echo "5) Restore project from backup"
  echo "6) Update project"
  echo "7) Run backup for all projects now"
  echo "8) Manage phpMyAdmin"
  echo "9) Change project domain"
  echo "10) Setup email server (docker-mailserver)"
  echo "11) Setup webmail (Roundcube)"
  echo "12) Manage email domains/mailboxes"
  echo "13) Modify webmail (Roundcube)"
  echo "14) Manage Reverb"
  echo ""
  read -r -p "Option: " action

  case "$action" in
    1) create_project ;;
    2) delete_project ;;
    3) list_projects ;;
    4) backup_project ;;
    5) restore_project ;;
    6) update_project ;;
    7) backup_all ;;
    8) phpmyadmin_manage ;;
    9) change_project_domain ;;
    10) setup_mailserver ;;
    11) setup_webmail_roundcube ;;
    12) manage_mailserver ;;
    13) modify_webmail_roundcube ;;
    14) manage_reverb ;;
    *) echo "Invalid option."; exit 1 ;;
  esac
}

require_root

if [ "${1:-}" = "backup-all" ]; then
  backup_all
  exit 0
fi

if [ "${1:-}" = "setup-cron" ]; then
  ensure_cron_jobs
  echo "Cron jobs installed/updated."
  exit 0
fi

banner
menu
