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
DOCKER_PMA_FIREWALL_RULES_FILE="${MANAGER_ETC_DIR}/docker-pma-firewall.rules"
DOCKER_PMA_FIREWALL_APPLY_SCRIPT="/usr/local/sbin/laravel-manager-apply-docker-pma-firewall"
DOCKER_PMA_FIREWALL_SERVICE_FILE="/etc/systemd/system/laravel-manager-docker-pma-firewall.service"
DOCKER_PMA_FIREWALL_CHAIN="LARAVEL-PMA-FW"
DEFAULT_BACKUP_RETENTION_DAYS="14"
SHARED_NETWORK="laravel-shared"
PROXY_COMPOSE="${PROXY_BASE}/docker-compose.yml"
SCRIPT_PATH="$(readlink -f "$0")"
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

  if [ "$value" -lt "$min_value" ]; then
    echo "$min_value"
  elif [ "$value" -gt "$max_value" ]; then
    echo "$max_value"
  else
    echo "$value"
  fi
}

format_memory_mb_for_redis() {
  local value_mb="$1"

  if [ "$value_mb" -ge 1024 ] && [ $((value_mb % 1024)) -eq 0 ]; then
    echo "$((value_mb / 1024))gb"
  else
    echo "${value_mb}mb"
  fi
}

