#!/bin/bash
set -Eeuo pipefail

# go-host: manage per-project users, systemd units, and Nginx sites

# Defaults (can be overridden by /etc/go-host/go-host.conf)
readonly DEFAULT_ETC_DIR=/etc/go-host
readonly DEFAULT_PROJECTS_DIR=/etc/go-host/projects.d
readonly DEFAULT_APPS_ROOT=/srv/apps
readonly DEFAULT_LOG_ROOT=/var/log
readonly DEFAULT_NGINX_AVAIL=/etc/nginx/sites-available
readonly DEFAULT_NGINX_ENABLED=/etc/nginx/sites-enabled

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_CFG_DIR="$REPO_DIR/config"

ETC_DIR="$DEFAULT_ETC_DIR"
PROJECTS_DIR="$DEFAULT_PROJECTS_DIR"
APPS_ROOT="$DEFAULT_APPS_ROOT"
LOG_ROOT="$DEFAULT_LOG_ROOT"
NGINX_AVAIL="$DEFAULT_NGINX_AVAIL"
NGINX_ENABLED="$DEFAULT_NGINX_ENABLED"

log() { echo "[go-host] $*"; }
err() { echo "[go-host][error] $*" >&2; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "This action requires root. Use sudo."; exit 1
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 render [project]   # show planned state from configs
  $0 apply  [project]   # apply configs: users, systemd, nginx

Configs:
  Main:     /etc/go-host/go-host.conf (defaults fall back to ./config/go-host.conf)
  Projects: /etc/go-host/projects.d/*.conf (fallback to ./config/projects.d/*.conf)

Project config (example):
  NAME=myapp
  ENABLED=yes
  DOMAIN=myapp.example.com
  PORT=18080
  # optional overrides
  # USER=svc-myapp
  # EXEC=/srv/apps/myapp/current/myapp
EOF
}

load_defaults() {
  # Load main config (if present)
  if [[ -f "$ETC_DIR/go-host.conf" ]]; then
    # shellcheck source=/dev/null
    source "$ETC_DIR/go-host.conf"
  elif [[ -f "$REPO_CFG_DIR/go-host.conf" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_CFG_DIR/go-host.conf"
  fi
  # Allow overrides from main config
  : "${PROJECTS_DIR:=$DEFAULT_PROJECTS_DIR}"
  : "${APPS_ROOT:=$DEFAULT_APPS_ROOT}"
  : "${LOG_ROOT:=$DEFAULT_LOG_ROOT}"
  : "${NGINX_AVAIL:=$DEFAULT_NGINX_AVAIL}"
  : "${NGINX_ENABLED:=$DEFAULT_NGINX_ENABLED}"
}

is_valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

read_project_conf() {
  local path="$1"
  # Reset vars before sourcing
  NAME=""; ENABLED=""; DOMAIN=""; PORT=""; USER=""; EXEC="";
  # shellcheck disable=SC1090,SC1091
  source "$path"
  [[ -n "$NAME" ]] || { err "Missing NAME in $path"; return 1; }
  is_valid_name "$NAME" || { err "Invalid NAME '$NAME' in $path"; return 1; }
  [[ -n "${USER:-}" ]] || USER="svc-$NAME"
  [[ -n "${EXEC:-}" ]] || EXEC="$APPS_ROOT/$NAME/current/$NAME"
  [[ -n "${ENABLED:-}" ]] || ENABLED="no"
  [[ -n "${PORT:-}" ]] || PORT=""
}

ensure_user() {
  local user="$1" home="$2"
  if id -u "$user" >/dev/null 2>&1; then
    return 0
  fi
  log "Creating system user $user"
  useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
}

ensure_dirs() {
  local user="$1" name="$2"
  install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name"
  install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name/current"
  install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name/releases"
  install -d -m 0755 -o root  -g root  "$LOG_ROOT/$name"
}

write_systemd_unit() {
  local name="$1" user="$2" exec="$3" envfile="$PROJECTS_DIR/$name.env"
  local unit_path="/etc/systemd/system/$name.service"
  log "Writing systemd unit $unit_path"
  cat >"$unit_path" <<UNIT
[Unit]
Description=$name Go service
After=network.target

[Service]
Type=simple
User=$user
Group=$user
WorkingDirectory=$APPS_ROOT/$name/current
EnvironmentFile=-$envfile
ExecStart=$exec
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APPS_ROOT/$name $LOG_ROOT/$name
AmbientCapabilities=
CapabilityBoundingSet=
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
UNIT
}

write_nginx_site() {
  local name="$1" domain="$2" port="$3"
  local site_path="$NGINX_AVAIL/$name.conf"
  log "Writing Nginx site $site_path"
  cat >"$site_path" <<NGINX
server {
  listen 80;
  server_name $domain;

  access_log $LOG_ROOT/$name/nginx.access.log;
  error_log  $LOG_ROOT/$name/nginx.error.log warn;

  location / {
    proxy_pass http://127.0.0.1:$port;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
  }
}
NGINX
}

enable_nginx_site() {
  local name="$1"
  ln -sf "$NGINX_AVAIL/$name.conf" "$NGINX_ENABLED/$name.conf"
}

disable_nginx_site() {
  local name="$1"
  rm -f "$NGINX_ENABLED/$name.conf"
}

apply_project() {
  local project_conf="$1"; read_project_conf "$project_conf"

  if [[ -z "$PORT" ]]; then
    err "Project $NAME: PORT is required"; return 1
  fi
  need_root
  ensure_user "$USER" "$APPS_ROOT/$NAME"
  ensure_dirs "$USER" "$NAME"
  write_systemd_unit "$NAME" "$USER" "$EXEC"
  write_nginx_site "$NAME" "$DOMAIN" "$PORT"

  systemctl daemon-reload
  if [[ "$ENABLED" == "yes" ]]; then
    log "Enabling and starting $NAME"
    systemctl enable --now "$NAME.service"
    enable_nginx_site "$NAME"
  else
    log "Disabling and stopping $NAME"
    systemctl disable --now "$NAME.service" || true
    disable_nginx_site "$NAME"
  fi
}

render_project() {
  local project_conf="$1"; read_project_conf "$project_conf"
  cat <<OUT
- project: $NAME
  enabled: $ENABLED
  user: $USER
  domain: ${DOMAIN:-<none>}
  port: ${PORT:-<unset>}
  exec: $EXEC
  app_dir: $APPS_ROOT/$NAME
  unit: /etc/systemd/system/$NAME.service
  nginx_site: $NGINX_AVAIL/$NAME.conf
OUT
}

find_project_files() {
  local only="$1"
  local dir=""
  if [[ -d "$PROJECTS_DIR" ]]; then
    dir="$PROJECTS_DIR"
  elif [[ -d "$REPO_CFG_DIR/projects.d" ]]; then
    dir="$REPO_CFG_DIR/projects.d"
  else
    err "No projects directory found: $PROJECTS_DIR or $REPO_CFG_DIR/projects.d"; exit 1
  fi
  if [[ -n "$only" ]]; then
    echo "$dir/$only.conf"
    return
  fi
  ls "$dir"/*.conf 2>/dev/null || true
}

main() {
  local cmd="${1:-}" arg="${2:-}"; shift || true
  case "$cmd" in
    render|apply) ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac

  load_defaults
  local files; IFS=$'\n' read -r -d '' -a files < <(find_project_files "$arg" && printf '\0') || true
  if [[ ${#files[@]} -eq 0 ]]; then
    err "No project configs found"; exit 1
  fi

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { err "Missing project config: $f"; exit 1; }
    if [[ "$cmd" == "render" ]]; then
      render_project "$f"
    else
      apply_project "$f"
    fi
  done

  if [[ "$cmd" == "apply" ]]; then
    log "Validating Nginx config"
    nginx -t && systemctl reload nginx
  fi
}

main "$@"

