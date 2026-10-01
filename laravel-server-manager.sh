#!/bin/bash

set -euo pipefail

PROXY_BASE="/opt/laravel-reverse-proxy"
PROXY_CONF_DIR="${PROXY_BASE}/nginx/conf.d"
PROXY_DEFAULT_DENY_CONF="${PROXY_CONF_DIR}/00-default-deny.conf"
PROXY_CERTBOT_CONF="${PROXY_BASE}/certbot/conf"
PROXY_CERTBOT_WWW="${PROXY_BASE}/certbot/www"
PROXY_PROJECTS_DIR="${PROXY_BASE}/projects"
PROJECTS_BASE="/var/www/projects"
BACKUPS_BASE="/var/backups/laravel-projects"
MANAGER_ETC_DIR="/etc/laravel-manager"
BACKUP_STATE_DIR="/var/lib/laravel-manager/backup-state"
DOCKER_PMA_FIREWALL_RULES_FILE="${MANAGER_ETC_DIR}/docker-pma-firewall.rules"
DOCKER_PMA_FIREWALL_APPLY_SCRIPT="/usr/local/sbin/laravel-manager-apply-docker-pma-firewall"
DOCKER_PMA_FIREWALL_SERVICE_FILE="/etc/systemd/system/laravel-manager-docker-pma-firewall.service"
DOCKER_PMA_FIREWALL_CHAIN="LARAVEL-PMA-FW"
DEFAULT_BACKUP_RETENTION_DAYS="14"
DEFAULT_BACKUP_INTERVAL_HOURS="24"
SHARED_NETWORK="laravel-shared"
PROXY_COMPOSE="${PROXY_BASE}/docker-compose.yml"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
AI_PLATFORM_BASE="/opt/vllm-ai-platform"
AI_PLATFORM_COMPOSE="${AI_PLATFORM_BASE}/compose.yaml"
AI_PLATFORM_ENV="${AI_PLATFORM_BASE}/.env"
AI_PLATFORM_META="${AI_PLATFORM_BASE}/.ai-platform-meta"
AI_PLATFORM_ASSETS="${SCRIPT_DIR}/ai-platform"
AI_PLATFORM_SHARE="/usr/local/share/laravel-server-manager/ai-platform"
AI_INTERNAL_NETWORK="vllm-ai-internal"
AI_EGRESS_NETWORK="vllm-ai-egress"
AI_DEFAULT_VLLM_VERSION="v0.30.0"
AI_DEFAULT_VLLM_IMAGE="vllm/vllm-openai:${AI_DEFAULT_VLLM_VERSION}"
AI_DEFAULT_NATIVE_VLLM_VERSION="${AI_DEFAULT_VLLM_VERSION#v}"
AI_SCHEMA_VERSION="2"
AI_BACKUPS_BASE="/var/backups/vllm-ai-platform"
AI_PROXY_CONFIG="${PROXY_CONF_DIR}/vllm-ai-platform.conf"
AI_ENVIRONMENT_SNAPSHOT="${AI_PLATFORM_BASE}/hardware/environment.json"
AI_NOTEBOOKS_BASE="${AI_PLATFORM_BASE}/notebooks"
AI_NATIVE_BASE="${AI_PLATFORM_BASE}/native"
AI_NATIVE_PLATFORM_VENV="${AI_NATIVE_BASE}/platform-venv"
AI_NATIVE_VLLM_VENV="${AI_NATIVE_BASE}/vllm-venv"
AI_NATIVE_SERVICE_USER="vllmai"
AI_CLOUDFLARED_TOKEN_FILE="${AI_PLATFORM_BASE}/secrets/cloudflare_tunnel_token"
AI_EXTERNAL_ACCESS_META="${AI_NATIVE_BASE}/external-access.env"
MAIL_BASE="/opt/mailserver"
MAIL_COMPOSE="${MAIL_BASE}/compose.yaml"
MAIL_ENV_FILE="${MAIL_BASE}/mailserver.env"
MAIL_FAIL2BAN_JAIL_FILE="${MAIL_BASE}/docker-data/dms/config/fail2ban-jail.cf"
MAIL_VIRTUAL_FILE="${MAIL_BASE}/docker-data/dms/config/postfix-virtual.cf"
WEBMAIL_BASE="/opt/webmail-roundcube"
WEBMAIL_COMPOSE="${WEBMAIL_BASE}/compose.yaml"
WEBMAIL_META_FILE="${WEBMAIL_BASE}/.webmail-meta"
WEBMAIL_PASSWORD_HELPER_DIR="${WEBMAIL_BASE}/password-helper"
WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR="${WEBMAIL_BASE}/force-password-change-plugin"
WEBMAIL_PASSWORD_CONFIG_FILE="${WEBMAIL_BASE}/data/config/password-change.inc.php"
WEBMAIL_PASSWORD_FORCE_STATE_FILE="${WEBMAIL_BASE}/data/config/force-password-change-users.txt"
WEBMAIL_PASSWORD_TOKEN_FILE="${WEBMAIL_BASE}/.password-helper-token"
WEBMAIL_PASSWORD_HELPER_CONTAINER="roundcube-password-helper"
WEBMAIL_MANAGESIEVE_CONFIG_FILE="${WEBMAIL_BASE}/data/config/managesieve.inc.php"
GUACAMOLE_BASE="/opt/apache-guacamole"
GUACAMOLE_COMPOSE="${GUACAMOLE_BASE}/compose.yaml"
GUACAMOLE_META_FILE="${GUACAMOLE_BASE}/.guacamole-meta"
GUACAMOLE_DEFAULT_UPSTREAM="guacamole-web:8080"
GUACAMOLE_DEFAULT_VERSION="1.6.0"
GUACAMOLE_WEB_CONTAINER_NAME="guacamole-web"
GUACAMOLE_GUACD_CONTAINER_NAME="guacd"
VNC_BASE="/opt/managed-vnc-server"
VNC_META_FILE="${VNC_BASE}/.vnc-meta"
VNC_SERVICE_NAME="servicedesk-vnc"
VNC_DEFAULT_USER="servicedesk-vnc"
VNC_DEFAULT_DISPLAY="1"
VNC_DEFAULT_GEOMETRY="1366x768"
VNC_DEFAULT_DEPTH="24"
PMA_UPLOAD_LIMIT="5G"
PMA_MEMORY_LIMIT="1G"
PMA_MAX_EXECUTION_TIME="0"
MARIADB_MAX_ALLOWED_PACKET="1G"
MARIADB_NET_READ_TIMEOUT="600"
MARIADB_NET_WRITE_TIMEOUT="600"
DEFAULT_LARAVEL_QUEUE_CONNECTION="redis"
DEFAULT_LARAVEL_QUEUE_NAMES="default"
DEFAULT_LARAVEL_QUEUE_SLEEP="1"
DEFAULT_LARAVEL_QUEUE_TRIES="5"
DEFAULT_LARAVEL_QUEUE_TIMEOUT="120"
DEFAULT_LARAVEL_QUEUE_MAX_TIME="3600"

# Values loaded from "${app_dir}/.project-meta" (declared to keep shellcheck happy)
PROJECT_NAME=""
DOMAIN=""
PROJECT_DOMAINS=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_ROOT_PASSWORD=""
PHP_CONTAINER=""
NODE_CONTAINER=""
DB_CONTAINER=""
REDIS_CONTAINER=""
APP_DIR=""
PMA_PORT=""
PMA_BIND_IP=""
REVERB_ENABLED=""
REVERB_DOMAIN=""
REVERB_PORT=""
REVERB_EXPOSURE=""
GUACAMOLE_PROXY_ENABLED=""
GUACAMOLE_PROXY_UPSTREAM=""
GUACAMOLE_STACK_VERSION=""
GUACAMOLE_JSON_SECRET_KEY=""
APP_PROFILE=""
BACKUP_RETENTION_DAYS=""
BACKUP_INTERVAL_HOURS=""
BACKUP_CLOUD_ENABLED=""
BACKUP_CLOUD_SCOPE=""
BACKUP_CLOUD_RETENTION_ENABLED=""
BACKUP_CLOUD_PROVIDER=""
BACKUP_CLOUD_REMOTE=""
BACKUP_CLOUD_FOLDER=""
UFW_PMA_ALLOWED_SOURCES=""
UFW_PMA_RESTRICTED=""
UFW_PMA_PORT=""
PROJECT_ACCESS_ALLOWED_SOURCES=""
PROJECT_ACCESS_RESTRICTED=""
LARAVEL_QUEUE_CONNECTION=""
LARAVEL_QUEUE_NAMES=""
LARAVEL_QUEUE_SLEEP=""
LARAVEL_QUEUE_TRIES=""
LARAVEL_QUEUE_TIMEOUT=""
LARAVEL_QUEUE_MAX_TIME=""
SERVER_RAM_MB=""
SERVER_CPU_CORES=""
SERVER_CAPACITY_PROFILE=""
PROJECT_TUNING_MODE=""
PROJECT_TUNING_PRESET=""
RAM_MB=""
CPU_CORES=""
PROFILE_NAME=""
PHP_FPM_CHILDREN=""
PHP_FPM_START_SERVERS=""
PHP_FPM_MIN_SPARE_SERVERS=""
PHP_FPM_MAX_SPARE_SERVERS=""
OPCACHE_MEMORY=""
REDIS_MEMORY=""
MYSQL_BUFFER=""
MYSQL_MAX_CONNECTIONS=""

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

docker_container_running() {
  local container_name="${1:-}"
  [ -n "$container_name" ] || return 1
  docker_container_exists "$container_name" || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo false)" = "true" ]
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

validate_backup_retention_days() {
  local days="${1:-}"
  [[ "$days" =~ ^[0-9]+$ ]] || return 1
  [ "$days" -ge 1 ] && [ "$days" -le 3650 ]
}

validate_backup_interval_hours() {
  local hours="${1:-}"
  [[ "$hours" =~ ^[0-9]+$ ]] || return 1
  [ "$hours" -ge 1 ] && [ "$hours" -le 24 ]
}

trim_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_positive_integer() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

normalize_queue_connection() {
  local value
  value="$(trim_whitespace "${1:-}")"
  [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  echo "$value"
}

normalize_queue_names_csv() {
  local input="${1:-}"
  local part queue result=""
  local -A seen=()
  local -a parts=()

  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    queue="$(trim_whitespace "$part")"
    [ -n "$queue" ] || continue
    [[ "$queue" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ -z "${seen[$queue]+x}" ]; then
      seen[$queue]=1
      result="${result:+${result},}${queue}"
    fi
  done

  [ -n "$result" ] || return 1
  echo "$result"
}

validate_ipv4_cidr() {
  local value="${1:-}"
  local ip="${value%/*}"
  local cidr=""
  local octet
  local -a octets=()

  if [[ "$value" == */* ]]; then
    cidr="${value#*/}"
    [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
    [ "$cidr" -ge 0 ] && [ "$cidr" -le 32 ] || return 1
  fi

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_ipv6_cidr() {
  local value="${1:-}"
  local ip="${value%/*}"
  local cidr=""

  if [[ "$value" != *:* ]]; then
    return 1
  fi

  if [[ "$value" == */* ]]; then
    cidr="${value#*/}"
    [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
    [ "$cidr" -ge 0 ] && [ "$cidr" -le 128 ] || return 1
  fi

  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

detect_server_ip() {
  local candidate=""

  # Allow an explicit value for hosts whose public IP is provided through NAT.
  candidate="$(trim_whitespace "${SERVER_IP:-}")"
  if [ -n "$candidate" ] && validate_ipv4_cidr "$candidate" && [[ "$candidate" != */* ]]; then
    echo "$candidate"
    return 0
  fi

  # An external lookup returns the address clients actually use to reach the server.
  if command -v curl >/dev/null 2>&1; then
    candidate="$(curl -4fsS --connect-timeout 2 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    candidate="$(trim_whitespace "$candidate")"
    if validate_ipv4_cidr "$candidate" && [[ "$candidate" != */* ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  # Fall back to the IPv4 address on the default route when Internet lookup fails.
  if command -v ip >/dev/null 2>&1; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    candidate="$(trim_whitespace "$candidate")"
    if validate_ipv4_cidr "$candidate" && [[ "$candidate" != */* ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  echo "YOUR_SERVER_IP"
}

validate_ufw_source() {
  local source="${1:-}"
  [ -n "$source" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$source" <<'PY'
import ipaddress
import sys

value = sys.argv[1]
try:
    if "/" in value:
        ipaddress.ip_network(value, strict=False)
    else:
        ipaddress.ip_address(value)
except ValueError:
    sys.exit(1)
PY
    return $?
  fi

  validate_ipv4_cidr "$source"
}

normalize_ufw_sources_csv() {
  local input="${1:-}"
  local part source result=""
  local -A seen=()
  local -a parts=()

  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    source="$(trim_whitespace "$part")"
    [ -n "$source" ] || continue
    if ! validate_ufw_source "$source"; then
      return 1
    fi
    if [ -z "${seen[$source]+x}" ]; then
      seen[$source]=1
      result="${result:+${result},}${source}"
    fi
  done

  [ -n "$result" ] || return 1
  echo "$result"
}

read_project_backup_retention_days() {
  local app_dir="$1"
  local meta_file="${app_dir}/.project-meta"
  local configured_days=""

  if [ -f "$meta_file" ]; then
    configured_days="$(
      BACKUP_RETENTION_DAYS=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${BACKUP_RETENTION_DAYS:-}"
    )"
  fi

  if validate_backup_retention_days "$configured_days"; then
    echo "$configured_days"
  else
    echo "$DEFAULT_BACKUP_RETENTION_DAYS"
  fi
}

read_project_backup_interval_hours() {
  local app_dir="$1"
  local configured_hours
  configured_hours="$(read_project_meta_var "$app_dir" "BACKUP_INTERVAL_HOURS")"

  if validate_backup_interval_hours "$configured_hours"; then
    echo "$configured_hours"
  else
    echo "$DEFAULT_BACKUP_INTERVAL_HOURS"
  fi
}

read_project_backup_cloud_enabled() {
  local app_dir="$1"
  local enabled
  enabled="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_ENABLED")"

  if [ "${enabled,,}" = "yes" ]; then
    echo "yes"
  else
    echo "no"
  fi
}

read_project_backup_cloud_scope() {
  local app_dir="$1"
  local scope
  scope="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_SCOPE")"

  case "${scope,,}" in
    manual|automatic|both) echo "${scope,,}" ;;
    *) echo "automatic" ;;
  esac
}

read_project_backup_cloud_retention_enabled() {
  local app_dir="$1"
  local enabled
  enabled="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_RETENTION_ENABLED")"

  # Cloud retention was always enabled before this setting existed, so an
  # unset value preserves the behavior of existing projects.
  case "${enabled,,}" in
    no) echo "no" ;;
    *) echo "yes" ;;
  esac
}

should_replicate_backup_to_cloud() {
  local app_dir="$1"
  local backup_kind="$2"
  local enabled scope

  enabled="$(read_project_backup_cloud_enabled "$app_dir")"
  [ "$enabled" = "yes" ] || return 1
  scope="$(read_project_backup_cloud_scope "$app_dir")"

  case "${backup_kind}:${scope}" in
    manual:manual|manual:both|auto:automatic|auto:both) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_backup_cloud_folder() {
  local folder
  folder="$(trim_whitespace "${1:-}")"
  folder="${folder#/}"
  folder="${folder%/}"
  printf '%s' "$folder"
}

prune_project_backups() {
  local project_name="$1"
  local retention_days="$2"
  local backup_dir="${BACKUPS_BASE}/${project_name}"

  if ! validate_backup_retention_days "$retention_days"; then
    retention_days="$DEFAULT_BACKUP_RETENTION_DAYS"
  fi

  [ -d "$backup_dir" ] || return 0
  find "$backup_dir" -type f -name "*.tar.gz" -mtime +"$retention_days" -delete || true
}

read_project_ufw_pma_allowed_sources() {
  local app_dir="$1"
  local meta_file="${app_dir}/.project-meta"
  local configured_sources=""

  if [ -f "$meta_file" ]; then
    configured_sources="$(
      UFW_PMA_ALLOWED_SOURCES=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${UFW_PMA_ALLOWED_SOURCES:-}"
    )"
  fi

  normalize_ufw_sources_csv "$configured_sources" 2>/dev/null || true
}

read_project_ufw_pma_restricted() {
  local app_dir="$1"
  local meta_file="${app_dir}/.project-meta"
  local restricted=""

  if [ -f "$meta_file" ]; then
    restricted="$(
      UFW_PMA_RESTRICTED=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${UFW_PMA_RESTRICTED:-}"
    )"
  fi

  if [ "${restricted,,}" = "yes" ]; then
    echo "yes"
  else
    echo "no"
  fi
}

read_project_ufw_pma_port() {
  local app_dir="$1"
  local fallback_port="${2:-}"
  local meta_file="${app_dir}/.project-meta"
  local saved_port=""

  if [ -f "$meta_file" ]; then
    saved_port="$(
      UFW_PMA_PORT=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${UFW_PMA_PORT:-}"
    )"
  fi

  if validate_port_number "$saved_port"; then
    echo "$saved_port"
  elif validate_port_number "$fallback_port"; then
    echo "$fallback_port"
  fi
}

read_project_access_allowed_sources() {
  local app_dir="$1"
  local meta_file="${app_dir}/.project-meta"
  local configured_sources=""

  if [ -f "$meta_file" ]; then
    configured_sources="$(
      PROJECT_ACCESS_ALLOWED_SOURCES=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${PROJECT_ACCESS_ALLOWED_SOURCES:-}"
    )"
  fi

  normalize_ufw_sources_csv "$configured_sources" 2>/dev/null || true
}

read_project_access_restricted() {
  local app_dir="$1"
  local meta_file="${app_dir}/.project-meta"
  local restricted=""

  if [ -f "$meta_file" ]; then
    restricted="$(
      PROJECT_ACCESS_RESTRICTED=""
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${PROJECT_ACCESS_RESTRICTED:-}"
    )"
  fi

  if [ "${restricted,,}" = "yes" ]; then
    echo "yes"
  else
    echo "no"
  fi
}

read_project_meta_var() {
  local app_dir="$1"
  local key="$2"
  local meta_file="${app_dir}/.project-meta"

  if [ -f "$meta_file" ]; then
    (
      set +u
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || true
      printf '%s' "${!key:-}"
    )
  fi
}

detect_laravel_queue_names() {
  local app_dir="$1"
  local grep_paths=()

  for path in app bootstrap config database routes; do
    [ -e "${app_dir}/${path}" ] && grep_paths+=("${app_dir}/${path}")
  done

  if [ "${#grep_paths[@]}" -gt 0 ] \
    && grep -R -E "onQueue\\([\"']webhooks[\"']|--queue=webhooks|queue:?webhooks|webhooks,default" "${grep_paths[@]}" >/dev/null 2>&1; then
    echo "webhooks,default"
  else
    echo "$DEFAULT_LARAVEL_QUEUE_NAMES"
  fi
}

read_project_laravel_queue_connection() {
  local app_dir="$1"
  local configured
  configured="$(read_project_meta_var "$app_dir" "LARAVEL_QUEUE_CONNECTION")"

  normalize_queue_connection "$configured" 2>/dev/null || echo "$DEFAULT_LARAVEL_QUEUE_CONNECTION"
}

read_project_laravel_queue_names() {
  local app_dir="$1"
  local configured detected
  configured="$(read_project_meta_var "$app_dir" "LARAVEL_QUEUE_NAMES")"

  if normalize_queue_names_csv "$configured" 2>/dev/null; then
    return 0
  fi

  detected="$(detect_laravel_queue_names "$app_dir")"
  normalize_queue_names_csv "$detected" 2>/dev/null || echo "$DEFAULT_LARAVEL_QUEUE_NAMES"
}

read_project_laravel_queue_integer() {
  local app_dir="$1"
  local key="$2"
  local fallback="$3"
  local configured
  configured="$(read_project_meta_var "$app_dir" "$key")"

  if validate_positive_integer "$configured"; then
    echo "$configured"
  else
    echo "$fallback"
  fi
}

build_nginx_access_block() {
  local allowed_sources="${1:-}"
  local restricted="${2:-no}"
  local indent="${3:-        }"
  local normalized_sources source
  local -a sources=()

  [ "$restricted" = "yes" ] || return 0
  normalized_sources="$(normalize_ufw_sources_csv "$allowed_sources" 2>/dev/null)" || return 0

  IFS=',' read -r -a sources <<< "$normalized_sources"
  for source in "${sources[@]}"; do
    source="$(trim_whitespace "$source")"
    [ -n "$source" ] || continue
    printf '%sallow %s;\n' "$indent" "$source"
  done
  printf '%sdeny all;\n' "$indent"
}

ensure_ufw_available() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing UFW..."
  apt-get update -y
  apt-get install -y ufw

  if ! command -v ufw >/dev/null 2>&1; then
    echo "Failed to install UFW."
    return 1
  fi
}

write_docker_pma_firewall_apply_script() {
  mkdir -p "$(dirname "$DOCKER_PMA_FIREWALL_APPLY_SCRIPT")"

  cat > "$DOCKER_PMA_FIREWALL_APPLY_SCRIPT" <<EOF
#!/bin/sh
set -eu

RULES_FILE="${DOCKER_PMA_FIREWALL_RULES_FILE}"
CHAIN="${DOCKER_PMA_FIREWALL_CHAIN}"

if ! command -v iptables >/dev/null 2>&1; then
  exit 0
fi

IPTABLES="iptables"
if iptables -w -L >/dev/null 2>&1; then
  IPTABLES="iptables -w"
fi

\$IPTABLES -N DOCKER-USER 2>/dev/null || true
\$IPTABLES -N "\$CHAIN" 2>/dev/null || true
\$IPTABLES -F "\$CHAIN"
\$IPTABLES -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || \$IPTABLES -I FORWARD 1 -j DOCKER-USER
\$IPTABLES -C DOCKER-USER -j "\$CHAIN" >/dev/null 2>&1 || \$IPTABLES -I DOCKER-USER 1 -j "\$CHAIN"

CTDIR_ARGS=""
if iptables -m conntrack -h 2>&1 | grep -q -- '--ctdir'; then
  CTDIR_ARGS="--ctdir ORIGINAL"
fi

\$IPTABLES -A "\$CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

if [ -f "\$RULES_FILE" ]; then
  while IFS='|' read -r project port sources; do
    case "\$project" in
      ""|"#"*) continue ;;
    esac
    case "\$port" in
      ""|*[!0-9]*) continue ;;
    esac
    [ "\$port" -ge 1 ] && [ "\$port" -le 65535 ] || continue

    old_ifs="\$IFS"
    IFS=','
    set -- \$sources
    IFS="\$old_ifs"

    for source do
      [ -n "\$source" ] || continue
      case "\$source" in
        *:*) continue ;;
      esac
      # Docker DNAT changes the visible destination port. conntrack keeps the original host port.
      \$IPTABLES -A "\$CHAIN" -p tcp -s "\$source" -m conntrack \$CTDIR_ARGS --ctorigdstport "\$port" -j RETURN
    done

    \$IPTABLES -A "\$CHAIN" -p tcp -m conntrack \$CTDIR_ARGS --ctorigdstport "\$port" -j DROP
  done < "\$RULES_FILE"
fi

\$IPTABLES -A "\$CHAIN" -j RETURN
EOF

  chmod 700 "$DOCKER_PMA_FIREWALL_APPLY_SCRIPT"
}

write_docker_pma_firewall_service() {
  cat > "$DOCKER_PMA_FIREWALL_SERVICE_FILE" <<EOF
[Unit]
Description=Laravel Manager Docker phpMyAdmin firewall
After=docker.service ufw.service
Wants=docker.service ufw.service

[Service]
Type=oneshot
ExecStart=${DOCKER_PMA_FIREWALL_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

ensure_docker_pma_firewall_assets() {
  mkdir -p "$MANAGER_ETC_DIR"
  write_docker_pma_firewall_apply_script

  if command -v systemctl >/dev/null 2>&1; then
    write_docker_pma_firewall_service
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$(basename "$DOCKER_PMA_FIREWALL_SERVICE_FILE")" >/dev/null 2>&1 || true
  fi
}

sync_docker_pma_firewall_rules() {
  local tmp meta_file

  ensure_docker_pma_firewall_assets
  tmp="$(mktemp "${DOCKER_PMA_FIREWALL_RULES_FILE}.tmp.XXXXXX")"

  {
    echo "# Managed by laravel-server-manager. Do not edit by hand."
    echo "# Format: project|host_port|allowed_sources_csv"
    for meta_file in "$PROJECTS_BASE"/*/.project-meta; do
      [ -f "$meta_file" ] || continue
      (
        PROJECT_NAME=""
        PMA_PORT=""
        UFW_PMA_ALLOWED_SOURCES=""
        UFW_PMA_RESTRICTED=""
        UFW_PMA_PORT=""
        # shellcheck disable=SC1090
        # shellcheck disable=SC1091
        source "$meta_file" >/dev/null 2>&1 || exit 0

        project_name="${PROJECT_NAME:-$(basename "$(dirname "$meta_file")")}"
        pma_port="${UFW_PMA_PORT:-${PMA_PORT:-}}"
        if [ "${UFW_PMA_RESTRICTED:-no}" != "yes" ]; then
          exit 0
        fi
        validate_port_number "$pma_port" || exit 0
        if [ -n "${UFW_PMA_ALLOWED_SOURCES:-}" ]; then
          normalized_sources="$(normalize_ufw_sources_csv "$UFW_PMA_ALLOWED_SOURCES" 2>/dev/null)" || normalized_sources=""
        else
          normalized_sources=""
        fi

        printf '%s|%s|%s\n' "$project_name" "$pma_port" "$normalized_sources"
      )
    done
  } > "$tmp"

  install -m 600 "$tmp" "$DOCKER_PMA_FIREWALL_RULES_FILE"
  rm -f "$tmp"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$(basename "$DOCKER_PMA_FIREWALL_SERVICE_FILE")" >/dev/null 2>&1 || "$DOCKER_PMA_FIREWALL_APPLY_SCRIPT"
  elif ! "$DOCKER_PMA_FIREWALL_APPLY_SCRIPT"; then
    echo "Warning: failed to apply Docker phpMyAdmin firewall rules."
    return 1
  fi
}

show_matching_docker_pma_rules() {
  local port="$1"

  if ! command -v iptables >/dev/null 2>&1; then
    echo "  iptables not found."
    return 0
  fi

  if ! iptables -S "$DOCKER_PMA_FIREWALL_CHAIN" >/dev/null 2>&1; then
    echo "  Docker phpMyAdmin firewall chain not installed."
    return 0
  fi

  if ! iptables -S "$DOCKER_PMA_FIREWALL_CHAIN" 2>/dev/null | grep -E -- "--ctorigdstport ${port}([[:space:]]|$)"; then
    echo "  No matching Docker phpMyAdmin rules found."
  fi
}

apply_ufw_allow_source_port_tcp() {
  local source="$1"
  local port="$2"
  local rule_comment="$3"

  ufw allow from "$source" to any port "$port" proto tcp comment "$rule_comment" >/dev/null 2>&1 && return 0
  ufw allow from "$source" to any port "$port" proto tcp >/dev/null 2>&1 && return 0
  ufw allow proto tcp from "$source" to any port "$port" >/dev/null 2>&1 && return 0

  ufw allow from "$source" to any port "$port"
}

apply_ufw_deny_port_tcp() {
  local port="$1"
  local rule_comment="$2"

  ufw deny "${port}/tcp" comment "$rule_comment" >/dev/null 2>&1 && return 0
  ufw deny "${port}/tcp" >/dev/null 2>&1 && return 0
  ufw deny to any port "$port" proto tcp >/dev/null 2>&1 && return 0

  ufw deny "$port"
}

apply_ufw_allow_port_tcp() {
  local port="$1"
  local rule_comment="$2"

  if ! validate_port_number "$port"; then
    return 1
  fi

  ufw allow "${port}/tcp" comment "$rule_comment" >/dev/null 2>&1 && return 0
  ufw allow "${port}/tcp" >/dev/null 2>&1 && return 0

  ufw allow "$port"
}

detect_current_ssh_port() {
  local ssh_port=""

  if [ -n "${SSH_CONNECTION:-}" ]; then
    ssh_port="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
    if validate_port_number "$ssh_port"; then
      echo "$ssh_port"
      return 0
    fi
  fi

  echo "22"
}

ufw_is_inactive() {
  [ "$(ufw status 2>/dev/null | head -n 1 || true)" = "Status: inactive" ]
}

enable_ufw_if_inactive() {
  local ssh_port

  if ! ufw_is_inactive; then
    return 0
  fi

  ssh_port="$(detect_current_ssh_port)"

  echo "UFW is inactive. Allowing SSH and shared web ports before enabling it..."
  apply_ufw_allow_port_tcp "$ssh_port" "laravel-manager:ssh"
  if [ "$ssh_port" != "22" ]; then
    apply_ufw_allow_port_tcp "22" "laravel-manager:ssh"
  fi
  apply_ufw_allow_port_tcp "80" "laravel-manager:http"
  apply_ufw_allow_port_tcp "443" "laravel-manager:https"

  printf 'y\n' | ufw enable
}

show_matching_ufw_pma_rules() {
  local port="$1"
  local pattern
  local matched="no"

  pattern="(${port}/tcp|port[[:space:]]+${port}|[[:space:]]${port}[[:space:]])"

  if ufw status numbered 2>/dev/null | grep -E "$pattern"; then
    matched="yes"
  fi

  if [ "$matched" != "yes" ] && ufw_is_inactive; then
    if ufw show added 2>/dev/null | grep -E "$pattern"; then
      matched="yes"
    fi
  fi

  if [ "$matched" != "yes" ]; then
    echo "  No matching rules found."
  fi
}

delete_ufw_pma_rules() {
  local port="$1"
  local allowed_sources="${2:-}"
  local restricted="${3:-no}"
  local source
  local -a sources=()

  validate_port_number "$port" || return 0

  if [ -n "$allowed_sources" ]; then
    IFS=',' read -r -a sources <<< "$allowed_sources"
    for source in "${sources[@]}"; do
      source="$(trim_whitespace "$source")"
      [ -n "$source" ] || continue
      printf 'y\n' | ufw delete allow from "$source" to any port "$port" proto tcp >/dev/null 2>&1 || true
      printf 'y\n' | ufw delete allow proto tcp from "$source" to any port "$port" >/dev/null 2>&1 || true
      printf 'y\n' | ufw delete allow from "$source" to any port "$port" >/dev/null 2>&1 || true
    done
  fi

  if [ "$restricted" = "yes" ]; then
    printf 'y\n' | ufw delete deny "${port}/tcp" >/dev/null 2>&1 || true
    printf 'y\n' | ufw delete deny to any port "$port" proto tcp >/dev/null 2>&1 || true
    printf 'y\n' | ufw delete deny proto tcp from any to any port "$port" >/dev/null 2>&1 || true
    printf 'y\n' | ufw delete deny "$port" >/dev/null 2>&1 || true
  fi
}

apply_ufw_pma_rules() {
  local project_name="$1"
  local new_port="$2"
  local old_port="$3"
  local old_sources="$4"
  local new_sources="$5"
  local was_restricted="$6"
  local source
  local allow_comment="laravel-manager:${project_name}:phpmyadmin"
  local deny_comment="laravel-manager:${project_name}:phpmyadmin-deny"
  local -a sources=()

  if ! validate_port_number "$new_port"; then
    echo "Invalid phpMyAdmin port for UFW: ${new_port}"
    return 1
  fi

  delete_ufw_pma_rules "$old_port" "$old_sources" "$was_restricted"

  IFS=',' read -r -a sources <<< "$new_sources"
  for source in "${sources[@]}"; do
    source="$(trim_whitespace "$source")"
    [ -n "$source" ] || continue
    apply_ufw_allow_source_port_tcp "$source" "$new_port" "$allow_comment"
  done

  apply_ufw_deny_port_tcp "$new_port" "$deny_comment"
}

sql_escape_literal() {
  printf '%s' "${1:-}" | sed "s/'/''/g"
}

sql_escape_identifier() {
  printf '%s' "${1:-}" | sed 's/`/``/g'
}

wait_for_mariadb_root() {
  local db_container="$1"
  local root_password="$2"
  local attempt

  for attempt in $(seq 1 30); do
    if docker exec -e MYSQL_PWD="$root_password" "$db_container" mariadb-admin ping -h localhost -u root >/dev/null 2>&1; then
      return 0
    fi
    if docker exec -e MYSQL_PWD="$root_password" "$db_container" mysqladmin ping -h localhost -u root >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
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

sed_escape_replacement() {
  printf '%s' "${1:-}" | sed 's/[&|]/\\&/g'
}

set_env_file_var() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped

  escaped="$(sed_escape_replacement "$value")"

  if [ ! -f "$env_file" ]; then
    printf '%s=%s\n' "$key" "$value" > "$env_file"
    return 0
  fi

  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$env_file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
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
    return $?
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return $?
  fi

  echo "Docker Compose is not installed."
  exit 1
}

proxy_dc() {
  local previous_dir status
  previous_dir="$(pwd 2>/dev/null || true)"

  if ! cd "$PROXY_BASE"; then
    echo "Reverse proxy directory not found: ${PROXY_BASE}"
    return 1
  fi

  if dc -f "$PROXY_COMPOSE" "$@"; then
    status=0
  else
    status=$?
  fi

  if [ -n "$previous_dir" ] && [ -d "$previous_dir" ]; then
    cd "$previous_dir" || cd /
  else
    cd /
  fi

  return "$status"
}

random_hex_16() {
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

guacamole_saved_secret() {
  [ -f "$GUACAMOLE_META_FILE" ] || return 0
  (
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$GUACAMOLE_META_FILE"
    printf '%s' "${GUACAMOLE_JSON_SECRET_KEY:-}"
  )
}

guacamole_saved_version() {
  [ -f "$GUACAMOLE_META_FILE" ] || return 0
  (
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$GUACAMOLE_META_FILE"
    printf '%s' "${GUACAMOLE_STACK_VERSION:-}"
  )
}

write_guacamole_meta() {
  local guacamole_version="$1"
  local json_secret_key="$2"

  mkdir -p "$GUACAMOLE_BASE"
  {
    printf 'GUACAMOLE_STACK_VERSION=%q\n' "$guacamole_version"
    printf 'GUACAMOLE_JSON_SECRET_KEY=%q\n' "$json_secret_key"
    printf 'GUACAMOLE_STACK_UPSTREAM=%q\n' "$GUACAMOLE_DEFAULT_UPSTREAM"
    printf 'GUACAMOLE_WEB_CONTAINER_NAME=%q\n' "$GUACAMOLE_WEB_CONTAINER_NAME"
    printf 'GUACAMOLE_GUACD_CONTAINER_NAME=%q\n' "$GUACAMOLE_GUACD_CONTAINER_NAME"
  } > "$GUACAMOLE_META_FILE"
}

write_guacamole_compose() {
  local guacamole_version="$1"
  local json_secret_key="$2"

  mkdir -p "$GUACAMOLE_BASE"

  cat > "$GUACAMOLE_COMPOSE" <<EOF
services:
  guacd:
    image: guacamole/guacd:${guacamole_version}
    container_name: ${GUACAMOLE_GUACD_CONTAINER_NAME}
    restart: unless-stopped
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - ${GUACAMOLE_GUACD_CONTAINER_NAME}

  guacamole:
    image: guacamole/guacamole:${guacamole_version}
    container_name: ${GUACAMOLE_WEB_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      GUACD_HOSTNAME: ${GUACAMOLE_GUACD_CONTAINER_NAME}
      JSON_ENABLED: "true"
      JSON_SECRET_KEY: "${json_secret_key}"
      EXTENSION_PRIORITY: "json"
    depends_on:
      - guacd
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - ${GUACAMOLE_WEB_CONTAINER_NAME}

networks:
  ${SHARED_NETWORK}:
    external: true
EOF
}

ensure_managed_guacamole_stack() {
  local guacamole_version="${1:-$GUACAMOLE_DEFAULT_VERSION}"
  local json_secret_key="${2:-}"
  local saved_version saved_secret

  install_base
  ensure_proxy_stack

  saved_version="$(guacamole_saved_version)"
  saved_secret="$(guacamole_saved_secret)"

  if [ -z "$guacamole_version" ]; then
    guacamole_version="${saved_version:-$GUACAMOLE_DEFAULT_VERSION}"
  fi

  if [ -z "$json_secret_key" ]; then
    json_secret_key="${saved_secret:-}"
  fi

  if [ -z "$json_secret_key" ]; then
    json_secret_key="$(random_hex_16)"
  fi

  write_guacamole_compose "$guacamole_version" "$json_secret_key"
  write_guacamole_meta "$guacamole_version" "$json_secret_key"
  dc -f "$GUACAMOLE_COMPOSE" up -d --force-recreate --remove-orphans
}

detect_project_env_path() {
  local app_dir="$1"
  local candidate=""

  if [ -f "${app_dir}/.env" ]; then
    echo "${app_dir}/.env"
    return 0
  fi

  if [ -f "${app_dir}/public/.env" ]; then
    echo "${app_dir}/public/.env"
    return 0
  fi

  if [ -d "${app_dir}/public" ] && command -v find >/dev/null 2>&1; then
    while IFS= read -r -d '' candidate; do
      [ -n "$candidate" ] || continue
      echo "$candidate"
      return 0
    done < <(find "${app_dir}/public" -mindepth 2 -type f -name '.env' -print0 2>/dev/null)
  fi

  return 1
}

sync_project_guacamole_env() {
  local app_dir="$1"
  local domain="$2"
  local json_secret_key="$3"
  local env_file=""

  [ -n "$json_secret_key" ] || return 1
  env_file="$(detect_project_env_path "$app_dir" || true)"
  [ -n "$env_file" ] || return 1

  set_env_file_var "$env_file" "GUACAMOLE_ENABLED" "true"
  set_env_file_var "$env_file" "GUACAMOLE_BASE_URL" "https://${domain}/guacamole"
  set_env_file_var "$env_file" "GUACAMOLE_JSON_SECRET_KEY" "$json_secret_key"
  set_env_file_var "$env_file" "GUACAMOLE_EMBED_ALLOWED" "true"
}

disable_project_guacamole_env() {
  local app_dir="$1"
  local env_file=""

  env_file="$(detect_project_env_path "$app_dir" || true)"
  [ -n "$env_file" ] || return 1
  set_env_file_var "$env_file" "GUACAMOLE_ENABLED" "false"
}

reset_project_fpm_opcache() {
  local app_dir="$1"
  local domain="$2"
  local opcache_token opcache_file opcache_url curl_status

  [ -n "$domain" ] || return 1
  [ -d "${app_dir}/public" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  opcache_token="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  opcache_file="${app_dir}/public/.opcache-reset-${opcache_token}.php"
  opcache_url="https://${domain}/.opcache-reset-${opcache_token}.php"

  cat > "$opcache_file" <<'PHP'
<?php
header('Content-Type: text/plain; charset=UTF-8');
echo function_exists('opcache_reset') && opcache_reset() ? 'opcache_reset=true' : 'opcache_reset=false';
PHP
  chmod 0644 "$opcache_file" >/dev/null 2>&1 || true
  curl -fsS --max-time 10 "$opcache_url" >/dev/null 2>&1
  curl_status=$?
  rm -f "$opcache_file"

  return "$curl_status"
}

refresh_project_runtime_after_env_change() {
  local app_dir="$1"
  local project_name="$2"
  local domain="${3:-}"
  local php_container="${project_name}-php"
  local artisan_rel artisan_path

  [ -f "${app_dir}/docker-compose.yml" ] || return 1
  docker_container_exists "$php_container" || return 1

  artisan_rel="$(detect_project_artisan_rel "$app_dir" || true)"

  cd "$app_dir"
  if [ -n "$artisan_rel" ]; then
    artisan_path="/var/www/${artisan_rel}"
    dc exec -T php php "$artisan_path" optimize:clear >/dev/null 2>&1 || true
    dc exec -T php php "$artisan_path" queue:restart >/dev/null 2>&1 || true
  fi

  find storage/framework/views/livewire/classes storage/framework/views/livewire/views \
    -type f ! -name '.gitignore' -delete >/dev/null 2>&1 || true

  dc restart php >/dev/null 2>&1
  sleep 3
  reset_project_fpm_opcache "$app_dir" "$domain" >/dev/null 2>&1 || true
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

detect_project_artisan_rel() {
  local app_dir="$1"
  local candidate_dir=""

  if [ -f "${app_dir}/artisan" ] && [ -f "${app_dir}/bootstrap/app.php" ]; then
    echo "artisan"
    return 0
  fi

  # Common "one folder too deep" layouts:
  if [ -f "${app_dir}/public/artisan" ] && [ -f "${app_dir}/public/bootstrap/app.php" ]; then
    echo "public/artisan"
    return 0
  fi

  if [ -f "${app_dir}/public/public/artisan" ] && [ -f "${app_dir}/public/public/bootstrap/app.php" ]; then
    echo "public/public/artisan"
    return 0
  fi

  if command -v find >/dev/null 2>&1 && [ -d "${app_dir}/public" ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      candidate_dir="$(dirname "$candidate")"
      if [ -f "${candidate_dir}/bootstrap/app.php" ]; then
        echo "${candidate#${app_dir}/}"
        return 0
      fi
    done < <(find "${app_dir}/public" -maxdepth 6 -type f -name artisan 2>/dev/null || true)
  fi

  return 1
}

normalize_project_profile() {
  local profile="${1:-}"
  profile="${profile,,}"
  profile="${profile//_/-}"

  case "$profile" in
    laravel|"")
      echo "laravel"
      ;;
    thinkphp|fastadmin|thinkphp-fastadmin)
      echo "thinkphp-fastadmin"
      ;;
    php|generic|generic-php|wordpress)
      echo "generic-php"
      ;;
    node|nodejs|node-js)
      echo "node"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

normalize_yes_no() {
  local value="${1:-}"
  value="${value,,}"

  case "$value" in
    yes|y|true|1|on|enabled)
      echo "yes"
      ;;
    no|n|false|0|off|disabled|"")
      echo "no"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

normalize_guacamole_upstream() {
  local upstream="${1:-}"
  upstream="${upstream#http://}"
  upstream="${upstream#https://}"
  upstream="${upstream%%/*}"
  echo "$upstream"
}

validate_guacamole_upstream() {
  local upstream="${1:-}"

  [[ "$upstream" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || return 1

  local port="${upstream##*:}"
  validate_port_number "$port"
}

build_guacamole_proxy_block() {
  local guacamole_proxy_enabled="${1:-no}"
  local guacamole_proxy_upstream="${2:-$GUACAMOLE_DEFAULT_UPSTREAM}"
  local access_block="${3:-}"

  if [ "$guacamole_proxy_enabled" != "yes" ]; then
    return 0
  fi

  cat <<EOF
    location = /guacamole {
${access_block}
        return 301 /guacamole/;
    }

    location /guacamole/ {
${access_block}
        # Resolve the upstream through Docker DNS at request time so a missing
        # Guacamole container returns 502 only for /guacamole instead of
        # preventing nginx from starting for the whole reverse proxy.
        resolver 127.0.0.11 ipv6=off valid=30s;
        resolver_timeout 5s;
        set \$guacamole_upstream "${guacamole_proxy_upstream}";
        proxy_pass http://\$guacamole_upstream;
        proxy_buffering off;
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

EOF
}

detect_project_profile() {
  local app_dir="$1"
  local saved_profile=""

  if [ -f "${app_dir}/.project-meta" ]; then
    saved_profile="$(
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${app_dir}/.project-meta" >/dev/null 2>&1
      normalize_project_profile "${APP_PROFILE:-}" 2>/dev/null || true
    )"
    if [ -n "$saved_profile" ]; then
      echo "$saved_profile"
      return 0
    fi
  fi

  if [ -f "${app_dir}/server.js" ] && [ -f "${app_dir}/package.json" ]; then
    echo "node"
    return 0
  fi

  if [ -f "${app_dir}/composer.json" ] \
    && grep -Eq '"(karsonzhang/fastadmin|topthink/framework)"' "${app_dir}/composer.json" \
    && [ -f "${app_dir}/public/index.php" ]; then
    echo "thinkphp-fastadmin"
    return 0
  fi

  if [ -f "${app_dir}/public/index.php" ] && ls "${app_dir}"/public/admin_*.php >/dev/null 2>&1; then
    echo "thinkphp-fastadmin"
    return 0
  fi

  if detect_project_artisan_rel "$app_dir" >/dev/null 2>&1; then
    echo "laravel"
    return 0
  fi

  echo "laravel"
}

project_php_image_tag() {
  local app_profile="$1"

  case "$app_profile" in
    thinkphp-fastadmin)
      echo "8.0-fpm-alpine"
      ;;
    *)
      echo "8.3-fpm-alpine"
      ;;
  esac
}

write_default_deny_proxy_config() {
  mkdir -p "$PROXY_CONF_DIR"

  cat > "$PROXY_DEFAULT_DENY_CONF" <<'EOF'
# Managed by laravel-server-manager.
# Drop requests that do not match an explicit project/webmail/mail vhost.
# This prevents direct access by server IP or unknown Host headers.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 444;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
}

project_has_laravel_runtime() {
  local app_profile="$1"
  local app_dir="$2"

  [ "$app_profile" = "laravel" ] || return 1
  detect_project_artisan_rel "$app_dir" >/dev/null 2>&1
}

detect_project_docroot_rel() {
  local app_dir="$1"
  local artisan_rel artisan_dir_rel

  if [ -f "${app_dir}/public/index.php" ]; then
    echo "public"
    return 0
  fi

  if [ -f "${app_dir}/public/public/index.php" ]; then
    echo "public/public"
    return 0
  fi

  artisan_rel="$(detect_project_artisan_rel "$app_dir" || true)"
  if [ -n "$artisan_rel" ] && [ "$artisan_rel" != "artisan" ]; then
    artisan_dir_rel="${artisan_rel%/artisan}"
    if [ -n "$artisan_dir_rel" ]; then
      echo "${artisan_dir_rel}/public"
      return 0
    fi
  fi

  echo "public"
}

project_container_docroot() {
  local project_name="$1"
  local app_dir="${2:-$(resolve_project_dir "$project_name")}"
  local docroot_rel

  docroot_rel="$(detect_project_docroot_rel "$app_dir")"
  echo "/projects/${project_name}/${docroot_rel}"
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
  write_default_deny_proxy_config

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

  proxy_dc up -d
}

install_base() {
  echo "Installing base dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update -y
  apt-get install -y docker.io curl tar gzip coreutils procps rsync cron util-linux

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
  chmod 700 "$SCRIPT_PATH" >/dev/null 2>&1 || true

  if ! docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
    echo "Creating shared Docker network ${SHARED_NETWORK}..."
    docker network create "$SHARED_NETWORK"
  fi

  proxy_up
  ensure_cron_jobs
}

server_ram_total_mb() {
  local detected=""

  if command -v free >/dev/null 2>&1; then
    detected="$(free -m | awk '/Mem:/ {print $2; exit}')"
  fi

  if ! [[ "$detected" =~ ^[0-9]+$ ]] && [ -r /proc/meminfo ]; then
    detected="$(awk '/MemTotal:/ {printf "%d\n", $2 / 1024; exit}' /proc/meminfo)"
  fi

  if [[ "$detected" =~ ^[0-9]+$ ]] && [ "$detected" -gt 0 ]; then
    echo "$detected"
  else
    echo "0"
  fi
}

server_cpu_cores() {
  local detected=""

  if command -v nproc >/dev/null 2>&1; then
    detected="$(nproc 2>/dev/null || true)"
  fi

  if ! [[ "$detected" =~ ^[0-9]+$ ]] && command -v getconf >/dev/null 2>&1; then
    detected="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi

  if [[ "$detected" =~ ^[0-9]+$ ]] && [ "$detected" -gt 0 ]; then
    echo "$detected"
  else
    echo "1"
  fi
}

clamp_int() {
  local value="$1"
  local min_value="$2"
  local max_value="$3"

  if [ "$max_value" -lt "$min_value" ]; then
    max_value="$min_value"
  fi

  if [ "$value" -lt "$min_value" ]; then
    echo "$min_value"
  elif [ "$value" -gt "$max_value" ]; then
    echo "$max_value"
  else
    echo "$value"
  fi
}

normalize_memory_mb_value() {
  local value
  value="$(trim_whitespace "${1:-}")"
  value="${value,,}"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
    return 0
  fi

  if [[ "$value" =~ ^([0-9]+)m(b)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$value" =~ ^([0-9]+)g(b)?$ ]]; then
    echo "$((BASH_REMATCH[1] * 1024))"
    return 0
  fi

  return 1
}

format_memory_mb_for_redis() {
  local value_mb="$1"

  if [ "$value_mb" -ge 1024 ] && [ $((value_mb % 1024)) -eq 0 ]; then
    echo "$((value_mb / 1024))gb"
  else
    echo "${value_mb}mb"
  fi
}

normalize_project_tuning_mode() {
  local mode="${1:-}"
  mode="${mode,,}"

  case "$mode" in
    auto|automatic|"")
      echo "auto"
      ;;
    preset|presets|prefab|prebuilt|optimal)
      echo "preset"
      ;;
    custom|personalized|personalizada|manual)
      echo "custom"
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_project_tuning_preset() {
  local preset="${1:-}"
  preset="${preset,,}"
  preset="${preset//_/-}"

  case "$preset" in
    conservative|safe|small|low|bajo|conservador)
      echo "conservative"
      ;;
    balanced|normal|medium|medio|"")
      echo "balanced"
      ;;
    performance|high|alto|fast)
      echo "performance"
      ;;
    maximum|max|aggressive|agresivo)
      echo "maximum"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_server_capacity_or_exit() {
  local detected_ram detected_cpu
  detected_ram="$(server_ram_total_mb)"
  detected_cpu="$(server_cpu_cores)"

  RAM_MB="$detected_ram"
  CPU_CORES="$detected_cpu"

  if [ "$RAM_MB" -le 0 ]; then
    echo "Could not detect server RAM."
    exit 1
  fi

  if [ "$CPU_CORES" -le 0 ]; then
    echo "Could not detect server CPU cores."
    exit 1
  fi
}

derive_php_fpm_tuning() {
  PHP_FPM_START_SERVERS="$(clamp_int "$((PHP_FPM_CHILDREN / 4))" 1 8)"
  PHP_FPM_MIN_SPARE_SERVERS="$PHP_FPM_START_SERVERS"
  PHP_FPM_MAX_SPARE_SERVERS="$(clamp_int "$((PHP_FPM_CHILDREN / 2))" "$PHP_FPM_MIN_SPARE_SERVERS" 24)"
}

print_tuning_summary() {
  local app_profile="${1:-}"

  echo "Detected server capacity: ${RAM_MB} MB RAM, ${CPU_CORES} CPU core(s)"
  echo "Tuning mode: ${PROJECT_TUNING_MODE:-auto}${PROJECT_TUNING_PRESET:+/${PROJECT_TUNING_PRESET}}"
  echo "Applied profile: ${PROFILE_NAME}"
  if [ "$app_profile" = "node" ]; then
    echo "Project tuning: Node container can use available host CPU/RAM; no PHP/MariaDB/Redis tuning generated."
  else
    echo "Project tuning: PHP-FPM max_children=${PHP_FPM_CHILDREN}, MariaDB buffer=${MYSQL_BUFFER}, Redis maxmemory=${REDIS_MEMORY}"
  fi
}

detect_tuning() {
  local app_profile="${1:-}"
  local quiet="${2:-no}"
  local redis_memory_mb mysql_buffer_mb php_max_by_ram

  detect_server_capacity_or_exit
  PROJECT_TUNING_MODE="auto"
  PROJECT_TUNING_PRESET=""

  if [ "$RAM_MB" -le 2048 ] || [ "$CPU_CORES" -le 1 ]; then
    PROFILE_NAME="LOW CAPACITY"
    PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 4))" 4 6)"
    OPCACHE_MEMORY=128
    redis_memory_mb=256
    mysql_buffer_mb=128
    MYSQL_MAX_CONNECTIONS=75
  elif [ "$RAM_MB" -le 4096 ] || [ "$CPU_CORES" -le 2 ]; then
    PROFILE_NAME="BALANCED"
    PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 5))" 8 12)"
    OPCACHE_MEMORY=192
    redis_memory_mb="$(clamp_int "$((RAM_MB / 8))" 256 512)"
    mysql_buffer_mb="$(clamp_int "$((RAM_MB / 8))" 256 512)"
    MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 50))" 100 150)"
  else
    PROFILE_NAME="HIGH PERFORMANCE"
    php_max_by_ram="$((RAM_MB / 192))"
    php_max_by_ram="$(clamp_int "$php_max_by_ram" 16 80)"
    PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 8))" 16 "$php_max_by_ram")"
    OPCACHE_MEMORY="$(clamp_int "$((RAM_MB / 32))" 256 768)"
    redis_memory_mb="$(clamp_int "$((RAM_MB / 8))" 512 4096)"
    mysql_buffer_mb="$(clamp_int "$((RAM_MB / 6))" 512 4096)"
    MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 75))" 150 600)"
  fi

  derive_php_fpm_tuning
  REDIS_MEMORY="$(format_memory_mb_for_redis "$redis_memory_mb")"
  MYSQL_BUFFER="${mysql_buffer_mb}M"

  if [ "$quiet" != "quiet" ]; then
    print_tuning_summary "$app_profile"
  fi
}

apply_project_tuning_preset() {
  local preset="$1"
  local app_profile="${2:-}"
  local quiet="${3:-no}"
  local redis_memory_mb mysql_buffer_mb php_max_by_ram

  preset="$(normalize_project_tuning_preset "$preset")" || {
    echo "Invalid tuning preset. Use one of: conservative, balanced, performance, maximum."
    exit 1
  }

  detect_server_capacity_or_exit
  PROJECT_TUNING_MODE="preset"
  PROJECT_TUNING_PRESET="$preset"

  case "$preset" in
    conservative)
      PROFILE_NAME="PRESET CONSERVATIVE"
      php_max_by_ram="$(clamp_int "$((RAM_MB / 256))" 4 24)"
      PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 3))" 4 "$php_max_by_ram")"
      OPCACHE_MEMORY="$(clamp_int "$((RAM_MB / 64))" 128 256)"
      redis_memory_mb="$(clamp_int "$((RAM_MB / 12))" 128 1024)"
      mysql_buffer_mb="$(clamp_int "$((RAM_MB / 10))" 128 1024)"
      MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 35))" 75 200)"
      ;;
    balanced)
      PROFILE_NAME="PRESET BALANCED"
      php_max_by_ram="$(clamp_int "$((RAM_MB / 192))" 8 40)"
      PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 5))" 8 "$php_max_by_ram")"
      OPCACHE_MEMORY="$(clamp_int "$((RAM_MB / 48))" 192 384)"
      redis_memory_mb="$(clamp_int "$((RAM_MB / 8))" 256 2048)"
      mysql_buffer_mb="$(clamp_int "$((RAM_MB / 8))" 256 2048)"
      MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 50))" 100 350)"
      ;;
    performance)
      PROFILE_NAME="PRESET PERFORMANCE"
      php_max_by_ram="$(clamp_int "$((RAM_MB / 160))" 12 80)"
      PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 8))" 12 "$php_max_by_ram")"
      OPCACHE_MEMORY="$(clamp_int "$((RAM_MB / 32))" 256 768)"
      redis_memory_mb="$(clamp_int "$((RAM_MB / 6))" 512 4096)"
      mysql_buffer_mb="$(clamp_int "$((RAM_MB / 5))" 512 4096)"
      MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 75))" 150 600)"
      ;;
    maximum)
      PROFILE_NAME="PRESET MAXIMUM"
      php_max_by_ram="$(clamp_int "$((RAM_MB / 128))" 16 160)"
      PHP_FPM_CHILDREN="$(clamp_int "$((CPU_CORES * 12))" 16 "$php_max_by_ram")"
      OPCACHE_MEMORY="$(clamp_int "$((RAM_MB / 24))" 384 1024)"
      redis_memory_mb="$(clamp_int "$((RAM_MB / 4))" 1024 8192)"
      mysql_buffer_mb="$(clamp_int "$((RAM_MB / 3))" 1024 8192)"
      MYSQL_MAX_CONNECTIONS="$(clamp_int "$((CPU_CORES * 100))" 200 1000)"
      ;;
  esac

  derive_php_fpm_tuning
  REDIS_MEMORY="$(format_memory_mb_for_redis "$redis_memory_mb")"
  MYSQL_BUFFER="${mysql_buffer_mb}M"

  if [ "$quiet" != "quiet" ]; then
    print_tuning_summary "$app_profile"
  fi
}

set_custom_project_tuning_values() {
  local php_children="$1"
  local opcache_memory_mb="$2"
  local redis_memory_mb="$3"
  local mysql_buffer_mb="$4"
  local mysql_max_connections="$5"

  PHP_FPM_CHILDREN="$php_children"
  OPCACHE_MEMORY="$opcache_memory_mb"
  REDIS_MEMORY="$(format_memory_mb_for_redis "$redis_memory_mb")"
  MYSQL_BUFFER="${mysql_buffer_mb}M"
  MYSQL_MAX_CONNECTIONS="$mysql_max_connections"
  PROJECT_TUNING_MODE="custom"
  PROJECT_TUNING_PRESET=""
  PROFILE_NAME="CUSTOM"
  derive_php_fpm_tuning
}

validate_int_between() {
  local value="${1:-}"
  local min_value="$2"
  local max_value="$3"

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  [ "$value" -ge "$min_value" ] && [ "$value" -le "$max_value" ]
}

load_custom_project_tuning() {
  local app_dir="$1"
  local php_children opcache_memory redis_memory mysql_buffer mysql_max_connections
  local redis_memory_mb mysql_buffer_mb

  php_children="${PHP_FPM_CHILDREN:-$(read_project_meta_var "$app_dir" "PHP_FPM_CHILDREN")}"
  opcache_memory="${OPCACHE_MEMORY:-$(read_project_meta_var "$app_dir" "OPCACHE_MEMORY")}"
  redis_memory="${REDIS_MEMORY:-$(read_project_meta_var "$app_dir" "REDIS_MEMORY")}"
  mysql_buffer="${MYSQL_BUFFER:-$(read_project_meta_var "$app_dir" "MYSQL_BUFFER")}"
  mysql_max_connections="${MYSQL_MAX_CONNECTIONS:-$(read_project_meta_var "$app_dir" "MYSQL_MAX_CONNECTIONS")}"

  redis_memory_mb="$(normalize_memory_mb_value "$redis_memory" 2>/dev/null || true)"
  mysql_buffer_mb="$(normalize_memory_mb_value "$mysql_buffer" 2>/dev/null || true)"

  validate_int_between "$php_children" 1 500 || return 1
  validate_int_between "$opcache_memory" 32 4096 || return 1
  validate_int_between "$redis_memory_mb" 16 65536 || return 1
  validate_int_between "$mysql_buffer_mb" 16 131072 || return 1
  validate_int_between "$mysql_max_connections" 10 5000 || return 1

  set_custom_project_tuning_values "$php_children" "$opcache_memory" "$redis_memory_mb" "$mysql_buffer_mb" "$mysql_max_connections"
}

resolve_project_tuning() {
  local app_dir="$1"
  local app_profile="${2:-}"
  local quiet="${3:-no}"
  local tuning_mode tuning_preset

  if [ "$app_profile" = "node" ]; then
    detect_tuning "$app_profile" "$quiet"
    return 0
  fi

  tuning_mode="${PROJECT_TUNING_MODE:-$(read_project_meta_var "$app_dir" "PROJECT_TUNING_MODE")}"
  if ! tuning_mode="$(normalize_project_tuning_mode "$tuning_mode" 2>/dev/null)"; then
    tuning_mode="auto"
  fi

  case "$tuning_mode" in
    auto)
      detect_tuning "$app_profile" "$quiet"
      ;;
    preset)
      tuning_preset="${PROJECT_TUNING_PRESET:-$(read_project_meta_var "$app_dir" "PROJECT_TUNING_PRESET")}"
      if ! tuning_preset="$(normalize_project_tuning_preset "$tuning_preset" 2>/dev/null)"; then
        tuning_preset="balanced"
      fi
      apply_project_tuning_preset "$tuning_preset" "$app_profile" "$quiet"
      ;;
    custom)
      detect_server_capacity_or_exit
      if load_custom_project_tuning "$app_dir"; then
        if [ "$quiet" != "quiet" ]; then
          print_tuning_summary "$app_profile"
        fi
      else
        echo "Warning: saved custom tuning is invalid or incomplete; falling back to auto tuning."
        detect_tuning "$app_profile" "$quiet"
      fi
      ;;
  esac
}

prompt_project_tuning() {
  local app_dir="$1"
  local app_profile="$2"
  local action="${3:-project}"
  local saved_mode saved_preset default_mode mode preset
  local current_php current_opcache current_redis current_mysql current_connections
  local php_children opcache_memory redis_memory mysql_buffer mysql_connections
  local redis_memory_mb mysql_buffer_mb

  detect_server_capacity_or_exit

  if [ "$RAM_MB" -lt 1024 ]; then
    echo "Server capacity check failed for ${action}: at least 1024 MB RAM is required."
    exit 1
  fi

  if [ "$CPU_CORES" -lt 1 ]; then
    echo "Server capacity check failed for ${action}: at least 1 CPU core is required."
    exit 1
  fi

  if [ "$app_profile" = "node" ]; then
    echo "Node profile does not generate PHP/MariaDB/Redis tuning; using auto capacity metadata."
    detect_tuning "$app_profile"
    return 0
  fi

  saved_mode="${PROJECT_TUNING_MODE:-$(read_project_meta_var "$app_dir" "PROJECT_TUNING_MODE")}"
  if ! default_mode="$(normalize_project_tuning_mode "$saved_mode" 2>/dev/null)"; then
    default_mode="auto"
  fi

  echo ""
  echo "Project tuning"
  echo "--------------------------------------------------------------"
  echo "Server capacity: ${RAM_MB} MB RAM, ${CPU_CORES} CPU core(s)"
  echo "Modes:"
  echo "  auto   - choose values automatically from server RAM/CPU"
  echo "  preset - choose a prefabricated profile"
  echo "  custom - enter exact PHP/MariaDB/Redis values"
  echo "Presets: conservative, balanced, performance, maximum"
  echo "--------------------------------------------------------------"
  prompt mode "Tuning mode [auto/preset/custom] [${default_mode}]: " "$default_mode"
  if ! mode="$(normalize_project_tuning_mode "$mode")"; then
    echo "Invalid tuning mode. Use one of: auto, preset, custom."
    exit 1
  fi

  case "$mode" in
    auto)
      detect_tuning "$app_profile"
      ;;
    preset)
      saved_preset="${PROJECT_TUNING_PRESET:-$(read_project_meta_var "$app_dir" "PROJECT_TUNING_PRESET")}"
      if ! saved_preset="$(normalize_project_tuning_preset "$saved_preset" 2>/dev/null)"; then
        saved_preset="balanced"
      fi
      prompt preset "Tuning preset [conservative/balanced/performance/maximum] [${saved_preset}]: " "$saved_preset"
      apply_project_tuning_preset "$preset" "$app_profile"
      ;;
    custom)
      current_php="${PHP_FPM_CHILDREN:-$(read_project_meta_var "$app_dir" "PHP_FPM_CHILDREN")}"
      current_opcache="${OPCACHE_MEMORY:-$(read_project_meta_var "$app_dir" "OPCACHE_MEMORY")}"
      current_redis="${REDIS_MEMORY:-$(read_project_meta_var "$app_dir" "REDIS_MEMORY")}"
      current_mysql="${MYSQL_BUFFER:-$(read_project_meta_var "$app_dir" "MYSQL_BUFFER")}"
      current_connections="${MYSQL_MAX_CONNECTIONS:-$(read_project_meta_var "$app_dir" "MYSQL_MAX_CONNECTIONS")}"

      if ! redis_memory_mb="$(normalize_memory_mb_value "$current_redis" 2>/dev/null)" \
        || ! mysql_buffer_mb="$(normalize_memory_mb_value "$current_mysql" 2>/dev/null)" \
        || ! validate_int_between "$current_php" 1 500 \
        || ! validate_int_between "$current_opcache" 32 4096 \
        || ! validate_int_between "$current_connections" 10 5000; then
        detect_tuning "$app_profile" "quiet"
        current_php="$PHP_FPM_CHILDREN"
        current_opcache="$OPCACHE_MEMORY"
        redis_memory_mb="$(normalize_memory_mb_value "$REDIS_MEMORY")"
        mysql_buffer_mb="$(normalize_memory_mb_value "$MYSQL_BUFFER")"
        current_connections="$MYSQL_MAX_CONNECTIONS"
      fi

      prompt php_children "PHP-FPM max_children [${current_php}]: " "$current_php"
      prompt opcache_memory "OPcache memory MB [${current_opcache}]: " "$current_opcache"
      prompt redis_memory "Redis maxmemory MB [${redis_memory_mb}]: " "$redis_memory_mb"
      prompt mysql_buffer "MariaDB buffer pool MB [${mysql_buffer_mb}]: " "$mysql_buffer_mb"
      prompt mysql_connections "MariaDB max_connections [${current_connections}]: " "$current_connections"

      redis_memory_mb="$(normalize_memory_mb_value "$redis_memory" 2>/dev/null || true)"
      mysql_buffer_mb="$(normalize_memory_mb_value "$mysql_buffer" 2>/dev/null || true)"

      validate_int_between "$php_children" 1 500 || { echo "Invalid PHP-FPM max_children. Use 1-500."; exit 1; }
      validate_int_between "$opcache_memory" 32 4096 || { echo "Invalid OPcache memory. Use 32-4096 MB."; exit 1; }
      validate_int_between "$redis_memory_mb" 16 65536 || { echo "Invalid Redis memory. Use 16-65536 MB."; exit 1; }
      validate_int_between "$mysql_buffer_mb" 16 131072 || { echo "Invalid MariaDB buffer. Use 16-131072 MB."; exit 1; }
      validate_int_between "$mysql_connections" 10 5000 || { echo "Invalid MariaDB max_connections. Use 10-5000."; exit 1; }

      set_custom_project_tuning_values "$php_children" "$opcache_memory" "$redis_memory_mb" "$mysql_buffer_mb" "$mysql_connections"
      print_tuning_summary "$app_profile"
      ;;
  esac
}

verify_server_capacity_or_exit() {
  local action="${1:-manage project}"
  local app_profile="${2:-}"

  detect_tuning "$app_profile"

  if [ "$RAM_MB" -lt 1024 ]; then
    echo "Server capacity check failed for ${action}: at least 1024 MB RAM is required."
    exit 1
  fi

  if [ "$CPU_CORES" -lt 1 ]; then
    echo "Server capacity check failed for ${action}: at least 1 CPU core is required."
    exit 1
  fi

  echo "Server capacity check passed for ${action}."
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

project_dir_is_safe_for_permission_fix() {
  local app_dir="$1"
  local resolved_app_dir resolved_projects_base

  resolved_app_dir="$(readlink -f "$app_dir" 2>/dev/null || true)"
  resolved_projects_base="$(readlink -f "$PROJECTS_BASE" 2>/dev/null || true)"

  [ -n "$resolved_app_dir" ] || return 1
  [ -d "$resolved_app_dir" ] || return 1
  [ -f "${resolved_app_dir}/docker-compose.yml" ] || [ -f "${resolved_app_dir}/.project-meta" ] || return 1

  case "$resolved_app_dir" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/www)
      return 1
      ;;
  esac

  if [ -n "$resolved_projects_base" ] && [ "$resolved_app_dir" = "$resolved_projects_base" ]; then
    return 1
  fi

  return 0
}

fix_project_writable_path() {
  local path="$1"
  local owner="$2"
  local dir_mode="${3:-0775}"
  local file_mode="${4:-0664}"

  [ -e "$path" ] || return 0

  find "$path" -xdev -exec chown -h "$owner" {} + 2>/dev/null || true
  find "$path" -xdev -type d -exec chmod "$dir_mode" {} + 2>/dev/null || true
  find "$path" -xdev -type f -exec chmod "$file_mode" {} + 2>/dev/null || true
}

apply_project_permissions() {
  local app_dir="$1"
  local app_profile="${2:-}"
  local php_runtime_owner="82:82"
  local php_runtime_group="82"
  local resolved_app_dir writable_path env_file

  if ! project_dir_is_safe_for_permission_fix "$app_dir"; then
    echo "Warning: skipping project permission fix for unsafe path: ${app_dir}"
    return 0
  fi

  resolved_app_dir="$(readlink -f "$app_dir" 2>/dev/null || true)"
  if [ -n "$resolved_app_dir" ]; then
    app_dir="$resolved_app_dir"
  fi

  echo "Fixing project ownership and permissions..."

  find "$app_dir" -xdev -path "${app_dir}/.git" -prune -o -exec chown -h root:root {} + 2>/dev/null || true
  find "$app_dir" -xdev -path "${app_dir}/.git" -prune -o -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$app_dir" -xdev -path "${app_dir}/.git" -prune -o -type f -exec chmod u+rw,go+r,go-w {} + 2>/dev/null || true

  if [ -f "${app_dir}/.project-meta" ]; then
    chown root:root "${app_dir}/.project-meta" 2>/dev/null || true
    chmod 0600 "${app_dir}/.project-meta" 2>/dev/null || true
  fi

  while IFS= read -r env_file; do
    [ -n "$env_file" ] || continue
    chown "root:${php_runtime_group}" "$env_file" 2>/dev/null || true
    chmod 0640 "$env_file" 2>/dev/null || true
  done < <(find "$app_dir" -xdev -path "${app_dir}/.git" -prune -o -type f -name .env -print 2>/dev/null || true)

  if [ "$app_profile" = "node" ]; then
    fix_project_writable_path "${app_dir}/data" "root:root" 0750 0640
    return 0
  fi

  for writable_path in \
    "${app_dir}/storage" \
    "${app_dir}/bootstrap/cache" \
    "${app_dir}/public/storage" \
    "${app_dir}/public/uploads" \
    "${app_dir}/public/wp-content"; do
    fix_project_writable_path "$writable_path" "$php_runtime_owner" 0775 0664
  done
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
  local app_profile="${14:-}"
  local guacamole_proxy_enabled="${15:-no}"
  local guacamole_proxy_upstream="${16:-$GUACAMOLE_DEFAULT_UPSTREAM}"

  local php_container="${project_name}-php"
  local db_container="${project_name}-db"
  local redis_container="${project_name}-redis"
  local pma_container="${project_name}-phpmyadmin"
  local php_image_tag redis_command redis_healthcheck mysql_sql_mode_line
  local backup_retention_days backup_interval_hours backup_cloud_enabled
  local backup_cloud_scope backup_cloud_retention_enabled
  local backup_cloud_provider backup_cloud_remote backup_cloud_folder
  local ufw_pma_allowed_sources ufw_pma_restricted ufw_pma_port
  local project_access_allowed_sources project_access_restricted
  local laravel_queue_connection="" laravel_queue_names="" laravel_queue_sleep="" laravel_queue_tries=""
  local laravel_queue_timeout="" laravel_queue_max_time="" laravel_queue_stopwaitsecs=""
  local project_domains="${PROJECT_DOMAINS:-}"

  if [ -z "$pma_port" ]; then
    pma_port="$(pma_default_port "$project_name")"
  fi

  if [ -z "$pma_bind_ip" ]; then
    pma_bind_ip="127.0.0.1"
  fi

  if [ -z "$app_profile" ]; then
    app_profile="$(detect_project_profile "$app_dir")"
  else
    if ! app_profile="$(normalize_project_profile "$app_profile")"; then
      echo "Invalid app profile. Use one of: laravel, thinkphp, generic, node."
      exit 1
    fi
  fi

  if ! guacamole_proxy_enabled="$(normalize_yes_no "$guacamole_proxy_enabled")"; then
    echo "Invalid Guacamole proxy setting. Use yes or no."
    exit 1
  fi

  guacamole_proxy_upstream="$(normalize_guacamole_upstream "$guacamole_proxy_upstream")"
  if [ "$guacamole_proxy_enabled" = "yes" ] && ! validate_guacamole_upstream "$guacamole_proxy_upstream"; then
    echo "Invalid Guacamole upstream: ${guacamole_proxy_upstream}"
    echo "Use host:port, for example guacamole-web:8080"
    exit 1
  fi

  backup_retention_days="$(read_project_backup_retention_days "$app_dir")"
  backup_interval_hours="$(read_project_backup_interval_hours "$app_dir")"
  backup_cloud_enabled="$(read_project_backup_cloud_enabled "$app_dir")"
  backup_cloud_scope="$(read_project_backup_cloud_scope "$app_dir")"
  backup_cloud_retention_enabled="$(read_project_backup_cloud_retention_enabled "$app_dir")"
  backup_cloud_provider="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_PROVIDER")"
  backup_cloud_remote="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_REMOTE")"
  backup_cloud_folder="$(normalize_backup_cloud_folder "$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_FOLDER")")"
  ufw_pma_allowed_sources="$(read_project_ufw_pma_allowed_sources "$app_dir")"
  ufw_pma_restricted="$(read_project_ufw_pma_restricted "$app_dir")"
  ufw_pma_port="$(read_project_ufw_pma_port "$app_dir" "$pma_port")"
  project_access_allowed_sources="$(read_project_access_allowed_sources "$app_dir")"
  project_access_restricted="$(read_project_access_restricted "$app_dir")"
  project_domains="$(normalize_project_domain_list "$domain" "$project_domains" 2>/dev/null || echo "$domain")"
  resolve_project_tuning "$app_dir" "$app_profile" "quiet"

  if [ "$app_profile" = "node" ]; then
    local node_container="${project_name}-node"

    mkdir -p "${app_dir}/node" "${app_dir}/data"

    cat > "${app_dir}/node/Dockerfile" <<EOF
FROM node:20-alpine

WORKDIR /app

ENV NODE_ENV=production
ENV HTTP_PORT=8080
ENV WS_PORT=3533
ENV USERS_FILE=/app/data/users.txt

EXPOSE 8080 3533

CMD ["sh","-lc","while [ ! -f server.js ]; do echo 'Waiting for /app/server.js...'; sleep 10; done; if [ -f package-lock.json ]; then npm ci --omit=dev || npm install --omit=dev; elif [ -f package.json ]; then npm install --omit=dev; fi; node server.js"]
EOF

    cat > "${app_dir}/docker-compose.yml" <<EOF
version: "3.9"
services:
  node:
    build: ./node
    container_name: ${node_container}
    restart: unless-stopped
    environment:
      NODE_ENV: production
      HTTP_PORT: "8080"
      WS_PORT: "3533"
      USERS_FILE: /app/data/users.txt
    volumes:
      - ./:/app
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://127.0.0.1:8080/login.html >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - ${SHARED_NETWORK}

networks:
  ${SHARED_NETWORK}:
    external: true
EOF

    {
      printf 'PROJECT_NAME=%q\n' "$project_name"
      printf 'DOMAIN=%q\n' "$domain"
      printf 'PROJECT_DOMAINS=%q\n' "$project_domains"
      printf 'DB_NAME=%q\n' ""
      printf 'DB_USER=%q\n' ""
      printf 'DB_PASSWORD=%q\n' ""
      printf 'DB_ROOT_PASSWORD=%q\n' ""
      printf 'PHP_CONTAINER=%q\n' ""
      printf 'NODE_CONTAINER=%q\n' "$node_container"
      printf 'DB_CONTAINER=%q\n' ""
      printf 'REDIS_CONTAINER=%q\n' ""
      printf 'APP_DIR=%q\n' "$app_dir"
      printf 'PMA_PORT=%q\n' ""
      printf 'PMA_BIND_IP=%q\n' ""
      printf 'REVERB_ENABLED=%q\n' "no"
      printf 'REVERB_DOMAIN=%q\n' ""
      printf 'REVERB_PORT=%q\n' ""
      printf 'REVERB_EXPOSURE=%q\n' ""
      printf 'GUACAMOLE_PROXY_ENABLED=%q\n' "$guacamole_proxy_enabled"
      printf 'GUACAMOLE_PROXY_UPSTREAM=%q\n' "$guacamole_proxy_upstream"
      printf 'APP_PROFILE=%q\n' "$app_profile"
      printf 'SERVER_RAM_MB=%q\n' "$RAM_MB"
      printf 'SERVER_CPU_CORES=%q\n' "$CPU_CORES"
      printf 'SERVER_CAPACITY_PROFILE=%q\n' "$PROFILE_NAME"
      printf 'PROJECT_TUNING_MODE=%q\n' "${PROJECT_TUNING_MODE:-auto}"
      printf 'PROJECT_TUNING_PRESET=%q\n' "${PROJECT_TUNING_PRESET:-}"
      printf 'BACKUP_RETENTION_DAYS=%q\n' "$backup_retention_days"
      printf 'BACKUP_INTERVAL_HOURS=%q\n' "$backup_interval_hours"
      printf 'BACKUP_CLOUD_ENABLED=%q\n' "$backup_cloud_enabled"
      printf 'BACKUP_CLOUD_SCOPE=%q\n' "$backup_cloud_scope"
      printf 'BACKUP_CLOUD_RETENTION_ENABLED=%q\n' "$backup_cloud_retention_enabled"
      printf 'BACKUP_CLOUD_PROVIDER=%q\n' "$backup_cloud_provider"
      printf 'BACKUP_CLOUD_REMOTE=%q\n' "$backup_cloud_remote"
      printf 'BACKUP_CLOUD_FOLDER=%q\n' "$backup_cloud_folder"
      printf 'UFW_PMA_ALLOWED_SOURCES=%q\n' "$ufw_pma_allowed_sources"
      printf 'UFW_PMA_RESTRICTED=%q\n' "$ufw_pma_restricted"
      printf 'UFW_PMA_PORT=%q\n' ""
      printf 'PROJECT_ACCESS_ALLOWED_SOURCES=%q\n' "$project_access_allowed_sources"
      printf 'PROJECT_ACCESS_RESTRICTED=%q\n' "$project_access_restricted"
    } > "${app_dir}/.project-meta"

    apply_project_permissions "$app_dir" "$app_profile"
    return 0
  fi

  php_image_tag="$(project_php_image_tag "$app_profile")"
  redis_command="redis-server --appendonly yes --maxmemory ${REDIS_MEMORY} --maxmemory-policy allkeys-lru"
  redis_healthcheck="redis-cli ping"
  mysql_sql_mode_line=""
  if [ "$app_profile" = "thinkphp-fastadmin" ]; then
    redis_command="redis-server --appendonly yes --requirepass Yunbao123 --maxmemory ${REDIS_MEMORY} --maxmemory-policy allkeys-lru"
    redis_healthcheck="redis-cli -a Yunbao123 ping"
    mysql_sql_mode_line="sql_mode=NO_ENGINE_SUBSTITUTION"
  fi

  mkdir -p "${app_dir}/php" "${app_dir}/mariadb"

  cat > "${app_dir}/mariadb/my.cnf" <<EOF
[mysqld]
innodb_buffer_pool_size=${MYSQL_BUFFER}
innodb_log_file_size=128M
max_connections=${MYSQL_MAX_CONNECTIONS}
max_allowed_packet=${MARIADB_MAX_ALLOWED_PACKET}
net_read_timeout=${MARIADB_NET_READ_TIMEOUT}
net_write_timeout=${MARIADB_NET_WRITE_TIMEOUT}
${mysql_sql_mode_line}
EOF

  local artisan_rel_detected artisan_rel artisan_path
  artisan_rel="artisan"
  artisan_rel_detected="$(detect_project_artisan_rel "$app_dir" || true)"
  if [ -n "$artisan_rel_detected" ]; then
    artisan_rel="$artisan_rel_detected"
  fi
  artisan_path="/var/www/${artisan_rel}"

  if project_has_laravel_runtime "$app_profile" "$app_dir"; then
    laravel_queue_connection="$(read_project_laravel_queue_connection "$app_dir")"
    laravel_queue_names="$(read_project_laravel_queue_names "$app_dir")"
    laravel_queue_sleep="$(read_project_laravel_queue_integer "$app_dir" "LARAVEL_QUEUE_SLEEP" "$DEFAULT_LARAVEL_QUEUE_SLEEP")"
    laravel_queue_tries="$(read_project_laravel_queue_integer "$app_dir" "LARAVEL_QUEUE_TRIES" "$DEFAULT_LARAVEL_QUEUE_TRIES")"
    laravel_queue_timeout="$(read_project_laravel_queue_integer "$app_dir" "LARAVEL_QUEUE_TIMEOUT" "$DEFAULT_LARAVEL_QUEUE_TIMEOUT")"
    laravel_queue_max_time="$(read_project_laravel_queue_integer "$app_dir" "LARAVEL_QUEUE_MAX_TIME" "$DEFAULT_LARAVEL_QUEUE_MAX_TIME")"
    laravel_queue_stopwaitsecs="$((laravel_queue_timeout + 10))"
  fi

  cat > "${app_dir}/php/supervisord.conf" <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid

[unix_http_server]
file=/tmp/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

  if project_has_laravel_runtime "$app_profile" "$app_dir"; then
    cat >> "${app_dir}/php/supervisord.conf" <<EOF

[program:laravel-worker]
command=/bin/sh -c "while [ ! -f ${artisan_path} ]; do echo 'Waiting for ${artisan_path}...'; sleep 10; done; php ${artisan_path} queue:work ${laravel_queue_connection} --queue=${laravel_queue_names} --sleep=${laravel_queue_sleep} --tries=${laravel_queue_tries} --timeout=${laravel_queue_timeout} --max-time=${laravel_queue_max_time}"
autostart=true
autorestart=true
priority=20
startsecs=5
stopasgroup=true
killasgroup=true
stopwaitsecs=${laravel_queue_stopwaitsecs}
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
  fi

  if [ "$app_profile" = "laravel" ] && [ "${reverb_enabled}" = "yes" ]; then
    cat >> "${app_dir}/php/supervisord.conf" <<EOF

[program:laravel-reverb]
command=/bin/sh -c "while [ ! -f ${artisan_path} ]; do echo 'Waiting for ${artisan_path}...'; sleep 10; done; php ${artisan_path} reverb:start --host=0.0.0.0 --port=${reverb_port}"
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

FROM php:${php_image_tag}

RUN set -eux; \
    apk add --no-cache \
      curl \
      git \
      nodejs \
      npm \
      ffmpeg \
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
      curl-dev \
      freetype-dev \
      libjpeg-turbo-dev \
      libpng-dev \
      icu-dev \
      libzip-dev \
      oniguruma-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      bcmath \
      curl \
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
 && echo "opcache.fast_shutdown=1" >> /usr/local/etc/php/conf.d/opcache.ini \
 && echo "upload_max_filesize=5120M" >> /usr/local/etc/php/conf.d/uploads.ini \
 && echo "post_max_size=5120M" >> /usr/local/etc/php/conf.d/uploads.ini \
 && echo "max_execution_time=600" >> /usr/local/etc/php/conf.d/uploads.ini \
 && echo "max_input_time=600" >> /usr/local/etc/php/conf.d/uploads.ini \
 && echo "memory_limit=1024M" >> /usr/local/etc/php/conf.d/uploads.ini

RUN echo "pm = dynamic" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.max_children=${PHP_FPM_CHILDREN}" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.start_servers=${PHP_FPM_START_SERVERS}" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.min_spare_servers=${PHP_FPM_MIN_SPARE_SERVERS}" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo "pm.max_spare_servers=${PHP_FPM_MAX_SPARE_SERVERS}" >> /usr/local/etc/php-fpm.d/www.conf

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
    command: ${redis_command}
    healthcheck:
      test: ["CMD-SHELL", "${redis_healthcheck}"]
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
      UPLOAD_LIMIT: ${PMA_UPLOAD_LIMIT}
      MEMORY_LIMIT: ${PMA_MEMORY_LIMIT}
      MAX_EXECUTION_TIME: ${PMA_MAX_EXECUTION_TIME}
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
    printf 'PROJECT_DOMAINS=%q\n' "$project_domains"
    printf 'DB_NAME=%q\n' "$db_name"
    printf 'DB_USER=%q\n' "$db_user"
    printf 'DB_PASSWORD=%q\n' "$db_password"
    printf 'DB_ROOT_PASSWORD=%q\n' "$db_root_password"
    printf 'PHP_CONTAINER=%q\n' "$php_container"
    printf 'NODE_CONTAINER=%q\n' ""
    printf 'DB_CONTAINER=%q\n' "$db_container"
    printf 'REDIS_CONTAINER=%q\n' "$redis_container"
    printf 'APP_DIR=%q\n' "$app_dir"
    printf 'PMA_PORT=%q\n' "$pma_port"
    printf 'PMA_BIND_IP=%q\n' "$pma_bind_ip"
    printf 'REVERB_ENABLED=%q\n' "$reverb_enabled"
    printf 'REVERB_DOMAIN=%q\n' "$reverb_domain"
    printf 'REVERB_PORT=%q\n' "$reverb_port"
    printf 'REVERB_EXPOSURE=%q\n' "$reverb_exposure"
    printf 'GUACAMOLE_PROXY_ENABLED=%q\n' "$guacamole_proxy_enabled"
    printf 'GUACAMOLE_PROXY_UPSTREAM=%q\n' "$guacamole_proxy_upstream"
    printf 'APP_PROFILE=%q\n' "$app_profile"
    printf 'SERVER_RAM_MB=%q\n' "$RAM_MB"
    printf 'SERVER_CPU_CORES=%q\n' "$CPU_CORES"
    printf 'SERVER_CAPACITY_PROFILE=%q\n' "$PROFILE_NAME"
    printf 'PROJECT_TUNING_MODE=%q\n' "${PROJECT_TUNING_MODE:-auto}"
    printf 'PROJECT_TUNING_PRESET=%q\n' "${PROJECT_TUNING_PRESET:-}"
    printf 'PHP_FPM_CHILDREN=%q\n' "$PHP_FPM_CHILDREN"
    printf 'PHP_FPM_START_SERVERS=%q\n' "$PHP_FPM_START_SERVERS"
    printf 'PHP_FPM_MIN_SPARE_SERVERS=%q\n' "$PHP_FPM_MIN_SPARE_SERVERS"
    printf 'PHP_FPM_MAX_SPARE_SERVERS=%q\n' "$PHP_FPM_MAX_SPARE_SERVERS"
    printf 'OPCACHE_MEMORY=%q\n' "$OPCACHE_MEMORY"
    printf 'REDIS_MEMORY=%q\n' "$REDIS_MEMORY"
    printf 'MYSQL_BUFFER=%q\n' "$MYSQL_BUFFER"
    printf 'MYSQL_MAX_CONNECTIONS=%q\n' "$MYSQL_MAX_CONNECTIONS"
    printf 'BACKUP_RETENTION_DAYS=%q\n' "$backup_retention_days"
    printf 'BACKUP_INTERVAL_HOURS=%q\n' "$backup_interval_hours"
    printf 'BACKUP_CLOUD_ENABLED=%q\n' "$backup_cloud_enabled"
    printf 'BACKUP_CLOUD_SCOPE=%q\n' "$backup_cloud_scope"
    printf 'BACKUP_CLOUD_RETENTION_ENABLED=%q\n' "$backup_cloud_retention_enabled"
    printf 'BACKUP_CLOUD_PROVIDER=%q\n' "$backup_cloud_provider"
    printf 'BACKUP_CLOUD_REMOTE=%q\n' "$backup_cloud_remote"
    printf 'BACKUP_CLOUD_FOLDER=%q\n' "$backup_cloud_folder"
    printf 'UFW_PMA_ALLOWED_SOURCES=%q\n' "$ufw_pma_allowed_sources"
    printf 'UFW_PMA_RESTRICTED=%q\n' "$ufw_pma_restricted"
    printf 'UFW_PMA_PORT=%q\n' "$ufw_pma_port"
    printf 'PROJECT_ACCESS_ALLOWED_SOURCES=%q\n' "$project_access_allowed_sources"
    printf 'PROJECT_ACCESS_RESTRICTED=%q\n' "$project_access_restricted"
    printf 'LARAVEL_QUEUE_CONNECTION=%q\n' "$laravel_queue_connection"
    printf 'LARAVEL_QUEUE_NAMES=%q\n' "$laravel_queue_names"
    printf 'LARAVEL_QUEUE_SLEEP=%q\n' "$laravel_queue_sleep"
    printf 'LARAVEL_QUEUE_TRIES=%q\n' "$laravel_queue_tries"
    printf 'LARAVEL_QUEUE_TIMEOUT=%q\n' "$laravel_queue_timeout"
    printf 'LARAVEL_QUEUE_MAX_TIME=%q\n' "$laravel_queue_max_time"
  } > "${app_dir}/.project-meta"

  apply_project_permissions "$app_dir" "$app_profile"
}

write_proxy_config_http() {
  local project_name="$1"
  local domain="$2"
  local config_file="${3:-${PROXY_CONF_DIR}/${project_name}.conf}"
  local php_container="${project_name}-php"
  local node_container="${project_name}-node"
  local app_dir
  local docroot
  local app_profile
  local guacamole_proxy_enabled="no"
  local guacamole_proxy_upstream="$GUACAMOLE_DEFAULT_UPSTREAM"
  local guacamole_proxy_block=""
  local project_access_allowed_sources project_access_restricted project_access_block

  app_dir="$(resolve_project_dir "$project_name")"
  app_profile="$(detect_project_profile "$app_dir")"
  project_access_allowed_sources="$(read_project_access_allowed_sources "$app_dir")"
  project_access_restricted="$(read_project_access_restricted "$app_dir")"
  project_access_block="$(build_nginx_access_block "$project_access_allowed_sources" "$project_access_restricted" "        ")"
  if [ -f "${app_dir}/.project-meta" ]; then
    guacamole_proxy_enabled="$(
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${app_dir}/.project-meta" >/dev/null 2>&1
      printf '%s' "${GUACAMOLE_PROXY_ENABLED:-no}"
    )"
    guacamole_proxy_upstream="$(
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${app_dir}/.project-meta" >/dev/null 2>&1
      printf '%s' "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}"
    )"
    guacamole_proxy_upstream="$(normalize_guacamole_upstream "$guacamole_proxy_upstream")"
  fi
  guacamole_proxy_block="$(build_guacamole_proxy_block "$guacamole_proxy_enabled" "$guacamole_proxy_upstream" "$project_access_block")"

  if [ "$app_profile" = "node" ]; then
    cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${domain};

    client_max_body_size 5G;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

${guacamole_proxy_block}    location /ws/ {
${project_access_block}
        proxy_pass http://${node_container}:3533;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
${project_access_block}
        proxy_pass http://${node_container}:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
    return 0
  fi

  docroot="$(project_container_docroot "$project_name" "$app_dir")"

  cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${domain};

    root ${docroot};
    index index.php index.html;
    client_max_body_size 5G;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

${guacamole_proxy_block}    location / {
${project_access_block}
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php(?:/|$) {
${project_access_block}
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_pass ${php_container}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME ${docroot}\$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT ${docroot};
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 600s;
        fastcgi_send_timeout 600s;
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
  local config_file="${3:-${PROXY_CONF_DIR}/${project_name}.conf}"
  local php_container="${project_name}-php"
  local node_container="${project_name}-node"
  local app_dir
  local docroot
  local app_profile
  local guacamole_proxy_enabled="no"
  local guacamole_proxy_upstream="$GUACAMOLE_DEFAULT_UPSTREAM"
  local guacamole_proxy_block=""
  local project_access_allowed_sources project_access_restricted project_access_block

  app_dir="$(resolve_project_dir "$project_name")"
  app_profile="$(detect_project_profile "$app_dir")"
  project_access_allowed_sources="$(read_project_access_allowed_sources "$app_dir")"
  project_access_restricted="$(read_project_access_restricted "$app_dir")"
  project_access_block="$(build_nginx_access_block "$project_access_allowed_sources" "$project_access_restricted" "        ")"
  if [ -f "${app_dir}/.project-meta" ]; then
    guacamole_proxy_enabled="$(
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${app_dir}/.project-meta" >/dev/null 2>&1
      printf '%s' "${GUACAMOLE_PROXY_ENABLED:-no}"
    )"
    guacamole_proxy_upstream="$(
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${app_dir}/.project-meta" >/dev/null 2>&1
      printf '%s' "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}"
    )"
    guacamole_proxy_upstream="$(normalize_guacamole_upstream "$guacamole_proxy_upstream")"
  fi
  guacamole_proxy_block="$(build_guacamole_proxy_block "$guacamole_proxy_enabled" "$guacamole_proxy_upstream" "$project_access_block")"

  if [ "$app_profile" = "node" ]; then
    cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location = /guacamole {
${project_access_block}
        return 301 https://\$host/guacamole/;
    }

    location / {
${project_access_block}
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    client_max_body_size 5G;

${guacamole_proxy_block}    location /ws/ {
${project_access_block}
        proxy_pass http://${node_container}:3533;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
${project_access_block}
        proxy_pass http://${node_container}:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
    return 0
  fi

  docroot="$(project_container_docroot "$project_name" "$app_dir")"

  cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location = /guacamole {
${project_access_block}
        return 301 https://\$host/guacamole/;
    }

    location / {
${project_access_block}
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    root ${docroot};
    index index.php index.html;
    client_max_body_size 5G;

${guacamole_proxy_block}    location / {
${project_access_block}
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php(?:/|$) {
${project_access_block}
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_pass ${php_container}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME ${docroot}\$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT ${docroot};
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 600s;
        fastcgi_send_timeout 600s;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
}

project_has_https_certificate() {
  local domain="$1"
  [ -f "${PROXY_CERTBOT_CONF}/live/${domain}/fullchain.pem" ] \
    && [ -f "${PROXY_CERTBOT_CONF}/live/${domain}/privkey.pem" ]
}

normalize_project_domain_list() {
  local primary="$1"
  local configured="${2:-}"
  local normalized result part

  primary="$(normalize_domain "$primary")"
  validate_domain "$primary" || return 1

  normalized="$(normalize_domain_csv "${configured:-$primary}")"
  result="$primary"

  IFS=',' read -r -a parts <<< "$normalized"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    validate_domain "$part" || return 1
    if [ "$part" != "$primary" ] && ! csv_contains_value "$result" "$part"; then
      result="${result},${part}"
    fi
  done

  printf '%s' "$result"
}

project_domains_for_project() {
  local app_dir="$1"
  local primary="$2"
  local configured

  configured="$(read_project_meta_var "$app_dir" "PROJECT_DOMAINS")"
  normalize_project_domain_list "$primary" "$configured" 2>/dev/null || echo "$primary"
}

project_alias_proxy_config_file() {
  local project_name="$1"
  local domain="$2"
  echo "${PROXY_CONF_DIR}/${project_name}-alias-$(safe_domain_name "$domain").conf"
}

project_domain_proxy_config_file() {
  local project_name="$1"
  local domain="$2"
  local primary_domain="$3"

  if [ "$domain" = "$primary_domain" ]; then
    echo "${PROXY_CONF_DIR}/${project_name}.conf"
  else
    project_alias_proxy_config_file "$project_name" "$domain"
  fi
}

remove_stale_project_alias_proxy_configs() {
  local project_name="$1"
  local domains="$2"
  local primary_domain expected="" domain file base expected_file

  primary_domain="$(csv_first_value "$domains")"
  IFS=',' read -r -a parts <<< "$domains"
  for domain in "${parts[@]}"; do
    [ -n "$domain" ] || continue
    [ "$domain" != "$primary_domain" ] || continue
    expected_file="$(basename "$(project_alias_proxy_config_file "$project_name" "$domain")")"
    expected="${expected} ${expected_file}"
  done

  for file in "${PROXY_CONF_DIR}/${project_name}-alias-"*.conf; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    if [[ " ${expected} " != *" ${base} "* ]]; then
      rm -f "$file"
    fi
  done
}

write_project_domain_proxy_config() {
  local project_name="$1"
  local domain="$2"
  local primary_domain="$3"
  local config_file

  config_file="$(project_domain_proxy_config_file "$project_name" "$domain" "$primary_domain")"
  if project_has_https_certificate "$domain"; then
    write_proxy_config_https "$project_name" "$domain" "$config_file"
  else
    write_proxy_config_http "$project_name" "$domain" "$config_file"
  fi
}

write_project_proxy_configs() {
  local project_name="$1"
  local domains="$2"
  local primary_domain domain

  primary_domain="$(csv_first_value "$domains")"
  domains="$(normalize_project_domain_list "$primary_domain" "$domains")"
  primary_domain="$(csv_first_value "$domains")"

  remove_stale_project_alias_proxy_configs "$project_name" "$domains"

  IFS=',' read -r -a parts <<< "$domains"
  for domain in "${parts[@]}"; do
    [ -n "$domain" ] || continue
    write_project_domain_proxy_config "$project_name" "$domain" "$primary_domain"
  done
}

issue_project_domain_certificate() {
  local project_name="$1"
  local domain="$2"
  local email="$3"
  local primary_domain="$4"
  local config_file

  config_file="$(project_domain_proxy_config_file "$project_name" "$domain" "$primary_domain")"

  echo "Switching ${domain} to HTTP for certificate issuance..."
  write_proxy_config_http "$project_name" "$domain" "$config_file"
  proxy_dc restart reverse-proxy

  echo "Requesting SSL certificate for ${domain}..."
  if ! proxy_dc run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$domain"; then
    return 1
  fi

  echo "Enabling HTTPS for ${domain}..."
  write_proxy_config_https "$project_name" "$domain" "$config_file"
}

remove_project_certificate_files() {
  local domain="$1"

  rm -rf "${PROXY_CERTBOT_CONF}/live/${domain}" || true
  rm -rf "${PROXY_CERTBOT_CONF}/archive/${domain}" || true
  rm -rf "${PROXY_CERTBOT_CONF}/renewal/${domain}.conf" || true
}

remove_project_domain_proxy_config() {
  local project_name="$1"
  local domain="$2"
  local primary_domain="$3"
  local config_file

  config_file="$(project_domain_proxy_config_file "$project_name" "$domain" "$primary_domain")"
  rm -f "$config_file" || true
}

project_domain_list_remove() {
  local domains="$1"
  local remove_domain="$2"
  local result="" domain

  IFS=',' read -r -a parts <<< "$domains"
  for domain in "${parts[@]}"; do
    [ -n "$domain" ] || continue
    [ "$domain" != "$remove_domain" ] || continue
    if [ -z "$result" ]; then
      result="$domain"
    else
      result="${result},${domain}"
    fi
  done

  printf '%s' "$result"
}

regenerate_project_proxy_config() {
  local project_name="$1"
  local domain="$2"
  local app_dir domains

  app_dir="$(resolve_project_dir "$project_name")"
  domains="$(project_domains_for_project "$app_dir" "$domain")"
  write_project_proxy_configs "$project_name" "$domains"

  proxy_dc restart reverse-proxy
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

    client_max_body_size 5G;

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

print_project_env_template() {
  local app_profile="$1"
  local db_name="$2"
  local db_user="$3"

  case "$app_profile" in
    node)
      echo "NODE GAME PROFILE"
      echo "--------------------------------------------------------------"
      echo "Upload the game files so server.js and package.json are in the project root."
      echo "The container runs: npm install --omit=dev && node server.js"
      echo "The reverse proxy publishes HTTPS traffic to HTTP_PORT=8080 and /ws/ to WS_PORT=3533."
      echo "Game user data is stored at data/users.txt inside the project folder."
      echo "--------------------------------------------------------------"
      ;;
    thinkphp-fastadmin)
      echo "CONFIGURE YOUR ThinkPHP .env LIKE THIS:"
      echo "--------------------------------------------------------------"
      echo "[app]"
      echo "debug = false"
      echo "trace = false"
      echo ""
      echo "[database]"
      echo "type = mysql"
      echo "hostname = mariadb"
      echo "database = ${db_name}"
      echo "username = ${db_user}"
      echo "password = *****"
      echo "hostport = 3306"
      echo "charset = utf8mb4"
      echo "prefix = b_"
      echo "debug = false"
      echo ""
      echo "[redis]"
      echo "host = redis"
      echo "port = 6379"
      echo "password = Yunbao123"
      echo "--------------------------------------------------------------"
      echo "Import the project SQL after upload, for example:"
      echo "docker exec -i <project>-db sh -c \"exec mariadb -u root -p'<root-password>' '${db_name}'\" < xianxian.sql"
      ;;
    *)
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
      ;;
  esac
}

print_reverb_env_block() {
  local reverb_exposure="$1"
  local reverb_domain="$2"
  local reverb_port="$3"

  echo "Use this Laravel env block:"
  echo "--------------------------------------------------------------"
  echo "REVERB_SERVER_HOST=0.0.0.0"
  echo "REVERB_SERVER_PORT=${reverb_port}"
  echo ""
  if [ "$reverb_exposure" = "public" ]; then
    echo "REVERB_HOST=${reverb_domain}"
    echo "REVERB_PORT=443"
    echo "REVERB_SCHEME=https"
  else
    echo "REVERB_HOST=127.0.0.1"
    echo "REVERB_PORT=${reverb_port}"
    echo "REVERB_SCHEME=http"
  fi
  echo "--------------------------------------------------------------"
}

print_reverb_runtime_diagnostics() {
  local project_name="$1"
  local reverb_port="$2"
  local reverb_domain="${3:-}"
  local app_dir artisan_rel artisan_path
  local php_container="${project_name}-php"
  local vhost_conf="${PROXY_CONF_DIR}/reverb-${project_name}.conf"

  app_dir="$(resolve_project_dir "$project_name")"
  artisan_rel="$(detect_project_artisan_rel "$app_dir" || true)"
  artisan_path="/var/www/artisan"
  if [ -n "$artisan_rel" ]; then
    artisan_path="/var/www/${artisan_rel}"
  fi

  echo ""
  echo "Runtime diagnostics"
  echo "--------------------------------------------------------------"

  if [ -f "$vhost_conf" ]; then
    echo "Proxy vhost: ${vhost_conf}"
    grep -E 'server_name|proxy_pass' "$vhost_conf" || true
  else
    echo "Proxy vhost not found: ${vhost_conf}"
  fi

  if ! docker_container_exists "$php_container"; then
    echo "PHP container not found: ${php_container}"
    echo "--------------------------------------------------------------"
    return 1
  fi

  echo ""
  echo "PHP container: ${php_container}"

  echo ""
  echo "Artisan: ${artisan_path}"

  echo ""
  echo "Supervisor status:"
  if docker exec "$php_container" supervisorctl -c /etc/supervisord.conf status laravel-reverb >/dev/null 2>&1; then
    docker exec "$php_container" supervisorctl -c /etc/supervisord.conf status laravel-reverb || true
  else
    echo "Unable to query supervisor program status (supervisorctl failed)."
    echo "Tip: rebuild the PHP container so supervisord.conf includes a unix socket for supervisorctl."
  fi

  echo ""
  echo "Reverb command availability:"
  if docker exec "$php_container" sh -c "php ${artisan_path} reverb:start --help >/dev/null 2>&1"; then
    echo "OK: artisan reverb:start exists"
  else
    echo "FAIL: artisan reverb:start not available"
    echo "Tip: install Reverb in the app: composer require laravel/reverb && php artisan reverb:install"
  fi

  echo ""
  echo "Internal HTTP health check:"
  if docker exec "$php_container" sh -c "curl -fsS --max-time 3 http://127.0.0.1:${reverb_port}/up >/dev/null"; then
    echo "OK: http://127.0.0.1:${reverb_port}/up"
  else
    echo "FAIL: http://127.0.0.1:${reverb_port}/up"
    echo "Tip: docker logs ${php_container} --tail 200"
  fi

  if [ -n "$reverb_domain" ]; then
    echo ""
    echo "External proxy check (from host):"
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS --max-time 5 "https://${reverb_domain}/up" >/dev/null; then
        echo "OK: https://${reverb_domain}/up"
      else
        echo "FAIL: https://${reverb_domain}/up"
        echo "Tip: docker logs laravel-reverse-proxy --tail 200"
      fi
    else
      echo "curl not found on host."
    fi
  fi

  echo "--------------------------------------------------------------"
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
  local cron_line="30 * * * * /usr/bin/flock -n /run/lock/laravel-manager-backup.lock ${cron_cmd} backup-due >>/var/log/laravel-backup.log 2>&1"
  (crontab -l 2>/dev/null || true) \
    | awk -v add="$cron_line" 'index($0," backup-all >/var/log/laravel-backup.log")==0 && index($0," backup-due >>/var/log/laravel-backup.log")==0 {print} END{print add}' \
    | crontab -
}

laravel_scheduler_cron_line_for_project() {
  local project_name="$1"
  local php_container="$2"
  local artisan_rel="$3"
  local docker_bin="${4:-/usr/bin/docker}"
  local artisan_dir_rel container_workdir

  artisan_dir_rel="$(dirname "$artisan_rel")"
  if [ "$artisan_dir_rel" = "." ]; then
    container_workdir="/var/www"
  else
    container_workdir="/var/www/${artisan_dir_rel}"
  fi

  printf '* * * * * %s exec -w %s %s php artisan schedule:run >> /var/log/laravel-scheduler-%s.log 2>&1 # laravel-manager scheduler %s\n' \
    "$docker_bin" \
    "$container_workdir" \
    "$php_container" \
    "$project_name" \
    "$project_name"
}

setup_laravel_scheduler_crons() {
  local docker_bin tmp generated_tmp meta_file count

  docker_bin="$(command -v docker 2>/dev/null || true)"
  docker_bin="${docker_bin:-/usr/bin/docker}"
  tmp="$(mktemp)"
  generated_tmp="$(mktemp)"

  (crontab -l 2>/dev/null || true) \
    | awk 'index($0,"# laravel-manager scheduler ")==0 && $0 !~ /# [[:alnum:]_.-]+ laravel scheduler$/ {print}' \
    > "$tmp"

  for meta_file in "$PROJECTS_BASE"/*/.project-meta; do
    [ -f "$meta_file" ] || continue

    (
      set +u
      PROJECT_NAME=""
      PHP_CONTAINER=""
      APP_DIR=""
      APP_PROFILE=""

      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "$meta_file" >/dev/null 2>&1 || exit 0

      project_name="${PROJECT_NAME:-$(basename "$(dirname "$meta_file")")}"
      app_dir="${APP_DIR:-$(dirname "$meta_file")}"
      if [ -n "${APP_PROFILE:-}" ]; then
        app_profile="$(normalize_project_profile "$APP_PROFILE" 2>/dev/null || true)"
      else
        app_profile="$(detect_project_profile "$app_dir" 2>/dev/null || true)"
      fi

      [ "$app_profile" = "laravel" ] || exit 0

      artisan_rel="$(detect_project_artisan_rel "$app_dir" 2>/dev/null || true)"
      [ -n "$artisan_rel" ] || exit 0

      php_container="${PHP_CONTAINER:-${project_name}-php}"
      [ -n "$php_container" ] || exit 0

      laravel_scheduler_cron_line_for_project "$project_name" "$php_container" "$artisan_rel" "$docker_bin"
    ) >> "$generated_tmp"
  done

  if [ -s "$generated_tmp" ]; then
    cat "$generated_tmp" >> "$tmp"
  fi

  crontab "$tmp"
  count="$(wc -l < "$generated_tmp" | tr -d '[:space:]')"
  rm -f "$tmp" "$generated_tmp"

  echo "Laravel scheduler cron jobs installed/updated: ${count:-0} project(s)."
}

ensure_cron_jobs() {
  setup_ssl_renew_cron
  setup_backup_cron
  setup_laravel_scheduler_crons
  setup_ai_backup_cron
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

    client_max_body_size 5G;

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
  local password_change_enabled="${4:-no}"
  local managesieve_enabled="${5:-no}"

  mkdir -p "$WEBMAIL_BASE"
  {
    printf 'WEBMAIL_PRIMARY_DOMAIN=%q\n' "$webmail_domain"
    printf 'WEBMAIL_DOMAIN=%q\n' "$webmail_domain"
    printf 'WEBMAIL_DOMAINS=%q\n' "$webmail_domains"
    printf 'MAIL_HOST=%q\n' "$mail_host"
    printf 'WEBMAIL_PASSWORD_CHANGE_ENABLED=%q\n' "$password_change_enabled"
    printf 'WEBMAIL_MANAGESIEVE_ENABLED=%q\n' "$managesieve_enabled"
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
  local domain server_ip

  server_ip="$(detect_server_ip)"

  IFS=',' read -r -a domains <<< "$webmail_domains"
  for domain in "${domains[@]}"; do
    echo "  ${domain} -> ${server_ip}"
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

generate_secret_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi

  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

normalize_email_address() {
  local email="${1:-}"
  email="${email//[$'\t\r\n ']/}"
  email="${email,,}"
  printf '%s' "$email"
}

validate_email_address() {
  local email="${1:-}"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

normalize_email_csv() {
  local input="${1:-}"
  local part email result=""
  local -A seen=()
  local -a parts=()

  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    email="$(normalize_email_address "$part")"
    [ -n "$email" ] || continue
    if ! validate_email_address "$email"; then
      return 1
    fi
    if [ -z "${seen[$email]+x}" ]; then
      seen[$email]=1
      result="${result:+${result},}${email}"
    fi
  done

  [ -n "$result" ] || return 1
  echo "$result"
}

ensure_webmail_force_password_state_file() {
  mkdir -p "$(dirname "$WEBMAIL_PASSWORD_FORCE_STATE_FILE")"
  touch "$WEBMAIL_PASSWORD_FORCE_STATE_FILE"
  chmod 0664 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
  chown 33:33 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
}

webmail_force_password_mark() {
  local email
  email="$(normalize_email_address "${1:-}")"

  if ! validate_email_address "$email"; then
    echo "Invalid email address: ${email}"
    return 1
  fi

  ensure_webmail_force_password_state_file
  if grep -Fxiq "$email" "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" 2>/dev/null; then
    echo "Already marked for password change: ${email}"
    return 0
  fi

  printf '%s\n' "$email" >> "$WEBMAIL_PASSWORD_FORCE_STATE_FILE"
  chmod 0664 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
  chown 33:33 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
  echo "Marked for password change at next Roundcube login: ${email}"
}

webmail_force_password_clear() {
  local email tmp_file
  email="$(normalize_email_address "${1:-}")"

  if ! validate_email_address "$email"; then
    echo "Invalid email address: ${email}"
    return 1
  fi

  ensure_webmail_force_password_state_file
  tmp_file="$(mktemp)"
  awk -v target="$email" '
    BEGIN { removed = 0 }
    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (tolower(line) == target) {
        removed = 1
        next
      }
      print
    }
    END { exit removed ? 0 : 2 }
  ' "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" > "$tmp_file" || {
    local status=$?
    if [ "$status" -eq 2 ]; then
      mv "$tmp_file" "$WEBMAIL_PASSWORD_FORCE_STATE_FILE"
      chmod 0664 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
      chown 33:33 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
      echo "User was not marked: ${email}"
      return 0
    fi
    rm -f "$tmp_file"
    return "$status"
  }

  mv "$tmp_file" "$WEBMAIL_PASSWORD_FORCE_STATE_FILE"
  chmod 0664 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
  chown 33:33 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
  echo "Cleared forced password change for: ${email}"
}

webmail_force_password_list() {
  ensure_webmail_force_password_state_file
  awk '
    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "" && line !~ /^#/) {
        print tolower(line)
      }
    }
  ' "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" | sort -fu
}

mailbox_addresses() {
  local accounts_file="${MAIL_BASE}/docker-data/dms/config/postfix-accounts.cf"

  if [ -f "$accounts_file" ]; then
    awk -F'|' '
      /^[[:space:]]*#/ { next }
      NF >= 2 {
        account = $1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", account)
        if (account != "") {
          print tolower(account)
        }
      }
    ' "$accounts_file" | sort -fu
    return 0
  fi

  docker exec mailserver setup email list 2>/dev/null \
    | awk '/@/ {print tolower($1)}' \
    | sort -fu
}

mailbox_exists() {
  local email
  email="$(normalize_email_address "${1:-}")"
  validate_email_address "$email" || return 1
  mailbox_addresses | grep -Fxiq "$email"
}

mailbox_host_home_dir() {
  local email local_part domain
  email="$(normalize_email_address "${1:-}")"
  local_part="${email%@*}"
  domain="${email#*@}"
  printf '%s/docker-data/dms/mail-data/%s/%s/home' "$MAIL_BASE" "$domain" "$local_part"
}

mailbox_container_home_dir() {
  local email local_part domain
  email="$(normalize_email_address "${1:-}")"
  local_part="${email%@*}"
  domain="${email#*@}"
  printf '/var/mail/%s/%s/home' "$domain" "$local_part"
}

reload_mailserver_postfix() {
  docker exec mailserver postfix reload >/dev/null 2>&1 || true
}

reload_mailserver_dovecot() {
  docker exec mailserver doveadm reload >/dev/null 2>&1 || true
}

mail_alias_recipients() {
  local alias_addr="$1"
  alias_addr="$(normalize_email_address "$alias_addr")"

  [ -f "$MAIL_VIRTUAL_FILE" ] || return 1
  awk -v alias="$alias_addr" '
    /^[[:space:]]*#/ { next }
    NF >= 2 {
      key = tolower($1)
      if (key == alias) {
        $1 = ""
        gsub(/^[[:space:]]+/, "", $0)
        print tolower($0)
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$MAIL_VIRTUAL_FILE"
}

list_mail_aliases() {
  local alias_output

  if [ ! -s "$MAIL_VIRTUAL_FILE" ]; then
    echo "No mail aliases configured."
    return 0
  fi

  alias_output="$(
    awk '
    /^[[:space:]]*#/ { next }
    NF >= 2 {
      key = $1
      $1 = ""
      gsub(/^[[:space:]]+/, "", $0)
      printf "%s -> %s\n", tolower(key), tolower($0)
    }
    ' "$MAIL_VIRTUAL_FILE" | sort -fu
  )"

  if [ -n "$alias_output" ]; then
    echo "$alias_output"
  else
    echo "No mail aliases configured."
  fi
}

add_mail_alias() {
  local alias_addr="$1"
  local recipients_csv="$2"
  local recipient
  local -a recipients=()

  alias_addr="$(normalize_email_address "$alias_addr")"
  recipients_csv="$(normalize_email_csv "$recipients_csv")" || {
    echo "Invalid recipient list."
    return 1
  }

  if ! validate_email_address "$alias_addr"; then
    echo "Invalid alias address: ${alias_addr}"
    return 1
  fi

  if mailbox_exists "$alias_addr"; then
    echo "Alias source is already a real mailbox: ${alias_addr}"
    echo "Use mailbox forwarding for existing mailboxes."
    return 1
  fi

  IFS=',' read -r -a recipients <<< "$recipients_csv"
  for recipient in "${recipients[@]}"; do
    recipient="$(normalize_email_address "$recipient")"
    if [ "$recipient" = "$alias_addr" ]; then
      echo "Alias recipient cannot be the alias itself: ${recipient}"
      return 1
    fi
    docker exec -i mailserver setup alias add "$alias_addr" "$recipient"
  done

  reload_mailserver_postfix
  echo "Alias configured: ${alias_addr} -> ${recipients_csv}"
}

delete_mail_alias() {
  local alias_addr="$1"
  local recipients_csv="${2:-}"
  local existing_recipients recipient
  local -a recipients=()

  alias_addr="$(normalize_email_address "$alias_addr")"
  if ! validate_email_address "$alias_addr"; then
    echo "Invalid alias address: ${alias_addr}"
    return 1
  fi

  if [ -z "$recipients_csv" ]; then
    existing_recipients="$(mail_alias_recipients "$alias_addr" 2>/dev/null || true)"
    if [ -z "$existing_recipients" ]; then
      echo "Alias not found: ${alias_addr}"
      return 1
    fi
    recipients_csv="$existing_recipients"
  else
    recipients_csv="$(normalize_email_csv "$recipients_csv")" || {
      echo "Invalid recipient list."
      return 1
    }
  fi

  IFS=',' read -r -a recipients <<< "$recipients_csv"
  for recipient in "${recipients[@]}"; do
    recipient="$(normalize_email_address "$recipient")"
    [ -n "$recipient" ] || continue
    docker exec -i mailserver setup alias del "$alias_addr" "$recipient" >/dev/null 2>&1 || true
  done

  reload_mailserver_postfix
  echo "Alias recipient(s) removed for: ${alias_addr}"
}

mailbox_forward_sieve_host_path() {
  local email home_dir
  email="$(normalize_email_address "${1:-}")"
  home_dir="$(mailbox_host_home_dir "$email")"
  printf '%s/sieve/managesieve.sieve' "$home_dir"
}

mailbox_forward_sieve_container_path() {
  local email home_dir
  email="$(normalize_email_address "${1:-}")"
  home_dir="$(mailbox_container_home_dir "$email")"
  printf '%s/sieve/managesieve.sieve' "$home_dir"
}

list_mailbox_forwards() {
  local email sieve_file recipients keep_copy

  while IFS= read -r email; do
    [ -n "$email" ] || continue
    sieve_file="$(mailbox_forward_sieve_host_path "$email")"
    [ -f "$sieve_file" ] || continue
    grep -q "Managed by laravel-server-manager mailbox forwarding" "$sieve_file" || continue
    recipients="$(
      sed -n 's/^[[:space:]]*redirect[[:space:]][^"]*"\([^"]*\)".*/\1/p' "$sieve_file" \
        | paste -sd ',' -
    )"
    [ -n "$recipients" ] || continue
    keep_copy="no"
    if grep -q '^[[:space:]]*redirect[[:space:]]*:copy' "$sieve_file"; then
      keep_copy="yes"
    fi
    printf '%s -> %s (keep copy: %s)\n' "$email" "$recipients" "$keep_copy"
  done < <(mailbox_addresses)
}

set_mailbox_forward() {
  local email="$1"
  local recipients_csv="$2"
  local keep_copy="${3:-yes}"
  local recipient home_dir sieve_dir sieve_file active_link container_sieve
  local -a recipients=()

  email="$(normalize_email_address "$email")"
  recipients_csv="$(normalize_email_csv "$recipients_csv")" || {
    echo "Invalid recipient list."
    return 1
  }

  if ! mailbox_exists "$email"; then
    echo "Mailbox not found: ${email}"
    return 1
  fi

  keep_copy="${keep_copy,,}"
  case "$keep_copy" in
    yes|no) ;;
    *) echo "Invalid keep-copy value. Use yes or no."; return 1 ;;
  esac

  IFS=',' read -r -a recipients <<< "$recipients_csv"
  for recipient in "${recipients[@]}"; do
    recipient="$(normalize_email_address "$recipient")"
    if [ "$recipient" = "$email" ]; then
      echo "Forward recipient cannot be the source mailbox itself: ${recipient}"
      return 1
    fi
  done

  home_dir="$(mailbox_host_home_dir "$email")"
  sieve_dir="${home_dir}/sieve"
  sieve_file="$(mailbox_forward_sieve_host_path "$email")"
  active_link="${home_dir}/.dovecot.sieve"
  container_sieve="$(mailbox_forward_sieve_container_path "$email")"

  mkdir -p "$sieve_dir"
  {
    echo "# Managed by laravel-server-manager mailbox forwarding."
    echo "# Changes made in Roundcube filters can replace this script."
    if [ "$keep_copy" = "yes" ]; then
      echo 'require ["copy"];'
    fi
    for recipient in "${recipients[@]}"; do
      recipient="$(normalize_email_address "$recipient")"
      if [ "$keep_copy" = "yes" ]; then
        printf 'redirect :copy "%s";\n' "$recipient"
      else
        printf 'redirect "%s";\n' "$recipient"
      fi
    done
    echo "stop;"
  } > "$sieve_file"

  ln -sfn "sieve/managesieve.sieve" "$active_link"
  chown -R 5000:5000 "$home_dir" >/dev/null 2>&1 || true
  chmod 0700 "$home_dir" "$sieve_dir" >/dev/null 2>&1 || true
  chmod 0600 "$sieve_file" "$active_link" >/dev/null 2>&1 || true

  docker exec mailserver sievec "$container_sieve" >/dev/null
  chown -R 5000:5000 "$home_dir" >/dev/null 2>&1 || true
  reload_mailserver_dovecot

  echo "Mailbox forward configured: ${email} -> ${recipients_csv} (keep copy: ${keep_copy})"
}

clear_mailbox_forward() {
  local email="$1"
  local home_dir sieve_file active_link compiled_file link_target

  email="$(normalize_email_address "$email")"
  if ! validate_email_address "$email"; then
    echo "Invalid mailbox address: ${email}"
    return 1
  fi

  home_dir="$(mailbox_host_home_dir "$email")"
  sieve_file="$(mailbox_forward_sieve_host_path "$email")"
  compiled_file="${sieve_file%.sieve}.svbin"
  active_link="${home_dir}/.dovecot.sieve"

  if [ -f "$sieve_file" ] && ! grep -q "Managed by laravel-server-manager mailbox forwarding" "$sieve_file"; then
    echo "Forward script is not managed by laravel-server-manager; leaving it in place:"
    echo "  ${sieve_file}"
    return 1
  fi

  if [ -L "$active_link" ]; then
    link_target="$(readlink "$active_link" || true)"
    if [ "$link_target" = "sieve/managesieve.sieve" ]; then
      rm -f "$active_link"
    fi
  fi

  rm -f "$sieve_file" "$compiled_file"
  reload_mailserver_dovecot
  echo "Managed mailbox forward cleared for: ${email}"
}

webmail_password_change_enabled() {
  load_current_webmail_settings >/dev/null 2>&1 || true
  [ "${WEBMAIL_CURRENT_PASSWORD_CHANGE_ENABLED:-no}" = "yes" ]
}

shared_network_subnet() {
  docker network inspect "$SHARED_NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -n 1
}

ensure_mailserver_fail2ban_ignores_shared_network() {
  local subnet backup roundcube_ip

  docker_container_exists mailserver || return 0

  subnet="$(shared_network_subnet || true)"
  if [ -z "$subnet" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$MAIL_FAIL2BAN_JAIL_FILE")"
  if [ -f "$MAIL_FAIL2BAN_JAIL_FILE" ] && ! grep -q "Managed by laravel-server-manager" "$MAIL_FAIL2BAN_JAIL_FILE"; then
    backup="${MAIL_FAIL2BAN_JAIL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$MAIL_FAIL2BAN_JAIL_FILE" "$backup"
    echo "Existing fail2ban jail override backed up to: ${backup}"
  fi

  cat > "$MAIL_FAIL2BAN_JAIL_FILE" <<EOF
# Managed by laravel-server-manager.
# Prevent one webmail login mistake from banning the shared Roundcube container IP.
[DEFAULT]
ignoreip = 127.0.0.1/8 ${subnet}
EOF
  chmod 0644 "$MAIL_FAIL2BAN_JAIL_FILE" >/dev/null 2>&1 || true

  if docker_container_running mailserver \
    && docker exec mailserver sh -lc 'command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1'; then
    docker exec mailserver sh -lc 'cp /tmp/docker-mailserver/fail2ban-jail.cf /etc/fail2ban/jail.d/user-jail.local && fail2ban-client reload' >/dev/null 2>&1 || true

    if docker_container_exists roundcube-webmail; then
      roundcube_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' roundcube-webmail 2>/dev/null || true)"
      if [ -n "$roundcube_ip" ]; then
        docker exec mailserver fail2ban-client set dovecot unbanip "$roundcube_ip" >/dev/null 2>&1 || true
        docker exec mailserver fail2ban-client set postfix unbanip "$roundcube_ip" >/dev/null 2>&1 || true
      fi
    fi
  fi
}

ensure_roundcube_password_change_files() {
  local token

  mkdir -p "$WEBMAIL_PASSWORD_HELPER_DIR" "$WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR" "$(dirname "$WEBMAIL_PASSWORD_CONFIG_FILE")"
  ensure_webmail_force_password_state_file

  if [ ! -f "$WEBMAIL_PASSWORD_TOKEN_FILE" ]; then
    umask 077
    generate_secret_token > "$WEBMAIL_PASSWORD_TOKEN_FILE"
  fi

  chmod 600 "$WEBMAIL_PASSWORD_TOKEN_FILE" >/dev/null 2>&1 || true
  token="$(cat "$WEBMAIL_PASSWORD_TOKEN_FILE")"

  cat > "${WEBMAIL_PASSWORD_HELPER_DIR}/password-helper.py" <<'PY'
#!/usr/bin/env python3
import fcntl
import hmac
import os
import re
import signal
import stat
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ACCOUNTS_FILE = os.environ.get("MAIL_ACCOUNTS_FILE", "/tmp/docker-mailserver/postfix-accounts.cf")
FORCE_CHANGE_FILE = os.environ.get("FORCE_PASSWORD_FILE", "/roundcube-config/force-password-change-users.txt")
TOKEN = os.environ.get("PASSWORD_HELPER_TOKEN", "")
MIN_LENGTH = int(os.environ.get("PASSWORD_MIN_LENGTH", "8"))
LISTEN_HOST = os.environ.get("PASSWORD_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("PASSWORD_LISTEN_PORT", "8080"))
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def run_doveadm(args):
    return subprocess.run(
        ["doveadm", "pw", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
        check=False,
    )


def verify_password(stored_hash, password):
    result = run_doveadm(["-t", stored_hash, "-p", password])
    return result.returncode == 0


def generate_hash(password):
    result = run_doveadm(["-s", "SHA512-CRYPT", "-p", password])
    if result.returncode != 0:
        raise RuntimeError("failed to generate password hash")

    generated = result.stdout.strip()
    if not generated.startswith("{SHA512-CRYPT}"):
        raise RuntimeError("unexpected password hash format")

    return generated


def read_accounts():
    with open(ACCOUNTS_FILE, "r", encoding="utf-8") as handle:
        return handle.readlines()


def find_account(lines, username):
    wanted = username.lower()
    for index, line in enumerate(lines):
        stripped = line.rstrip("\n")
        if not stripped or stripped.startswith("#") or "|" not in stripped:
            continue

        account, stored_hash = stripped.split("|", 1)
        if account.lower() == wanted:
            return index, account, stored_hash

    return None, None, None


def clear_force_change(username):
    wanted = username.lower()
    directory = os.path.dirname(FORCE_CHANGE_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    lock_path = FORCE_CHANGE_FILE + ".lock"

    with open(lock_path, "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        try:
            with open(FORCE_CHANGE_FILE, "r", encoding="utf-8") as handle:
                lines = handle.readlines()
        except FileNotFoundError:
            lines = []

        kept = []
        changed = False
        for line in lines:
            if line.strip().lower() == wanted:
                changed = True
                continue
            kept.append(line)

        if not changed:
            return

        with open(FORCE_CHANGE_FILE, "w", encoding="utf-8") as handle:
            handle.writelines(kept)
            handle.flush()
            os.fsync(handle.fileno())


def reload_mailserver_auth():
    process_name = os.environ.get("MAIL_RELOAD_PROCESS", "dovecot")
    signalled = False

    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue

        try:
            with open(f"/proc/{entry}/comm", "r", encoding="utf-8") as handle:
                comm = handle.read().strip()
        except OSError:
            continue

        if comm != process_name:
            continue

        os.kill(int(entry), signal.SIGHUP)
        signalled = True

    if not signalled:
        raise RuntimeError(f"{process_name} process not found for reload")


def update_account(username, current_password, new_password):
    lock_path = ACCOUNTS_FILE + ".lock"
    account = username

    with open(lock_path, "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        lines = read_accounts()
        index, account, stored_hash = find_account(lines, username)
        if index is None:
            return 404, "user not found"

        if not verify_password(stored_hash, current_password):
            return 401, "current password is invalid"

        new_hash = generate_hash(new_password)
        newline = "\n" if lines[index].endswith("\n") else ""
        lines[index] = f"{account}|{new_hash}{newline}"

        file_stat = os.stat(ACCOUNTS_FILE)
        directory = os.path.dirname(ACCOUNTS_FILE)
        fd, tmp_path = tempfile.mkstemp(prefix=".postfix-accounts.", dir=directory, text=True)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as tmp:
                tmp.writelines(lines)
                tmp.flush()
                os.fsync(tmp.fileno())

            os.chmod(tmp_path, stat.S_IMODE(file_stat.st_mode))
            os.chown(tmp_path, file_stat.st_uid, file_stat.st_gid)
            os.replace(tmp_path, ACCOUNTS_FILE)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    reload_mailserver_auth()

    try:
        clear_force_change(account)
    except Exception as exc:
        print(f"force password marker clear failed user={account}: {exc}", flush=True)

    return 200, "ok"


class Handler(BaseHTTPRequestHandler):
    server_version = "RoundcubePasswordHelper/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def write_plain(self, status, body):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if urlparse(self.path).path == "/health":
            self.write_plain(200, "ok")
            return
        self.write_plain(404, "not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/change":
            self.write_plain(404, "not found")
            return

        query_token = parse_qs(parsed.query).get("token", [""])[0]
        if not TOKEN or not hmac.compare_digest(query_token, TOKEN):
            self.write_plain(403, "forbidden")
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 16384:
            self.write_plain(400, "invalid request")
            return

        body = self.rfile.read(length).decode("utf-8", errors="replace")
        params = parse_qs(body, keep_blank_values=True)
        username = params.get("user", [""])[0].strip()
        current_password = params.get("curpass", [""])[0]
        new_password = params.get("newpass", [""])[0]

        if not EMAIL_RE.match(username):
            self.write_plain(400, "invalid user")
            return

        if len(new_password) < MIN_LENGTH:
            self.write_plain(400, "password too short")
            return

        if "\x00" in current_password or "\x00" in new_password:
            self.write_plain(400, "invalid password")
            return

        try:
            status, message = update_account(username, current_password, new_password)
        except Exception as exc:
            print(f"password change error user={username}: {exc}", flush=True)
            self.write_plain(500, "internal error")
            return

        if status == 200:
            print(f"password change success user={username}", flush=True)
            self.write_plain(200, "ok")
            return

        print(f"password change rejected user={username}: {message}", flush=True)
        self.write_plain(status, message)


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
PY

  chmod 755 "${WEBMAIL_PASSWORD_HELPER_DIR}/password-helper.py"

  cat > "$WEBMAIL_PASSWORD_CONFIG_FILE" <<EOF
<?php
\$config['password_driver'] = 'httpapi';
\$config['password_confirm_current'] = true;
\$config['password_minimum_length'] = 8;
\$config['password_log'] = false;
\$config['password_httpapi_url'] = 'http://roundcube-password-helper:8080/change?token=${token}';
\$config['password_httpapi_method'] = 'POST';
\$config['password_httpapi_var_user'] = 'user';
\$config['password_httpapi_var_curpass'] = 'curpass';
\$config['password_httpapi_var_newpass'] = 'newpass';
\$config['password_httpapi_expect'] = '/^ok$/i';
EOF

  chmod 0644 "$WEBMAIL_PASSWORD_CONFIG_FILE"

  cat > "${WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR}/config.inc.php" <<'PHP'
<?php
$config['force_password_change_state_file'] = '/var/roundcube/config/force-password-change-users.txt';
PHP

  cat > "${WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR}/force_password_change.php" <<'PHP'
<?php

class force_password_change extends rcube_plugin
{
    public $task = '.*';

    private $rc;

    public function init()
    {
        $this->rc = rcmail::get_instance();
        $this->load_config();

        $this->add_hook('login_after', [$this, 'login_after']);
        $this->add_hook('startup', [$this, 'startup']);
        $this->add_hook('password_change', [$this, 'password_change']);
    }

    public function login_after($args)
    {
        $username = $this->username();

        if ($username && $this->is_forced($username)) {
            $_SESSION['force_password_change'] = true;
        }
        else {
            unset($_SESSION['force_password_change']);
        }

        return $args;
    }

    public function startup($args)
    {
        if (empty($_SESSION['user_id'])) {
            return $args;
        }

        $username = $this->username();
        if (!$username) {
            return $args;
        }

        $forced = $this->is_forced($username);
        if ($forced) {
            $_SESSION['force_password_change'] = true;
        }
        else {
            unset($_SESSION['force_password_change']);
            return $args;
        }

        if (!$this->is_password_screen() && !$this->is_logout()) {
            $this->rc->output->redirect([
                '_task' => 'settings',
                '_action' => 'plugin.password',
                '_first' => 1,
                '_forced' => 1,
            ], 0);
        }

        return $args;
    }

    public function password_change($args)
    {
        $username = $this->username();
        if ($username) {
            $this->clear_forced($username);
        }

        unset($_SESSION['force_password_change']);

        return $args;
    }

    private function username()
    {
        if ($this->rc && $this->rc->user && !empty($this->rc->user->data['username'])) {
            return strtolower(trim($this->rc->user->data['username']));
        }

        if ($this->rc && method_exists($this->rc, 'get_user_name')) {
            $username = $this->rc->get_user_name();
            if ($username) {
                return strtolower(trim($username));
            }
        }

        return '';
    }

    private function is_password_screen()
    {
        return $this->rc->task === 'settings'
            && strpos((string) $this->rc->action, 'plugin.password') === 0;
    }

    private function is_logout()
    {
        return $this->rc->task === 'logout' || $this->rc->action === 'logout';
    }

    private function state_file()
    {
        return $this->rc->config->get('force_password_change_state_file', '/var/roundcube/config/force-password-change-users.txt');
    }

    private function is_forced($username)
    {
        $path = $this->state_file();
        if (!$path || !is_readable($path)) {
            return false;
        }

        $wanted = strtolower(trim($username));
        $lines = @file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!$lines) {
            return false;
        }

        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || strpos($line, '#') === 0) {
                continue;
            }

            if (strtolower($line) === $wanted) {
                return true;
            }
        }

        return false;
    }

    private function clear_forced($username)
    {
        $path = $this->state_file();
        $dir = dirname($path);
        if (!$path || !is_dir($dir)) {
            return;
        }

        if (!file_exists($path)) {
            @touch($path);
            @chmod($path, 0664);
        }

        $lock = @fopen($path . '.lock', 'c');
        if (!$lock) {
            return;
        }

        if (!flock($lock, LOCK_EX)) {
            fclose($lock);
            return;
        }

        $wanted = strtolower(trim($username));
        $lines = @file($path, FILE_IGNORE_NEW_LINES);
        $kept = [];
        $changed = false;

        foreach ($lines ?: [] as $line) {
            if (strtolower(trim($line)) === $wanted) {
                $changed = true;
                continue;
            }
            $kept[] = rtrim($line, "\r\n");
        }

        if ($changed) {
            $body = count($kept) ? implode(PHP_EOL, $kept) . PHP_EOL : '';
            @file_put_contents($path, $body);
            @chmod($path, 0664);
        }

        flock($lock, LOCK_UN);
        fclose($lock);
    }
}
PHP

  chmod 0755 "$WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR"
  chmod 0644 "${WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR}/config.inc.php" "${WEBMAIL_PASSWORD_FORCE_PLUGIN_DIR}/force_password_change.php"
  chown -R 33:33 "${WEBMAIL_BASE}/data/config" >/dev/null 2>&1 || true
}

ensure_roundcube_managesieve_files() {
  local mail_host="${1:-mailserver}"

  mkdir -p "$(dirname "$WEBMAIL_MANAGESIEVE_CONFIG_FILE")"

  cat > "$WEBMAIL_MANAGESIEVE_CONFIG_FILE" <<EOF
<?php
\$config['managesieve_host'] = 'tls://${mail_host}';
\$config['managesieve_auth_type'] = null;
\$config['managesieve_conn_options'] = null;
\$config['managesieve_script_name'] = 'managesieve';
\$config['managesieve_mbox_encoding'] = 'UTF-8';
\$config['managesieve_forward'] = 1;
\$config['managesieve_vacation'] = 1;
\$config['managesieve_raw_editor'] = false;
EOF

  chmod 0644 "$WEBMAIL_MANAGESIEVE_CONFIG_FILE"
  chown 33:33 "$WEBMAIL_MANAGESIEVE_CONFIG_FILE" >/dev/null 2>&1 || true
}

mailserver_managesieve_enabled() {
  if [ -f "$MAIL_ENV_FILE" ] && grep -q '^ENABLE_MANAGESIEVE=1$' "$MAIL_ENV_FILE"; then
    return 0
  fi

  docker exec mailserver sh -c 'test "${ENABLE_MANAGESIEVE:-0}" = "1"' >/dev/null 2>&1
}

enable_mailserver_managesieve() {
  if [ ! -f "$MAIL_ENV_FILE" ] || [ ! -f "$MAIL_COMPOSE" ]; then
    echo "Mailserver config files not found."
    echo "Run option 10 first: Setup email server (docker-mailserver)."
    return 1
  fi

  set_env_file_var "$MAIL_ENV_FILE" "ENABLE_MANAGESIEVE" "1"
  echo "Recreating mailserver with ManageSieve enabled..."
  dc -f "$MAIL_COMPOSE" up -d --force-recreate mailserver

  for _ in $(seq 1 30); do
    if docker exec mailserver sh -c "ss -lnt 2>/dev/null | grep -q ':4190\\b'"; then
      return 0
    fi
    sleep 2
  done

  echo "Warning: ManageSieve did not start listening on port 4190 yet."
  return 1
}

roundcube_managesieve_health() {
  docker exec roundcube-webmail php -r '
    $errno = 0;
    $errstr = "";
    $fp = @fsockopen("mailserver", 4190, $errno, $errstr, 3);
    if (!$fp) {
        exit(1);
    }
    fclose($fp);
    exit(0);
  ' >/dev/null 2>&1
}

show_mail_forwarding_status() {
  local managesieve_ports plugin_line forwards_output

  echo ""
  echo "Mail aliases and forwarding status"
  echo "--------------------------------------------------------------"
  if mailserver_managesieve_enabled; then
    echo "Mailserver ManageSieve: enabled"
  else
    echo "Mailserver ManageSieve: disabled"
  fi

  echo "ManageSieve internal listener:"
  if docker exec mailserver sh -c "ss -lnt 2>/dev/null | grep ':4190\\b'" >/dev/null 2>&1; then
    docker exec mailserver sh -c "ss -lnt 2>/dev/null | grep ':4190\\b'" | sed 's/^/  /'
  else
    echo "  not listening"
  fi

  echo ""
  echo "Roundcube ManageSieve:"
  load_current_webmail_settings >/dev/null 2>&1 || true
  echo "  configured: ${WEBMAIL_CURRENT_MANAGESIEVE_ENABLED:-no}"
  if docker_container_exists roundcube-webmail; then
    plugin_line="$(docker exec roundcube-webmail sh -c 'grep -n "managesieve\\|plugins" /var/www/html/config/config.docker.inc.php 2>/dev/null | head -5' || true)"
    if [ -n "$plugin_line" ]; then
      echo "$plugin_line" | sed 's/^/  /'
    fi
    if roundcube_managesieve_health; then
      echo "  health: ok"
    else
      echo "  health: unavailable"
    fi
  else
    echo "  roundcube container not found"
  fi

  echo ""
  echo "Host-published ManageSieve ports:"
  managesieve_ports="$(docker port mailserver 4190/tcp 2>/dev/null || true)"
  if [ -n "$managesieve_ports" ]; then
    echo "$managesieve_ports" | sed 's/^/  /'
  else
    echo "  none"
  fi

  echo ""
  echo "Aliases:"
  list_mail_aliases | sed 's/^/  /'
  echo ""
  echo "Managed mailbox forwards:"
  forwards_output="$(list_mailbox_forwards || true)"
  if [ -n "$forwards_output" ]; then
    echo "$forwards_output" | sed 's/^/  /'
  else
    echo "  none"
  fi
  echo "--------------------------------------------------------------"
}

enable_webmail_mailbox_forwards() {
  local proceed

  ensure_mailserver_running

  if [ ! -f "$WEBMAIL_COMPOSE" ]; then
    echo "Webmail stack not found."
    echo "Run option 11 first: Setup webmail (Roundcube)."
    exit 1
  fi

  load_current_webmail_settings
  if [ -z "$WEBMAIL_CURRENT_PRIMARY" ] || [ -z "$WEBMAIL_CURRENT_DOMAINS" ] || [ -z "$WEBMAIL_CURRENT_MAIL_HOST" ]; then
    echo "Could not detect current Roundcube settings."
    echo "Run option 13 first to normalize the webmail configuration."
    exit 1
  fi

  echo ""
  echo "Enable mailbox forwarding from Roundcube"
  echo "--------------------------------------------------------------"
  echo "This enables docker-mailserver ManageSieve internally and adds"
  echo "Roundcube's Filters/Forwarding UI. No ManageSieve port is"
  echo "published to the Internet."
  echo ""
  read -r -p "Enable this feature and recreate mailserver/Roundcube? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  enable_mailserver_managesieve || true
  ensure_roundcube_managesieve_files "$WEBMAIL_CURRENT_MAIL_HOST"
  write_roundcube_compose "$WEBMAIL_CURRENT_PRIMARY" "$WEBMAIL_CURRENT_DOMAINS" "$WEBMAIL_CURRENT_MAIL_HOST" "$WEBMAIL_CURRENT_PASSWORD_CHANGE_ENABLED" "yes"

  echo "Recreating Roundcube with ManageSieve plugin..."
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate --remove-orphans
  proxy_dc restart reverse-proxy >/dev/null 2>&1 || true

  show_mail_forwarding_status
  if ! roundcube_managesieve_health; then
    echo "Warning: Roundcube could not reach ManageSieve on mailserver:4190."
    exit 1
  fi

  echo "Mailbox forwarding UI is enabled in Roundcube."
}

write_roundcube_compose() {
  local webmail_domain="$1"
  local webmail_domains="$2"
  local mail_host="$3"
  local password_change_enabled="${4:-no}"
  local managesieve_enabled="${5:-no}"
  local roundcube_plugins="archive,zipdownload"

  mkdir -p "${WEBMAIL_BASE}/data/db" "${WEBMAIL_BASE}/data/config" "${WEBMAIL_BASE}/data/temp"
  chown -R 33:33 "${WEBMAIL_BASE}/data" >/dev/null 2>&1 || true
  ensure_roundcube_managesieve_files "$mail_host"

  if [ "$password_change_enabled" = "yes" ]; then
    ensure_roundcube_password_change_files
    roundcube_plugins="archive,zipdownload,password,force_password_change"
  fi
  if [ "$managesieve_enabled" = "yes" ]; then
    roundcube_plugins="${roundcube_plugins},managesieve"
  fi

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
      ROUNDCUBEMAIL_PLUGINS: "${roundcube_plugins}"
    volumes:
      - ./data/db:/var/roundcube/db
      - ./data/config:/var/roundcube/config
      - ./data/temp:/tmp/roundcube-temp
      - ./force-password-change-plugin:/var/www/html/plugins/force_password_change:ro
      - ./data/config/managesieve.inc.php:/var/www/html/plugins/managesieve/config.inc.php:ro
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - roundcube-webmail
EOF

  if [ "$password_change_enabled" = "yes" ]; then
    cat >> "$WEBMAIL_COMPOSE" <<EOF

  password-helper:
    image: ghcr.io/docker-mailserver/docker-mailserver:latest
    container_name: ${WEBMAIL_PASSWORD_HELPER_CONTAINER}
    restart: unless-stopped
    pid: "container:mailserver"
    entrypoint: ["python3", "/app/password-helper.py"]
    environment:
      MAIL_ACCOUNTS_FILE: "/tmp/docker-mailserver/postfix-accounts.cf"
      FORCE_PASSWORD_FILE: "/roundcube-config/force-password-change-users.txt"
      MAIL_RELOAD_PROCESS: "dovecot"
      PASSWORD_HELPER_TOKEN: "$(cat "$WEBMAIL_PASSWORD_TOKEN_FILE")"
      PASSWORD_MIN_LENGTH: "8"
      PASSWORD_LISTEN_HOST: "0.0.0.0"
      PASSWORD_LISTEN_PORT: "8080"
    volumes:
      - ./password-helper:/app:ro
      - ./data/config:/roundcube-config
      - ${MAIL_BASE}/docker-data/dms/config:/tmp/docker-mailserver
    networks:
      ${SHARED_NETWORK}:
        aliases:
          - roundcube-password-helper
EOF
  fi

  cat >> "$WEBMAIL_COMPOSE" <<EOF

networks:
  ${SHARED_NETWORK}:
    external: true
EOF

  write_webmail_meta "$webmail_domain" "$webmail_domains" "$mail_host" "$password_change_enabled" "$managesieve_enabled"
}

issue_webmail_certificate() {
  local webmail_domain="$1"
  local cert_email="$2"

  echo "Issuing Let's Encrypt certificate for ${webmail_domain}..."
  write_acme_only_vhost "$webmail_domain"
  proxy_dc restart reverse-proxy

  if ! proxy_dc run --rm certbot certonly \
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
  proxy_dc restart reverse-proxy

  if ! proxy_dc run --rm certbot certonly \
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
  proxy_dc restart reverse-proxy

  if ! proxy_dc run --rm certbot certonly \
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
  local current_webmail_domains current_webmail_domain current_mail_host current_password_change_enabled current_managesieve_enabled

  [ -f "$WEBMAIL_COMPOSE" ] || return 0

  current_webmail_domains=""
  current_webmail_domain=""
  current_mail_host=""
  current_password_change_enabled="no"
  current_managesieve_enabled="no"

  if [ -f "$WEBMAIL_META_FILE" ]; then
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$WEBMAIL_META_FILE"
    current_webmail_domain="${WEBMAIL_PRIMARY_DOMAIN:-${WEBMAIL_DOMAIN:-}}"
    current_webmail_domains="${WEBMAIL_DOMAINS:-}"
    current_mail_host="${MAIL_HOST:-}"
    current_password_change_enabled="${WEBMAIL_PASSWORD_CHANGE_ENABLED:-no}"
    current_managesieve_enabled="${WEBMAIL_MANAGESIEVE_ENABLED:-no}"
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
  write_roundcube_compose "$current_webmail_domain" "$current_webmail_domains" "$new_mail_host" "$current_password_change_enabled" "$current_managesieve_enabled"
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate
}

setup_mailserver() {
  local mail_domain mail_host admin_user admin_email admin_password proceed remove_old_cert server_ip

  server_ip="$(detect_server_ip)"

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
  echo "  ${mail_host} -> ${server_ip}"
  echo ""
  echo "MX (for ${mail_domain}):"
  echo "  ${mail_domain} MX 10 ${mail_host}"
  echo ""
  echo "PTR / rDNS (set at your VPS/provider):"
  echo "  ${server_ip} PTR ${mail_host}"
  echo ""
  echo "SPF (TXT for ${mail_domain}):"
  echo "  v=spf1 mx -all"
  echo ""
  echo "DKIM + DMARC:"
  echo "  The script will generate DKIM keys and show you the TXT record to add."
  echo "  Recommended DMARC (TXT for _dmarc.${mail_domain}):"
  echo "    $(mail_dmarc_record "$mail_domain")"
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
  proxy_dc restart reverse-proxy

  if ! proxy_dc run --rm certbot certonly \
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
ENABLE_MANAGESIEVE=1

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
  echo "  $(mail_spf_record)"
  echo ""
  echo "DMARC (TXT for _dmarc.${domain}):"
  echo "  $(mail_dmarc_record "$domain")"
  echo ""
  echo "DKIM:"
  echo "  Add the TXT record from:"
  echo "    ${MAIL_BASE}/docker-data/dms/config/opendkim/keys/${domain}/mail.txt"
  echo ""
  echo "Cloudflare note:"
  echo "  Keep mail host A records and MX targets as DNS only (gray cloud)."
  echo "  Webmail HTTP/HTTPS records may be proxied (orange cloud)."
  echo "--------------------------------------------------------------"
}

mail_spf_record() {
  echo "v=spf1 mx -all"
}

mail_dmarc_record() {
  local domain="$1"
  echo "v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@${domain}"
}

mail_dkim_domains() {
  find "${MAIL_BASE}/docker-data/dms/config/opendkim/keys" \
    -maxdepth 2 -type f -name "mail.txt" -printf '%h\n' 2>/dev/null \
    | sed 's#.*/##' \
    | sort -u
}

mailbox_domains() {
  local accounts_file="${MAIL_BASE}/docker-data/dms/config/postfix-accounts.cf"

  if [ -f "$accounts_file" ]; then
    awk -F'[|@]' 'NF >= 3 {print $2}' "$accounts_file" | sort -u
    return 0
  fi

  docker exec mailserver setup email list 2>/dev/null \
    | sed -n 's/.*[<* ]\([A-Za-z0-9._%+-]\+@[A-Za-z0-9.-]\+\.[A-Za-z]\{2,\}\).*/\1/p' \
    | awk -F@ '{print $2}' \
    | sort -u
}

dns_lookup_record() {
  local type="$1"
  local name="$2"
  local resolver="${DNS_RESOLVER:-1.1.1.1}"

  if command -v dig >/dev/null 2>&1; then
    dig @"$resolver" +short "$name" "$type" 2>/dev/null || true
    return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup -type="$type" "$name" "$resolver" 2>/dev/null || true
    return 0
  fi

  echo "DNS lookup skipped: dig/nslookup not installed."
}

print_current_dns_record() {
  local label="$1"
  local type="$2"
  local name="$3"
  local output

  output="$(dns_lookup_record "$type" "$name" | sed '/^$/d' || true)"
  echo "${label}:"
  if [ -n "$output" ]; then
    echo "$output" | sed 's/^/  /'
  else
    echo "  Not found"
  fi
}

audit_mail_dns() {
  local mail_host mailbox_domain_list dkim_domain_list all_domains domain

  ensure_mailserver_running

  mail_host=""
  if [ -f "$MAIL_ENV_FILE" ]; then
    mail_host="$(awk -F= '/^OVERRIDE_HOSTNAME=/{print $2}' "$MAIL_ENV_FILE" | head -n 1)"
  fi

  if [ -z "$mail_host" ]; then
    prompt mail_host "Mail host/FQDN (e.g. mail.example.com): "
    mail_host="$(normalize_domain "$mail_host")"
    if ! validate_domain "$mail_host"; then
      echo "Invalid host: ${mail_host}"
      exit 1
    fi
  fi

  mailbox_domain_list="$(mailbox_domains || true)"
  dkim_domain_list="$(mail_dkim_domains || true)"
  all_domains="$(
    {
      echo "$mailbox_domain_list"
      echo "$dkim_domain_list"
    } | sed '/^$/d' | sort -u
  )"

  echo ""
  echo "Mail DNS audit"
  echo "--------------------------------------------------------------"
  echo "Mail host: ${mail_host}"
  echo "Resolver: ${DNS_RESOLVER:-1.1.1.1}"
  echo ""
  print_current_dns_record "Mail host A (${mail_host})" "A" "$mail_host"
  echo ""
  echo "Mailbox domains found:"
  if [ -n "$mailbox_domain_list" ]; then
    echo "$mailbox_domain_list" | sed 's/^/  /'
  else
    echo "  None"
  fi
  echo ""
  echo "DKIM key domains found:"
  if [ -n "$dkim_domain_list" ]; then
    echo "$dkim_domain_list" | sed 's/^/  /'
  else
    echo "  None"
  fi
  echo "--------------------------------------------------------------"

  if [ -z "$all_domains" ]; then
    echo "No mail domains were found."
    return 0
  fi

  while IFS= read -r domain; do
    [ -n "$domain" ] || continue

    echo ""
    echo "Domain: ${domain}"
    echo "--------------------------------------------------------------"
    echo "Expected:"
    echo "  MX: ${domain} MX 10 ${mail_host}"
    echo "  SPF TXT (${domain}): $(mail_spf_record)"
    echo "  DMARC TXT (_dmarc.${domain}): $(mail_dmarc_record "$domain")"
    echo "  DKIM TXT: mail._domainkey.${domain}"
    echo ""
    echo "Current DNS:"
    print_current_dns_record "  MX" "MX" "$domain"
    print_current_dns_record "  SPF/TXT" "TXT" "$domain"
    print_current_dns_record "  DMARC" "TXT" "_dmarc.${domain}"
    print_current_dns_record "  DKIM" "TXT" "mail._domainkey.${domain}"

    if ! echo "$mailbox_domain_list" | grep -Fxq "$domain"; then
      echo ""
      echo "Note: DKIM exists for ${domain}, but no mailbox for this domain was found."
    fi

    if ! echo "$dkim_domain_list" | grep -Fxq "$domain"; then
      echo ""
      echo "Warning: Mailboxes exist for ${domain}, but no DKIM key was found."
      echo "Generate DKIM with menu 12 -> gen-dkim for ${domain}."
    fi
  done <<< "$all_domains"

  echo ""
  echo "Cloudflare reminder:"
  echo "  mail.* A records and MX targets must stay DNS only (gray cloud)."
  echo "  Do not proxy SMTP/IMAP records. webmail.* can be proxied for HTTPS."
}

smtp_port_25_check() {
  local output=""

  if command -v nc >/dev/null 2>&1; then
    output="$(
      timeout 12 bash -c "printf 'EHLO laravel-manager.local\r\nQUIT\r\n' | nc -w 8 127.0.0.1 25" 2>/dev/null || true
    )"
  else
    output="$(
      timeout 12 bash -c '
        exec 3<>/dev/tcp/127.0.0.1/25 || exit 1
        printf "EHLO laravel-manager.local\r\nQUIT\r\n" >&3
        while IFS= read -r -t 3 line <&3; do
          printf "%s\n" "$line"
          case "$line" in
            221*) break ;;
          esac
        done
      ' 2>/dev/null || true
    )"
  fi

  if echo "$output" | grep -q '^220'; then
    echo "SMTP port 25 responded locally:"
    echo "$output" | sed -n '1,8p'
    return 0
  fi

  echo "Warning: SMTP port 25 did not return a local greeting."
  if [ -n "$output" ]; then
    echo "$output" | sed -n '1,8p'
  fi
  return 1
}

repair_postscreen_cache() {
  local cache_file backup_dir backup_file proceed

  ensure_mailserver_running

  if [ ! -f "$MAIL_COMPOSE" ]; then
    echo "Mailserver compose file not found: ${MAIL_COMPOSE}"
    echo "Run option 10 first: Setup email server (docker-mailserver)."
    exit 1
  fi

  cache_file="${MAIL_BASE}/docker-data/dms/mail-state/lib-postfix/postscreen_cache.db"
  backup_dir="/root/mailserver-repair-backups/$(date +%Y%m%d-%H%M%S)"

  echo ""
  echo "Repair Postfix postscreen cache"
  echo "--------------------------------------------------------------"
  echo "This can fix errors like:"
  echo "  postscreen_cache.db: Unknown error"
  echo ""
  echo "The mailserver container will be stopped briefly, the postscreen"
  echo "cache file will be backed up and removed, then mailserver will be"
  echo "recreated from ${MAIL_COMPOSE}."
  echo ""
  read -r -p "Proceed with postscreen cache repair? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  mkdir -p "$backup_dir"
  cp -a "$MAIL_COMPOSE" "$backup_dir/compose.yaml"
  [ -f "$MAIL_ENV_FILE" ] && cp -a "$MAIL_ENV_FILE" "$backup_dir/mailserver.env"

  if [ -f "$cache_file" ]; then
    backup_file="$backup_dir/postscreen_cache.db"
    cp -a "$cache_file" "$backup_file"
    echo "Backed up postscreen cache to: ${backup_file}"
  else
    echo "No existing postscreen cache file found at: ${cache_file}"
  fi

  echo "Stopping mailserver..."
  dc -f "$MAIL_COMPOSE" stop mailserver || true

  echo "Removing postscreen cache..."
  rm -f "$cache_file"

  echo "Recreating mailserver..."
  dc -f "$MAIL_COMPOSE" up -d --force-recreate mailserver

  echo "Waiting for mailserver to start..."
  for _ in $(seq 1 30); do
    if docker_container_running "mailserver"; then
      break
    fi
    sleep 2
  done

  if ! docker_container_running "mailserver"; then
    echo "mailserver did not start successfully."
    echo "Check logs with: docker logs mailserver"
    exit 1
  fi

  echo ""
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || $1=="mailserver"'
  echo ""
  smtp_port_25_check || true
  echo ""
  echo "Recent critical mailserver log lines:"
  docker logs --since 5m mailserver 2>&1 \
    | grep -Ei 'fatal|panic|error|failed|bad command startup|postscreen_cache' \
    || echo "No critical mailserver log lines found in the last 5 minutes."
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
  local old_mail_host new_mail_host cert_email remove_old new_mail_domain current_postmaster server_ip

  server_ip="$(detect_server_ip)"

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
  echo "  A/AAAA: ${new_mail_host} -> ${server_ip}"
  echo "  PTR/rDNS: ${server_ip} -> ${new_mail_host}"
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
  local action email_addr email_password domain_list mail_host guessed_host dkim_file confirm_delete force_change password_reset_done
  local alias_addr recipients_csv keep_copy confirm_clear forwards_output

  echo ""
  echo "Manage email server (docker-mailserver)"
  echo ""
  echo "Tip: For multiple domains, keep one mail host (e.g. mail.example.com) and"
  echo "set each domain's MX to that host."
  echo ""

  ensure_mailserver_running

  prompt action "Action [status/add-domain/change-mail-host/add-mailbox/delete-mailbox/reset-password/list-mailboxes/add-alias/delete-alias/list-aliases/set-forward/clear-forward/list-forwards/enable-webmail-forwards/forward-status/gen-dkim/show-dkim/dns-help/audit-dns/repair-postscreen-cache]: " "status"

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
      email_addr="$(normalize_email_address "$email_addr")"
      if ! validate_email_address "$email_addr"; then
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
      reload_mailserver_dovecot
      echo "Mailbox created."
      if webmail_password_change_enabled; then
        webmail_force_password_mark "$email_addr" || true
      fi
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
      reload_mailserver_dovecot
      echo "Mailbox deleted."
      ;;
    reset-password)
      prompt email_addr "Mailbox address to reset password for (e.g. user@example.com): "
      email_addr="$(normalize_email_address "$email_addr")"
      if ! validate_email_address "$email_addr"; then
        echo "Invalid email address: ${email_addr}"
        exit 1
      fi
      prompt_secret email_password "New mailbox password: "
      if [ -z "$email_password" ]; then
        echo "Password is required."
        exit 1
      fi
      echo "Resetting password for: ${email_addr}"
      password_reset_done="no"
      if docker exec -i mailserver setup email update "$email_addr" "$email_password"; then
        echo "Password updated."
        password_reset_done="yes"
      elif docker exec -i mailserver setup email add "$email_addr" "$email_password"; then
        echo "Password updated."
        echo "Note: Your docker-mailserver setup tool did not accept 'update'."
        echo "This used 'add' as a fallback (some versions treat it as a password reset)."
        password_reset_done="yes"
      else
        echo "Failed to reset password."
        echo "Try inside the container:"
        echo "  docker exec -it mailserver setup email help"
        exit 1
      fi
      if [ "$password_reset_done" = "yes" ]; then
        reload_mailserver_dovecot
      fi
      if [ "$password_reset_done" = "yes" ] && webmail_password_change_enabled; then
        prompt force_change "Force this user to change password at next Roundcube login? (yes/no): " "yes"
        if [ "${force_change,,}" = "yes" ]; then
          webmail_force_password_mark "$email_addr" || true
        fi
      fi
      ;;
    list-mailboxes)
      docker exec -i mailserver setup email list || true
      ;;
    add-alias)
      prompt alias_addr "Alias address (e.g. sales@example.com): "
      alias_addr="$(normalize_email_address "$alias_addr")"
      if ! validate_email_address "$alias_addr"; then
        echo "Invalid alias address: ${alias_addr}"
        exit 1
      fi
      prompt recipients_csv "Recipient address(es), comma-separated: "
      if ! recipients_csv="$(normalize_email_csv "$recipients_csv")"; then
        echo "Invalid recipient list."
        exit 1
      fi
      add_mail_alias "$alias_addr" "$recipients_csv"
      ;;
    delete-alias)
      prompt alias_addr "Alias address to modify/delete: "
      alias_addr="$(normalize_email_address "$alias_addr")"
      if ! validate_email_address "$alias_addr"; then
        echo "Invalid alias address: ${alias_addr}"
        exit 1
      fi
      prompt recipients_csv "Recipient(s) to remove, comma-separated [blank = all recipients for alias]: "
      if [ -n "$recipients_csv" ]; then
        if ! recipients_csv="$(normalize_email_csv "$recipients_csv")"; then
          echo "Invalid recipient list."
          exit 1
        fi
      fi
      delete_mail_alias "$alias_addr" "$recipients_csv"
      ;;
    list-aliases)
      list_mail_aliases
      ;;
    set-forward)
      prompt email_addr "Existing mailbox to forward (e.g. user@example.com): "
      email_addr="$(normalize_email_address "$email_addr")"
      if ! validate_email_address "$email_addr"; then
        echo "Invalid mailbox address: ${email_addr}"
        exit 1
      fi
      prompt recipients_csv "Forward recipient address(es), comma-separated: "
      if ! recipients_csv="$(normalize_email_csv "$recipients_csv")"; then
        echo "Invalid recipient list."
        exit 1
      fi
      prompt keep_copy "Keep a copy in the original mailbox? (yes/no): " "yes"
      set_mailbox_forward "$email_addr" "$recipients_csv" "$keep_copy"
      ;;
    clear-forward)
      prompt email_addr "Mailbox address to clear managed forward for: "
      email_addr="$(normalize_email_address "$email_addr")"
      if ! validate_email_address "$email_addr"; then
        echo "Invalid mailbox address: ${email_addr}"
        exit 1
      fi
      prompt confirm_clear "Clear managed forward for ${email_addr}? (yes/no): " "no"
      if [ "${confirm_clear,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi
      clear_mailbox_forward "$email_addr"
      ;;
    list-forwards)
      forwards_output="$(list_mailbox_forwards || true)"
      if [ -n "$forwards_output" ]; then
        echo "$forwards_output"
      else
        echo "No managed mailbox forwards configured."
      fi
      ;;
    enable-webmail-forwards)
      enable_webmail_mailbox_forwards
      ;;
    forward-status)
      show_mail_forwarding_status
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
    audit-dns|audit-mail-dns)
      audit_mail_dns
      ;;
    repair-postscreen-cache)
      repair_postscreen_cache
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
  ensure_mailserver_fail2ban_ignores_shared_network

  if ! issue_webmail_certificates "$webmail_domains" "admin@${mail_domain}"; then
    exit 1
  fi

  echo "Creating Roundcube stack in ${WEBMAIL_BASE}..."
  write_roundcube_compose "$webmail_domain" "$webmail_domains" "$mail_host"

  echo "Starting Roundcube..."
  dc -f "$WEBMAIL_COMPOSE" up -d

  echo "Publishing webmail via reverse proxy..."
  write_roundcube_proxy_configs "$webmail_domains"
  proxy_dc restart reverse-proxy

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
  local current_webmail_domain current_webmail_domains current_mail_host current_password_change_enabled current_managesieve_enabled webmail_domains webmail_domain mail_host mail_domain proceed remove_old old_domain removed_domains part

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
  current_password_change_enabled="no"
  current_managesieve_enabled="no"

  if [ -f "$WEBMAIL_META_FILE" ]; then
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$WEBMAIL_META_FILE"
    current_webmail_domain="${WEBMAIL_PRIMARY_DOMAIN:-${WEBMAIL_DOMAIN:-}}"
    current_webmail_domains="${WEBMAIL_DOMAINS:-}"
    current_mail_host="${MAIL_HOST:-}"
    current_password_change_enabled="${WEBMAIL_PASSWORD_CHANGE_ENABLED:-no}"
    current_managesieve_enabled="${WEBMAIL_MANAGESIEVE_ENABLED:-no}"
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

  ensure_mailserver_fail2ban_ignores_shared_network

  echo "Rewriting Roundcube stack..."
  write_roundcube_compose "$webmail_domain" "$webmail_domains" "$mail_host" "$current_password_change_enabled" "$current_managesieve_enabled"
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
  proxy_dc restart reverse-proxy

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

load_current_webmail_settings() {
  WEBMAIL_CURRENT_PRIMARY=""
  WEBMAIL_CURRENT_DOMAINS=""
  WEBMAIL_CURRENT_MAIL_HOST=""
  WEBMAIL_CURRENT_PASSWORD_CHANGE_ENABLED="no"
  WEBMAIL_CURRENT_MANAGESIEVE_ENABLED="no"

  if [ -f "$WEBMAIL_META_FILE" ]; then
    local WEBMAIL_PRIMARY_DOMAIN="" WEBMAIL_DOMAIN="" WEBMAIL_DOMAINS="" MAIL_HOST="" WEBMAIL_PASSWORD_CHANGE_ENABLED="" WEBMAIL_MANAGESIEVE_ENABLED=""
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$WEBMAIL_META_FILE"
    WEBMAIL_CURRENT_PRIMARY="${WEBMAIL_PRIMARY_DOMAIN:-${WEBMAIL_DOMAIN:-}}"
    WEBMAIL_CURRENT_DOMAINS="${WEBMAIL_DOMAINS:-}"
    WEBMAIL_CURRENT_MAIL_HOST="${MAIL_HOST:-}"
    WEBMAIL_CURRENT_PASSWORD_CHANGE_ENABLED="${WEBMAIL_PASSWORD_CHANGE_ENABLED:-no}"
    WEBMAIL_CURRENT_MANAGESIEVE_ENABLED="${WEBMAIL_MANAGESIEVE_ENABLED:-no}"
  fi

  if [ -z "$WEBMAIL_CURRENT_PRIMARY" ]; then
    WEBMAIL_CURRENT_PRIMARY="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | head -n 1)"
  fi
  if [ -z "$WEBMAIL_CURRENT_DOMAINS" ]; then
    WEBMAIL_CURRENT_DOMAINS="$(awk '/server_name / {print $2}' "${PROXY_CONF_DIR}"/webmail-*.conf 2>/dev/null | sed 's/;//' | sort -u | paste -sd ',' -)"
  fi
  if [ -z "$WEBMAIL_CURRENT_DOMAINS" ] && [ -n "$WEBMAIL_CURRENT_PRIMARY" ]; then
    WEBMAIL_CURRENT_DOMAINS="$WEBMAIL_CURRENT_PRIMARY"
  fi
  if [ -z "$WEBMAIL_CURRENT_MAIL_HOST" ] && [ -f "$WEBMAIL_COMPOSE" ]; then
    WEBMAIL_CURRENT_MAIL_HOST="$(awk -F'"' '/ROUNDCUBEMAIL_DEFAULT_HOST:/ {print $2}' "$WEBMAIL_COMPOSE" | sed 's/^ssl:\/\///' | head -n 1)"
  fi
}

roundcube_password_helper_health() {
  if ! docker_container_running "$WEBMAIL_PASSWORD_HELPER_CONTAINER"; then
    return 1
  fi

  docker exec roundcube-webmail php -r '
    $result = @file_get_contents("http://roundcube-password-helper:8080/health");
    exit(trim((string) $result) === "ok" ? 0 : 1);
  ' >/dev/null 2>&1
}

show_webmail_password_change_status() {
  local helper_ports forced_users

  load_current_webmail_settings

  echo ""
  echo "Webmail password change status"
  echo "--------------------------------------------------------------"
  echo "Configured: ${WEBMAIL_CURRENT_PASSWORD_CHANGE_ENABLED}"
  echo "Primary webmail domain: ${WEBMAIL_CURRENT_PRIMARY:-not found}"
  echo "All webmail domains: ${WEBMAIL_CURRENT_DOMAINS:-not found}"
  echo "Mail host: ${WEBMAIL_CURRENT_MAIL_HOST:-not found}"
  echo "Roundcube config: ${WEBMAIL_PASSWORD_CONFIG_FILE}"
  echo "Helper script: ${WEBMAIL_PASSWORD_HELPER_DIR}/password-helper.py"
  echo ""
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    | awk -v helper="$WEBMAIL_PASSWORD_HELPER_CONTAINER" 'NR==1 || $1=="roundcube-webmail" || $1==helper'

  echo ""
  echo "Helper host-published ports:"
  if docker_container_exists "$WEBMAIL_PASSWORD_HELPER_CONTAINER"; then
    helper_ports="$(docker port "$WEBMAIL_PASSWORD_HELPER_CONTAINER" 2>/dev/null || true)"
    if [ -n "$helper_ports" ]; then
      echo "$helper_ports" | sed 's/^/  /'
    else
      echo "  none"
    fi
  else
    echo "  helper container not found"
  fi

  if roundcube_password_helper_health; then
    echo ""
    echo "Helper health: ok"
  else
    echo ""
    echo "Helper health: unavailable"
  fi

  forced_users="$(webmail_force_password_list || true)"
  echo ""
  echo "Users forced to change password:"
  if [ -n "$forced_users" ]; then
    echo "$forced_users" | sed 's/^/  /'
  else
    echo "  none"
  fi
  echo "--------------------------------------------------------------"
}

enable_webmail_password_change() {
  local proceed

  ensure_mailserver_running
  ensure_mailserver_fail2ban_ignores_shared_network

  if [ ! -f "$WEBMAIL_COMPOSE" ]; then
    echo "Webmail stack not found."
    echo "Run option 11 first: Setup webmail (Roundcube)."
    exit 1
  fi

  load_current_webmail_settings
  if [ -z "$WEBMAIL_CURRENT_PRIMARY" ] || [ -z "$WEBMAIL_CURRENT_DOMAINS" ] || [ -z "$WEBMAIL_CURRENT_MAIL_HOST" ]; then
    echo "Could not detect current Roundcube settings."
    echo "Run option 13 first to normalize the webmail configuration."
    exit 1
  fi

  echo ""
  echo "Enable password changes from Roundcube"
  echo "--------------------------------------------------------------"
  echo "Roundcube will enable the built-in password plugin."
  echo "An internal helper container will update docker-mailserver accounts."
  echo "No public port will be exposed for the helper."
  echo ""
  echo "Primary webmail domain: ${WEBMAIL_CURRENT_PRIMARY}"
  echo "All webmail domains: ${WEBMAIL_CURRENT_DOMAINS}"
  echo "Mail host: ${WEBMAIL_CURRENT_MAIL_HOST}"
  echo ""
  read -r -p "Enable this feature and recreate Roundcube? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  ensure_roundcube_password_change_files
  write_roundcube_compose "$WEBMAIL_CURRENT_PRIMARY" "$WEBMAIL_CURRENT_DOMAINS" "$WEBMAIL_CURRENT_MAIL_HOST" "yes" "$WEBMAIL_CURRENT_MANAGESIEVE_ENABLED"

  echo "Starting Roundcube with password helper..."
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate --remove-orphans

  echo "Refreshing reverse proxy upstream..."
  proxy_dc restart reverse-proxy >/dev/null 2>&1 || true

  echo "Waiting for password helper..."
  for _ in $(seq 1 20); do
    if roundcube_password_helper_health; then
      break
    fi
    sleep 2
  done

  show_webmail_password_change_status
  if ! roundcube_password_helper_health; then
    echo "Warning: password helper did not respond to the health check."
    echo "Check logs with: docker logs ${WEBMAIL_PASSWORD_HELPER_CONTAINER}"
    exit 1
  fi

  echo "Password changes are enabled in Roundcube settings."
}

disable_webmail_password_change() {
  local proceed

  if [ ! -f "$WEBMAIL_COMPOSE" ]; then
    echo "Webmail stack not found."
    exit 1
  fi

  load_current_webmail_settings
  if [ -z "$WEBMAIL_CURRENT_PRIMARY" ] || [ -z "$WEBMAIL_CURRENT_DOMAINS" ] || [ -z "$WEBMAIL_CURRENT_MAIL_HOST" ]; then
    echo "Could not detect current Roundcube settings."
    exit 1
  fi

  read -r -p "Disable Roundcube password changes and recreate webmail? (yes/no): " proceed
  if [ "${proceed,,}" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  rm -f "$WEBMAIL_PASSWORD_CONFIG_FILE"
  write_roundcube_compose "$WEBMAIL_CURRENT_PRIMARY" "$WEBMAIL_CURRENT_DOMAINS" "$WEBMAIL_CURRENT_MAIL_HOST" "no" "$WEBMAIL_CURRENT_MANAGESIEVE_ENABLED"

  echo "Recreating Roundcube without password helper..."
  dc -f "$WEBMAIL_COMPOSE" up -d --force-recreate --remove-orphans
  docker rm -f "$WEBMAIL_PASSWORD_HELPER_CONTAINER" >/dev/null 2>&1 || true
  proxy_dc restart reverse-proxy >/dev/null 2>&1 || true

  show_webmail_password_change_status
}

manage_webmail_password_change() {
  local action email_addr mailbox_list confirm_clear

  echo ""
  echo "Manage webmail password changes"
  echo ""
  prompt action "Action [status/enable/disable/list-forced/force-user/clear-user/force-all/clear-all]: " "status"

  case "${action,,}" in
    status)
      show_webmail_password_change_status
      ;;
    enable)
      enable_webmail_password_change
      ;;
    disable)
      disable_webmail_password_change
      ;;
    list-forced)
      webmail_force_password_list
      ;;
    force-user)
      prompt email_addr "Mailbox address to force password change for: "
      webmail_force_password_mark "$email_addr"
      ;;
    clear-user)
      prompt email_addr "Mailbox address to clear forced password change for: "
      webmail_force_password_clear "$email_addr"
      ;;
    force-all)
      ensure_mailserver_running
      mailbox_list="$(mailbox_addresses || true)"
      if [ -z "$mailbox_list" ]; then
        echo "No mailboxes found."
        exit 1
      fi
      echo "Marking all mailboxes for password change at next Roundcube login..."
      while IFS= read -r email_addr; do
        [ -n "$email_addr" ] || continue
        webmail_force_password_mark "$email_addr"
      done <<< "$mailbox_list"
      ;;
    clear-all)
      echo "This will clear the forced password change marker for every mailbox."
      read -r -p "Type CLEAR to confirm: " confirm_clear
      if [ "$confirm_clear" != "CLEAR" ]; then
        echo "Cancelled."
        exit 0
      fi
      ensure_webmail_force_password_state_file
      : > "$WEBMAIL_PASSWORD_FORCE_STATE_FILE"
      chmod 0664 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
      chown 33:33 "$WEBMAIL_PASSWORD_FORCE_STATE_FILE" >/dev/null 2>&1 || true
      echo "All forced password change markers cleared."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

create_project() {
  local project_slug domain email db_name db_user db_password db_root_password app_dir project_name pma_port pma_bind_ip app_profile detected_profile

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
  prompt app_dir "Project directory [${PROJECTS_BASE}/${project_name}]: " "${PROJECTS_BASE}/${project_name}"
  detected_profile="$(detect_project_profile "$app_dir")"
  prompt app_profile "App profile [laravel/thinkphp/generic/node] [${detected_profile}]: " "$detected_profile"
  if ! app_profile="$(normalize_project_profile "$app_profile")"; then
    echo "Invalid app profile. Use one of: laravel, thinkphp, generic, node."
    exit 1
  fi

  if [ "$app_profile" = "node" ]; then
    db_name=""
    db_user=""
    db_password=""
    db_root_password=""
  else
    prompt db_name "Database name: "
    prompt db_user "Database user: "
    prompt_secret db_password "Database password: "
    prompt_secret db_root_password "MariaDB root password: "
  fi

  if [ -z "$email" ]; then
    echo "Email is required."
    exit 1
  fi

  if [ "$app_profile" != "node" ] && { [ -z "$db_name" ] || [ -z "$db_user" ] || [ -z "$db_password" ] || [ -z "$db_root_password" ]; }; then
    echo "All database fields are required."
    exit 1
  fi

  if [ -d "$app_dir" ] && [ -f "${app_dir}/docker-compose.yml" ]; then
    echo "A project already exists at ${app_dir}"
    exit 1
  fi

  install_base
  prompt_project_tuning "$app_dir" "$app_profile" "create project"

  if [ -e "${PROXY_PROJECTS_DIR}/${project_name}" ]; then
    echo "A project already exists with the name: ${project_name}"
    exit 1
  fi

  echo "Creating project structure..."
  mkdir -p "$app_dir"
  ln -sfn "$app_dir" "${PROXY_PROJECTS_DIR}/${project_name}"

  pma_port="$(pma_default_port "$project_name")"
  pma_bind_ip="127.0.0.1"
  write_project_files "$app_dir" "$project_name" "$domain" "$db_name" "$db_user" "$db_password" "$db_root_password" "$pma_port" "$pma_bind_ip" "no" "" "8080" "local" "$app_profile"
  write_proxy_config_http "$project_name" "$domain"

  echo "Starting project containers..."
  cd "$app_dir"
  dc up -d --build

  echo "Restarting reverse proxy..."
  proxy_dc restart reverse-proxy

  sleep 8

  echo "Requesting SSL certificate..."
  proxy_dc run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$domain"

  write_proxy_config_https "$project_name" "$domain"
  proxy_dc restart reverse-proxy

  ensure_cron_jobs

  echo ""
  echo "=============================================================="
  echo "INSTALLATION COMPLETE"
  echo "Project: ${project_name}"
  echo "Profile: ${app_profile}"
  echo "Domain: https://${domain}"
  echo "Project path: ${app_dir}"
  if [ "$app_profile" = "node" ]; then
    echo "Node apps belong in ${app_dir}/ so ${app_dir}/server.js and ${app_dir}/package.json exist."
  else
    echo "Laravel apps belong in ${app_dir}/ so ${app_dir}/public/index.php exists."
    echo "ThinkPHP/FastAdmin apps belong in ${app_dir}/ so ${app_dir}/public/index.php exists."
    echo "Document-root apps like WordPress belong in ${app_dir}/public/."
  fi
  echo "If you change the uploaded layout later, run 'Update project' to regenerate Nginx."
  echo "Applied capacity profile: ${PROFILE_NAME} (${RAM_MB} MB RAM, ${CPU_CORES} CPU core(s))"
  echo ""
  print_project_env_template "$app_profile" "$db_name" "$db_user"
  echo ""
  if [ "$app_profile" = "laravel" ]; then
    echo "The queue worker runs under Supervisor inside the PHP container."
  fi
  echo "Automatic backup checks run hourly at minute 30 (default interval: ${DEFAULT_BACKUP_INTERVAL_HOURS} hours)."
  echo "=============================================================="
}

change_project_domain() {
  local project_slug project_name app_dir old_domain new_domain remove_domain email remove_old action
  local current_domains new_domains default_email

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
  current_domains="$(project_domains_for_project "$app_dir" "$old_domain")"

  echo ""
  echo "Project: ${PROJECT_NAME}"
  echo "Primary domain: ${old_domain}"
  echo "All domains: ${current_domains}"
  echo ""
  prompt action "Action [change-primary/add-domain/remove-domain/list]: " "change-primary"

  case "${action,,}" in
    list)
      echo ""
      echo "Project domains:"
      echo "$current_domains" | tr ',' '\n' | sed 's/^/  /'
      ;;
    add-domain)
      prompt new_domain "Domain to add (e.g. www.example.com): "
      new_domain="$(normalize_domain "$new_domain")"
      if ! validate_domain "$new_domain"; then
        echo "Invalid domain: ${new_domain}"
        exit 1
      fi
      if csv_contains_value "$current_domains" "$new_domain"; then
        echo "Domain already exists for this project: ${new_domain}"
        exit 0
      fi

      default_email="admin@${new_domain#*.}"
      prompt email "Email for Let's Encrypt [${default_email}]: " "$default_email"
      if [ -z "$email" ]; then
        echo "Email is required."
        exit 1
      fi

      ensure_proxy_stack
      if ! issue_project_domain_certificate "$PROJECT_NAME" "$new_domain" "$email" "$old_domain"; then
        echo "Failed to issue certificate. Restoring previous project domains..."
        write_project_proxy_configs "$PROJECT_NAME" "$current_domains"
        proxy_dc restart reverse-proxy
        exit 1
      fi

      new_domains="$(normalize_project_domain_list "$old_domain" "${current_domains},${new_domain}")"
      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_DOMAINS" "$new_domains"
      PROJECT_DOMAINS="$new_domains"
      write_project_proxy_configs "$PROJECT_NAME" "$new_domains"
      proxy_dc restart reverse-proxy

      echo "Domain added: https://${new_domain}"
      echo "All domains: ${new_domains}"
      ;;
    remove-domain)
      prompt remove_domain "Domain to remove from this project: "
      remove_domain="$(normalize_domain "$remove_domain")"
      if ! validate_domain "$remove_domain"; then
        echo "Invalid domain: ${remove_domain}"
        exit 1
      fi
      if [ "$remove_domain" = "$old_domain" ]; then
        echo "Cannot remove the primary domain here. Use change-primary first."
        exit 1
      fi
      if ! csv_contains_value "$current_domains" "$remove_domain"; then
        echo "Domain is not configured for this project: ${remove_domain}"
        exit 0
      fi

      new_domains="$(project_domain_list_remove "$current_domains" "$remove_domain")"
      new_domains="$(normalize_project_domain_list "$old_domain" "$new_domains")"
      remove_project_domain_proxy_config "$PROJECT_NAME" "$remove_domain" "$old_domain"
      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_DOMAINS" "$new_domains"
      PROJECT_DOMAINS="$new_domains"
      write_project_proxy_configs "$PROJECT_NAME" "$new_domains"
      proxy_dc restart reverse-proxy

      echo ""
      prompt remove_old "Remove certificate files for ${remove_domain}? (yes/no): " "no"
      if [ "${remove_old,,}" = "yes" ]; then
        remove_project_certificate_files "$remove_domain"
        echo "Certificate files removed."
      fi

      echo "Domain removed: ${remove_domain}"
      echo "All domains: ${new_domains}"
      ;;
    change-primary)
      prompt new_domain "New primary domain (e.g. example.com): "
      new_domain="$(normalize_domain "$new_domain")"
      if ! validate_domain "$new_domain"; then
        echo "Invalid domain: ${new_domain}"
        exit 1
      fi

      if [ "$new_domain" = "$old_domain" ]; then
        echo "New domain is the same as the current primary domain."
        exit 0
      fi

      default_email="admin@${new_domain#*.}"
      prompt email "Email for Let's Encrypt [${default_email}]: " "$default_email"
      if [ -z "$email" ]; then
        echo "Email is required."
        exit 1
      fi

      new_domains="$(project_domain_list_remove "$current_domains" "$old_domain")"
      new_domains="$(normalize_project_domain_list "$new_domain" "$new_domains")"

      ensure_proxy_stack
      if ! issue_project_domain_certificate "$PROJECT_NAME" "$new_domain" "$email" "$new_domain"; then
        echo "Failed to issue certificate. Restoring previous project domains..."
        write_project_proxy_configs "$PROJECT_NAME" "$current_domains"
        proxy_dc restart reverse-proxy
        exit 1
      fi

      set_project_meta_var "${app_dir}/.project-meta" "DOMAIN" "$new_domain"
      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_DOMAINS" "$new_domains"
      DOMAIN="$new_domain"
      PROJECT_DOMAINS="$new_domains"
      write_project_proxy_configs "$PROJECT_NAME" "$new_domains"
      proxy_dc restart reverse-proxy

      echo ""
      prompt remove_old "Remove old certificate files for ${old_domain}? (yes/no): " "no"
      if [ "${remove_old,,}" = "yes" ]; then
        remove_project_certificate_files "$old_domain"
        echo "Old certificate files removed."
      fi

      echo "Primary domain updated: https://${new_domain}"
      echo "All domains: ${new_domains}"
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

delete_project() {
  local project_slug project_name app_dir domain reverb_domain project_domains domain_part
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
    project_domains="${PROJECT_DOMAINS:-${DOMAIN:-}}"
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
  if [ -n "${NODE_CONTAINER:-}" ]; then docker rm -f "${NODE_CONTAINER}" 2>/dev/null || true; fi
  if [ -n "${DB_CONTAINER:-}" ]; then docker rm -f "${DB_CONTAINER}" 2>/dev/null || true; fi
  if [ -n "${REDIS_CONTAINER:-}" ]; then docker rm -f "${REDIS_CONTAINER}" 2>/dev/null || true; fi

  echo "Removing Nginx configuration..."
  rm -f "${PROXY_CONF_DIR}/${project_name}.conf"
  rm -f "${PROXY_CONF_DIR}/${project_name}-alias-"*.conf 2>/dev/null || true
  remove_reverb_proxy_config "$project_name"

  if [ -n "$project_domains" ]; then
    echo "Removing SSL certificates..."
    IFS=',' read -r -a parts <<< "$project_domains"
    for domain_part in "${parts[@]}"; do
      [ -n "$domain_part" ] || continue
      remove_project_certificate_files "$domain_part"
    done
  elif [ -n "$domain" ]; then
    echo "Removing SSL certificates..."
    remove_project_certificate_files "$domain"
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
  rm -f "$(backup_state_file "$project_name")"

  echo "Restarting reverse proxy..."
  proxy_dc restart reverse-proxy

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
        local saved_capacity_profile saved_capacity_ram saved_capacity_cpu saved_tuning_mode saved_tuning_preset
        saved_capacity_profile="$(read_project_meta_var "$dir" "SERVER_CAPACITY_PROFILE")"
        saved_capacity_ram="$(read_project_meta_var "$dir" "SERVER_RAM_MB")"
        saved_capacity_cpu="$(read_project_meta_var "$dir" "SERVER_CPU_CORES")"
        saved_tuning_mode="$(read_project_meta_var "$dir" "PROJECT_TUNING_MODE")"
        saved_tuning_preset="$(read_project_meta_var "$dir" "PROJECT_TUNING_PRESET")"
        # shellcheck disable=SC1090
        # shellcheck disable=SC1091
        source "${dir}/.project-meta"
        echo "Project: ${project_name}"
        echo "Profile: ${APP_PROFILE:-$(detect_project_profile "$dir")}"
        if [ -n "$saved_tuning_mode" ]; then
          echo "Tuning : ${saved_tuning_mode}${saved_tuning_preset:+/${saved_tuning_preset}}"
        fi
        if [ -n "$saved_capacity_profile" ]; then
          echo "Capacity: ${saved_capacity_profile} (${saved_capacity_ram:-unknown} MB RAM, ${saved_capacity_cpu:-unknown} CPU core(s))"
        fi
        echo "Domain : ${DOMAIN}"
        echo "Path   : ${APP_DIR}"
        if [ -n "${DB_NAME:-}" ]; then
          echo "DB      : ${DB_NAME}"
        fi
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
      local saved_capacity_profile saved_capacity_ram saved_capacity_cpu saved_tuning_mode saved_tuning_preset
      saved_capacity_profile="$(read_project_meta_var "$dir" "SERVER_CAPACITY_PROFILE")"
      saved_capacity_ram="$(read_project_meta_var "$dir" "SERVER_RAM_MB")"
      saved_capacity_cpu="$(read_project_meta_var "$dir" "SERVER_CPU_CORES")"
      saved_tuning_mode="$(read_project_meta_var "$dir" "PROJECT_TUNING_MODE")"
      saved_tuning_preset="$(read_project_meta_var "$dir" "PROJECT_TUNING_PRESET")"
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${dir}/.project-meta"
      echo "Project: ${project_name}"
      echo "Profile: ${APP_PROFILE:-$(detect_project_profile "$dir")}"
      if [ -n "$saved_tuning_mode" ]; then
        echo "Tuning : ${saved_tuning_mode}${saved_tuning_preset:+/${saved_tuning_preset}}"
      fi
      if [ -n "$saved_capacity_profile" ]; then
        echo "Capacity: ${saved_capacity_profile} (${saved_capacity_ram:-unknown} MB RAM, ${saved_capacity_cpu:-unknown} CPU core(s))"
      fi
      echo "Domain : ${DOMAIN}"
      echo "Path   : ${APP_DIR}"
      if [ -n "${DB_NAME:-}" ]; then
        echo "DB      : ${DB_NAME}"
      fi
      echo "--------------------------------------------------------------"
    else
      echo "Project: ${project_name}"
      echo "Path   : ${dir}"
      echo "--------------------------------------------------------------"
    fi
  done
}

ensure_latest_stable_rclone() {
  local installer_file latest_release installed_release

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install rclone."
    return 1
  fi

  echo "Checking the latest stable rclone release from rclone.org..."
  if ! latest_release="$(curl --proto '=https' --tlsv1.2 -fsSL https://downloads.rclone.org/version.txt)"; then
    echo "Unable to determine the latest stable rclone release."
    return 1
  fi
  latest_release="${latest_release%%$'\n'*}"
  latest_release="${latest_release%$'\r'}"
  if [[ ! "$latest_release" =~ ^rclone\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "The official rclone release manifest returned an unexpected version."
    return 1
  fi

  installed_release=""
  if command -v rclone >/dev/null 2>&1; then
    installed_release="$(rclone version 2>/dev/null | head -n 1 | tr -d '\r')" || installed_release=""
  fi
  if [ "$installed_release" = "$latest_release" ]; then
    echo "rclone ready: ${installed_release}"
    return 0
  fi

  installer_file="$(mktemp)"
  if ! curl --proto '=https' --tlsv1.2 -fsSL https://rclone.org/install.sh -o "$installer_file"; then
    echo "Unable to download the official rclone installer."
    rm -f "$installer_file"
    return 1
  fi

  if ! bash -n "$installer_file"; then
    echo "The downloaded rclone installer is not a valid shell script."
    rm -f "$installer_file"
    return 1
  fi
  # The official installer may return a non-zero status when no files need to
  # change. Verify the resulting version instead of treating that status alone
  # as an installation failure.
  if ! bash "$installer_file"; then
    echo "The rclone installer returned a non-zero status; verifying the installed version..."
  fi
  rm -f "$installer_file"
  hash -r

  installed_release=""
  if command -v rclone >/dev/null 2>&1; then
    installed_release="$(rclone version 2>/dev/null | head -n 1 | tr -d '\r')" || installed_release=""
  fi
  if [ "$installed_release" != "$latest_release" ]; then
    echo "Unable to install the latest stable rclone release (${latest_release})."
    if [ -n "$installed_release" ]; then
      echo "Installed version: ${installed_release}"
    fi
    return 1
  fi

  echo "rclone ready: ${installed_release}"
}

rclone_remote_type() {
  local remote="$1"
  rclone config show "$remote" 2>/dev/null \
    | awk -F '=' '/^[[:space:]]*type[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
}

SELECTED_RCLONE_REMOTE=""
select_rclone_remote() {
  local provider="$1"
  local expected_type remote_line remote remote_type choice index
  local -a compatible_remotes=()

  case "$provider" in
    google-drive) expected_type="drive" ;;
    onedrive) expected_type="onedrive" ;;
    *) return 1 ;;
  esac

  SELECTED_RCLONE_REMOTE=""
  while true; do
    compatible_remotes=()
    while IFS= read -r remote_line; do
      remote="${remote_line%:}"
      [ -n "$remote" ] || continue
      remote_type="$(rclone_remote_type "$remote")"
      [ "$remote_type" = "$expected_type" ] && compatible_remotes+=("$remote")
    done < <(rclone listremotes 2>/dev/null || true)

    echo ""
    echo "Configured ${provider} remotes:"
    if [ "${#compatible_remotes[@]}" -eq 0 ]; then
      echo "  (none)"
    else
      for index in "${!compatible_remotes[@]}"; do
        echo "$((index + 1))) ${compatible_remotes[$index]}"
      done
    fi
    echo "n) Configure a new cloud account with rclone"
    echo "q) Cancel"
    read -r -p "Selection: " choice

    case "${choice,,}" in
      n)
        echo ""
        echo "rclone's configuration wizard will now open."
        echo "Choose provider type '${expected_type}', finish OAuth authorization, then quit the wizard."
        if ! rclone config; then
          echo "rclone configuration did not complete successfully."
          return 1
        fi
        ;;
      q) return 1 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] \
          && [ "$choice" -ge 1 ] \
          && [ "$choice" -le "${#compatible_remotes[@]}" ]; then
          SELECTED_RCLONE_REMOTE="${compatible_remotes[$((choice - 1))]}"
          return 0
        fi
        echo "Invalid selection."
        ;;
    esac
  done
}

SELECTED_RCLONE_FOLDER=""
browse_rclone_folder() {
  local remote="$1"
  local current
  current="$(normalize_backup_cloud_folder "${2:-}")"
  local listing folder choice new_folder index remote_path
  local -a folders=()

  SELECTED_RCLONE_FOLDER=""
  while true; do
    remote_path="${remote}:${current}"
    if ! listing="$(rclone lsf "$remote_path" --dirs-only --max-depth 1 2>/dev/null)"; then
      echo "Unable to list ${remote_path}. Check the remote connection and permissions."
      if [ -n "$current" ]; then
        echo "Returning to the remote root."
        current=""
        continue
      fi
      return 1
    fi

    folders=()
    while IFS= read -r folder; do
      folder="${folder%/}"
      [ -n "$folder" ] && folders+=("$folder")
    done <<< "$listing"

    echo ""
    echo "Cloud folder: ${remote}:${current:-/}"
    echo "0) Use this folder"
    for index in "${!folders[@]}"; do
      echo "$((index + 1))) ${folders[$index]}"
    done
    echo "u) Go to parent folder"
    echo "n) Create a new folder"
    echo "q) Cancel"
    read -r -p "Selection: " choice

    case "${choice,,}" in
      0)
        if ! rclone mkdir "$remote_path"; then
          echo "Unable to access the selected folder."
          continue
        fi
        SELECTED_RCLONE_FOLDER="$current"
        return 0
        ;;
      u)
        if [[ "$current" == */* ]]; then
          current="${current%/*}"
        else
          current=""
        fi
        ;;
      n)
        prompt new_folder "New folder name: "
        new_folder="$(trim_whitespace "$new_folder")"
        if [ -z "$new_folder" ] || [ "$new_folder" = "." ] || [ "$new_folder" = ".." ] || [[ "$new_folder" == *"/"* ]]; then
          echo "Invalid folder name. Use a single folder name without '/'."
          continue
        fi
        if [ -n "$current" ]; then
          current="${current}/${new_folder}"
        else
          current="$new_folder"
        fi
        if ! rclone mkdir "${remote}:${current}"; then
          echo "Unable to create the folder."
          if [[ "$current" == */* ]]; then
            current="${current%/*}"
          else
            current=""
          fi
        fi
        ;;
      q) return 1 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] \
          && [ "$choice" -ge 1 ] \
          && [ "$choice" -le "${#folders[@]}" ]; then
          if [ -n "$current" ]; then
            current="${current}/${folders[$((choice - 1))]}"
          else
            current="${folders[$((choice - 1))]}"
          fi
        else
          echo "Invalid selection."
        fi
        ;;
    esac
  done
}

upload_backup_to_cloud() {
  local project_name="$1"
  local app_dir="$2"
  local archive_path="$3"
  local retention_days="$4"
  local backup_kind="$5"
  local enabled cloud_retention_enabled provider remote folder remote_dir archive_name

  enabled="$(read_project_backup_cloud_enabled "$app_dir")"
  [ "$enabled" = "yes" ] || return 0
  cloud_retention_enabled="$(read_project_backup_cloud_retention_enabled "$app_dir")"

  provider="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_PROVIDER")"
  remote="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_REMOTE")"
  folder="$(normalize_backup_cloud_folder "$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_FOLDER")")"

  if [ "$provider" != "google-drive" ] && [ "$provider" != "onedrive" ]; then
    echo "Cloud backup is enabled but the provider is invalid for ${project_name}."
    return 1
  fi
  if [ -z "$remote" ] || ! command -v rclone >/dev/null 2>&1; then
    echo "Cloud backup is enabled for ${project_name}, but rclone or its remote is unavailable."
    return 1
  fi

  remote_dir="${remote}:${folder}"
  archive_name="$(basename "$archive_path")"
  echo "Uploading ${backup_kind} backup to ${provider} (${remote_dir})..."
  if ! rclone copyto "$archive_path" "${remote_dir}/${archive_name}" --retries 3 --low-level-retries 10; then
    echo "Cloud upload failed for ${project_name}."
    return 1
  fi

  if [ "$cloud_retention_enabled" = "yes" ]; then
    echo "Pruning cloud backups older than ${retention_days} day(s)..."
    if ! rclone delete "$remote_dir" \
      --min-age "${retention_days}d" \
      --include "${project_name}-*.tar.gz" \
      --max-depth 1; then
      echo "Cloud retention cleanup failed for ${project_name}."
      return 1
    fi
  fi

  echo "Cloud backup uploaded: ${remote_dir}/${archive_name}"
}

backup_state_file() {
  local project_name="$1"
  printf '%s/%s.last-success' "$BACKUP_STATE_DIR" "$project_name"
}

last_automatic_backup_time() {
  local project_name="$1"
  local state_file last_success latest_archive_time
  state_file="$(backup_state_file "$project_name")"
  last_success=""

  if [ -f "$state_file" ]; then
    read -r last_success < "$state_file" || true
  fi
  if [[ "$last_success" =~ ^[0-9]+$ ]]; then
    echo "$last_success"
    return 0
  fi

  latest_archive_time=""
  if [ -d "${BACKUPS_BASE}/${project_name}" ]; then
    latest_archive_time="$(
      find "${BACKUPS_BASE}/${project_name}" -maxdepth 1 -type f -name "${project_name}-*-auto.tar.gz" -printf '%T@\n' 2>/dev/null \
        | sort -nr \
        | awk 'NR == 1 {printf "%d", $1}'
    )"
  fi
  if [[ "$latest_archive_time" =~ ^[0-9]+$ ]]; then
    echo "$latest_archive_time"
  else
    echo "0"
  fi
}

project_automatic_backup_due() {
  local project_name="$1"
  local app_dir="$2"
  local now="$3"
  local interval_hours last_success interval_seconds
  interval_hours="$(read_project_backup_interval_hours "$app_dir")"
  last_success="$(last_automatic_backup_time "$project_name")"
  interval_seconds=$((interval_hours * 3600))

  [ "$last_success" -eq 0 ] || [ $((now - last_success)) -ge "$interval_seconds" ]
}

mark_automatic_backup_success() {
  local project_name="$1"
  local started_at="$2"
  local state_file
  mkdir -p "$BACKUP_STATE_DIR"
  chmod 700 "$BACKUP_STATE_DIR"
  state_file="$(backup_state_file "$project_name")"
  printf '%s\n' "$started_at" > "$state_file"
  chmod 600 "$state_file"
}

backup_project_internal() {
  local project_name="$1"
  local suffix="${2:-manual}"
  local app_dir app_profile backup_retention_days
  local BACKUP_RETENTION_DAYS=""
  app_dir="$(resolve_project_dir "$project_name")"

  ensure_project_exists "$project_name" "$app_dir"
  backup_retention_days="$(read_project_backup_retention_days "$app_dir")"

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"

  if [ "$app_profile" != "node" ]; then
    require_nonempty "DB_CONTAINER" "${DB_CONTAINER}"
    require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
    require_nonempty "DB_NAME" "${DB_NAME}"
  fi

  local timestamp backup_dir tmp_sql archive_name archive_path
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUPS_BASE}/${project_name}/${timestamp}-${suffix}"
  tmp_sql="${backup_dir}/database.sql"
  archive_name="${project_name}-${timestamp}-${suffix}.tar.gz"
  archive_path="${BACKUPS_BASE}/${project_name}/${archive_name}"

  if ! mkdir -p "$backup_dir" || ! : > "$tmp_sql"; then
    echo "Unable to prepare backup directory: ${backup_dir}"
    return 1
  fi

  if [ "$app_profile" = "node" ]; then
    echo "Skipping database export for node project."
  else
    echo "Exporting database..."
    if docker_container_exists "${DB_CONTAINER}"; then
      if ! docker exec "${DB_CONTAINER}" sh -c \
        "exec mariadb-dump -u root -p'${DB_ROOT_PASSWORD}' '${DB_NAME}'" > "$tmp_sql"; then
        echo "Database export failed for ${project_name}."
        rm -rf "$backup_dir" || true
        return 1
      fi
    else
      echo "Warning: DB container does not exist (${DB_CONTAINER}). Backup without database."
    fi
  fi

  echo "Copying project files..."
  if ! mkdir -p "${backup_dir}/project"; then
    echo "Unable to prepare the project backup directory."
    rm -rf "$backup_dir" || true
    return 1
  fi
  if ! rsync -a \
    --exclude vendor \
    --exclude node_modules \
    --exclude storage/logs \
    --exclude storage/framework/cache \
    --exclude storage/framework/sessions \
    --exclude storage/framework/views \
    --exclude .git \
    "${app_dir}/" "${backup_dir}/project/"; then
    echo "Project file copy failed for ${project_name}."
    rm -rf "$backup_dir" || true
    return 1
  fi

  if ! cp "${app_dir}/.project-meta" "${backup_dir}/.project-meta"; then
    echo "Unable to include project metadata in the backup."
    rm -rf "$backup_dir" || true
    return 1
  fi

  echo "Compressing backup..."
  if ! tar -czf "$archive_path" -C "${backup_dir}" .; then
    echo "Backup compression failed for ${project_name}."
    rm -rf "$backup_dir" || true
    rm -f "$archive_path" || true
    return 1
  fi

  rm -rf "$backup_dir" || true

  echo "Backup created: ${archive_path}"

  echo "Pruning backups older than ${backup_retention_days} day(s)..."
  prune_project_backups "$project_name" "$backup_retention_days"

  if should_replicate_backup_to_cloud "$app_dir" "$suffix"; then
    if ! upload_backup_to_cloud "$project_name" "$app_dir" "$archive_path" "$backup_retention_days" "$suffix"; then
      return 3
    fi
  fi
}

backup_project() {
  local project_slug project_name backup_status
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
  if backup_project_internal "$project_name" "manual"; then
    return 0
  else
    backup_status=$?
  fi

  if [ "$backup_status" -eq 3 ]; then
    echo "Local manual backup succeeded for ${project_name}, but its cloud copy failed."
    return 1
  fi
  return "$backup_status"
}

backup_project_for_run() {
  local project_name="$1"
  local mode="$2"
  local app_dir interval_hours started_at
  app_dir="$(resolve_project_dir "$project_name")"

  if [ "$mode" = "scheduled" ]; then
    interval_hours="$(read_project_backup_interval_hours "$app_dir")"
    started_at="$(date +%s)"
    if ! project_automatic_backup_due "$project_name" "$app_dir" "$started_at"; then
      echo "Skipping ${project_name}: next automatic backup is not due (${interval_hours}-hour interval)."
      return 2
    fi
  else
    started_at="$(date +%s)"
  fi

  echo "Starting automatic backup for ${project_name}..."
  local backup_status
  if (backup_project_internal "$project_name" "auto"); then
    backup_status=0
  else
    backup_status=$?
  fi

  case "$backup_status" in
    0)
      mark_automatic_backup_success "$project_name" "$started_at"
      return 0
      ;;
    3)
      mark_automatic_backup_success "$project_name" "$started_at"
      echo "Local backup succeeded for ${project_name}, but its cloud copy failed."
      return 1
      ;;
    *)
      echo "Automatic backup failed for ${project_name}."
      return 1
      ;;
  esac
}

backup_all() {
  local mode="${1:-force}"
  local failures=0 backed_up=0 skipped=0 project_name

  if [ "$mode" != "force" ] && [ "$mode" != "scheduled" ]; then
    echo "Invalid backup mode: ${mode}"
    return 1
  fi

  if [ -d "$PROXY_PROJECTS_DIR" ] && [ -n "$(ls -A "$PROXY_PROJECTS_DIR" 2>/dev/null)" ]; then
    for link in "$PROXY_PROJECTS_DIR"/*; do
      [ -e "$link" ] || continue
      project_name="$(basename "$link")"
      if backup_project_for_run "$project_name" "$mode"; then
        backed_up=$((backed_up + 1))
      else
        case "$?" in
          2) skipped=$((skipped + 1)) ;;
          *) failures=$((failures + 1)) ;;
        esac
      fi
    done
  elif [ ! -d "$PROJECTS_BASE" ] || [ -z "$(ls -A "$PROJECTS_BASE" 2>/dev/null)" ]; then
    echo "No projects to back up."
    return 0
  else
    for dir in "$PROJECTS_BASE"/*; do
      [ -d "$dir" ] || continue
      project_name="$(basename "$dir")"
      if backup_project_for_run "$project_name" "$mode"; then
        backed_up=$((backed_up + 1))
      else
        case "$?" in
          2) skipped=$((skipped + 1)) ;;
          *) failures=$((failures + 1)) ;;
        esac
      fi
    done
  fi

  echo "Automatic backup run complete: ${backed_up} created, ${skipped} not due, ${failures} failed."
  [ "$failures" -eq 0 ]
}

manage_backup_settings() {
  local project_slug project_name app_dir current_days new_days current_hours new_hours
  local current_cloud_enabled current_cloud_scope current_cloud_retention_enabled
  local current_provider current_remote current_folder
  local enable_cloud enable_cloud_retention scope_choice scope_default provider_choice
  local new_cloud_enabled="no" new_cloud_scope="automatic" new_provider="" new_remote="" new_folder=""
  local new_cloud_retention_enabled="yes"

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name for backup settings: "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"

  if [ ! -f "${app_dir}/.project-meta" ]; then
    echo "Project metadata not found at ${app_dir}/.project-meta"
    echo "Backup settings require a project created or managed by this script."
    exit 1
  fi

  current_days="$(read_project_backup_retention_days "$app_dir")"
  current_hours="$(read_project_backup_interval_hours "$app_dir")"
  current_cloud_enabled="$(read_project_backup_cloud_enabled "$app_dir")"
  current_cloud_scope="$(read_project_backup_cloud_scope "$app_dir")"
  new_cloud_scope="$current_cloud_scope"
  current_cloud_retention_enabled="$(read_project_backup_cloud_retention_enabled "$app_dir")"
  new_cloud_retention_enabled="$current_cloud_retention_enabled"
  current_provider="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_PROVIDER")"
  current_remote="$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_REMOTE")"
  current_folder="$(normalize_backup_cloud_folder "$(read_project_meta_var "$app_dir" "BACKUP_CLOUD_FOLDER")")"

  echo ""
  echo "Backup settings for ${project_name}"
  echo "Current retention: keep backups for the last ${current_days} day(s)."
  echo "Current automatic interval: every ${current_hours} hour(s)."
  if [ "$current_cloud_enabled" = "yes" ]; then
    echo "Current cloud copy: ${current_provider} (${current_remote}:${current_folder:-/}); scope: ${current_cloud_scope}."
    if [ "$current_cloud_retention_enabled" = "yes" ]; then
      echo "Current cloud retention: same ${current_days}-day limit as local backups."
    else
      echo "Current cloud retention: disabled."
    fi
  else
    echo "Current cloud copy: disabled."
  fi
  prompt new_days "Days of backups to keep (e.g. 60): " "$current_days"

  if ! validate_backup_retention_days "$new_days"; then
    echo "Invalid retention. Use a whole number between 1 and 3650."
    exit 1
  fi

  prompt new_hours "Hours between automatic backups (1-24): " "$current_hours"
  if ! validate_backup_interval_hours "$new_hours"; then
    echo "Invalid interval. Use a whole number between 1 and 24."
    exit 1
  fi

  prompt enable_cloud "Replicate backups to Google Drive or OneDrive? (yes/no): " "$current_cloud_enabled"
  if ! new_cloud_enabled="$(normalize_yes_no "$enable_cloud")"; then
    echo "Invalid choice. Use yes or no."
    exit 1
  fi

  if [ "$new_cloud_enabled" = "yes" ]; then
    echo ""
    echo "Backups to replicate:"
    echo "1) Manual backups only"
    echo "2) Automatic backups only"
    echo "3) Manual and automatic backups"
    case "$current_cloud_scope" in
      manual) scope_default="1" ;;
      both) scope_default="3" ;;
      *) scope_default="2" ;;
    esac
    prompt scope_choice "Selection: " "$scope_default"
    case "$scope_choice" in
      1) new_cloud_scope="manual" ;;
      2) new_cloud_scope="automatic" ;;
      3) new_cloud_scope="both" ;;
      *) echo "Invalid backup replication scope."; exit 1 ;;
    esac

    prompt enable_cloud_retention "Apply the same retention limit to cloud backups? (yes/no): " "$current_cloud_retention_enabled"
    if ! new_cloud_retention_enabled="$(normalize_yes_no "$enable_cloud_retention")"; then
      echo "Invalid choice. Use yes or no."
      exit 1
    fi

    if ! ensure_latest_stable_rclone; then
      exit 1
    fi

    echo ""
    echo "Cloud provider:"
    echo "1) Google Drive"
    echo "2) OneDrive"
    if [ "$current_provider" = "onedrive" ]; then
      prompt provider_choice "Selection: " "2"
    else
      prompt provider_choice "Selection: " "1"
    fi
    case "$provider_choice" in
      1) new_provider="google-drive" ;;
      2) new_provider="onedrive" ;;
      *) echo "Invalid cloud provider."; exit 1 ;;
    esac

    if ! select_rclone_remote "$new_provider"; then
      echo "Cloud backup configuration cancelled. No backup settings were changed."
      return 1
    fi
    new_remote="$SELECTED_RCLONE_REMOTE"

    if [ "$new_remote" = "$current_remote" ]; then
      current_folder="$(normalize_backup_cloud_folder "$current_folder")"
    else
      current_folder=""
    fi
    if ! browse_rclone_folder "$new_remote" "$current_folder"; then
      echo "Cloud folder selection cancelled. No backup settings were changed."
      return 1
    fi
    new_folder="$SELECTED_RCLONE_FOLDER"
  fi

  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_RETENTION_DAYS" "$new_days"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_INTERVAL_HOURS" "$new_hours"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_ENABLED" "$new_cloud_enabled"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_SCOPE" "$new_cloud_scope"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_RETENTION_ENABLED" "$new_cloud_retention_enabled"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_PROVIDER" "$new_provider"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_REMOTE" "$new_remote"
  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_CLOUD_FOLDER" "$new_folder"
  chmod 600 "${app_dir}/.project-meta"
  setup_backup_cron

  echo ""
  echo "Backup settings updated."
  echo "Project: ${project_name}"
  echo "Keep backups for the last ${new_days} day(s)."
  echo "Automatic backup interval: every ${new_hours} hour(s)."
  if [ "$new_cloud_enabled" = "yes" ]; then
    echo "Cloud copy: ${new_provider} (${new_remote}:${new_folder:-/})."
    echo "Cloud replication scope: ${new_cloud_scope}."
    if [ "$new_cloud_retention_enabled" = "yes" ]; then
      echo "Cloud copies use the same ${new_days}-day retention as local backups."
    else
      echo "Cloud retention cleanup: disabled. Cloud backups are kept until removed manually."
    fi
  else
    echo "Cloud copy: disabled."
  fi
  echo "Old local backups are pruned whenever a backup runs."
  if [ "$new_cloud_enabled" = "yes" ] && [ "$new_cloud_retention_enabled" = "yes" ]; then
    echo "Old cloud backups are pruned whenever a backup is replicated."
  fi
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
  local app_profile
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"

  if [ "$app_profile" != "node" ]; then
    require_nonempty "DB_CONTAINER" "${DB_CONTAINER}"
    require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
    require_nonempty "DB_NAME" "${DB_NAME}"
  fi

  echo "Stopping project services..."
  cd "$app_dir"
  dc down || true

  echo "Restoring files..."
  rsync -a --delete "${tmp_restore}/project/" "${app_dir}/"

  echo "Starting services..."
  dc up -d --build

  sleep 10

  if [ "$app_profile" = "node" ]; then
    echo "Skipping database restore for node project."
  else
    echo "Restoring database..."
    docker exec -i "${DB_CONTAINER}" sh -c \
      "exec mariadb -u root -p'${DB_ROOT_PASSWORD}' '${DB_NAME}'" < "${tmp_restore}/database.sql"
  fi

  proxy_dc restart reverse-proxy

  rm -rf "$tmp_restore"

  echo "Restore completed."
}

update_project() {
  local project_slug project_name app_dir pma_port pma_bind_ip reverb_enabled reverb_domain reverb_port reverb_exposure app_profile
  local guacamole_proxy_enabled guacamole_proxy_upstream
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

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"
  require_nonempty "DOMAIN" "${DOMAIN}"
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  if [ "$app_profile" != "node" ]; then
    require_nonempty "DB_NAME" "${DB_NAME}"
    require_nonempty "DB_USER" "${DB_USER}"
    require_nonempty "DB_PASSWORD" "${DB_PASSWORD}"
    require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
  fi

  prompt_project_tuning "$app_dir" "$app_profile" "update project"

  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"
  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"
  guacamole_proxy_enabled="${GUACAMOLE_PROXY_ENABLED:-no}"
  if ! guacamole_proxy_enabled="$(normalize_yes_no "$guacamole_proxy_enabled")"; then
    guacamole_proxy_enabled="no"
  fi
  guacamole_proxy_upstream="$(normalize_guacamole_upstream "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}")"

  echo "Regenerating project configuration..."
  write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
  write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
  if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
    write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
  else
    remove_reverb_proxy_config "$PROJECT_NAME"
  fi

  cd "$app_dir"
  dc up -d --build
  proxy_dc restart reverse-proxy
  if [ "$app_profile" = "laravel" ]; then
    refresh_project_runtime_after_env_change "$app_dir" "$PROJECT_NAME" "$DOMAIN" >/dev/null 2>&1 || true
  fi
  ensure_cron_jobs

  echo "Project updated."
}

phpmyadmin_manage() {
  local project_slug project_name app_dir pma_container pma_port pma_bind_ip action new_port exposure confirm server_ip

  server_ip="$(detect_server_ip)"

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
    echo "  - Public: http://${server_ip}:${pma_port}/"
  else
    echo "  - On the server: http://127.0.0.1:${pma_port}/"
  fi
  echo "  - From your computer via SSH tunnel:"
  echo "      ssh -L 8080:127.0.0.1:${pma_port} root@${server_ip}"
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
        echo "phpMyAdmin enabled on http://${server_ip}:${new_port}/ (public)."
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
        echo "phpMyAdmin is now public on http://${server_ip}:${pma_port}/"
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
        echo "phpMyAdmin port updated to http://${server_ip}:${new_port}/ (public)."
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

manage_project_ufw() {
  local project_slug project_name app_dir action app_profile
  local pma_port pma_bind_ip saved_sources saved_restricted saved_ufw_port
  local new_sources normalized_sources confirm ufw_status

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (UFW): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"

  if [ ! -f "${app_dir}/.project-meta" ]; then
    echo "Project metadata not found at ${app_dir}/.project-meta"
    echo "Run 'Update project' once to regenerate project files."
    exit 1
  fi

  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "${app_dir}/.project-meta"
  require_nonempty "PROJECT_NAME" "${PROJECT_NAME}"
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"
  saved_sources="$(read_project_ufw_pma_allowed_sources "$app_dir")"
  saved_restricted="$(read_project_ufw_pma_restricted "$app_dir")"
  saved_ufw_port="$(read_project_ufw_pma_port "$app_dir" "$pma_port")"

  if [ "$app_profile" = "node" ] || ! grep -q "^[[:space:]]*phpmyadmin:" "${app_dir}/docker-compose.yml"; then
    echo "No per-project direct ports are managed by UFW for this project."
    echo "Normal website traffic uses the shared reverse proxy on ports 80 and 443."
    exit 1
  fi

  ensure_ufw_available

  ufw_status="$(ufw status 2>/dev/null | head -n 1 || true)"

  echo ""
  echo "Project UFW"
  echo "Project       : ${PROJECT_NAME}"
  echo "Web traffic   : shared reverse proxy ports 80/443"
  if [ "$pma_bind_ip" = "0.0.0.0" ]; then
    echo "phpMyAdmin   : 0.0.0.0:${pma_port} (public bind)"
  else
    echo "phpMyAdmin   : 127.0.0.1:${pma_port} (localhost-only bind)"
  fi
  echo "UFW status    : ${ufw_status:-unknown}"
  echo "Saved sources : ${saved_sources:-none}"
  echo "Restricted    : ${saved_restricted}"
  if [ -n "$saved_ufw_port" ] && [ "$saved_ufw_port" != "$pma_port" ]; then
    echo "Saved UFW port: ${saved_ufw_port} (current phpMyAdmin port is ${pma_port})"
  fi
  echo ""
  echo "Matching UFW rules for phpMyAdmin port ${pma_port}:"
  show_matching_ufw_pma_rules "$pma_port"
  echo ""
  echo "Matching Docker rules for phpMyAdmin port ${pma_port}:"
  show_matching_docker_pma_rules "$pma_port"
  echo ""
  echo "Note: UFW cannot isolate individual project domains on shared ports 80/443."
  echo "Note: Docker-published ports are filtered through ${DOCKER_PMA_FIREWALL_CHAIN}."
  echo ""

  prompt action "Action [status/restrict-phpmyadmin/block-phpmyadmin/clear-phpmyadmin-rules/show-ufw]: " "status"

  case "${action,,}" in
    status)
      return 0
      ;;
    show-ufw)
      ufw status numbered
      ;;
    restrict-phpmyadmin)
      if [ "$pma_bind_ip" != "0.0.0.0" ]; then
        echo ""
        echo "phpMyAdmin is currently bound to localhost only."
        echo "UFW rules will be saved, but public access still requires menu option 8 -> expose -> public."
      fi

      echo ""
      echo "This will allow the listed IP/CIDR sources and deny other traffic to ${pma_port}/tcp."
      prompt new_sources "Allowed IP/CIDR list (comma-separated, e.g. 203.0.113.10,203.0.113.0/24): " "$saved_sources"
      if ! normalized_sources="$(normalize_ufw_sources_csv "$new_sources")"; then
        echo "Invalid source list. Use IPv4/IPv6 addresses or CIDR ranges separated by commas."
        exit 1
      fi

      prompt confirm "Apply UFW phpMyAdmin rules for ${PROJECT_NAME}? (yes/no): " "yes"
      if [ "${confirm,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi

      apply_ufw_pma_rules "$PROJECT_NAME" "$pma_port" "$saved_ufw_port" "$saved_sources" "$normalized_sources" "$saved_restricted"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_ALLOWED_SOURCES" "$normalized_sources"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_RESTRICTED" "yes"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_PORT" "$pma_port"
      enable_ufw_if_inactive
      sync_docker_pma_firewall_rules

      echo "Project UFW phpMyAdmin rules applied."
      echo "Allowed sources: ${normalized_sources}"
      echo "Denied by default: ${pma_port}/tcp"
      echo "Docker-published access is filtered through ${DOCKER_PMA_FIREWALL_CHAIN}."
      ;;
    block-phpmyadmin)
      echo ""
      echo "This will deny public Docker-published traffic to ${pma_port}/tcp for phpMyAdmin."
      echo "You can still use phpMyAdmin through a localhost bind or an SSH tunnel if enabled that way."
      prompt confirm "Block public phpMyAdmin access for ${PROJECT_NAME}? (yes/no): " "yes"
      if [ "${confirm,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi

      apply_ufw_pma_rules "$PROJECT_NAME" "$pma_port" "$saved_ufw_port" "$saved_sources" "" "$saved_restricted"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_ALLOWED_SOURCES" ""
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_RESTRICTED" "yes"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_PORT" "$pma_port"
      enable_ufw_if_inactive

      sync_docker_pma_firewall_rules

      echo "Public phpMyAdmin access is blocked on ${pma_port}/tcp."
      echo "Docker-published access is filtered through ${DOCKER_PMA_FIREWALL_CHAIN}."
      ;;
    clear-phpmyadmin-rules)
      prompt confirm "Remove saved UFW phpMyAdmin rules for ${PROJECT_NAME}? (yes/no): " "no"
      if [ "${confirm,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi

      delete_ufw_pma_rules "$saved_ufw_port" "$saved_sources" "$saved_restricted"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_ALLOWED_SOURCES" ""
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_RESTRICTED" "no"
      set_project_meta_var "${app_dir}/.project-meta" "UFW_PMA_PORT" ""
      sync_docker_pma_firewall_rules

      echo "Saved UFW phpMyAdmin rules cleared for ${PROJECT_NAME}."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

manage_project_access() {
  local project_slug project_name app_dir action app_profile
  local allowed_sources restricted new_sources normalized_sources confirm

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (access settings): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"

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
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  allowed_sources="$(read_project_access_allowed_sources "$app_dir")"
  restricted="$(read_project_access_restricted "$app_dir")"

  echo ""
  echo "Project access"
  echo "Project : ${PROJECT_NAME}"
  echo "Domain  : ${DOMAIN}"
  echo "Profile : ${app_profile}"
  if [ "$restricted" = "yes" ] && [ -n "$allowed_sources" ]; then
    echo "Mode    : restricted"
    echo "Allowed : ${allowed_sources}"
  else
    echo "Mode    : public"
  fi
  echo ""
  echo "This controls Nginx access for this project's website on ports 80/443."
  echo "Let's Encrypt ACME challenge paths remain public for certificate renewal."
  echo ""

  prompt action "Action [status/restrict/clear]: " "status"

  case "${action,,}" in
    status)
      return 0
      ;;
    restrict)
      prompt new_sources "Allowed IP/CIDR list (comma-separated, e.g. 203.0.113.10,203.0.113.0/24): " "$allowed_sources"
      if ! normalized_sources="$(normalize_ufw_sources_csv "$new_sources")"; then
        echo "Invalid source list. Use IPv4/IPv6 addresses or CIDR ranges separated by commas."
        exit 1
      fi

      echo ""
      echo "This will restrict ${DOMAIN} to:"
      echo "  ${normalized_sources}"
      prompt confirm "Apply project access restriction? (yes/no): " "yes"
      if [ "${confirm,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi

      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_ACCESS_ALLOWED_SOURCES" "$normalized_sources"
      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_ACCESS_RESTRICTED" "yes"
      regenerate_project_proxy_config "$PROJECT_NAME" "$DOMAIN"

      echo "Project access restricted for ${DOMAIN}."
      echo "Allowed sources: ${normalized_sources}"
      ;;
    clear)
      prompt confirm "Remove project access restriction for ${DOMAIN}? (yes/no): " "no"
      if [ "${confirm,,}" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi

      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_ACCESS_ALLOWED_SOURCES" ""
      set_project_meta_var "${app_dir}/.project-meta" "PROJECT_ACCESS_RESTRICTED" "no"
      regenerate_project_proxy_config "$PROJECT_NAME" "$DOMAIN"

      echo "Project access is now public for ${DOMAIN}."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

reset_database_passwords() {
  local project_slug project_name app_dir scope
  local new_db_password new_root_password confirm
  local db_user_sql db_password_sql root_password_sql db_name_sql
  local pma_port pma_bind_ip reverb_enabled reverb_domain reverb_port reverb_exposure app_profile
  local guacamole_proxy_enabled guacamole_proxy_upstream

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (database passwords): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"

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
  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  if [ "$app_profile" = "node" ]; then
    echo "Node projects do not have a managed MariaDB database."
    exit 1
  fi
  require_nonempty "DB_NAME" "${DB_NAME}"
  require_nonempty "DB_USER" "${DB_USER}"
  require_nonempty "DB_PASSWORD" "${DB_PASSWORD}"
  require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
  require_nonempty "DB_CONTAINER" "${DB_CONTAINER}"

  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"
  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"
  guacamole_proxy_enabled="${GUACAMOLE_PROXY_ENABLED:-no}"
  if ! guacamole_proxy_enabled="$(normalize_yes_no "$guacamole_proxy_enabled")"; then
    guacamole_proxy_enabled="no"
  fi
  guacamole_proxy_upstream="$(normalize_guacamole_upstream "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}")"

  echo ""
  echo "Database password reset"
  echo "Project : ${PROJECT_NAME}"
  echo "Database: ${DB_NAME}"
  echo "DB user : ${DB_USER}"
  echo ""

  prompt scope "Reset which password [app/root/both]: " "app"
  scope="${scope,,}"
  case "$scope" in
    app|root|both) ;;
    *)
      echo "Invalid option: ${scope}"
      exit 1
      ;;
  esac

  new_db_password="${DB_PASSWORD}"
  new_root_password="${DB_ROOT_PASSWORD}"

  if [ "$scope" = "app" ] || [ "$scope" = "both" ]; then
    prompt_secret new_db_password "New password for DB user ${DB_USER}: "
    if [ -z "$new_db_password" ]; then
      echo "DB user password is required."
      exit 1
    fi
  fi

  if [ "$scope" = "root" ] || [ "$scope" = "both" ]; then
    prompt_secret new_root_password "New MariaDB root password: "
    if [ -z "$new_root_password" ]; then
      echo "Root password is required."
      exit 1
    fi
  fi

  echo ""
  echo "This will update MariaDB credentials and regenerate project configuration."
  if [ "$scope" = "app" ] || [ "$scope" = "both" ]; then
    echo "  - Application DB user password"
  fi
  if [ "$scope" = "root" ] || [ "$scope" = "both" ]; then
    echo "  - MariaDB root password"
  fi
  read -r -p "Type YES to continue: " confirm
  if [ "$confirm" != "YES" ]; then
    echo "Cancelled."
    exit 0
  fi

  cd "$app_dir"
  dc up -d mariadb >/dev/null

  echo "Waiting for MariaDB..."
  if ! docker_container_exists "${DB_CONTAINER}" || ! wait_for_mariadb_root "${DB_CONTAINER}" "${DB_ROOT_PASSWORD}"; then
    echo "Failed to connect to MariaDB with the current root password from project metadata."
    exit 1
  fi

  db_user_sql="$(sql_escape_literal "$DB_USER")"
  db_password_sql="$(sql_escape_literal "$new_db_password")"
  root_password_sql="$(sql_escape_literal "$new_root_password")"
  db_name_sql="$(sql_escape_identifier "$DB_NAME")"

  echo "Updating MariaDB credentials..."
  if ! docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" -i "${DB_CONTAINER}" mariadb -u root <<EOF
$( [ "$scope" = "app" ] || [ "$scope" = "both" ] && cat <<SQL
CREATE USER IF NOT EXISTS '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
ALTER USER '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'%';
SQL
)
$( [ "$scope" = "root" ] || [ "$scope" = "both" ] && cat <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_password_sql}';
SQL
)
FLUSH PRIVILEGES;
EOF
  then
    echo "Failed to update database credentials."
    exit 1
  fi

  if [ "$scope" = "app" ] || [ "$scope" = "both" ]; then
    DB_PASSWORD="$new_db_password"
  fi
  if [ "$scope" = "root" ] || [ "$scope" = "both" ]; then
    DB_ROOT_PASSWORD="$new_root_password"
  fi

  echo "Regenerating project configuration..."
  write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
  write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
  if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
    write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
  else
    remove_reverb_proxy_config "$PROJECT_NAME"
  fi

  dc up -d --force-recreate mariadb >/dev/null
  if grep -q "^[[:space:]]*phpmyadmin:" "${app_dir}/docker-compose.yml"; then
    dc up -d phpmyadmin >/dev/null 2>&1 || true
  fi
  proxy_dc restart reverse-proxy >/dev/null 2>&1 || true

  echo "Database password reset completed."
  if [ "$scope" = "app" ] || [ "$scope" = "both" ]; then
    echo "Update your app .env / secrets with the new DB user password."
  fi
}

manage_reverb() {
  local project_slug project_name app_dir action reverb_enabled reverb_domain reverb_port reverb_exposure cert_email remove_old suggested_domain
  local new_reverb_domain new_reverb_port new_reverb_exposure
  local app_profile guacamole_proxy_enabled guacamole_proxy_upstream

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

  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  if [ "$app_profile" != "laravel" ]; then
    echo "Reverb management is only supported for Laravel projects."
    echo "Current profile: ${app_profile}"
    exit 1
  fi

  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"
  guacamole_proxy_enabled="${GUACAMOLE_PROXY_ENABLED:-no}"
  if ! guacamole_proxy_enabled="$(normalize_yes_no "$guacamole_proxy_enabled")"; then
    guacamole_proxy_enabled="no"
  fi
  guacamole_proxy_upstream="$(normalize_guacamole_upstream "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}")"

  echo ""
  echo "Reverb"
  echo "Status : ${reverb_enabled}"
  if [ -n "$reverb_domain" ]; then
    echo "Domain : ${reverb_domain}"
  fi
  echo "Port   : ${reverb_port}"
  echo "Scope  : ${reverb_exposure}"
  echo ""

  prompt action "Action [status/enable/change-domain/change-port/exposure/restart/disable]: " "status"

  case "${action,,}" in
    status)
      if [ "$reverb_enabled" = "yes" ]; then
        print_reverb_runtime_diagnostics "$PROJECT_NAME" "$reverb_port" "$reverb_domain" || true
      fi
      return 0
      ;;
    restart)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is not enabled."
        exit 1
      fi

      echo "Rebuilding PHP container and restarting reverse proxy..."
      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      if [ -n "$reverb_domain" ]; then
        write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
      fi

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

      print_reverb_runtime_diagnostics "$PROJECT_NAME" "$reverb_port" "$reverb_domain" || true
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

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

      echo ""
      echo "Reverb enabled: https://${reverb_domain}"
      echo "Exposure: ${reverb_exposure}"
      echo "Update your Laravel app if needed:"
      echo "  composer require laravel/reverb"
      echo "  php artisan reverb:install"
      print_reverb_env_block "$reverb_exposure" "$reverb_domain" "$reverb_port"
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

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$new_reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$new_reverb_domain" "$reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

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

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$new_reverb_port" "$reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$new_reverb_port" "$reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

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

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "yes" "$reverb_domain" "$reverb_port" "$new_reverb_exposure" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$new_reverb_exposure"

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

      echo "Reverb exposure updated: ${new_reverb_exposure}."
      ;;
    disable)
      if [ "$reverb_enabled" != "yes" ]; then
        echo "Reverb is already disabled."
        exit 0
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}" "${PMA_BIND_IP:-127.0.0.1}" "no" "" "${reverb_port}" "${reverb_exposure}" "$app_profile" "$guacamole_proxy_enabled" "$guacamole_proxy_upstream"
      remove_reverb_proxy_config "$PROJECT_NAME"

      cd "$app_dir"
      dc up -d --build php
      proxy_dc restart reverse-proxy

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

manage_guacamole_proxy() {
  local project_slug project_name app_dir action app_profile
  local db_name db_user db_password db_root_password
  local pma_port pma_bind_ip reverb_enabled reverb_domain reverb_port reverb_exposure
  local guacamole_proxy_enabled guacamole_proxy_upstream new_guacamole_proxy_upstream
  local stack_present web_running guacd_running managed_guacamole_secret managed_guacamole_version project_env_path

  echo ""
  echo "Existing projects:"
  print_existing_projects
  echo ""
  prompt project_slug "Project short name (Guacamole proxy): "
  project_name="$(slug_to_name "$project_slug")"
  if [ -z "$project_name" ]; then
    echo "Invalid project short name."
    exit 1
  fi

  app_dir="$(resolve_project_dir "$project_name")"
  ensure_project_exists "$project_name" "$app_dir"

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

  app_profile="${APP_PROFILE:-$(detect_project_profile "$app_dir")}"
  db_name="${DB_NAME:-}"
  db_user="${DB_USER:-}"
  db_password="${DB_PASSWORD:-}"
  db_root_password="${DB_ROOT_PASSWORD:-}"
  if [ "$app_profile" != "node" ]; then
    require_nonempty "DB_NAME" "${db_name}"
    require_nonempty "DB_USER" "${db_user}"
    require_nonempty "DB_PASSWORD" "${db_password}"
    require_nonempty "DB_ROOT_PASSWORD" "${db_root_password}"
  fi

  pma_port="${PMA_PORT:-$(pma_default_port "$PROJECT_NAME")}"
  pma_bind_ip="${PMA_BIND_IP:-127.0.0.1}"
  reverb_enabled="${REVERB_ENABLED:-no}"
  reverb_domain="${REVERB_DOMAIN:-}"
  reverb_port="${REVERB_PORT:-8080}"
  reverb_exposure="${REVERB_EXPOSURE:-local}"
  guacamole_proxy_enabled="${GUACAMOLE_PROXY_ENABLED:-no}"
  if ! guacamole_proxy_enabled="$(normalize_yes_no "$guacamole_proxy_enabled")"; then
    guacamole_proxy_enabled="no"
  fi
  guacamole_proxy_upstream="$(normalize_guacamole_upstream "${GUACAMOLE_PROXY_UPSTREAM:-$GUACAMOLE_DEFAULT_UPSTREAM}")"
  managed_guacamole_secret="$(guacamole_saved_secret)"
  managed_guacamole_version="$(guacamole_saved_version)"
  project_env_path="$(detect_project_env_path "$app_dir" || true)"
  [ -n "$managed_guacamole_version" ] || managed_guacamole_version="$GUACAMOLE_DEFAULT_VERSION"

  stack_present="no"
  [ -f "$GUACAMOLE_COMPOSE" ] && stack_present="yes"
  web_running="no"
  docker_container_running "$GUACAMOLE_WEB_CONTAINER_NAME" && web_running="yes"
  guacd_running="no"
  docker_container_running "$GUACAMOLE_GUACD_CONTAINER_NAME" && guacd_running="yes"

  echo ""
  echo "Guacamole"
  echo "Proxy status : ${guacamole_proxy_enabled}"
  echo "Upstream     : ${guacamole_proxy_upstream}"
  echo "Shared stack : ${stack_present} (web=${web_running}, guacd=${guacd_running})"
  echo "Project      : https://${DOMAIN}"
  echo "Proxy URL    : https://${DOMAIN}/guacamole/"
  echo ""
  echo "If you keep the default upstream (${GUACAMOLE_DEFAULT_UPSTREAM}), this"
  echo "manager can provision and maintain the shared Apache Guacamole stack."
  echo ""

  prompt action "Action [status/install-stack/enable/change-upstream/disable]: " "status"

  case "${action,,}" in
    status)
      echo ""
      echo "Managed stack path : ${GUACAMOLE_BASE}"
      echo "Managed compose    : ${GUACAMOLE_COMPOSE}"
      echo "Managed version    : ${managed_guacamole_version}"
      if [ -n "$managed_guacamole_secret" ]; then
        echo "Managed JSON secret: ${managed_guacamole_secret}"
      else
        echo "Managed JSON secret: not generated yet"
      fi
      echo ""
      echo "Project .env values:"
      if [ -n "$managed_guacamole_secret" ] && [ "$guacamole_proxy_upstream" = "$GUACAMOLE_DEFAULT_UPSTREAM" ]; then
        echo "  GUACAMOLE_ENABLED=true"
        echo "  GUACAMOLE_BASE_URL=https://${DOMAIN}/guacamole"
        echo "  GUACAMOLE_JSON_SECRET_KEY=${managed_guacamole_secret}"
        echo "  GUACAMOLE_EMBED_ALLOWED=true"
      else
        echo "  GUACAMOLE_ENABLED=true"
        echo "  GUACAMOLE_BASE_URL=https://${DOMAIN}/guacamole"
        echo "  GUACAMOLE_JSON_SECRET_KEY=YOUR_GUACAMOLE_JSON_SECRET_KEY"
        echo "  GUACAMOLE_EMBED_ALLOWED=true"
      fi
      if [ -n "$project_env_path" ]; then
        echo ""
        echo "Detected app env   : ${project_env_path}"
      else
        echo ""
        echo "Detected app env   : not found (checked project root, public/.env, and public/**/.env)"
      fi
      return 0
      ;;
    install-stack)
      ensure_managed_guacamole_stack "$managed_guacamole_version"
      managed_guacamole_secret="$(guacamole_saved_secret)"

      echo ""
      echo "Managed Apache Guacamole stack is installed."
      echo "Upstream: ${GUACAMOLE_DEFAULT_UPSTREAM}"
      echo "JSON secret: ${managed_guacamole_secret}"

      if sync_project_guacamole_env "$app_dir" "$DOMAIN" "$managed_guacamole_secret"; then
        echo "Updated ${project_env_path:-${app_dir}/.env} with GUACAMOLE_* values."
        if refresh_project_runtime_after_env_change "$app_dir" "$PROJECT_NAME" "$DOMAIN"; then
          echo "Restarted the PHP container so the new GUACAMOLE_* values take effect."
        fi
      else
        echo "Project .env not found. Set these values manually:"
        echo "  GUACAMOLE_ENABLED=true"
        echo "  GUACAMOLE_BASE_URL=https://${DOMAIN}/guacamole"
        echo "  GUACAMOLE_JSON_SECRET_KEY=${managed_guacamole_secret}"
        echo "  GUACAMOLE_EMBED_ALLOWED=true"
      fi
      return 0
      ;;
    enable)
      prompt new_guacamole_proxy_upstream "Guacamole upstream [${guacamole_proxy_upstream}]: " "${guacamole_proxy_upstream}"
      new_guacamole_proxy_upstream="$(normalize_guacamole_upstream "$new_guacamole_proxy_upstream")"
      if ! validate_guacamole_upstream "$new_guacamole_proxy_upstream"; then
        echo "Invalid Guacamole upstream: ${new_guacamole_proxy_upstream}"
        echo "Use host:port, for example guacamole-web:8080"
        exit 1
      fi

      if [ "$new_guacamole_proxy_upstream" = "$GUACAMOLE_DEFAULT_UPSTREAM" ]; then
        ensure_managed_guacamole_stack "$managed_guacamole_version"
        managed_guacamole_secret="$(guacamole_saved_secret)"
      else
        managed_guacamole_secret=""
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$db_name" "$db_user" "$db_password" "$db_root_password" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "yes" "$new_guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
        write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
      else
        remove_reverb_proxy_config "$PROJECT_NAME"
      fi

      ensure_proxy_stack
      proxy_dc restart reverse-proxy

      echo ""
      echo "Guacamole proxy enabled: https://${DOMAIN}/guacamole/"
      echo "Upstream: ${new_guacamole_proxy_upstream}"
      if [ "$new_guacamole_proxy_upstream" = "$GUACAMOLE_DEFAULT_UPSTREAM" ] && [ -n "$managed_guacamole_secret" ]; then
        if sync_project_guacamole_env "$app_dir" "$DOMAIN" "$managed_guacamole_secret"; then
          echo "Updated ${project_env_path:-${app_dir}/.env} with GUACAMOLE_* values."
          if refresh_project_runtime_after_env_change "$app_dir" "$PROJECT_NAME" "$DOMAIN"; then
            echo "Restarted the PHP container so the new GUACAMOLE_* values take effect."
          fi
        else
          echo "Project .env not found. Set these values manually:"
          echo "  GUACAMOLE_ENABLED=true"
          echo "  GUACAMOLE_BASE_URL=https://${DOMAIN}/guacamole"
          echo "  GUACAMOLE_JSON_SECRET_KEY=${managed_guacamole_secret}"
          echo "  GUACAMOLE_EMBED_ALLOWED=true"
        fi
      else
        echo "Update your app .env with the matching Guacamole JSON secret:"
        echo "  GUACAMOLE_ENABLED=true"
        echo "  GUACAMOLE_BASE_URL=https://${DOMAIN}/guacamole"
        echo "  GUACAMOLE_JSON_SECRET_KEY=YOUR_GUACAMOLE_JSON_SECRET_KEY"
        echo "  GUACAMOLE_EMBED_ALLOWED=true"
      fi
      ;;
    change-upstream)
      if [ "$guacamole_proxy_enabled" != "yes" ]; then
        echo "Guacamole proxy is not enabled."
        exit 1
      fi

      prompt new_guacamole_proxy_upstream "New Guacamole upstream [${guacamole_proxy_upstream}]: " "${guacamole_proxy_upstream}"
      new_guacamole_proxy_upstream="$(normalize_guacamole_upstream "$new_guacamole_proxy_upstream")"
      if ! validate_guacamole_upstream "$new_guacamole_proxy_upstream"; then
        echo "Invalid Guacamole upstream: ${new_guacamole_proxy_upstream}"
        echo "Use host:port, for example guacamole-web:8080"
        exit 1
      fi

      if [ "$new_guacamole_proxy_upstream" = "$guacamole_proxy_upstream" ]; then
        echo "No changes detected."
        exit 0
      fi

      if [ "$new_guacamole_proxy_upstream" = "$GUACAMOLE_DEFAULT_UPSTREAM" ]; then
        ensure_managed_guacamole_stack "$managed_guacamole_version"
        managed_guacamole_secret="$(guacamole_saved_secret)"
      else
        managed_guacamole_secret=""
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$db_name" "$db_user" "$db_password" "$db_root_password" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "yes" "$new_guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
        write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
      else
        remove_reverb_proxy_config "$PROJECT_NAME"
      fi

      ensure_proxy_stack
      proxy_dc restart reverse-proxy

      echo "Guacamole upstream updated to ${new_guacamole_proxy_upstream}."
      if [ "$new_guacamole_proxy_upstream" = "$GUACAMOLE_DEFAULT_UPSTREAM" ] && [ -n "$managed_guacamole_secret" ]; then
        if sync_project_guacamole_env "$app_dir" "$DOMAIN" "$managed_guacamole_secret"; then
          echo "Updated ${project_env_path:-${app_dir}/.env} with GUACAMOLE_* values."
          if refresh_project_runtime_after_env_change "$app_dir" "$PROJECT_NAME" "$DOMAIN"; then
            echo "Restarted the PHP container so the new GUACAMOLE_* values take effect."
          fi
        fi
      else
        echo "If this upstream uses a different JSON secret, update your app .env manually."
      fi
      ;;
    disable)
      if [ "$guacamole_proxy_enabled" != "yes" ]; then
        echo "Guacamole proxy is already disabled."
        exit 0
      fi

      write_project_files "$app_dir" "$PROJECT_NAME" "$DOMAIN" "$db_name" "$db_user" "$db_password" "$db_root_password" "$pma_port" "$pma_bind_ip" "$reverb_enabled" "$reverb_domain" "$reverb_port" "$reverb_exposure" "$app_profile" "no" "$guacamole_proxy_upstream"
      write_project_proxy_configs "$PROJECT_NAME" "$(project_domains_for_project "$app_dir" "$DOMAIN")"
      if [ "$reverb_enabled" = "yes" ] && [ -n "$reverb_domain" ]; then
        write_reverb_proxy_config_https "$PROJECT_NAME" "$reverb_domain" "$reverb_port" "$reverb_exposure"
      else
        remove_reverb_proxy_config "$PROJECT_NAME"
      fi

      ensure_proxy_stack
      proxy_dc restart reverse-proxy

      if disable_project_guacamole_env "$app_dir"; then
        echo "Updated ${project_env_path:-${app_dir}/.env}: GUACAMOLE_ENABLED=false"
        if refresh_project_runtime_after_env_change "$app_dir" "$PROJECT_NAME" "$DOMAIN"; then
          echo "Restarted the PHP container so the Guacamole env change takes effect."
        fi
      fi

      echo "Guacamole proxy disabled."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

vnc_port_for_display() {
  local display="${1:-$VNC_DEFAULT_DISPLAY}"
  echo $((5900 + display))
}

validate_vnc_display() {
  local display="${1:-}"
  [[ "$display" =~ ^[0-9]+$ ]] || return 1
  [ "$display" -ge 1 ] && [ "$display" -le 99 ]
}

validate_vnc_geometry() {
  local geometry="${1:-}"
  [[ "$geometry" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]
}

vnc_saved_value() {
  local key="$1"
  [ -f "$VNC_META_FILE" ] || return 0
  (
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    source "$VNC_META_FILE"
    printf '%s' "${!key:-}"
  )
}

write_vnc_meta() {
  local vnc_user="$1"
  local display="$2"
  local geometry="$3"
  local depth="$4"
  local listen_scope="$5"

  mkdir -p "$VNC_BASE"
  {
    printf 'VNC_USER=%q\n' "$vnc_user"
    printf 'VNC_DISPLAY=%q\n' "$display"
    printf 'VNC_PORT=%q\n' "$(vnc_port_for_display "$display")"
    printf 'VNC_GEOMETRY=%q\n' "$geometry"
    printf 'VNC_DEPTH=%q\n' "$depth"
    printf 'VNC_LISTEN_SCOPE=%q\n' "$listen_scope"
    printf 'VNC_SERVICE_NAME=%q\n' "$VNC_SERVICE_NAME"
  } > "$VNC_META_FILE"
}

ensure_vnc_user() {
  local vnc_user="$1"

  if id "$vnc_user" >/dev/null 2>&1; then
    return 0
  fi

  useradd --create-home --shell /bin/bash "$vnc_user"
}

write_vnc_password() {
  local vnc_user="$1"
  local vnc_password="$2"
  local home_dir

  home_dir="$(getent passwd "$vnc_user" | cut -d: -f6)"
  require_nonempty "VNC user home" "$home_dir"

  install -d -m 700 -o "$vnc_user" -g "$vnc_user" "${home_dir}/.vnc"
  printf '%s\n' "$vnc_password" | vncpasswd -f > "${home_dir}/.vnc/passwd"
  chown "$vnc_user:$vnc_user" "${home_dir}/.vnc/passwd"
  chmod 600 "${home_dir}/.vnc/passwd"
}

write_vnc_xstartup() {
  local vnc_user="$1"
  local home_dir

  home_dir="$(getent passwd "$vnc_user" | cut -d: -f6)"
  require_nonempty "VNC user home" "$home_dir"

  install -d -m 700 -o "$vnc_user" -g "$vnc_user" "${home_dir}/.vnc"
  cat > "${home_dir}/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
  chown "$vnc_user:$vnc_user" "${home_dir}/.vnc/xstartup"
  chmod 755 "${home_dir}/.vnc/xstartup"
}

write_vnc_systemd_service() {
  local vnc_user="$1"
  local display="$2"
  local geometry="$3"
  local depth="$4"
  local listen_scope="$5"
  local localhost_arg="-localhost yes"

  if [ "$listen_scope" = "network" ]; then
    localhost_arg="-localhost no"
  fi

  cat > "/etc/systemd/system/${VNC_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Managed TigerVNC server for Guacamole
After=network.target

[Service]
Type=simple
User=${vnc_user}
PAMName=login
ExecStartPre=-/usr/bin/vncserver -kill :${display}
ExecStart=/usr/bin/vncserver :${display} -fg ${localhost_arg} -geometry ${geometry} -depth ${depth}
ExecStop=/usr/bin/vncserver -kill :${display}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_managed_vnc_server() {
  local vnc_user="$1"
  local display="$2"
  local geometry="$3"
  local depth="$4"
  local listen_scope="$5"
  local vnc_password="$6"

  install_base
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    tigervnc-standalone-server \
    tigervnc-common \
    xfce4 \
    xfce4-goodies \
    dbus-x11 \
    xterm

  ensure_vnc_user "$vnc_user"
  write_vnc_password "$vnc_user" "$vnc_password"
  write_vnc_xstartup "$vnc_user"
  write_vnc_systemd_service "$vnc_user" "$display" "$geometry" "$depth" "$listen_scope"
  write_vnc_meta "$vnc_user" "$display" "$geometry" "$depth" "$listen_scope"

  systemctl daemon-reload
  systemctl enable --now "${VNC_SERVICE_NAME}.service"
}

manage_vnc_server() {
  local action saved_user saved_display saved_geometry saved_depth saved_scope
  local vnc_user display geometry depth listen_scope vnc_password confirm port bind_hint

  saved_user="$(vnc_saved_value VNC_USER)"
  saved_display="$(vnc_saved_value VNC_DISPLAY)"
  saved_geometry="$(vnc_saved_value VNC_GEOMETRY)"
  saved_depth="$(vnc_saved_value VNC_DEPTH)"
  saved_scope="$(vnc_saved_value VNC_LISTEN_SCOPE)"

  saved_user="${saved_user:-$VNC_DEFAULT_USER}"
  saved_display="${saved_display:-$VNC_DEFAULT_DISPLAY}"
  saved_geometry="${saved_geometry:-$VNC_DEFAULT_GEOMETRY}"
  saved_depth="${saved_depth:-$VNC_DEFAULT_DEPTH}"
  saved_scope="${saved_scope:-network}"

  echo ""
  echo "Managed VNC Server"
  echo "Service       : ${VNC_SERVICE_NAME}.service"
  echo "Meta file     : ${VNC_META_FILE}"
  echo "Saved user    : ${saved_user}"
  echo "Saved display : :${saved_display} (port $(vnc_port_for_display "$saved_display"))"
  echo "Saved geometry: ${saved_geometry}"
  echo "Saved scope   : ${saved_scope}"
  echo ""
  echo "Guacamole provides the browser viewer. This installs a VNC server"
  echo "on the Ubuntu host so Guacamole can connect to it by host and port."
  echo ""

  prompt action "Action [status/install/start/stop/restart/remove]: " "status"

  case "${action,,}" in
    status)
      echo ""
      systemctl status "${VNC_SERVICE_NAME}.service" --no-pager || true
      echo ""
      if [ -f "$VNC_META_FILE" ]; then
        echo "Connection values for Guacamole:"
        echo "  Protocol: VNC"
        echo "  Host    : <this-server-ip-or-docker-host-gateway>"
        echo "  Port    : $(vnc_port_for_display "$saved_display")"
        echo "  Username: leave blank"
        echo "  Password: the VNC password configured during install"
      else
        echo "Managed VNC server is not installed yet."
      fi
      ;;
    install)
      prompt vnc_user "Linux user for VNC session [${saved_user}]: " "$saved_user"
      if ! [[ "$vnc_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        echo "Invalid Linux user name: ${vnc_user}"
        exit 1
      fi

      prompt display "VNC display number [${saved_display}]: " "$saved_display"
      if ! validate_vnc_display "$display"; then
        echo "Invalid VNC display. Use a number from 1 to 99."
        exit 1
      fi

      prompt geometry "Desktop geometry [${saved_geometry}]: " "$saved_geometry"
      if ! validate_vnc_geometry "$geometry"; then
        echo "Invalid geometry. Use WIDTHxHEIGHT, for example 1366x768."
        exit 1
      fi

      prompt depth "Color depth [${saved_depth}]: " "$saved_depth"
      if ! [[ "$depth" =~ ^(16|24|32)$ ]]; then
        echo "Invalid color depth. Use 16, 24, or 32."
        exit 1
      fi

      prompt listen_scope "Listen scope [network/localhost] [${saved_scope}]: " "$saved_scope"
      listen_scope="${listen_scope,,}"
      case "$listen_scope" in
        network|localhost) ;;
        *) echo "Invalid listen scope. Use network or localhost."; exit 1 ;;
      esac

      prompt_secret vnc_password "VNC password: "
      if [ "${#vnc_password}" -lt 6 ]; then
        echo "VNC password must be at least 6 characters."
        exit 1
      fi

      port="$(vnc_port_for_display "$display")"
      if tcp_port_in_use "$port"; then
        prompt confirm "Port ${port} appears to be in use. Continue and let vncserver decide? (yes/no): " "no"
        if [ "${confirm,,}" != "yes" ]; then
          exit 1
        fi
      fi

      install_managed_vnc_server "$vnc_user" "$display" "$geometry" "$depth" "$listen_scope" "$vnc_password"

      bind_hint="localhost only"
      if [ "$listen_scope" = "network" ]; then
        bind_hint="network reachable"
      fi

      echo ""
      echo "Managed VNC server installed and started."
      echo "Service : ${VNC_SERVICE_NAME}.service"
      echo "Display : :${display}"
      echo "Port    : ${port}"
      echo "Scope   : ${bind_hint}"
      echo ""
      echo "Use these values in Guacamole:"
      echo "  Protocol: VNC"
      echo "  Host    : server IP address or Docker host gateway"
      echo "  Port    : ${port}"
      echo "  Password: the password entered above"
      ;;
    start)
      systemctl start "${VNC_SERVICE_NAME}.service"
      echo "Managed VNC server started."
      ;;
    stop)
      systemctl stop "${VNC_SERVICE_NAME}.service"
      echo "Managed VNC server stopped."
      ;;
    restart)
      systemctl restart "${VNC_SERVICE_NAME}.service"
      echo "Managed VNC server restarted."
      ;;
    remove)
      prompt confirm "Stop and remove managed VNC service metadata? Packages are kept installed. (yes/no): " "no"
      if [ "${confirm,,}" != "yes" ]; then
        exit 0
      fi
      systemctl disable --now "${VNC_SERVICE_NAME}.service" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${VNC_SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -f "$VNC_META_FILE"
      echo "Managed VNC service removed. Installed packages and Linux user were left in place."
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

ai_assets_dir() {
  if [ -f "${AI_PLATFORM_ASSETS}/compose.yaml" ]; then
    printf '%s\n' "$AI_PLATFORM_ASSETS"
  elif [ -f "${AI_PLATFORM_SHARE}/compose.yaml" ]; then
    printf '%s\n' "$AI_PLATFORM_SHARE"
  else
    echo "AI platform assets were not found beside the manager or in ${AI_PLATFORM_SHARE}." >&2
    return 1
  fi
}

setup_ai_backup_cron() {
  local cron_line="15 2 * * * /usr/bin/flock -n /run/lock/vllm-ai-platform-backup.lock /bin/bash ${SCRIPT_PATH} ai-backup >>/var/log/vllm-ai-platform-backup.log 2>&1"
  local hardware_line="* * * * * /usr/bin/flock -n /run/lock/vllm-ai-platform-hardware.lock /bin/bash ${SCRIPT_PATH} ai-hardware-snapshot >>/var/log/vllm-ai-platform-hardware.log 2>&1"
  local current
  current="$(crontab -l 2>/dev/null || true)"
  current="$(printf '%s\n' "$current" | awk 'index($0," vllm-ai-platform-backup.lock ")==0 && index($0," vllm-ai-platform-hardware.lock ")==0 {print}')"
  if ai_is_installed; then
    printf '%s\n%s\n%s\n' "$current" "$cron_line" "$hardware_line" | sed '/^[[:space:]]*$/d' | crontab -
  else
    printf '%s\n' "$current" | sed '/^[[:space:]]*$/d' | crontab -
  fi
}

remove_ai_cron_jobs() {
  local current
  command -v crontab >/dev/null 2>&1 || return 0
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" \
    | awk 'index($0," vllm-ai-platform-backup.lock ")==0 && index($0," vllm-ai-platform-hardware.lock ")==0 {print}' \
    | sed '/^[[:space:]]*$/d' \
    | crontab -
}

ai_is_installed() {
  [ -f "$AI_PLATFORM_COMPOSE" ] && [ -f "$AI_PLATFORM_ENV" ]
}

ai_require_installed() {
  if ! ai_is_installed; then
    echo "The vLLM AI platform is not installed. Choose installation from the AI platform menu first."
    return 1
  fi
}

ai_dc() {
  local previous_dir status
  ai_require_installed || return 1
  previous_dir="$(pwd 2>/dev/null || true)"
  cd "$AI_PLATFORM_BASE" || return 1
  if dc --env-file "$AI_PLATFORM_ENV" -f "$AI_PLATFORM_COMPOSE" "$@"; then
    status=0
  else
    status=$?
  fi
  if [ -n "$previous_dir" ] && [ -d "$previous_dir" ]; then
    cd "$previous_dir" || cd /
  else
    cd /
  fi
  return "$status"
}

ai_runtime_mode() {
  local mode
  mode="$(ai_env_value AI_RUNTIME_MODE)"
  case "${mode,,}" in
    native) echo native ;;
    *) echo docker ;;
  esac
}

ai_native() {
  local python="${AI_NATIVE_PLATFORM_VENV}/bin/python"
  ai_require_installed || return 1
  if [ ! -x "$python" ]; then
    echo "Native platform environment is unavailable: ${AI_NATIVE_PLATFORM_VENV}" >&2
    return 1
  fi
  (
    cd "$AI_PLATFORM_BASE" || exit 1
    "$python" scripts/native_runtime.py "$@"
  )
}

ai_cli() {
  if [ "$(ai_runtime_mode)" = "native" ]; then
    local python="${AI_NATIVE_PLATFORM_VENV}/bin/python"
    [ -x "$python" ] || {
      echo "Native platform environment is unavailable: ${AI_NATIVE_PLATFORM_VENV}" >&2
      return 1
    }
    (
      cd "$AI_PLATFORM_BASE" || exit 1
      runuser -u "$AI_NATIVE_SERVICE_USER" -- "$python" -m app.cli "$@"
    )
  else
    ai_dc exec -T controller python -m app.cli "$@"
  fi
}

ai_env_value() {
  local key="$1"
  [ -f "$AI_PLATFORM_ENV" ] || return 0
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$AI_PLATFORM_ENV"
}

ai_random_secret() {
  openssl rand -hex 32
}

ai_password_is_strong() {
  local value="$1" categories=0
  [ "${#value}" -ge 12 ] && [ "${#value}" -le 256 ] || return 1
  [[ "$value" =~ [[:lower:]] ]] && categories=$((categories + 1))
  [[ "$value" =~ [[:upper:]] ]] && categories=$((categories + 1))
  [[ "$value" =~ [[:digit:]] ]] && categories=$((categories + 1))
  [[ "$value" =~ [^[:alnum:]] ]] && categories=$((categories + 1))
  [ "$categories" -ge 3 ]
}

ai_copy_assets() {
  local source
  source="$(ai_assets_dir)"
  mkdir -p "$AI_PLATFORM_BASE"
  rsync -a --delete \
    --exclude='.env' \
    --exclude='database/' \
    --exclude='redis/' \
    --exclude='models/' \
    --exclude='hf-cache/' \
    --exclude='hardware/' \
    --exclude='notebooks/' \
    --exclude='jupyter-venv/' \
    --exclude='native/' \
    --exclude='state/' \
    --exclude='backups/' \
    --exclude='logs/' \
    --exclude='generated/' \
    --exclude='model-configs/' \
    --exclude='secrets/' \
    --exclude='.ai-platform-meta' \
    --exclude='.deployed-release.json' \
    "${source}/" "${AI_PLATFORM_BASE}/"
  mkdir -p \
    "${AI_PLATFORM_BASE}/database" \
    "${AI_PLATFORM_BASE}/redis" \
    "${AI_PLATFORM_BASE}/models" \
    "${AI_PLATFORM_BASE}/hf-cache" \
    "${AI_PLATFORM_BASE}/hardware" \
    "${AI_PLATFORM_BASE}/notebooks/diagnostics" \
    "${AI_PLATFORM_BASE}/notebooks/benchmarks" \
    "${AI_PLATFORM_BASE}/notebooks/examples" \
    "${AI_PLATFORM_BASE}/state" \
    "${AI_PLATFORM_BASE}/logs" \
    "${AI_PLATFORM_BASE}/generated" \
    "${AI_PLATFORM_BASE}/model-configs" \
    "${AI_NATIVE_BASE}/cache" \
    "${AI_PLATFORM_BASE}/secrets" \
    "$AI_BACKUPS_BASE"
  chmod 700 "${AI_PLATFORM_BASE}/secrets" "$AI_BACKUPS_BASE"
}

ai_environment_probe_script() {
  if [ -f "${AI_PLATFORM_BASE}/scripts/environment_probe.py" ]; then
    printf '%s\n' "${AI_PLATFORM_BASE}/scripts/environment_probe.py"
  else
    printf '%s\n' "$(ai_assets_dir)/scripts/environment_probe.py"
  fi
}

ai_environment_refresh() {
  local test_pytorch="${1:-no}" script
  script="$(ai_environment_probe_script)"
  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$script" ]; then
    echo "Environment probe unavailable: Python 3 or the probe script is missing."
    return 1
  fi
  mkdir -p "${AI_PLATFORM_BASE}/hardware"
  local args=(--platform-root "$AI_PLATFORM_BASE" --output "$AI_ENVIRONMENT_SNAPSHOT")
  [ "$test_pytorch" = "yes" ] && args+=(--test-pytorch)
  python3 "$script" "${args[@]}"
}

ai_environment_value() {
  local path="$1"
  [ -f "$AI_ENVIRONMENT_SNAPSHOT" ] || return 0
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" "$path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
PY
}

ai_environment_preflight() {
  local script temporary
  script="$(ai_environment_probe_script)"
  command -v python3 >/dev/null 2>&1 && [ -f "$script" ] || return 0
  temporary="$(mktemp /tmp/vllm-ai-environment.XXXXXX.json)"
  if python3 "$script" --platform-root "$AI_PLATFORM_BASE" --output "$temporary"; then
    python3 - "$temporary" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
jupyter = value.get("jupyter", {})
capabilities = value.get("capabilities", {})
print("AI environment preflight:")
print(f"  type={value.get('environment_type', 'UNKNOWN')} provider={value.get('provider', 'unknown')}")
print(f"  jupyter={'detected' if jupyter.get('detected') else 'not-detected'} running={bool(jupyter.get('running'))} management={jupyter.get('management', 'UNKNOWN')}")
print(f"  docker-daemon={bool(capabilities.get('docker_daemon_available'))} systemd={bool(capabilities.get('systemd_available'))} cap-sys-admin={bool(capabilities.get('cap_sys_admin'))}")
if jupyter.get("management") == "PROVIDER_MANAGED":
    print("  action=PRESERVE PROVIDER JUPYTER; startup, authentication, proxy and configuration will not be changed")
PY
  fi
  rm -f "$temporary"
}

ai_host_mutation_allowed() {
  [ -f "$AI_ENVIRONMENT_SNAPSHOT" ] || ai_environment_refresh no >/dev/null 2>&1 || return 1
  jq -e '(.environment_type == "FULL_VM" or .environment_type == "BARE_METAL") and .capabilities.root_privileges == true' "$AI_ENVIRONMENT_SNAPSHOT" >/dev/null 2>&1
}

ai_prepare_marketplace_container_base() {
  local required missing=()
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "No usable Docker daemon is exposed in this marketplace container."
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "Docker Compose is unavailable. It will not be installed into the provider environment automatically."
    return 1
  fi
  for required in python3 jq openssl rsync curl tar gzip; do
    command -v "$required" >/dev/null 2>&1 || missing+=("$required")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Provider container is missing required existing commands: ${missing[*]}"
    echo "No packages were installed automatically; use a compatible provider image or explicitly prepare it."
    return 1
  fi
  mkdir -p "$PROJECTS_BASE" "$BACKUPS_BASE"
  chmod 700 "$SCRIPT_PATH" >/dev/null 2>&1 || true
  if ! docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
    docker network create "$SHARED_NETWORK"
  fi
  proxy_up
  echo "Marketplace/container mode: skipped apt, systemd, host firewall and cron mutations."
}

ai_native_base_python() {
  local candidate
  for candidate in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if (3, 10) <= sys.version_info[:2] < (3, 15) else 1)
PY
    then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ai_native_prepare_prerequisites() {
  local base_python
  if [ "$(uname -s)" != "Linux" ]; then
    echo "Native vLLM mode requires Linux."
    return 1
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "Native NVIDIA vLLM mode requires a provider-visible NVIDIA GPU and nvidia-smi."
    return 1
  fi
  if ! base_python="$(ai_native_base_python)"; then
    echo "Native vLLM ${AI_DEFAULT_NATIVE_VLLM_VERSION} requires Python 3.10 through 3.14."
    return 1
  fi

  local missing=()
  command -v redis-server >/dev/null 2>&1 || missing+=(redis-server)
  "$base_python" -c 'import ensurepip, venv' >/dev/null 2>&1 || missing+=(python3-venv)
  command -v runuser >/dev/null 2>&1 || missing+=(util-linux)
  if [ "${#missing[@]}" -gt 0 ]; then
    if ! command -v apt-get >/dev/null 2>&1; then
      echo "Missing native prerequisites: ${missing[*]}"
      echo "No supported package manager was found. Prepare a compatible provider image and retry."
      return 1
    fi
    echo "Installing isolated native-runtime prerequisites: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates "${missing[@]}"
  fi
  if [ "$(cat /proc/1/comm 2>/dev/null || true)" != "systemd" ]; then
    local redis_unit_link redis_unit_target
    for redis_unit_link in \
      /etc/systemd/system/redis.service \
      /etc/systemd/system/multi-user.target.wants/redis-server.service; do
      [ -L "$redis_unit_link" ] || continue
      redis_unit_target="$(readlink "$redis_unit_link")"
      case "$redis_unit_target" in
        /lib/systemd/system/redis-server.service|/usr/lib/systemd/system/redis-server.service)
          rm -f -- "$redis_unit_link"
          ;;
      esac
    done
  fi
  command -v redis-server >/dev/null 2>&1 || {
    echo "redis-server remains unavailable after prerequisite installation."
    return 1
  }
}

ai_native_prepare_service_user() {
  if ! id "$AI_NATIVE_SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$AI_PLATFORM_BASE" --shell /usr/sbin/nologin "$AI_NATIVE_SERVICE_USER"
  fi
  local service_group
  service_group="$(id -gn "$AI_NATIVE_SERVICE_USER")"
  mkdir -p \
    "${AI_PLATFORM_BASE}/database" \
    "${AI_PLATFORM_BASE}/redis" \
    "${AI_PLATFORM_BASE}/models" \
    "${AI_PLATFORM_BASE}/hf-cache" \
    "${AI_PLATFORM_BASE}/hardware" \
    "${AI_PLATFORM_BASE}/state/native-models" \
    "${AI_PLATFORM_BASE}/logs" \
    "${AI_PLATFORM_BASE}/generated" \
    "${AI_PLATFORM_BASE}/model-configs" \
    "${AI_PLATFORM_BASE}/secrets" \
    "$AI_NATIVE_BASE"
  chown -R "${AI_NATIVE_SERVICE_USER}:${service_group}" \
    "${AI_PLATFORM_BASE}/database" \
    "${AI_PLATFORM_BASE}/redis" \
    "${AI_PLATFORM_BASE}/models" \
    "${AI_PLATFORM_BASE}/hf-cache" \
    "${AI_PLATFORM_BASE}/hardware" \
    "${AI_PLATFORM_BASE}/state" \
    "${AI_PLATFORM_BASE}/logs" \
    "${AI_PLATFORM_BASE}/generated" \
    "${AI_PLATFORM_BASE}/model-configs" \
    "${AI_NATIVE_BASE}/cache"
  chown "root:${service_group}" "$AI_PLATFORM_ENV" "${AI_PLATFORM_BASE}/secrets/hf_token"
  chmod 640 "$AI_PLATFORM_ENV" "${AI_PLATFORM_BASE}/secrets/hf_token"
  if [ -f "$AI_CLOUDFLARED_TOKEN_FILE" ]; then
    chown "root:${service_group}" "$AI_CLOUDFLARED_TOKEN_FILE"
    chmod 640 "$AI_CLOUDFLARED_TOKEN_FILE"
  fi
  chown "root:${service_group}" "${AI_PLATFORM_BASE}/secrets"
  chmod 710 "${AI_PLATFORM_BASE}/secrets"
}

ai_native_resolve_venv_path() {
  local requested="$1" resolved="$1"
  if [ -L "$requested" ]; then
    resolved="$(readlink -f -- "$requested")" || {
      echo "Unable to resolve native environment link: ${requested}" >&2
      return 1
    }
  fi
  case "$resolved" in
    "${AI_NATIVE_BASE}"/*)
      printf '%s\n' "$resolved"
      ;;
    *)
      echo "Native environment path escapes ${AI_NATIVE_BASE}: ${resolved}" >&2
      return 1
      ;;
  esac
}

ai_native_install_environments() {
  local version="$1" current="" base_python platform_venv_target vllm_venv_target
  base_python="$(ai_native_base_python)" || {
    echo "No compatible system Python was found for native vLLM environments."
    return 1
  }
  platform_venv_target="$(ai_native_resolve_venv_path "$AI_NATIVE_PLATFORM_VENV")" || return 1
  vllm_venv_target="$(ai_native_resolve_venv_path "$AI_NATIVE_VLLM_VENV")" || return 1
  "$base_python" -m venv --copies "$platform_venv_target"
  "${AI_NATIVE_PLATFORM_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel
  "${AI_NATIVE_PLATFORM_VENV}/bin/python" -m pip install -r "${AI_PLATFORM_BASE}/requirements-native.txt"

  "$base_python" -m venv --copies "$vllm_venv_target"
  "${AI_NATIVE_PLATFORM_VENV}/bin/python" -m pip install --upgrade uv
  current="$(${AI_NATIVE_VLLM_VENV}/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("vllm"))' 2>/dev/null || true)"
  if [ "$current" != "$version" ]; then
    echo "Installing native vLLM ${version} in an isolated environment. This can download several gigabytes."
    "${AI_NATIVE_PLATFORM_VENV}/bin/uv" pip install \
      --python "${AI_NATIVE_VLLM_VENV}/bin/python" \
      --torch-backend=auto \
      "vllm==${version}"
  fi
  env -u PYTHONHOME -u PYTHONPATH "${AI_NATIVE_VLLM_VENV}/bin/python" \
    "${AI_PLATFORM_BASE}/scripts/patch_vllm_responses_thinking_budget.py"
  "${AI_NATIVE_VLLM_VENV}/bin/vllm" --version
}

ai_native_initialize_environment() {
  local version="$1"
  if [ ! -f "$AI_PLATFORM_ENV" ]; then
    cp "${AI_PLATFORM_BASE}/.env.example" "$AI_PLATFORM_ENV"
    set_env_file_var "$AI_PLATFORM_ENV" "APP_SECRET" "$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "API_KEY_PEPPER" "$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "INTERNAL_GATEWAY_TOKEN" "$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "CONTROLLER_TOKEN" "$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "PROXY_SHARED_TOKEN" "$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "REDIS_PASSWORD" "$(ai_random_secret)"
  fi
  set_env_file_var "$AI_PLATFORM_ENV" "AI_PLATFORM_SCHEMA_VERSION" "$AI_SCHEMA_VERSION"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_RUNTIME_MODE" "native"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "localhost"
  set_env_file_var "$AI_PLATFORM_ENV" "DATABASE_URL" "sqlite:////opt/vllm-ai-platform/database/platform.db"
  set_env_file_var "$AI_PLATFORM_ENV" "REDIS_URL" "redis://:$(ai_env_value REDIS_PASSWORD)@127.0.0.1:16379/0"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_PLATFORM_ROOT" "$AI_PLATFORM_BASE"
  set_env_file_var "$AI_PLATFORM_ENV" "HF_TOKEN_FILE" "${AI_PLATFORM_BASE}/secrets/hf_token"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_RUNTIME_MODE" "native"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_SERVICE_USER" "$AI_NATIVE_SERVICE_USER"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_VERSION" "$version"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_EXECUTABLE" "${AI_NATIVE_VLLM_VENV}/bin/vllm"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_GATEWAY_PORT" "8000"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_WEB_PORT" "18080"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_CONTROLLER_PORT" "8090"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_REDIS_PORT" "16379"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_PORT_START" "19000"
  set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_PORT_END" "19999"
  set_env_file_var "$AI_PLATFORM_ENV" "GATEWAY_INTERNAL_URL" "http://127.0.0.1:8000"
  set_env_file_var "$AI_PLATFORM_ENV" "CONTROLLER_INTERNAL_URL" "http://127.0.0.1:8090"
  set_env_file_var "$AI_PLATFORM_ENV" "TRUSTED_PROXY_CIDRS" "127.0.0.1/32,::1/128"
  set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" ""
  set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "false"
  if [ ! -f "${AI_PLATFORM_BASE}/secrets/hf_token" ]; then
    : > "${AI_PLATFORM_BASE}/secrets/hf_token"
  fi
  chmod 600 "$AI_PLATFORM_ENV" "${AI_PLATFORM_BASE}/secrets/hf_token"
}

ai_install_native() {
  local existed="no" version panel chat hf_token admin_name admin_email admin_password admin_password_confirm
  ai_is_installed && existed="yes"
  ai_copy_assets
  ai_native_prepare_prerequisites
  version="$(ai_env_value NATIVE_VLLM_VERSION)"
  prompt version "Pinned native vLLM version: " "${version:-$AI_DEFAULT_NATIVE_VLLM_VERSION}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)$ ]]; then
    echo "Use a pinned native vLLM package version such as ${AI_DEFAULT_NATIVE_VLLM_VERSION}."
    return 1
  fi
  ai_native_initialize_environment "$version"
  prompt panel "Enable administrator web panel? (yes/no): " "$( [ "$(ai_env_value ADMIN_PANEL_ENABLED)" = "false" ] && echo no || echo yes )"
  prompt chat "Enable end-user chat portal? (yes/no): " "$( [ "$(ai_env_value CHAT_PORTAL_ENABLED)" = "false" ] && echo no || echo yes )"
  [ "${panel,,}" = "yes" ] && panel=true || panel=false
  [ "${chat,,}" = "yes" ] && chat=true || chat=false
  set_env_file_var "$AI_PLATFORM_ENV" "ADMIN_PANEL_ENABLED" "$panel"
  set_env_file_var "$AI_PLATFORM_ENV" "CHAT_PORTAL_ENABLED" "$chat"
  prompt_secret hf_token "Hugging Face token (blank keeps existing/public-only): "
  if [ -n "$hf_token" ]; then
    printf '%s' "$hf_token" > "${AI_PLATFORM_BASE}/secrets/hf_token"
  fi

  ai_native_prepare_service_user
  ai_native_install_environments "$version"
  ai_native_prepare_service_user
  ai_hardware_refresh no
  ai_native configure
  ai_native start

  if [ "$existed" = "no" ]; then
    prompt admin_name "First administrator name: " "Administrator"
    prompt admin_email "First administrator email: " ""
    while true; do
      prompt_secret admin_password "First administrator password (minimum 12 characters): "
      prompt_secret admin_password_confirm "Confirm password: "
      if ai_password_is_strong "$admin_password" && [ "$admin_password" = "$admin_password_confirm" ]; then
        break
      fi
      echo "Passwords must match, contain 12-256 characters, and use at least three character categories."
    done
    printf '%s\n' "$admin_password" \
      | ai_cli init-admin --name "$admin_name" --email "$admin_email" --password-stdin
  fi

  if [ ! -f "$AI_PLATFORM_META" ]; then
    printf 'schema_version=%s\ninstalled_at=%s\n' "$AI_SCHEMA_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AI_PLATFORM_META"
  fi
  set_env_file_var "$AI_PLATFORM_META" "runtime_mode" "native"
  set_env_file_var "$AI_PLATFORM_META" "native_vllm_version" "$version"
  chmod 600 "$AI_PLATFORM_META"
  echo "Native AI Platform is ready on private loopback listeners."
  echo "  Gateway: http://127.0.0.1:8000/v1"
  echo "  Admin/chat: http://127.0.0.1:18080"
  echo "Use SSH/Vast.ai port forwarding or an explicitly configured TLS proxy; no provider ports were exposed automatically."
}

ai_hardware_refresh() {
  local validate="${1:-no}"
  local args=(--storage-path "$AI_PLATFORM_BASE" --output "${AI_PLATFORM_BASE}/hardware/current.json")
  if [ "$validate" = "yes" ]; then
    args+=(--validate-docker)
  fi
  python3 "${AI_PLATFORM_BASE}/scripts/hardware_probe.py" "${args[@]}"
  ai_environment_refresh no || true
  if [ ! -f "${AI_PLATFORM_BASE}/hardware/baseline.json" ]; then
    cp "${AI_PLATFORM_BASE}/hardware/current.json" "${AI_PLATFORM_BASE}/hardware/baseline.json"
  fi
  python3 "${AI_PLATFORM_BASE}/scripts/compare_hardware.py" \
    "${AI_PLATFORM_BASE}/hardware/baseline.json" \
    "${AI_PLATFORM_BASE}/hardware/current.json" \
    --output "${AI_PLATFORM_BASE}/hardware/change.json"
}

ai_hardware_show() {
  local accept
  ai_require_installed || return 1
  ai_hardware_refresh no
  echo ""
  echo "Current hardware:"
  python3 -m json.tool "${AI_PLATFORM_BASE}/hardware/current.json"
  echo ""
  echo "Changes from accepted baseline:"
  python3 -m json.tool "${AI_PLATFORM_BASE}/hardware/change.json"
  prompt accept "Accept the current hardware as the new baseline? (yes/no): " "no"
  if [ "${accept,,}" = "yes" ]; then
    cp "${AI_PLATFORM_BASE}/hardware/current.json" "${AI_PLATFORM_BASE}/hardware/baseline.json"
    chmod 600 "${AI_PLATFORM_BASE}/hardware/baseline.json"
    echo "Hardware baseline updated."
  fi
}

ai_gpu_diagnostics() {
  local validate="${1:-yes}"
  echo "Host NVIDIA diagnostic:"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  else
    echo "  nvidia-smi is unavailable. Install a supported NVIDIA driver first."
  fi
  echo ""
  local docker_ready="no"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_ready="yes"
    docker info --format 'Docker server: {{.ServerVersion}} | runtimes: {{json .Runtimes}}' 2>/dev/null || true
  else
    echo "  Docker daemon unavailable; container GPU validation is skipped without modifying the host."
  fi
  if [ "$validate" = "yes" ] && command -v nvidia-smi >/dev/null 2>&1 && [ "$docker_ready" = "yes" ]; then
    echo ""
    echo "Testing GPU access in a disposable CUDA container..."
    docker run --rm --gpus all nvidia/cuda:12.9.1-base-ubuntu24.04 nvidia-smi -L
  fi
}

ai_install_nvidia_runtime() {
  local daemon_file="/etc/docker/daemon.json"
  local backup_file=""

  ai_environment_refresh no || true
  if ! ai_host_mutation_allowed; then
    echo "NVIDIA Container Toolkit host mutation is disabled in provider/marketplace containers or without host privileges."
    echo "Use the provider's CUDA/GPU configuration; no systemd, Docker daemon or provider startup files were changed."
    return 1
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "A working host NVIDIA driver is required before installing the container runtime."
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit

  if [ -f "$daemon_file" ]; then
    backup_file="${daemon_file}.before-vllm.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$daemon_file" "$backup_file"
    echo "Docker daemon configuration backed up to ${backup_file}."
  fi

  nvidia-ctk runtime configure --runtime=docker
  if ! python3 -m json.tool "$daemon_file" >/dev/null; then
    echo "nvidia-ctk produced invalid JSON."
    if [ -n "$backup_file" ]; then
      cp -a "$backup_file" "$daemon_file"
    else
      rm -f "$daemon_file"
    fi
    systemctl restart docker || true
    return 1
  fi
  systemctl restart docker
  ai_gpu_diagnostics yes
}

ai_write_proxy_http() {
  local domain="$1"
  cat > "$AI_PROXY_CONFIG" <<EOF
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://ai-web:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-AI-Proxy-Token $(ai_env_value PROXY_SHARED_TOKEN);
    }
}
EOF
}

ai_write_proxy_https() {
  local domain="$1"
  cat > "$AI_PROXY_CONFIG" <<EOF
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
    client_max_body_size 128m;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location /v1/ {
        proxy_pass http://ai-gateway:8000;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-AI-Proxy-Token $(ai_env_value PROXY_SHARED_TOKEN);
        proxy_set_header Connection "";
    }

    location / {
        proxy_pass http://ai-web:8080;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-AI-Proxy-Token $(ai_env_value PROXY_SHARED_TOKEN);
        proxy_set_header Connection "";
    }
}
EOF
}

ai_configure_proxy() {
  local domain="$1"
  local email="$2"
  local old_config=""

  ensure_proxy_stack
  if [ -f "$AI_PROXY_CONFIG" ]; then
    old_config="$(mktemp)"
    cp "$AI_PROXY_CONFIG" "$old_config"
  fi

  ai_write_proxy_http "$domain"
  chmod 600 "$AI_PROXY_CONFIG"
  if ! proxy_dc exec -T reverse-proxy nginx -t; then
    if [ -n "$old_config" ]; then cp "$old_config" "$AI_PROXY_CONFIG"; else rm -f "$AI_PROXY_CONFIG"; fi
    rm -f "$old_config"
    echo "Nginx rejected the AI HTTP proxy configuration."
    return 1
  fi
  proxy_dc restart reverse-proxy

  if ! proxy_dc run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$domain"; then
    if [ -n "$old_config" ]; then cp "$old_config" "$AI_PROXY_CONFIG"; else rm -f "$AI_PROXY_CONFIG"; fi
    rm -f "$old_config"
    proxy_dc restart reverse-proxy || true
    return 1
  fi

  ai_write_proxy_https "$domain"
  chmod 600 "$AI_PROXY_CONFIG"
  if ! proxy_dc exec -T reverse-proxy nginx -t; then
    if [ -n "$old_config" ]; then cp "$old_config" "$AI_PROXY_CONFIG"; else rm -f "$AI_PROXY_CONFIG"; fi
    rm -f "$old_config"
    proxy_dc restart reverse-proxy || true
    echo "Nginx rejected the AI HTTPS proxy configuration; the prior configuration was restored."
    return 1
  fi
  rm -f "$old_config"
  proxy_dc restart reverse-proxy
}

ai_sync_proxy_from_env() {
  local domain old_config=""
  domain="$(ai_env_value AI_DOMAIN)"
  if ! validate_domain "$domain"; then
    echo "The restored AI_DOMAIN is invalid; the proxy was not changed."
    return 1
  fi
  ensure_proxy_stack
  if [ -f "$AI_PROXY_CONFIG" ]; then
    old_config="$(mktemp)"
    cp "$AI_PROXY_CONFIG" "$old_config"
  fi
  ai_write_proxy_https "$domain"
  chmod 600 "$AI_PROXY_CONFIG"
  if ! proxy_dc exec -T reverse-proxy nginx -t; then
    if [ -n "$old_config" ]; then cp "$old_config" "$AI_PROXY_CONFIG"; else rm -f "$AI_PROXY_CONFIG"; fi
    rm -f "$old_config"
    echo "Nginx rejected the restored proxy configuration; the prior configuration was restored."
    return 1
  fi
  rm -f "$old_config"
  proxy_dc restart reverse-proxy
}

ai_model_catalog_path() {
  local refreshed="${AI_PLATFORM_BASE}/state/model-catalog.json"
  local bundled="${AI_PLATFORM_BASE}/config/model-catalog.json"
  local refreshed_date bundled_date refreshed_version bundled_version newest_version
  if [ -r "$refreshed" ] && jq -e '.schema_version >= 3 and (.models | length > 0)' "$refreshed" >/dev/null 2>&1; then
    refreshed_date="$(jq -r '.capabilities_reviewed_at // .updated_at // ""' "$refreshed")"
    bundled_date="$(jq -r '.capabilities_reviewed_at // .updated_at // ""' "$bundled")"
    refreshed_version="$(jq -r '.catalog_version // "0"' "$refreshed")"
    bundled_version="$(jq -r '.catalog_version // "0"' "$bundled")"
    newest_version="$(printf '%s\n%s\n' "$refreshed_version" "$bundled_version" | sort -V | tail -n1)"
    if [[ "$refreshed_date" > "$bundled_date" ]] || { [ "$refreshed_date" = "$bundled_date" ] && [ "$newest_version" = "$refreshed_version" ]; }; then
      printf '%s\n' "$refreshed"
      return 0
    fi
  fi
  printf '%s\n' "$bundled"
}

ai_add_catalog_model() {
  local catalog_key="$1" alias="$2"
  local catalog
  local catalog_id catalog_revision catalog_caps catalog_size catalog_context catalog_tools catalog_parser
  local catalog_quantization catalog_dtype catalog_max_sequences catalog_profile catalog_reasoning catalog_gpu_utilization
  catalog="$(ai_model_catalog_path)"
  catalog_id="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .model_id' "$catalog" | head -n1)"
  if [ -z "$catalog_id" ] || [ "$catalog_id" = "null" ]; then
    echo "Unknown catalog key: ${catalog_key}"
    return 1
  fi
  catalog_caps="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | (((.model_capabilities // []) + (.runtime_capabilities // []) + (.capabilities // [])) | unique | join(","))' "$catalog" | head -n1)"
  catalog_size="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .estimated_weight_gb' "$catalog" | head -n1)"
  catalog_context="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .default_max_model_len' "$catalog" | head -n1)"
  catalog_tools="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .tool_calling' "$catalog" | head -n1)"
  catalog_parser="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .tool_call_parser // empty' "$catalog" | head -n1)"
  catalog_quantization="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .quantization // empty' "$catalog" | head -n1)"
  catalog_revision="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .revision // "main"' "$catalog" | head -n1)"
  catalog_dtype="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .dtype // "auto"' "$catalog" | head -n1)"
  catalog_max_sequences="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .max_num_seqs // 4' "$catalog" | head -n1)"
  catalog_profile="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .performance_profile // "AUTO"' "$catalog" | head -n1)"
  catalog_reasoning="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .reasoning_parser // empty' "$catalog" | head -n1)"
  catalog_gpu_utilization="$(jq -r --arg key "$catalog_key" '.models[] | select(.key == $key) | .gpu_memory_utilization // 0.82' "$catalog" | head -n1)"
  [ -n "$alias" ] || alias="$catalog_key"
  local catalog_args=(models add --model-id "$catalog_id" --revision "$catalog_revision" --alias "$alias"
    --capabilities "$catalog_caps" --estimated-weight-gb "$catalog_size" --max-model-len "$catalog_context"
    --dtype "$catalog_dtype" --max-num-seqs "$catalog_max_sequences"
    --gpu-memory-utilization "$catalog_gpu_utilization" --performance-profile "$catalog_profile")
  [ -z "$catalog_quantization" ] || catalog_args+=(--quantization "$catalog_quantization")
  [ -z "$catalog_reasoning" ] || catalog_args+=(--reasoning-parser "$catalog_reasoning")
  if [ "$catalog_tools" = "true" ]; then
    catalog_args+=(--tool-calling --tool-call-parser "$catalog_parser")
  fi
  ai_cli "${catalog_args[@]}"
}

ai_catalog_model_wizard() {
  local catalog
  catalog="$(ai_model_catalog_path)"
  local choice count index catalog_key alias confirm download_now activate_now set_default
  local total_vram recommended_vram fit_label activate_default model_id display_name summary category
  local estimated_size max_context revision capabilities

  if [ ! -r "$catalog" ] || ! jq -e '.schema_version >= 2 and (.models | length > 0)' "$catalog" >/dev/null 2>&1; then
    echo "The curated model catalog is missing or invalid."
    return 1
  fi

  ai_hardware_refresh no >/dev/null 2>&1 || true
  total_vram="$(jq -r '([.gpus[]?.memory_total_bytes] | add // 0) / 1073741824' "${AI_PLATFORM_BASE}/hardware/current.json" 2>/dev/null || echo 0)"
  [[ "$total_vram" =~ ^[0-9]+([.][0-9]+)?$ ]] || total_vram=0

  echo ""
  echo "Stable curated model installer"
  jq -r '"Catalog: \(.catalog_version) | reviewed \(.updated_at) | validated with vLLM \(.validated_vllm_version)"' "$catalog"
  if jq -e '.gpus | length > 0' "${AI_PLATFORM_BASE}/hardware/current.json" >/dev/null 2>&1; then
    jq -r '(.gpus | map(.name) | unique | join(", ")) as $names | ([.gpus[].memory_total_bytes] | add / 1073741824) as $vram | "Detected GPU: \($names) | total VRAM: \(($vram * 10 | floor) / 10) GiB"' "${AI_PLATFORM_BASE}/hardware/current.json"
  else
    echo "Detected GPU: unavailable; compatibility will be checked again before activation."
  fi
  echo "FIT = recommended for detected VRAM; TIGHT = may require reduced context/offload."
  echo ""
  jq -r --argjson vram "$total_vram" '
    .models | to_entries[] |
    .value as $model |
    (if $vram <= 0 then "UNKNOWN"
     elif $model.recommended_vram_gb <= ($vram * 0.82) then "FIT"
     elif $model.recommended_vram_gb <= ($vram * 0.97) then "TIGHT"
     else "TOO LARGE" end) as $fit |
    "\(.key + 1)) [\($fit)] \($model.display_name) - \($model.category)\n" +
    "    \($model.summary)\n" +
    "    disk ~\($model.estimated_weight_gb) GiB | VRAM ~\($model.recommended_vram_gb) GiB | context \($model.default_max_model_len)"
  ' "$catalog"
  echo "0) Back"

  prompt choice "Choose a model number: " "1"
  if [ "$choice" = "0" ]; then
    return 0
  fi
  count="$(jq '.models | length' "$catalog")"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    echo "Choose a number between 1 and ${count}."
    return 1
  fi
  index=$((choice - 1))
  catalog_key="$(jq -r --argjson index "$index" '.models[$index].key' "$catalog")"
  display_name="$(jq -r --argjson index "$index" '.models[$index].display_name' "$catalog")"
  model_id="$(jq -r --argjson index "$index" '.models[$index].model_id' "$catalog")"
  summary="$(jq -r --argjson index "$index" '.models[$index].summary' "$catalog")"
  category="$(jq -r --argjson index "$index" '.models[$index].category' "$catalog")"
  estimated_size="$(jq -r --argjson index "$index" '.models[$index].estimated_weight_gb' "$catalog")"
  recommended_vram="$(jq -r --argjson index "$index" '.models[$index].recommended_vram_gb' "$catalog")"
  max_context="$(jq -r --argjson index "$index" '.models[$index].default_max_model_len' "$catalog")"
  revision="$(jq -r --argjson index "$index" '.models[$index].revision' "$catalog")"
  capabilities="$(jq -r --argjson index "$index" '.models[$index] | (((.model_capabilities // []) + (.runtime_capabilities // []) + (.capabilities // [])) | unique | join(","))' "$catalog")"
  fit_label="$(jq -nr --argjson vram "$total_vram" --argjson recommended "$recommended_vram" '
    if $vram <= 0 then "UNKNOWN"
    elif $recommended <= ($vram * 0.82) then "FIT"
    elif $recommended <= ($vram * 0.97) then "TIGHT"
    else "TOO LARGE" end')"

  echo ""
  echo "Install plan"
  echo "  Model:        ${display_name} (${category})"
  echo "  Repository:   ${model_id}"
  echo "  Revision:     ${revision}"
  echo "  Capabilities: ${capabilities}"
  echo "  Disk:         ~${estimated_size} GiB"
  echo "  VRAM:         ~${recommended_vram} GiB (${fit_label})"
  echo "  Context:      ${max_context} tokens"
  echo "  Notes:        ${summary}"
  if [ "$fit_label" = "TOO LARGE" ]; then
    echo "WARNING: This model is not recommended for the currently detected GPU memory."
  fi
  prompt confirm "Register this reviewed model? (yes/no): " "yes"
  [ "${confirm,,}" = "yes" ] || return 0
  prompt alias "Stable API alias: " "$catalog_key"
  ai_add_catalog_model "$catalog_key" "$alias" || return 1

  echo "Compatibility plan:"
  ai_cli models compatibility "$alias" || true
  prompt download_now "Download/resume the pinned model weights now? (yes/no): " "yes"
  [ "${download_now,,}" = "yes" ] || return 0
  ai_cli models download "$alias" || return 1

  activate_default="no"
  [ "$fit_label" = "FIT" ] && activate_default="yes"
  prompt activate_now "Validate capacity and activate now? (yes/no): " "$activate_default"
  if [ "${activate_now,,}" = "yes" ]; then
    ai_cli models activate "$alias" || return 1
    prompt set_default "Set this as the default model? (yes/no): " "yes"
    [ "${set_default,,}" = "yes" ] && ai_cli models default "$alias"
  fi
}

ai_health_report() {
  local entry service port failed=0
  echo "AI service health:"
  for entry in gateway:8000 web:8080 controller:8090; do
    service="${entry%%:*}"
    port="${entry##*:}"
    if ai_dc exec -T "$service" python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${port}/health', timeout=5)" >/dev/null 2>&1; then
      echo "  ${service}: healthy"
    else
      echo "  ${service}: unhealthy"
      failed=1
    fi
  done
  ai_dc ps
  return "$failed"
}

ai_install_or_repair() {
  local existed="no"
  local domain email image hf_token admin_name admin_email admin_password admin_password_confirm
  local panel chat repair_runtime initial_model initial_alias environment_type container_mode="no" native_mode

  ai_is_installed && existed="yes"
  ai_environment_preflight
  ai_environment_refresh no || true
  environment_type="$(ai_environment_value environment_type)"
  case "$environment_type" in
    VAST_AI_CONTAINER|OTHER_MARKETPLACE_CONTAINER|DOCKER_CONTAINER)
      container_mode="yes"
      if ! ai_prepare_marketplace_container_base; then
        prompt native_mode "Docker is unavailable. Install the isolated native runtime instead? (yes/no): " "yes"
        if [ "${native_mode,,}" = "yes" ]; then
          ai_install_native
          return
        fi
        echo "AI Platform installation was cancelled. Existing provider Jupyter was not modified."
        return 0
      fi
      ;;
    *)
      install_base
      ;;
  esac
  if [ "$container_mode" = "no" ]; then
    apt-get install -y python3 jq openssl rsync ca-certificates curl gnupg
  fi
  ai_copy_assets
  chown 10001:10001 "${AI_PLATFORM_BASE}/state"
  chmod 750 "${AI_PLATFORM_BASE}/state"

  domain="$(ai_env_value AI_DOMAIN)"
  prompt domain "AI domain: " "${domain:-ai.example.com}"
  domain="${domain,,}"
  if ! validate_domain "$domain"; then
    echo "Invalid fully qualified domain name."
    return 1
  fi
  prompt email "Let's Encrypt email: " ""
  if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Invalid email address."
    return 1
  fi
  image="$(ai_env_value VLLM_IMAGE)"
  prompt image "Pinned vLLM image: " "${image:-$AI_DEFAULT_VLLM_IMAGE}"
  if [[ ! "$image" =~ ^vllm/vllm-openai:[A-Za-z0-9._-]+$ ]]; then
    echo "Use a pinned vllm/vllm-openai:<tag> image."
    return 1
  fi

  if [ ! -f "$AI_PLATFORM_ENV" ]; then
    cp "${AI_PLATFORM_BASE}/.env.example" "$AI_PLATFORM_ENV"
    local postgres_password redis_password app_secret api_pepper internal_token controller_token proxy_token
    postgres_password="$(ai_random_secret)"
    redis_password="$(ai_random_secret)"
    app_secret="$(ai_random_secret)"
    api_pepper="$(ai_random_secret)"
    internal_token="$(ai_random_secret)"
    controller_token="$(ai_random_secret)"
    proxy_token="$(ai_random_secret)"
    set_env_file_var "$AI_PLATFORM_ENV" "POSTGRES_PASSWORD" "$postgres_password"
    set_env_file_var "$AI_PLATFORM_ENV" "DATABASE_URL" "postgresql+psycopg://vllm_ai:${postgres_password}@postgres:5432/vllm_ai"
    set_env_file_var "$AI_PLATFORM_ENV" "REDIS_PASSWORD" "$redis_password"
    set_env_file_var "$AI_PLATFORM_ENV" "REDIS_URL" "redis://:${redis_password}@redis:6379/0"
    set_env_file_var "$AI_PLATFORM_ENV" "APP_SECRET" "$app_secret"
    set_env_file_var "$AI_PLATFORM_ENV" "API_KEY_PEPPER" "$api_pepper"
    set_env_file_var "$AI_PLATFORM_ENV" "INTERNAL_GATEWAY_TOKEN" "$internal_token"
    set_env_file_var "$AI_PLATFORM_ENV" "CONTROLLER_TOKEN" "$controller_token"
    set_env_file_var "$AI_PLATFORM_ENV" "PROXY_SHARED_TOKEN" "$proxy_token"
  fi

  if [ -z "$(ai_env_value PROXY_SHARED_TOKEN)" ] || [ "$(ai_env_value PROXY_SHARED_TOKEN)" = "replace-me" ]; then
    set_env_file_var "$AI_PLATFORM_ENV" "PROXY_SHARED_TOKEN" "$(ai_random_secret)"
  fi

  set_env_file_var "$AI_PLATFORM_ENV" "AI_PLATFORM_SCHEMA_VERSION" "$AI_SCHEMA_VERSION"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "$domain"
  set_env_file_var "$AI_PLATFORM_ENV" "VLLM_IMAGE" "$image"
  set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" "https://${domain}"
  set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "true"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_PLATFORM_ROOT" "$AI_PLATFORM_BASE"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_SHARED_NETWORK" "$SHARED_NETWORK"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_INTERNAL_NETWORK" "$AI_INTERNAL_NETWORK"

  prompt panel "Enable administrator web panel? (yes/no): " "$( [ "$(ai_env_value ADMIN_PANEL_ENABLED)" = "false" ] && echo no || echo yes )"
  prompt chat "Enable end-user chat portal? (yes/no): " "$( [ "$(ai_env_value CHAT_PORTAL_ENABLED)" = "false" ] && echo no || echo yes )"
  [ "${panel,,}" = "yes" ] && panel="true" || panel="false"
  [ "${chat,,}" = "yes" ] && chat="true" || chat="false"
  set_env_file_var "$AI_PLATFORM_ENV" "ADMIN_PANEL_ENABLED" "$panel"
  set_env_file_var "$AI_PLATFORM_ENV" "CHAT_PORTAL_ENABLED" "$chat"

  prompt_secret hf_token "Hugging Face token (blank keeps existing/public-only): "
  if [ -n "$hf_token" ]; then
    printf '%s' "$hf_token" > "${AI_PLATFORM_BASE}/secrets/hf_token"
  elif [ ! -f "${AI_PLATFORM_BASE}/secrets/hf_token" ]; then
    : > "${AI_PLATFORM_BASE}/secrets/hf_token"
  fi
  chmod 600 "$AI_PLATFORM_ENV" "${AI_PLATFORM_BASE}/secrets/hf_token"
  if [ ! -f "$AI_PLATFORM_META" ]; then
    printf 'schema_version=%s\ninstalled_at=%s\n' "$AI_SCHEMA_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AI_PLATFORM_META"
  else
    set_env_file_var "$AI_PLATFORM_META" "schema_version" "$AI_SCHEMA_VERSION"
    set_env_file_var "$AI_PLATFORM_META" "last_repaired_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  set_env_file_var "$AI_PLATFORM_META" "vllm_image" "$image"
  chmod 600 "$AI_PLATFORM_META"

  ai_hardware_refresh no
  if ! ai_gpu_diagnostics yes; then
    prompt repair_runtime "GPU container validation failed. Install/repair NVIDIA Container Toolkit now? (yes/no): " "yes"
    if [ "${repair_runtime,,}" = "yes" ]; then
      ai_install_nvidia_runtime
      ai_hardware_refresh yes
    else
      echo "Installation cannot safely activate models until GPU container access works."
    fi
  else
    ai_hardware_refresh yes
  fi

  echo "Pulling pinned vLLM runtime image ${image}..."
  docker pull "$image"
  ai_dc config >/dev/null
  ai_dc build --pull
  ai_dc up -d postgres redis
  ai_dc run --rm migrate
  ai_dc up -d gateway web controller

  if [ "$existed" = "no" ]; then
    prompt admin_name "First administrator name: " "Administrator"
    prompt admin_email "First administrator email: " ""
    while true; do
      prompt_secret admin_password "First administrator password (minimum 12 characters): "
      prompt_secret admin_password_confirm "Confirm password: "
      if ai_password_is_strong "$admin_password" && [ "$admin_password" = "$admin_password_confirm" ]; then
        break
      fi
      echo "Passwords must match, contain 12-256 characters, and use at least three of lowercase, uppercase, numbers and symbols."
    done
    printf '%s\n' "$admin_password" \
      | ai_dc exec -T controller python -m app.cli init-admin \
        --name "$admin_name" --email "$admin_email" --password-stdin

    echo "Curated models available for optional registration:"
    jq -r '.models[] | (((.model_capabilities // []) + (.runtime_capabilities // []) + (.capabilities // [])) | unique | join(",")) as $caps | "  \(.key): \(.model_id) [\($caps)]"' "$(ai_model_catalog_path)"
    prompt initial_model "Initial catalog model key (blank skips; registration does not download or activate): " ""
    if [ -n "$initial_model" ]; then
      prompt initial_alias "Stable API alias: " "$initial_model"
      ai_add_catalog_model "$initial_model" "$initial_alias"
    fi
  fi

  ai_configure_proxy "$domain" "$email"
  if [ "$container_mode" = "no" ] && command -v crontab >/dev/null 2>&1; then
    ensure_cron_jobs
  else
    echo "Host cron integration skipped in marketplace/container mode. Run diagnostics and backups through the provider scheduler if required."
  fi
  if ! ai_health_report; then
    echo "Installation completed, but one or more AI services failed their health check."
    return 1
  fi
  echo ""
  echo "vLLM AI platform is ready at https://${domain}/"
  echo "OpenAI-compatible API base: https://${domain}/v1"
}

ai_platform_start() {
  ai_require_installed || return 1
  ai_hardware_refresh no
  if jq -e '.downgrade_detected == true or .requires_model_review == true' "${AI_PLATFORM_BASE}/hardware/change.json" >/dev/null; then
    echo "Hardware changes require model compatibility review:"
    jq . "${AI_PLATFORM_BASE}/hardware/change.json"
  fi
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native start
  else
    ai_dc up -d postgres redis
    ai_dc run --rm migrate
    ai_dc up -d gateway web controller
  fi
  ai_cli models reconcile --wait-seconds 600 || true
}

ai_platform_stop() {
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native stop
    return
  fi
  local ids
  ids="$(docker ps -q --filter label=com.vllm-ai-platform.managed=true)"
  if [ -n "$ids" ]; then
    docker stop $ids
  fi
  ai_dc stop
}

ai_platform_restart() {
  ai_platform_stop
  ai_platform_start
}

ai_platform_status() {
  if ! ai_is_installed; then
    echo "AI platform: not installed"
    return 0
  fi
  echo "AI platform: installed"
  echo "Runtime mode: $(ai_runtime_mode)"
  echo "Domain: $(ai_env_value AI_DOMAIN)"
  if [ "$(ai_runtime_mode)" = "native" ]; then
    echo "Native vLLM: $(ai_env_value NATIVE_VLLM_VERSION)"
  else
    echo "vLLM image: $(ai_env_value VLLM_IMAGE)"
  fi
  if [ -f "${AI_PLATFORM_BASE}/hardware/current.json" ]; then
    jq -r '"Host: CPU=\(.cpu.model // "unknown") | RAM=\(((.memory.total_bytes // 0) / 1073741824 * 10 | floor) / 10) GiB | GPUs=\(.gpus | length)", (.gpu_driver.version // "unknown") as $driver | (.gpus[]? | "  GPU \(.index): \(.name) | \(((.memory_total_bytes // 0) / 1048576 | floor)) MiB | driver \($driver)")' "${AI_PLATFORM_BASE}/hardware/current.json"
  fi
  if [ -f "$AI_ENVIRONMENT_SNAPSHOT" ]; then
    jq -r '"Environment: \(.environment_type // "UNKNOWN") | provider=\(.provider // "unknown")", "Jupyter: detected=\(.jupyter.detected // false) running=\(.jupyter.running // false) management=\(.jupyter.management // "UNKNOWN") action=\(.jupyter.action // "UNKNOWN")"' "$AI_ENVIRONMENT_SNAPSHOT" 2>/dev/null || true
  fi
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native status 2>/dev/null || true
    ai_cli status 2>/dev/null || true
  else
    echo "Running Compose services:"
    ai_dc ps --status running --services 2>/dev/null || true
    echo "Managed model containers:"
    docker ps --filter label=com.vllm-ai-platform.managed=true \
      --format '  {{.Names}}  {{.Status}}' 2>/dev/null || true
    if ai_dc ps --status running --services 2>/dev/null | grep -qx controller; then
      ai_cli status || true
    fi
  fi
}

ai_platform_diagnostics() {
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_hardware_refresh no || true
  else
    ai_hardware_refresh yes || true
  fi
  ai_platform_status
  echo ""
  ai_gpu_diagnostics no || true
  echo ""
  if [ "$(ai_runtime_mode)" = "native" ]; then
    echo "Native runtime validation:"
    ai_native status || true
    "${AI_NATIVE_VLLM_VENV}/bin/vllm" --version 2>/dev/null || true
    echo "  All managed HTTP and model listeners bind to loopback."
  else
    echo "Compose validation:"
    ai_dc config >/dev/null && echo "  OK"
    echo "Runtime versions:"
    docker --version 2>/dev/null || true
    dc version 2>/dev/null || true
    echo "AI networks:"
    docker network inspect "$AI_INTERNAL_NETWORK" "$AI_EGRESS_NETWORK" "$SHARED_NETWORK" \
      --format '  {{.Name}} internal={{.Internal}} containers={{len .Containers}}' 2>/dev/null || true
  fi
  echo "AI filesystem:"
  jq -r '"  path=\(.storage.path) total=\((.storage.total_bytes / 1073741824 * 10 | floor) / 10) GiB used=\((.storage.used_bytes / 1073741824 * 10 | floor) / 10) GiB free=\((.storage.free_bytes / 1073741824 * 10 | floor) / 10) GiB"' "${AI_PLATFORM_BASE}/hardware/current.json" 2>/dev/null || true
  echo "Health:"
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native status || true
    echo "Recent service errors:"
    tail -n 80 "${AI_PLATFORM_BASE}/logs/gateway.log" "${AI_PLATFORM_BASE}/logs/web.log" "${AI_PLATFORM_BASE}/logs/controller.log" 2>/dev/null \
      | grep -Ei 'error|exception|failed|traceback|out of memory|cuda' \
      | tail -n 40 || echo "  No matching recent errors."
  else
    ai_dc ps
    echo "Recent service errors:"
    ai_dc logs --tail 80 gateway web controller 2>&1 \
      | grep -Ei 'error|exception|failed|traceback|out of memory|cuda' \
      | tail -n 40 || echo "  No matching recent errors."
  fi
  echo "Coding/IDE capability report:"
  ai_cli coding-diagnostics || true
  echo "Jupyter/environment capability report:"
  ai_cli jupyter-diagnostics || true
}

ai_jupyter_status() {
  ai_environment_refresh no || return 1
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
jupyter = value.get("jupyter", {})
yes_no = lambda item: "YES" if item else "NO"
status = "RUNNING" if jupyter.get("running") else "STOPPED" if jupyter.get("detected") else "NOT INSTALLED"
print("============================================================")
print("JUPYTER INTEGRATION")
print("============================================================")
print(f"Provider:            {value.get('provider', 'unknown')}")
print(f"Runtime:             {value.get('runtime', {}).get('kind', 'unknown')}")
print(f"Environment type:    {value.get('environment_type', 'UNKNOWN')}")
print(f"Jupyter:             {'DETECTED' if jupyter.get('detected') else 'NOT DETECTED'}")
print(f"JupyterLab:          {'AVAILABLE' if jupyter.get('lab_available') else 'NOT DETECTED'}")
print(f"Status:              {status}")
print(f"Management:          {jupyter.get('management', 'UNKNOWN')}")
print(f"AI Platform action:  {jupyter.get('action', 'UNKNOWN')}")
print(f"Python:              {value.get('python', {}).get('version', 'unknown')}")
print(f"CUDA visible:        {yes_no(value.get('cuda', {}).get('visible'))}")
print(f"GPU visible:         {yes_no(value.get('gpu', {}).get('visible'))}")
print(f"PyTorch:             {'AVAILABLE' if value.get('pytorch', {}).get('available') else 'NOT AVAILABLE'}")
print(f"PyTorch GPU:         {value.get('pytorch', {}).get('gpu_status', 'NOT_TESTED')}")
print(f"Docker daemon:       {yes_no(value.get('capabilities', {}).get('docker_daemon_available'))}")
print(f"systemd:             {yes_no(value.get('capabilities', {}).get('systemd_available'))}")
PY
}

ai_jupyter_environment_information() {
  ai_environment_refresh no || return 1
  python3 -m json.tool "$AI_ENVIRONMENT_SNAPSHOT"
}

ai_jupyter_cuda_test() {
  ai_environment_refresh no || true
  echo "Safe CUDA/GPU diagnostic (read-only):"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw \
      --format=csv,noheader,nounits || true
  else
    echo "  nvidia-smi is unavailable; nothing was installed or changed."
  fi
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print(json.dumps({"cuda": value.get("cuda", {}), "gpu": value.get("gpu", {})}, indent=2))
PY
}

ai_jupyter_pytorch_test() {
  ai_environment_refresh yes || return 1
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    pytorch = json.load(handle).get("pytorch", {})
if pytorch.get("available"):
    print("PyTorch: AVAILABLE")
    print(f"PyTorch GPU: {pytorch.get('gpu_status', 'NOT_TESTED')}")
    print(f"Device count: {pytorch.get('device_count') or 0}")
    print(f"Version: {pytorch.get('torch_version') or 'unknown'}")
    print(f"PyTorch CUDA: {pytorch.get('torch_cuda_version') or 'unknown'}")
else:
    print("PyTorch GPU Test: NOT AVAILABLE")
    print("No package was installed or upgraded.")
PY
}

ai_jupyter_test_vllm_api() {
  local base_url api_key model run_chat configured_domain tester test_status tester_args=()
  configured_domain="$(ai_env_value AI_DOMAIN)"
  base_url="https://${configured_domain:-ai.example.com}/v1"
  prompt base_url "Gateway API base URL: " "$base_url"
  if [[ ! "$base_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v1/?$ ]]; then
    echo "Use an HTTPS Gateway base ending in /v1. Raw vLLM URLs are not accepted."
    return 1
  fi
  base_url="${base_url%/}"
  prompt_secret api_key "Dedicated diagnostic Gateway API key: "
  if [[ ! "$api_key" =~ ^ovai_live_[A-Za-z0-9._-]+$ ]]; then
    unset api_key
    echo "The API key format is invalid."
    return 1
  fi
  prompt run_chat "Send one short chat request through the Gateway? (yes/no): " "yes"
  if [ "${run_chat,,}" = "yes" ]; then
    prompt model "Active authorized model alias: " ""
    if [[ ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
      unset api_key
      echo "Invalid model alias."
      return 1
    fi
    tester_args=(--model "$model")
  fi
  if [ -f "${AI_PLATFORM_BASE}/scripts/test_gateway.py" ]; then
    tester="${AI_PLATFORM_BASE}/scripts/test_gateway.py"
  else
    tester="$(ai_assets_dir)/scripts/test_gateway.py"
  fi
  if printf '%s\n' "$api_key" | python3 "$tester" --base-url "$base_url" --api-key-stdin "${tester_args[@]}"; then
    test_status=0
  else
    test_status=$?
  fi
  unset api_key
  return "$test_status"
}

ai_jupyter_generate_notebook() {
  local kind="$1" owner generator owner_args=()
  ai_environment_refresh no || true
  if [ -f "${AI_PLATFORM_BASE}/scripts/generate_notebook.py" ]; then
    generator="${AI_PLATFORM_BASE}/scripts/generate_notebook.py"
  else
    generator="$(ai_assets_dir)/scripts/generate_notebook.py"
  fi
  owner="$(ai_environment_value jupyter.effective_user)"
  if [ -n "$owner" ] && [ "$owner" != "root" ] && id "$owner" >/dev/null 2>&1; then
    owner_args=(--owner "$owner")
  fi
  python3 "$generator" "$kind" \
    --output-dir "$AI_NOTEBOOKS_BASE" "${owner_args[@]}"
  echo "The notebook contains no API key. Supply a restricted Gateway credential at runtime."
}

ai_jupyter_provider_access() {
  ai_environment_refresh no || return 1
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
jupyter = value.get("jupyter", {})
status = "RUNNING" if jupyter.get("running") else "DETECTED / STOPPED" if jupyter.get("detected") else "NOT DETECTED"
listeners = ", ".join(f"{item.get('address')}:{item.get('port')} [{item.get('scope')}]" for item in jupyter.get("internal_listeners", [])) or "not discoverable"
print(f"Provider: {value.get('provider', 'unknown')}")
print(f"Jupyter: {status}")
print(f"Management: {jupyter.get('management', 'UNKNOWN')}")
print(f"Access: {jupyter.get('provider_access', 'Not detected')}")
print(f"Internal listeners: {listeners}")
print("External URL: NOT INFERRED")
print("Provider credentials: NEVER DISPLAYED")
PY
}

ai_jupyter_security_diagnostics() {
  ai_environment_refresh no || return 1
  python3 - "$AI_ENVIRONMENT_SNAPSHOT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
security = value.get("security", {})
jupyter = value.get("jupyter", {})
print(f"Probe mode: {security.get('probe_mode')}")
print(f"Provider configuration modified: {security.get('provider_configuration_modified')}")
print(f"Provider startup modified: {security.get('provider_startup_modified')}")
print(f"Provider authentication modified: {security.get('provider_authentication_modified')}")
print(f"New public Jupyter listener created: {security.get('platform_public_jupyter_listener_created')}")
print(f"Runtime file contents read: {security.get('runtime_file_contents_read')}")
print(f"Process arguments included: {security.get('process_arguments_included')}")
print(f"Secrets included: {security.get('secrets_included')}")
print(f"Provider-managed: {jupyter.get('management') == 'PROVIDER_MANAGED'}")
print(f"Policy: {jupyter.get('action')}")
for listener in jupyter.get("internal_listeners", []):
    print(f"Listener: {listener.get('address')}:{listener.get('port')} scope={listener.get('scope')}")
if any(item.get("scope") == "ALL_INTERFACES" for item in jupyter.get("internal_listeners", [])):
    print("WARNING: a detected Jupyter listener uses all interfaces. Verify provider authentication; this platform will not rewrite it.")
PY
  echo "No Jupyter token, password, Gateway key, HF token, encryption key or private key is read or printed."
}

ai_jupyter_install_isolated() {
  local environment_type detected confirm owner
  ai_environment_refresh no || return 1
  environment_type="$(jq -r '.environment_type' "$AI_ENVIRONMENT_SNAPSHOT")"
  detected="$(jq -r '.jupyter.detected' "$AI_ENVIRONMENT_SNAPSHOT")"
  if [ "$environment_type" != "FULL_VM" ] && [ "$environment_type" != "BARE_METAL" ]; then
    echo "Optional installation is disabled in containers and marketplace environments. Existing provider Jupyter must be preserved."
    return 1
  fi
  if [ "$detected" = "true" ]; then
    echo "Jupyter already exists. It will not be reinstalled, replaced or reconfigured."
    return 1
  fi
  prompt owner "Non-root OS user who will own generated notebooks: " ""
  if [ -z "$owner" ] || [ "$owner" = "root" ] || ! id "$owner" >/dev/null 2>&1; then
    echo "Choose an existing non-root operating-system user."
    return 1
  fi
  prompt confirm "Type INSTALL ISOLATED JUPYTER to create a private virtual environment without starting a server: " ""
  [ "$confirm" = "INSTALL ISOLATED JUPYTER" ] || return 0
  if ! python3 -m venv "${AI_PLATFORM_BASE}/jupyter-venv"; then
    apt-get update -y
    apt-get install -y python3-venv
    python3 -m venv "${AI_PLATFORM_BASE}/jupyter-venv"
  fi
  "${AI_PLATFORM_BASE}/jupyter-venv/bin/python" -m pip install --upgrade pip
  "${AI_PLATFORM_BASE}/jupyter-venv/bin/python" -m pip install 'jupyterlab>=4,<5'
  mkdir -p "${AI_PLATFORM_BASE}/state" "$AI_NOTEBOOKS_BASE"
  printf '{"management":"AI_PLATFORM_MANAGED","startup_managed":false,"public_listener_created":false}\n' > "${AI_PLATFORM_BASE}/state/jupyter-managed.json"
  chown -R "$owner":"$(id -gn "$owner")" "$AI_NOTEBOOKS_BASE"
  find "$AI_NOTEBOOKS_BASE" -type d -exec chmod 770 {} +
  find "$AI_NOTEBOOKS_BASE" -type f -name '*.ipynb' -exec chmod 660 {} +
  ai_environment_refresh no
  echo "JupyterLab was installed in an isolated virtual environment but was NOT started, exposed, proxied or added to systemd."
  echo "Launch it manually as ${owner}, bound to 127.0.0.1, and access it through an SSH tunnel or an explicitly secured proxy."
  echo "Command: ${AI_PLATFORM_BASE}/jupyter-venv/bin/jupyter lab --no-browser --ip=127.0.0.1 --notebook-dir=${AI_NOTEBOOKS_BASE}"
}

ai_jupyter_menu() {
  local action environment_type detected show_install
  while true; do
    echo ""
    echo "============================================================"
    echo "                    JUPYTER INTEGRATION"
    echo "============================================================"
    ai_jupyter_status || true
    echo "1) Jupyter Status"
    echo "2) Environment Information"
    echo "3) Test CUDA"
    echo "4) Test PyTorch GPU"
    echo "5) Test vLLM API through the Gateway"
    echo "6) Generate vLLM Test Notebook"
    echo "7) Generate GPU Benchmark Notebook"
    echo "8) Generate Tool-Calling Test Notebook"
    echo "9) Generate Embeddings / RAG Test Notebook"
    echo "10) Show Provider Access Information"
    echo "11) Security Diagnostics"
    environment_type="$(ai_environment_value environment_type)"
    detected="$(ai_environment_value jupyter.detected)"
    show_install="no"
    if { [ "$environment_type" = "FULL_VM" ] || [ "$environment_type" = "BARE_METAL" ]; } && [ "$detected" != "true" ]; then
      show_install="yes"
      echo "12) Optional isolated JupyterLab install (trusted VPS only)"
    fi
    echo "0) Back"
    prompt action "Option: " "0"
    case "$action" in
      1) ai_jupyter_status ;;
      2) ai_jupyter_environment_information ;;
      3) ai_jupyter_cuda_test ;;
      4) ai_jupyter_pytorch_test ;;
      5) ai_jupyter_test_vllm_api ;;
      6) ai_jupyter_generate_notebook vllm-api ;;
      7) ai_jupyter_generate_notebook gpu-benchmark ;;
      8) ai_jupyter_generate_notebook tool-calling ;;
      9) ai_jupyter_generate_notebook embeddings-rag ;;
      10) ai_jupyter_provider_access ;;
      11) ai_jupyter_security_diagnostics ;;
      12)
        if [ "$show_install" = "yes" ]; then
          ai_jupyter_install_isolated
        else
          echo "Installation is not available for a detected/provider-managed Jupyter environment."
        fi
        ;;
      0) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_platform_logs() {
  local service lines
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" = "native" ]; then
    prompt service "Service (gateway/web/controller/redis/cloudflared/supervisord/all/backup-cron or model:<alias>): " "all"
  else
    prompt service "Service (gateway/web/controller/postgres/redis/all/proxy/backup-cron or model:<container>): " "all"
  fi
  prompt lines "Number of lines: " "150"
  if [[ "$service" == model:* ]]; then
    if [ "$(ai_runtime_mode)" = "native" ]; then
      local safe_alias
      safe_alias="$(printf '%s' "${service#model:}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
      tail -n "$lines" "${AI_PLATFORM_BASE}/logs/model-vllm-ai-${safe_alias}.log"
    else
      docker logs --tail "$lines" "${service#model:}"
    fi
  elif [ "$service" = "proxy" ]; then
    proxy_dc logs --tail "$lines" reverse-proxy
  elif [ "$service" = "backup-cron" ]; then
    tail -n "$lines" /var/log/vllm-ai-platform-backup.log 2>/dev/null || echo "No AI backup log exists yet."
  elif [ "$service" = "all" ]; then
    if [ "$(ai_runtime_mode)" = "native" ]; then
      tail -n "$lines" "${AI_PLATFORM_BASE}/logs/"*.log 2>/dev/null || echo "No native logs exist yet."
    else
      ai_dc logs --tail "$lines"
    fi
  else
    if [ "$(ai_runtime_mode)" = "native" ]; then
      ai_native logs "$service" --lines "$lines"
    else
      ai_dc logs --tail "$lines" "$service"
    fi
  fi
}

ai_model_menu() {
  local action model_id alias revision caps size gpus tp pp profile path confirm new_alias
  local quantization dtype max_context max_sequences trust_remote tools parser chat_template auto_start
  local token_required hf_token download_now activate_now
  ai_require_installed || return 1
  while true; do
    echo ""
    echo "Model management"
    echo "1) List models"
    echo "2) Install a current stable model (guided)"
    echo "3) Add arbitrary Hugging Face model"
    echo "4) Import custom model path"
    echo "5) Download/resume model"
    echo "6) Activate model"
    echo "7) Deactivate model"
    echo "8) Show model details"
    echo "9) Analyze compatibility"
    echo "10) Set default model"
    echo "11) Change model alias"
    echo "12) Configure GPUs/tensor parallelism/profile"
    echo "13) Tune performance profile"
    echo "14) Restart model"
    echo "15) Clone model configuration"
    echo "16) Delete model record only"
    echo "17) Delete model and downloaded weights"
    echo "18) Show internal vLLM metrics"
    echo "19) Plan/safely switch active model for limited VRAM"
    echo "20) Back"
    prompt action "Option: " "20"
    case "$action" in
      1) ai_cli models list ;;
      2) ai_catalog_model_wizard ;;
      3)
        prompt model_id "Hugging Face model ID: " ""
        prompt revision "Pinned revision/tag/commit: " "main"
        prompt alias "Stable API alias: " ""
        prompt caps "Capabilities (general,chat,coding,agentic,reasoning,tool_calling,responses,embeddings,vision): " "chat,completions"
        prompt size "Estimated weight size in GiB (0 if unknown): " "0"
        prompt token_required "Does this gated/private model require a Hugging Face token? (yes/no): " "no"
        if [ "${token_required,,}" = "yes" ]; then
          prompt_secret hf_token "Hugging Face token (blank keeps the configured token): "
          if [ -n "$hf_token" ]; then
            printf '%s' "$hf_token" > "${AI_PLATFORM_BASE}/secrets/hf_token"
            chmod 600 "${AI_PLATFORM_BASE}/secrets/hf_token"
          fi
        fi
        prompt trust_remote "Trust remote model code? Type YES only after reviewing the repository: " "no"
        prompt quantization "Quantization (blank/awq/gptq/fp8/...): " ""
        prompt dtype "dtype: " "auto"
        prompt max_context "Maximum model context: " "4096"
        prompt gpus "GPU indexes (comma-separated or auto): " "auto"
        prompt tp "Tensor parallel size: " "1"
        prompt pp "Pipeline parallel size: " "1"
        prompt max_sequences "Maximum concurrent sequences: " "4"
        prompt tools "Enable compatible tool/function calling? (yes/no): " "no"
        parser=""
        if [ "${tools,,}" = "yes" ]; then
          prompt parser "vLLM tool-call parser supported by this model: " ""
        fi
        prompt chat_template "Chat template path/text (blank uses the model default): " ""
        prompt auto_start "Auto-start this model when the platform starts? (yes/no): " "no"
        prompt profile "Profile (AUTO/CONSERVATIVE/BALANCED/PERFORMANCE/MAXIMUM/CUSTOM): " "AUTO"
        profile="${profile^^}"
        case "$profile" in
          AUTO|CONSERVATIVE|BALANCED|PERFORMANCE|MAXIMUM|CUSTOM) ;;
          *) echo "Invalid performance profile."; continue ;;
        esac
        local add_args=(models add --model-id "$model_id" --revision "$revision" --alias "$alias"
          --capabilities "$caps" --estimated-weight-gb "$size" --quantization "$quantization"
          --dtype "$dtype" --max-model-len "$max_context" --gpus "$gpus"
          --tensor-parallel-size "$tp" --pipeline-parallel-size "$pp" --max-num-seqs "$max_sequences"
          --performance-profile "$profile" --chat-template "$chat_template")
        [ "$trust_remote" = "YES" ] && add_args+=(--trust-remote-code)
        if [ "${tools,,}" = "yes" ]; then add_args+=(--tool-calling --tool-call-parser "$parser"); fi
        [ "${auto_start,,}" = "yes" ] && add_args+=(--auto-start)
        ai_cli "${add_args[@]}"
        prompt download_now "Download/resume model weights now? (yes/no): " "yes"
        if [ "${download_now,,}" = "yes" ]; then
          ai_cli models download "$alias"
          prompt activate_now "Validate capacity and activate now? (yes/no): " "no"
          [ "${activate_now,,}" = "yes" ] && ai_cli models activate "$alias"
        fi
        ;;
      4)
        prompt path "Absolute model path under ${AI_PLATFORM_BASE}/models: " ""
        prompt alias "Stable API alias: " ""
        prompt caps "Capabilities: " "chat,completions"
        if [[ "$path" != "${AI_PLATFORM_BASE}/models/"* ]]; then
          echo "The path must be below ${AI_PLATFORM_BASE}/models."
          continue
        fi
        path="/models/${path#"${AI_PLATFORM_BASE}/models/"}"
        ai_cli models add --model-id "local/${alias}" --alias "$alias" \
          --local-path "$path" --capabilities "$caps"
        ;;
      5) prompt model_id "Model ID or alias: " ""; ai_cli models download "$model_id" ;;
      6) prompt model_id "Model ID or alias: " ""; ai_cli models activate "$model_id" ;;
      7) prompt model_id "Model ID or alias: " ""; ai_cli models deactivate "$model_id" ;;
      8) prompt model_id "Model ID or alias: " ""; ai_cli models details "$model_id" ;;
      9) prompt model_id "Model ID or alias: " ""; ai_cli models compatibility "$model_id" ;;
      10) prompt model_id "Model ID or alias: " ""; ai_cli models default "$model_id" ;;
      11)
        prompt model_id "Model ID or current alias: " ""
        prompt new_alias "New alias: " ""
        ai_cli models alias "$model_id" "$new_alias"
        ;;
      12)
        prompt model_id "Model ID or alias: " ""
        prompt gpus "GPU indexes (comma-separated or auto): " "auto"
        prompt tp "Tensor parallel size: " "1"
        prompt profile "Profile (AUTO/CONSERVATIVE/BALANCED/PERFORMANCE/MAXIMUM/CUSTOM): " "AUTO"
        ai_cli models configure "$model_id" --gpus "$gpus" --tensor-parallel-size "$tp" --performance-profile "${profile^^}"
        ;;
      13)
        prompt model_id "Model ID or alias: " ""
        prompt profile "Profile (AUTO/CONSERVATIVE/BALANCED/PERFORMANCE/MAXIMUM/CUSTOM): " "BALANCED"
        if [ "${profile^^}" = "MAXIMUM" ]; then
          prompt confirm "MAXIMUM uses the smallest safety reserve permitted by the profile. Apply after validation? (yes/no): " "no"
          [ "${confirm,,}" = "yes" ] || continue
        fi
        ai_cli performance "$model_id" "${profile^^}" --apply
        ;;
      14) prompt model_id "Model ID or alias: " ""; ai_cli models restart "$model_id" ;;
      15)
        prompt model_id "Model ID or alias: " ""
        prompt new_alias "Alias for clone: " ""
        ai_cli models clone "$model_id" "$new_alias"
        ;;
      16)
        prompt model_id "Model ID or alias: " ""
        prompt confirm "Delete the model record but keep weights? (yes/no): " "no"
        [ "${confirm,,}" = "yes" ] && ai_cli models delete "$model_id"
        ;;
      17)
        prompt model_id "Model ID or alias: " ""
        prompt confirm "Permanently delete this record and its managed weight directory? Type DELETE: " ""
        [ "$confirm" = "DELETE" ] && ai_cli models delete "$model_id" --delete-weights
        ;;
      18) prompt model_id "Model ID or alias: " ""; ai_cli models metrics "$model_id" ;;
      19)
        prompt model_id "Downloaded model ID or alias: " ""
        ai_cli models plan "$model_id" || continue
        prompt confirm "Stop the listed conflicting model(s) and activate this one? (yes/no): " "no"
        [ "${confirm,,}" = "yes" ] && ai_cli models switch "$model_id"
        ;;
      20) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_user_menu() {
  local action name email role user_id password description models scopes endpoints purpose service_id confirm custom_system
  while true; do
    echo ""
    echo "Users and service accounts"
    echo "1) List users"
    echo "2) Create user"
    echo "3) Enable user"
    echo "4) Disable user"
    echo "5) Reset user password"
    echo "6) List service accounts"
    echo "7) Create service account"
    echo "8) Enable service account"
    echo "9) Disable service account"
    echo "10) Delete service account"
    echo "11) Back"
    prompt action "Option: " "11"
    case "$action" in
      1) ai_cli users list ;;
      2)
        prompt name "Name: " ""
        prompt email "Email: " ""
        prompt role "Role (super_admin/administrator/user): " "user"
        prompt_secret password "Temporary password: "
        printf '%s\n' "$password" | ai_dc exec -T controller python -m app.cli users create --name "$name" --email "$email" --role "$role"
        ;;
      3|4)
        prompt user_id "User numeric ID: " ""
        [ "$action" = "3" ] && ai_cli users enable "$user_id" || ai_cli users disable "$user_id"
        ;;
      5)
        prompt user_id "User numeric ID: " ""
        prompt_secret password "New temporary password: "
        printf '%s\n' "$password" | ai_dc exec -T controller python -m app.cli users reset-password "$user_id"
        ;;
      6) ai_cli service-accounts list ;;
      7)
        prompt name "Service account name: " ""
        prompt description "Description: " ""
        prompt purpose "Purpose (general_api/omnivis_production/coding_agent/custom): " "general_api"
        prompt models "Allowed model aliases (blank means all permitted models): " ""
        prompt scopes "Allowed scopes: " "models,chat"
        prompt endpoints "Allowed endpoints (comma-separated; blank keeps legacy behavior): " ""
        prompt custom_system "Permit custom system messages? (yes/no): " "no"
        local service_args=(service-accounts create --name "$name" --description "$description" --purpose "$purpose" --models "$models" --scopes "$scopes" --endpoints "$endpoints")
        [ "${custom_system,,}" = "yes" ] && service_args+=(--allow-custom-system-messages)
        ai_cli "${service_args[@]}"
        ;;
      8|9)
        prompt service_id "Service account numeric ID: " ""
        [ "$action" = "8" ] && ai_cli service-accounts enable "$service_id" || ai_cli service-accounts disable "$service_id"
        ;;
      10)
        prompt service_id "Service account numeric ID: " ""
        prompt confirm "Delete it and all attached API keys? Type DELETE: " ""
        [ "$confirm" = "DELETE" ] && ai_cli service-accounts delete "$service_id"
        ;;
      11) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_key_menu() {
  local action name owner_type owner_id models cidrs scopes endpoints key_id
  while true; do
    echo ""
    echo "API keys"
    echo "1) List  2) Create  3) Revoke  4) Rotate  5) Back"
    prompt action "Option: " "5"
    case "$action" in
      1) ai_cli keys list ;;
      2)
        prompt name "Key name: " ""
        prompt owner_type "Owner type (user/service): " "user"
        prompt owner_id "Owner numeric ID: " ""
        prompt models "Allowed model aliases (blank means owner policy): " ""
        prompt cidrs "Allowed IPv4/IPv6 CIDRs (blank means inherited policy): " ""
        prompt scopes "Allowed scopes: " "models,chat"
        prompt endpoints "Allowed endpoints (comma-separated; blank inherits owner/legacy behavior): " ""
        if [ "$owner_type" = "service" ]; then
          ai_cli keys create --name "$name" --service-account-id "$owner_id" --models "$models" --cidrs "$cidrs" --scopes "$scopes" --endpoints "$endpoints"
        else
          ai_cli keys create --name "$name" --user-id "$owner_id" --models "$models" --cidrs "$cidrs" --scopes "$scopes" --endpoints "$endpoints"
        fi
        ;;
      3|4)
        prompt key_id "API key numeric ID: " ""
        [ "$action" = "3" ] && ai_cli keys revoke "$key_id" || ai_cli keys rotate "$key_id"
        ;;
      5) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_ip_menu() {
  local action cidr scope subject description rule_id
  while true; do
    echo ""
    echo "IP allowlists"
    echo "1) List  2) Add  3) Delete  4) Back"
    prompt action "Option: " "4"
    case "$action" in
      1) ai_cli ip list ;;
      2)
        prompt cidr "IPv4 or IPv6 CIDR: " ""
        prompt scope "Scope (global/service_account/api_key): " "global"
        prompt subject "Subject ID (blank for global): " ""
        prompt description "Description: " ""
        local args=(ip add "$cidr" --scope "$scope" --description "$description")
        [ -n "$subject" ] && args+=(--subject-id "$subject")
        ai_cli "${args[@]}"
        ;;
      3) prompt rule_id "Rule numeric ID: " ""; ai_cli ip delete "$rule_id" ;;
      4) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_cloudflared_binary() {
  local candidate from_path
  from_path="$(command -v cloudflared 2>/dev/null || true)"
  for candidate in /opt/instance-tools/bin/cloudflared /usr/local/bin/cloudflared /usr/bin/cloudflared "$from_path"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ai_hostname_is_valid() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import re
import sys

value = sys.argv[1].strip().lower().rstrip(".")
if len(value) > 253 or "." not in value or "://" in value or "/" in value:
    raise SystemExit(1)
try:
    value.encode("ascii")
except UnicodeEncodeError:
    raise SystemExit(1)
label = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
raise SystemExit(0 if all(label.fullmatch(part) for part in value.split(".")) else 1)
PY
}

ai_external_health_code() {
  local hostname="$1"
  [ -n "$hostname" ] || {
    printf 'not-configured\n'
    return 0
  }
  curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 12 "https://${hostname}/health" 2>/dev/null || true
}

ai_external_access_status() {
  local mode panel_hostname api_hostname code
  ai_require_installed || return 1
  mode="$(ai_env_value EXTERNAL_EXPOSURE_MODE)"
  mode="${mode:-none}"
  panel_hostname="$(ai_env_value CLOUDFLARE_PANEL_HOSTNAME)"
  api_hostname="$(ai_env_value CLOUDFLARE_API_HOSTNAME)"
  echo "External exposure: ${mode}"
  if [ "$mode" != "cloudflare" ]; then
    echo "  No managed public tunnel is enabled. Loopback/SSH access remains private."
    return 0
  fi
  echo "  Panel: https://${panel_hostname}"
  [ -z "$api_hostname" ] || echo "  API:   https://${api_hostname}/v1"
  if [ "$(ai_runtime_mode)" = "native" ]; then
    "${AI_NATIVE_PLATFORM_VENV}/bin/supervisorctl" \
      -c "${AI_NATIVE_BASE}/supervisord.conf" status cloudflared 2>/dev/null \
      || echo "  cloudflared is not RUNNING. Review its log from this menu."
  fi
  code="$(ai_external_health_code "$panel_hostname")"
  echo "  Panel public health: ${code:-000}"
  if [ -n "$api_hostname" ]; then
    code="$(ai_external_health_code "$api_hostname")"
    echo "  API public health:   ${code:-000}"
  fi
}

ai_cloudflare_configure() {
  local binary panel_hostname api_hostname token routes_ready service_group status_text
  local old_mode old_domain old_origins old_cookie old_binary old_token_path old_panel old_api
  local token_backup="" had_token="no" running="no" attempt code
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" != "native" ]; then
    echo "This managed Cloudflare Tunnel option currently targets the isolated native runtime."
    echo "Docker/VPS installations should use the existing TLS reverse-proxy workflow."
    return 1
  fi
  binary="$(ai_cloudflared_binary)" || {
    echo "cloudflared is not installed. Install the official binary and retry."
    return 1
  }
  if ! "$binary" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
    echo "The installed cloudflared does not support --token-file; version 2025.4.0 or newer is required."
    return 1
  fi

  panel_hostname="$(ai_env_value CLOUDFLARE_PANEL_HOSTNAME)"
  [ -n "$panel_hostname" ] || panel_hostname="$(ai_env_value AI_DOMAIN)"
  [ "$panel_hostname" = "localhost" ] && panel_hostname=""
  [ "$panel_hostname" = "ai.example.com" ] && panel_hostname=""
  api_hostname="$(ai_env_value CLOUDFLARE_API_HOSTNAME)"
  prompt panel_hostname "Public panel hostname (example: ia.example.com): " "$panel_hostname"
  panel_hostname="${panel_hostname,,}"
  panel_hostname="${panel_hostname%.}"
  ai_hostname_is_valid "$panel_hostname" || {
    echo "Enter a DNS hostname only, without https://, port or path."
    return 1
  }
  prompt api_hostname "Public API hostname (blank disables public API): " "$api_hostname"
  api_hostname="${api_hostname,,}"
  api_hostname="${api_hostname%.}"
  if [ -n "$api_hostname" ]; then
    ai_hostname_is_valid "$api_hostname" || {
      echo "The API hostname is invalid. Enter only a DNS hostname."
      return 1
    }
    if [ "$api_hostname" = "$panel_hostname" ]; then
      echo "Use different hostnames for the panel and API."
      return 1
    fi
  fi

  if [ -f "$AI_CLOUDFLARED_TOKEN_FILE" ]; then
    had_token="yes"
    token_backup="$(mktemp /tmp/vllm-ai-cloudflare-token.XXXXXX)"
    cp "$AI_CLOUDFLARED_TOKEN_FILE" "$token_backup"
    chmod 600 "$token_backup"
    echo "A connector token is already stored; leave the next value blank to keep it."
  fi
  prompt_secret token "Cloudflare Tunnel connector token (hidden): "
  if [ -n "$token" ]; then
    if [ "${#token}" -lt 40 ] || [ "${#token}" -gt 4096 ] || [[ "$token" =~ [[:space:]] ]]; then
      [ -z "$token_backup" ] || rm -f -- "$token_backup"
      echo "The connector token format is invalid."
      return 1
    fi
    (umask 027; printf '%s' "$token" > "$AI_CLOUDFLARED_TOKEN_FILE")
  elif [ ! -f "$AI_CLOUDFLARED_TOKEN_FILE" ]; then
    [ -z "$token_backup" ] || rm -f -- "$token_backup"
    echo "A connector token is required the first time."
    return 1
  fi
  unset token

  service_group="$(id -gn "$AI_NATIVE_SERVICE_USER")"
  chown "root:${service_group}" "${AI_PLATFORM_BASE}/secrets"
  chmod 710 "${AI_PLATFORM_BASE}/secrets"
  chown "root:${service_group}" "$AI_CLOUDFLARED_TOKEN_FILE"
  chmod 640 "$AI_CLOUDFLARED_TOKEN_FILE"
  if command -v runuser >/dev/null 2>&1 \
    && ! runuser -u "$AI_NATIVE_SERVICE_USER" -- test -r "$AI_CLOUDFLARED_TOKEN_FILE"; then
    echo "The cloudflared service user cannot read the protected connector token."
    if [ "$had_token" = "yes" ]; then
      cp "$token_backup" "$AI_CLOUDFLARED_TOKEN_FILE"
      chown "root:${service_group}" "$AI_CLOUDFLARED_TOKEN_FILE"
      chmod 640 "$AI_CLOUDFLARED_TOKEN_FILE"
    else
      rm -f -- "$AI_CLOUDFLARED_TOKEN_FILE"
    fi
    [ -z "$token_backup" ] || rm -f -- "$token_backup"
    return 1
  fi

  old_mode="$(ai_env_value EXTERNAL_EXPOSURE_MODE)"
  old_domain="$(ai_env_value AI_DOMAIN)"
  old_origins="$(ai_env_value ALLOWED_ORIGINS)"
  old_cookie="$(ai_env_value COOKIE_SECURE)"
  old_binary="$(ai_env_value CLOUDFLARED_EXECUTABLE)"
  old_token_path="$(ai_env_value CLOUDFLARED_TOKEN_FILE)"
  old_panel="$(ai_env_value CLOUDFLARE_PANEL_HOSTNAME)"
  old_api="$(ai_env_value CLOUDFLARE_API_HOSTNAME)"

  set_env_file_var "$AI_PLATFORM_ENV" "EXTERNAL_EXPOSURE_MODE" "cloudflare"
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_EXECUTABLE" "$binary"
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_TOKEN_FILE" "$AI_CLOUDFLARED_TOKEN_FILE"
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_PANEL_HOSTNAME" "$panel_hostname"
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_API_HOSTNAME" "$api_hostname"
  set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "$panel_hostname"
  set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" "https://${panel_hostname}"
  set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "true"
  if ! ai_native restart; then
    echo "Tunnel configuration failed; restoring the previous platform settings."
    set_env_file_var "$AI_PLATFORM_ENV" "EXTERNAL_EXPOSURE_MODE" "${old_mode:-none}"
    set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "$old_domain"
    set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" "$old_origins"
    set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "$old_cookie"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_EXECUTABLE" "$old_binary"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_TOKEN_FILE" "$old_token_path"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_PANEL_HOSTNAME" "$old_panel"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_API_HOSTNAME" "$old_api"
    if [ "$had_token" = "yes" ]; then
      cp "$token_backup" "$AI_CLOUDFLARED_TOKEN_FILE"
    else
      rm -f -- "$AI_CLOUDFLARED_TOKEN_FILE"
    fi
    ai_native start || true
    [ -z "$token_backup" ] || rm -f -- "$token_backup"
    return 1
  fi

  for attempt in {1..20}; do
    status_text="$("${AI_NATIVE_PLATFORM_VENV}/bin/supervisorctl" -c "${AI_NATIVE_BASE}/supervisord.conf" status cloudflared 2>&1 || true)"
    if grep -Eq '^cloudflared[[:space:]]+RUNNING' <<< "$status_text"; then
      running="yes"
      break
    fi
    sleep 1
  done
  if [ "$running" != "yes" ]; then
    echo "cloudflared did not remain running:"
    printf '%s\n' "$status_text"
    ai_native logs cloudflared --lines 80 || true
    echo "The token or tunnel configuration must be corrected. Restoring private access settings."
    set_env_file_var "$AI_PLATFORM_ENV" "EXTERNAL_EXPOSURE_MODE" "${old_mode:-none}"
    set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "$old_domain"
    set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" "$old_origins"
    set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "$old_cookie"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_EXECUTABLE" "$old_binary"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARED_TOKEN_FILE" "$old_token_path"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_PANEL_HOSTNAME" "$old_panel"
    set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_API_HOSTNAME" "$old_api"
    if [ "$had_token" = "yes" ]; then
      cp "$token_backup" "$AI_CLOUDFLARED_TOKEN_FILE"
      chown "root:${service_group}" "$AI_CLOUDFLARED_TOKEN_FILE"
      chmod 640 "$AI_CLOUDFLARED_TOKEN_FILE"
    else
      rm -f -- "$AI_CLOUDFLARED_TOKEN_FILE"
    fi
    ai_native restart || true
    [ -z "$token_backup" ] || rm -f -- "$token_backup"
    return 1
  fi

  mkdir -p "$AI_NATIVE_BASE"
  printf 'mode=cloudflare\npanel_hostname=%s\napi_hostname=%s\nconfigured_at=%s\n' \
    "$panel_hostname" "$api_hostname" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AI_EXTERNAL_ACCESS_META"
  chmod 600 "$AI_EXTERNAL_ACCESS_META"
  [ -z "$token_backup" ] || rm -f -- "$token_backup"
  echo "Cloudflare connector is managed by the native platform Supervisor."
  echo "Return to Cloudflare, wait for the connector to show Connected, then create these Published application routes:"
  echo "  ${panel_hostname} -> http://localhost:18080"
  [ -z "$api_hostname" ] || echo "  ${api_hostname} -> http://localhost:8000"
  echo "Add a final catch-all route to http_status:404."
  prompt routes_ready "Are the routes saved and ready for a public health check? (yes/no): " "no"
  if [ "${routes_ready,,}" = "yes" ]; then
    code="$(ai_external_health_code "$panel_hostname")"
    echo "Panel public health: ${code:-000}"
    if [ -n "$api_hostname" ]; then
      code="$(ai_external_health_code "$api_hostname")"
      echo "API public health: ${code:-000}"
    fi
    echo "If a health code is 000/404, allow DNS and tunnel-route propagation, then use Status to retry."
  else
    echo "The connector remains active. Finish the routes in Cloudflare, then choose Status and public health."
  fi
}

ai_external_access_disable() {
  local confirm delete_token
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" != "native" ]; then
    echo "Managed Cloudflare exposure is not enabled for this runtime."
    return 1
  fi
  prompt confirm "Disable the managed public tunnel and return to private SSH access? (yes/no): " "no"
  [ "${confirm,,}" = "yes" ] || return 0
  set_env_file_var "$AI_PLATFORM_ENV" "EXTERNAL_EXPOSURE_MODE" "none"
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_PANEL_HOSTNAME" ""
  set_env_file_var "$AI_PLATFORM_ENV" "CLOUDFLARE_API_HOSTNAME" ""
  set_env_file_var "$AI_PLATFORM_ENV" "AI_DOMAIN" "localhost"
  set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" ""
  set_env_file_var "$AI_PLATFORM_ENV" "COOKIE_SECURE" "false"
  ai_native restart
  rm -f -- "$AI_EXTERNAL_ACCESS_META"
  prompt delete_token "Delete the stored Cloudflare connector token? (yes/no): " "yes"
  if [ "${delete_token,,}" = "yes" ]; then
    rm -f -- "$AI_CLOUDFLARED_TOKEN_FILE"
    echo "Stored connector token deleted."
  fi
  echo "Managed external exposure is disabled; loopback services remain available through SSH forwarding."
}

ai_external_access_menu() {
  local action
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" != "native" ]; then
    echo "External domain management from this menu is available for the native runtime."
    echo "Docker/VPS installations should use the platform TLS reverse-proxy configuration."
    return 1
  fi
  while true; do
    echo ""
    echo "External domain / Cloudflare Tunnel"
    echo "1) Configure or update custom-domain tunnel"
    echo "2) Status and public health"
    echo "3) View cloudflared log"
    echo "4) Disable managed external exposure"
    echo "5) Back"
    prompt action "Option: " "5"
    case "$action" in
      1) ai_cloudflare_configure ;;
      2) ai_external_access_status ;;
      3) ai_native logs cloudflared --lines 150 ;;
      4) ai_external_access_disable ;;
      5) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

ai_portal_settings() {
  local panel chat origins
  ai_require_installed || return 1
  prompt panel "Enable admin panel? (yes/no): " "$( [ "$(ai_env_value ADMIN_PANEL_ENABLED)" = "true" ] && echo yes || echo no )"
  prompt chat "Enable chat portal? (yes/no): " "$( [ "$(ai_env_value CHAT_PORTAL_ENABLED)" = "true" ] && echo yes || echo no )"
  prompt origins "Allowed browser origins (comma-separated, exact HTTPS origins): " "$(ai_env_value ALLOWED_ORIGINS)"
  [ "${panel,,}" = "yes" ] && panel=true || panel=false
  [ "${chat,,}" = "yes" ] && chat=true || chat=false
  set_env_file_var "$AI_PLATFORM_ENV" "ADMIN_PANEL_ENABLED" "$panel"
  set_env_file_var "$AI_PLATFORM_ENV" "CHAT_PORTAL_ENABLED" "$chat"
  set_env_file_var "$AI_PLATFORM_ENV" "ALLOWED_ORIGINS" "$origins"
  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native restart
    ai_cli models reconcile --wait-seconds 600 || true
  else
    ai_dc up -d --force-recreate gateway web controller
  fi
}

ai_platform_backup() {
  local include_models="${1:-ask}"
  local stamp staging archive retention
  ai_require_installed || return 1
  if [ "$include_models" = "ask" ]; then
    prompt include_models "Include model weights? This can be very large (yes/no): " "no"
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  staging="$(mktemp -d)"
  archive="${AI_BACKUPS_BASE}/vllm-ai-platform-${stamp}.tar.gz"
  mkdir -p "${staging}/config"
  chmod 700 "$staging"

  if [ "$(ai_runtime_mode)" = "native" ]; then
    "${AI_NATIVE_PLATFORM_VENV}/bin/python" - "${AI_PLATFORM_BASE}/database/platform.db" "${staging}/database.dump" <<'PY'
import sqlite3
import sys

source, destination = sys.argv[1:]
with sqlite3.connect(source) as current, sqlite3.connect(destination) as backup:
    current.backup(backup)
PY
  else
    ai_dc exec -T postgres pg_dump \
      -U "$(ai_env_value POSTGRES_USER)" \
      -d "$(ai_env_value POSTGRES_DB)" \
      -Fc > "${staging}/database.dump"
  fi
  rsync -a \
    --exclude='database/' --exclude='redis/' --exclude='models/' --exclude='hf-cache/' \
    --exclude='backups/' --exclude='logs/' --exclude='jupyter-venv/' --exclude='native/' \
    "${AI_PLATFORM_BASE}/" "${staging}/config/"
  if [ "${include_models,,}" = "yes" ]; then
    mkdir -p "${staging}/models"
    rsync -a "${AI_PLATFORM_BASE}/models/" "${staging}/models/"
  fi
  printf '{"format":"vllm-ai-platform-backup","schema_version":1,"created_at":"%s","includes_models":%s,"runtime_mode":"%s","vllm_image":"%s","native_vllm_version":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$( [ "${include_models,,}" = "yes" ] && echo true || echo false )" \
    "$(ai_runtime_mode)" \
    "$(ai_env_value VLLM_IMAGE)" \
    "$(ai_env_value NATIVE_VLLM_VERSION)" > "${staging}/manifest.json"
  if [ -d "${staging}/models" ]; then
    (umask 077; tar -C "$staging" -czf "$archive" manifest.json database.dump config models)
  else
    (umask 077; tar -C "$staging" -czf "$archive" manifest.json database.dump config)
  fi
  chmod 600 "$archive"
  python3 "${AI_PLATFORM_BASE}/scripts/safe_archive.py" inspect "$archive" >/dev/null
  (
    cd "$AI_BACKUPS_BASE" || exit 1
    sha256sum "$(basename "$archive")" > "$(basename "${archive}.sha256")"
  )
  chmod 600 "${archive}.sha256"
  rm -rf "$staging"
  retention="$(ai_env_value AI_BACKUP_RETENTION_DAYS)"
  find "$AI_BACKUPS_BASE" -maxdepth 1 -type f -name 'vllm-ai-platform-*.tar.gz*' -mtime "+${retention:-14}" -delete
  echo "Backup created: ${archive}"
  echo "Model weights included: $( [ "${include_models,,}" = "yes" ] && echo yes || echo no )"
}

ai_platform_restore() {
  local archive confirm staging restore_models redownload aliases alias backup_runtime current_runtime
  local restored_db_user restored_db_password sql_password
  ai_require_installed || return 1
  prompt archive "Backup archive path: " ""
  archive="$(readlink -f "$archive" 2>/dev/null || true)"
  if [ -z "$archive" ] || [ ! -f "$archive" ]; then
    echo "Backup archive not found."
    return 1
  fi
  if [ -f "${archive}.sha256" ]; then
    (
      cd "$(dirname "$archive")" || exit 1
      sha256sum -c "$(basename "${archive}.sha256")"
    )
  else
    echo "Warning: no checksum sidecar was found; the archive will still receive structural validation."
  fi
  python3 "${AI_PLATFORM_BASE}/scripts/safe_archive.py" inspect "$archive"
  prompt confirm "Restore this backup? Current configuration and database will be replaced. Type RESTORE: " ""
  [ "$confirm" = "RESTORE" ] || return 0
  ai_platform_backup no
  staging="$(mktemp -d)"
  python3 "${AI_PLATFORM_BASE}/scripts/safe_archive.py" extract "$archive" "$staging"
  if [ ! -f "${staging}/config/compose.yaml" ] || [ ! -f "${staging}/database.dump" ]; then
    rm -rf "$staging"
    echo "Backup is incomplete."
    return 1
  fi
  backup_runtime="$(python3 - "${staging}/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("runtime_mode", "docker"))
PY
)"
  current_runtime="$(ai_runtime_mode)"
  if [ "$backup_runtime" != "$current_runtime" ]; then
    rm -rf "$staging"
    echo "Cross-runtime restore is not automatic: backup=${backup_runtime}, installed=${current_runtime}."
    echo "Install the matching runtime first or migrate the database explicitly."
    return 1
  fi
  ai_platform_stop || true
  rsync -a --delete \
    --exclude='database/' --exclude='redis/' --exclude='models/' --exclude='hf-cache/' \
    --exclude='backups/' --exclude='logs/' --exclude='jupyter-venv/' --exclude='native/' \
    "${staging}/config/" "${AI_PLATFORM_BASE}/"
  chmod 600 "$AI_PLATFORM_ENV" "${AI_PLATFORM_BASE}/secrets/hf_token"
  if [ -d "${staging}/models" ]; then
    prompt restore_models "Restore model weights included in the backup? (yes/no): " "no"
    if [ "${restore_models,,}" = "yes" ]; then
      rsync -a --delete "${staging}/models/" "${AI_PLATFORM_BASE}/models/"
    fi
  fi
  if [ "$(ai_runtime_mode)" = "native" ]; then
    "${AI_NATIVE_PLATFORM_VENV}/bin/python" - "${staging}/database.dump" "${AI_PLATFORM_BASE}/database/platform.db" <<'PY'
import sqlite3
import sys

source, destination = sys.argv[1:]
with sqlite3.connect(source) as backup:
    if backup.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise SystemExit("restored SQLite backup failed integrity validation")
    with sqlite3.connect(destination) as current:
        backup.backup(current)
PY
    ai_native_prepare_service_user
    ai_native start
  else
    ai_dc up -d postgres redis
    restored_db_user="$(ai_env_value POSTGRES_USER)"
    restored_db_password="$(ai_env_value POSTGRES_PASSWORD)"
    if [[ ! "$restored_db_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [ -z "$restored_db_password" ]; then
      rm -rf "$staging"
      echo "The restored database credentials are invalid."
      return 1
    fi
    # pg_dump does not preserve PostgreSQL role passwords. Reapply the restored
    # secret so a backup can move safely to a freshly initialized VPS.
    sql_password="${restored_db_password//\'/\'\'}"
    printf "ALTER ROLE \"%s\" PASSWORD '%s';\n" "$restored_db_user" "$sql_password" \
      | ai_dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$restored_db_user" -d postgres
    ai_dc exec -T postgres pg_restore \
      -U "$(ai_env_value POSTGRES_USER)" \
      -d "$(ai_env_value POSTGRES_DB)" \
      --clean --if-exists < "${staging}/database.dump"
    ai_dc run --rm migrate
    ai_dc up -d gateway web controller
    ai_sync_proxy_from_env
  fi
  ai_cli models verify-storage
  prompt redownload "Redownload missing Hugging Face models now? (yes/no): " "no"
  if [ "${redownload,,}" = "yes" ]; then
    prompt aliases "Missing model aliases to download (comma-separated): " ""
    IFS=',' read -r -a missing_aliases <<< "$aliases"
    for alias in "${missing_aliases[@]}"; do
      alias="${alias//[[:space:]]/}"
      [ -z "$alias" ] || ai_cli models download "$alias"
    done
  fi
  rm -rf "$staging"
  ai_hardware_refresh no
  echo "Restore complete. Review model compatibility before activation."
}

ai_safe_remove_path() {
  local target="$1"
  local expected="$2"
  local resolved
  [ -e "$target" ] || return 0
  resolved="$(readlink -f "$target")"
  if [ "$resolved" != "$expected" ]; then
    echo "Refusing to remove unexpected path: ${resolved}"
    return 1
  fi
  rm -rf "$resolved"
}

ai_platform_uninstall() {
  local mode confirm ids
  ai_require_installed || return 1
  echo "1) Disable containers/proxy only; preserve all files"
  echo "2) Remove application, database and cache; preserve weights and backups"
  echo "3) Full removal including model weights and backups"
  prompt mode "Removal mode: " "1"
  prompt confirm "Type UNINSTALL-AI to continue: " ""
  [ "$confirm" = "UNINSTALL-AI" ] || return 0

  if [ "$(ai_runtime_mode)" = "native" ]; then
    ai_native stop || true
  else
    ids="$(docker ps -aq --filter label=com.vllm-ai-platform.managed=true)"
    [ -z "$ids" ] || docker rm -f $ids
    ai_dc down || true
  fi
  remove_ai_cron_jobs
  if [ -f "$AI_PROXY_CONFIG" ]; then
    rm -f "$AI_PROXY_CONFIG"
    proxy_dc exec -T reverse-proxy nginx -t && proxy_dc restart reverse-proxy || true
  fi

  case "$mode" in
    1) echo "AI containers and proxy were removed; all platform files remain recoverable." ;;
    2)
      local keep_dir
      keep_dir="$(mktemp -d)"
      mv "${AI_PLATFORM_BASE}/models" "${keep_dir}/models"
      ai_safe_remove_path "$AI_PLATFORM_BASE" "/opt/vllm-ai-platform"
      mkdir -p "$AI_PLATFORM_BASE"
      mv "${keep_dir}/models" "${AI_PLATFORM_BASE}/models"
      rmdir "$keep_dir"
      echo "Application/database/cache removed. Weights and backups were preserved."
      ;;
    3)
      prompt confirm "This deletes database, weights and AI backups. Type DELETE-EVERYTHING: " ""
      if [ "$confirm" = "DELETE-EVERYTHING" ]; then
        ai_safe_remove_path "$AI_PLATFORM_BASE" "/opt/vllm-ai-platform"
        ai_safe_remove_path "$AI_BACKUPS_BASE" "/var/backups/vllm-ai-platform"
        echo "AI application, database, weights, cache and backups were permanently removed."
      fi
      ;;
    *) echo "Invalid mode." ;;
  esac
}

ai_update_platform() {
  local image confirm old_image ids
  ai_require_installed || return 1
  if [ "$(ai_runtime_mode)" = "native" ]; then
    local version old_version
    old_version="$(ai_env_value NATIVE_VLLM_VERSION)"
    prompt version "New pinned native vLLM package version: " "$old_version"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)$ ]]; then
      echo "Invalid pinned native vLLM version."
      return 1
    fi
    prompt confirm "Create a backup and update the isolated native environments? (yes/no): " "yes"
    [ "${confirm,,}" = "yes" ] || return 0
    ai_platform_backup no
    ai_copy_assets
    set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_VERSION" "$version"
    ai_native_install_environments "$version"
    ai_native_prepare_service_user
    if ! ai_cli models validate-config || ! ai_native restart || ! ai_cli models reconcile --wait-seconds 600 --strict; then
      echo "Native update validation failed. Reinstalling the previous pinned vLLM version."
      set_env_file_var "$AI_PLATFORM_ENV" "NATIVE_VLLM_VERSION" "$old_version"
      ai_native_install_environments "$old_version"
      ai_native restart || true
      ai_cli models reconcile --wait-seconds 600 || true
      return 1
    fi
    set_env_file_var "$AI_PLATFORM_META" "native_vllm_version" "$version"
    set_env_file_var "$AI_PLATFORM_META" "last_updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Native vLLM update applied."
    return 0
  fi
  old_image="$(ai_env_value VLLM_IMAGE)"
  echo "Current image: ${old_image}"
  prompt image "New pinned vLLM image: " "$old_image"
  if [[ ! "$image" =~ ^vllm/vllm-openai:[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid pinned image."
    return 1
  fi
  prompt confirm "Create a database/config backup and apply this update? (yes/no): " "yes"
  [ "${confirm,,}" = "yes" ] || return 0
  ai_platform_backup no
  ai_copy_assets
  set_env_file_var "$AI_PLATFORM_ENV" "VLLM_IMAGE" "$image"
  if ! docker pull "$image" \
    || ! ai_dc config >/dev/null \
    || ! ai_dc build --pull \
    || ! ai_dc run --rm migrate \
    || ! ai_dc run --rm --no-deps controller python -m app.cli models validate-config; then
    echo "Update validation failed. Restoring the previous pinned vLLM image."
    set_env_file_var "$AI_PLATFORM_ENV" "VLLM_IMAGE" "$old_image"
    set_env_file_var "$AI_PLATFORM_META" "vllm_image" "$old_image"
    ai_dc build
    ai_dc up -d gateway web controller
    return 1
  fi
  ids="$(docker ps -q --filter label=com.vllm-ai-platform.managed=true)"
  if [ -n "$ids" ]; then
    docker stop --time 30 $ids
    docker rm $ids
  fi
  if ! ai_dc up -d --force-recreate gateway web controller \
    || ! ai_cli models reconcile --wait-seconds 600 --strict; then
    echo "Updated services failed to start. Restoring the previous pinned vLLM image."
    set_env_file_var "$AI_PLATFORM_ENV" "VLLM_IMAGE" "$old_image"
    set_env_file_var "$AI_PLATFORM_META" "vllm_image" "$old_image"
    ids="$(docker ps -aq --filter label=com.vllm-ai-platform.managed=true)"
    [ -z "$ids" ] || docker rm -f $ids
    ai_dc build
    ai_dc up -d --force-recreate gateway web controller
    ai_cli models reconcile --wait-seconds 600 || true
    return 1
  fi
  set_env_file_var "$AI_PLATFORM_META" "vllm_image" "$image"
  set_env_file_var "$AI_PLATFORM_META" "last_updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Update applied. Roll back by restoring the backup shown above and resetting VLLM_IMAGE."
}

manage_ai_platform() {
  local action
  while true; do
    echo ""
    echo "============================================================"
    echo "                 vLLM / AI PLATFORM MANAGER"
    echo "============================================================"
    ai_platform_status
    echo "============================================================"
    echo "1) Install or repair AI platform (Docker/native auto-detect)"
    echo "2) Platform status"
    echo "3) Hardware inventory and change review"
    echo "4) NVIDIA/Docker GPU diagnostics"
    echo "5) Install or repair NVIDIA Container Toolkit"
    echo "6) Start platform and reconcile models"
    echo "7) Stop platform"
    echo "8) Restart platform"
    echo "9) Manage models"
    echo "10) Manage users"
    echo "11) Manage API keys"
    echo "12) Manage IP allowlists"
    echo "13) Portal and API settings"
    echo "14) Usage summary"
    echo "15) Diagnostics"
    echo "16) View logs"
    echo "17) Backup"
    echo "18) Restore"
    echo "19) Update pinned platform version"
    echo "20) Jupyter Integration"
    echo "21) External domain / Cloudflare Tunnel"
    echo "22) Uninstall / remove"
    echo "23) Back"
    prompt action "Option: " "23"
    case "$action" in
      1) ai_install_or_repair ;;
      2) ai_platform_status ;;
      3) ai_hardware_show ;;
      4) ai_gpu_diagnostics yes ;;
      5) ai_install_nvidia_runtime ;;
      6) ai_platform_start ;;
      7) ai_platform_stop ;;
      8) ai_platform_restart ;;
      9) ai_model_menu ;;
      10) ai_user_menu ;;
      11) ai_key_menu ;;
      12) ai_ip_menu ;;
      13) ai_portal_settings ;;
      14) ai_cli usage --limit 100 ;;
      15) ai_platform_diagnostics ;;
      16) ai_platform_logs ;;
      17) ai_platform_backup ask ;;
      18) ai_platform_restore ;;
      19) ai_update_platform ;;
      20) ai_jupyter_menu ;;
      21) ai_external_access_menu ;;
      22) ai_platform_uninstall ;;
      23) return 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
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
  echo "15) Reset database passwords"
  echo "16) Manage Guacamole (stack + proxy)"
  echo "17) Manage VNC Server (TigerVNC)"
  echo "18) Backup settings"
  echo "19) Manage project UFW"
  echo "20) Project access settings"
  echo "21) Manage webmail password changes"
  echo "22) Manage vLLM / AI Platform"
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
    15) reset_database_passwords ;;
    16) manage_guacamole_proxy ;;
    17) manage_vnc_server ;;
    18) manage_backup_settings ;;
    19) manage_project_ufw ;;
    20) manage_project_access ;;
    21) manage_webmail_password_change ;;
    22) manage_ai_platform ;;
    *) echo "Invalid option."; exit 1 ;;
  esac
}

require_root

if [ "${1:-}" = "backup-all" ]; then
  backup_all force
  exit 0
fi

if [ "${1:-}" = "backup-due" ]; then
  backup_all scheduled
  exit 0
fi

if [ "${1:-}" = "setup-cron" ]; then
  ensure_cron_jobs
  echo "Cron jobs installed/updated."
  exit 0
fi

if [ "${1:-}" = "capacity-check" ] || [ "${1:-}" = "check-capacity" ]; then
  app_profile="${2:-laravel}"
  if ! app_profile="$(normalize_project_profile "$app_profile")"; then
    echo "Invalid app profile. Use one of: laravel, thinkphp, generic, node."
    exit 1
  fi
  verify_server_capacity_or_exit "capacity check" "$app_profile"
  exit 0
fi

if [ "${1:-}" = "manage-vnc" ]; then
  banner
  manage_vnc_server
  exit 0
fi

if [ "${1:-}" = "ai-status" ]; then
  ai_platform_status
  exit 0
fi

if [ "${1:-}" = "ai-install-native" ]; then
  ai_environment_preflight
  ai_install_native
  exit 0
fi

if [ "${1:-}" = "ai-hardware" ] || [ "${1:-}" = "ai-gpu-info" ] || [ "${1:-}" = "gpu-info" ]; then
  ai_require_installed
  ai_hardware_refresh no
  python3 -m json.tool "${AI_PLATFORM_BASE}/hardware/current.json"
  exit 0
fi

if [ "${1:-}" = "ai-hardware-snapshot" ]; then
  ai_require_installed
  ai_hardware_refresh no
  exit 0
fi

if [ "${1:-}" = "ai-diagnostics" ]; then
  ai_platform_diagnostics
  exit 0
fi

if [ "${1:-}" = "ai-jupyter" ]; then
  ai_jupyter_menu
  exit 0
fi

if [ "${1:-}" = "ai-external" ] || [ "${1:-}" = "ai-domain" ]; then
  ai_external_access_menu
  exit 0
fi

if [ "${1:-}" = "ai-start" ]; then
  ai_platform_start
  exit 0
fi

if [ "${1:-}" = "ai-stop" ]; then
  ai_platform_stop
  exit 0
fi

if [ "${1:-}" = "ai-restart" ]; then
  ai_platform_restart
  exit 0
fi

if [ "${1:-}" = "ai-models" ]; then
  shift
  if [ "$#" -eq 0 ]; then
    ai_model_menu
    exit 0
  fi
  ai_cli models "$@"
  exit 0
fi

if [ "${1:-}" = "ai-backup" ]; then
  ai_platform_backup no
  exit 0
fi

banner
menu