detect_tuning() {
  local app_profile="${1:-}"
  local detected_ram detected_cpu redis_memory_mb mysql_buffer_mb php_max_by_ram

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

  echo "Detected server capacity: ${RAM_MB} MB RAM, ${CPU_CORES} CPU core(s)"

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

  PHP_FPM_START_SERVERS="$(clamp_int "$((PHP_FPM_CHILDREN / 4))" 1 8)"
  PHP_FPM_MIN_SPARE_SERVERS="$PHP_FPM_START_SERVERS"
  PHP_FPM_MAX_SPARE_SERVERS="$(clamp_int "$((PHP_FPM_CHILDREN / 2))" "$PHP_FPM_MIN_SPARE_SERVERS" 24)"
  REDIS_MEMORY="$(format_memory_mb_for_redis "$redis_memory_mb")"
  MYSQL_BUFFER="${mysql_buffer_mb}M"

  echo "Applied profile: ${PROFILE_NAME}"
  if [ "$app_profile" = "node" ]; then
    echo "Project tuning: Node container can use available host CPU/RAM; no PHP/MariaDB/Redis tuning generated."
  else
    echo "Project tuning: PHP-FPM max_children=${PHP_FPM_CHILDREN}, MariaDB buffer=${MYSQL_BUFFER}, Redis maxmemory=${REDIS_MEMORY}"
  fi
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
  local backup_retention_days ufw_pma_allowed_sources ufw_pma_restricted ufw_pma_port
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
  ufw_pma_allowed_sources="$(read_project_ufw_pma_allowed_sources "$app_dir")"
  ufw_pma_restricted="$(read_project_ufw_pma_restricted "$app_dir")"
  ufw_pma_port="$(read_project_ufw_pma_port "$app_dir" "$pma_port")"
  project_access_allowed_sources="$(read_project_access_allowed_sources "$app_dir")"
  project_access_restricted="$(read_project_access_restricted "$app_dir")"
  project_domains="$(normalize_project_domain_list "$domain" "$project_domains" 2>/dev/null || echo "$domain")"
  detect_tuning "$app_profile"

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
      printf 'BACKUP_RETENTION_DAYS=%q\n' "$backup_retention_days"
      printf 'UFW_PMA_ALLOWED_SOURCES=%q\n' "$ufw_pma_allowed_sources"
      printf 'UFW_PMA_RESTRICTED=%q\n' "$ufw_pma_restricted"
      printf 'UFW_PMA_PORT=%q\n' ""
      printf 'PROJECT_ACCESS_ALLOWED_SOURCES=%q\n' "$project_access_allowed_sources"
      printf 'PROJECT_ACCESS_RESTRICTED=%q\n' "$project_access_restricted"
    } > "${app_dir}/.project-meta"

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
    printf 'PHP_FPM_CHILDREN=%q\n' "$PHP_FPM_CHILDREN"
    printf 'PHP_FPM_START_SERVERS=%q\n' "$PHP_FPM_START_SERVERS"
    printf 'PHP_FPM_MIN_SPARE_SERVERS=%q\n' "$PHP_FPM_MIN_SPARE_SERVERS"
    printf 'PHP_FPM_MAX_SPARE_SERVERS=%q\n' "$PHP_FPM_MAX_SPARE_SERVERS"
    printf 'OPCACHE_MEMORY=%q\n' "$OPCACHE_MEMORY"
    printf 'REDIS_MEMORY=%q\n' "$REDIS_MEMORY"
    printf 'MYSQL_BUFFER=%q\n' "$MYSQL_BUFFER"
    printf 'MYSQL_MAX_CONNECTIONS=%q\n' "$MYSQL_MAX_CONNECTIONS"
    printf 'BACKUP_RETENTION_DAYS=%q\n' "$backup_retention_days"
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
  verify_server_capacity_or_exit "create project" "$app_profile"

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
  echo "Daily automatic backup scheduled at 02:30."
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
        local saved_capacity_profile saved_capacity_ram saved_capacity_cpu
        saved_capacity_profile="$(read_project_meta_var "$dir" "SERVER_CAPACITY_PROFILE")"
        saved_capacity_ram="$(read_project_meta_var "$dir" "SERVER_RAM_MB")"
        saved_capacity_cpu="$(read_project_meta_var "$dir" "SERVER_CPU_CORES")"
        # shellcheck disable=SC1090
        # shellcheck disable=SC1091
        source "${dir}/.project-meta"
        echo "Project: ${project_name}"
        echo "Profile: ${APP_PROFILE:-$(detect_project_profile "$dir")}"
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
      local saved_capacity_profile saved_capacity_ram saved_capacity_cpu
      saved_capacity_profile="$(read_project_meta_var "$dir" "SERVER_CAPACITY_PROFILE")"
      saved_capacity_ram="$(read_project_meta_var "$dir" "SERVER_RAM_MB")"
      saved_capacity_cpu="$(read_project_meta_var "$dir" "SERVER_CPU_CORES")"
      # shellcheck disable=SC1090
      # shellcheck disable=SC1091
      source "${dir}/.project-meta"
      echo "Project: ${project_name}"
      echo "Profile: ${APP_PROFILE:-$(detect_project_profile "$dir")}"
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

  mkdir -p "$backup_dir"
  : > "$tmp_sql"

  if [ "$app_profile" = "node" ]; then
    echo "Skipping database export for node project."
  else
    echo "Exporting database..."
    if docker_container_exists "${DB_CONTAINER}"; then
      docker exec "${DB_CONTAINER}" sh -c \
        "exec mariadb-dump -u root -p'${DB_ROOT_PASSWORD}' '${DB_NAME}'" > "$tmp_sql"
    else
      echo "Warning: DB container does not exist (${DB_CONTAINER}). Backup without database."
    fi
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

  echo "Pruning backups older than ${backup_retention_days} day(s)..."
  prune_project_backups "$project_name" "$backup_retention_days"
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

manage_backup_settings() {
  local project_slug project_name app_dir current_days new_days

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

  echo ""
  echo "Backup settings for ${project_name}"
  echo "Current retention: keep backups for the last ${current_days} day(s)."
  prompt new_days "Days of backups to keep (e.g. 60): " "$current_days"

  if ! validate_backup_retention_days "$new_days"; then
    echo "Invalid retention. Use a whole number between 1 and 3650."
    exit 1
  fi

  set_project_meta_var "${app_dir}/.project-meta" "BACKUP_RETENTION_DAYS" "$new_days"

  echo ""
  echo "Backup retention updated."
  echo "Project: ${project_name}"
  echo "Keep backups for the last ${new_days} day(s)."
  echo "Old backups are pruned when the next backup runs."
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
  verify_server_capacity_or_exit "update project" "$app_profile"
  if [ "$app_profile" != "node" ]; then
    require_nonempty "DB_NAME" "${DB_NAME}"
    require_nonempty "DB_USER" "${DB_USER}"
    require_nonempty "DB_PASSWORD" "${DB_PASSWORD}"
    require_nonempty "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
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

banner
menu
