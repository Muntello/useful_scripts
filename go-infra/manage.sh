#!/bin/bash
set -Eeuo pipefail

# Go Infra Manager: manage Go app projects (users, systemd units, Nginx sites)
# Run as the admin user with sudo privileges.

########################################
# Settings (can be overridden by /etc/go-infra/go-infra.conf)
########################################

PROJECTS_DIR=/etc/go-infra/projects.d
APPS_ROOT=/srv/apps
LOG_ROOT=/var/log
NGINX_AVAIL=/etc/nginx/sites-available
NGINX_ENABLED=/etc/nginx/sites-enabled
TEMPLATES_DIR=/etc/go-infra/templates

# TLS / Let's Encrypt
CERTBOT_EMAIL=""
CERTBOT_STAGING="no"
ACME_WEBROOT="/var/www/acme"
TLS_PROFILE="intermediate"  # modern|intermediate
APP_LOG_MODE="journal"      # journal|file

########################################

log() { echo "[go-infra] $*"; }
warn() { echo "[go-infra][warn] $*" >&2; }
err() { echo "[go-infra][error] $*" >&2; }

need_sudo() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then return 0; fi
  if sudo -n true 2>/dev/null; then return 0; fi
  err "This script needs sudo. Run as admin user with sudo rights."; exit 1
}

load_config() {
  if [[ -f /etc/go-infra/go-infra.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/go-infra/go-infra.conf
  fi
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  list                          List projects
  render [NAME]                 Show desired state
  apply  [NAME]                 Apply config(s): users, systemd, nginx
  add-project --name N --domain D --port P [--user U] [--exec PATH] [--enable]
  remove-project --name N [--purge]
  pause-project --name N        Switch site to maintenance
  resume-project --name N       Restore normal site
  create-env --name N           Create/edit env file with secure perms
  add-user --name U [--home H]  Create a system user for project

Project config file format (\$PROJECTS_DIR/NAME.conf):
  NAME=myapp
  ENABLED=yes|no
  DOMAIN=site.example.com
  PORT=18080
  # USER=svc-myapp
  # EXEC=/srv/apps/myapp/current/myapp
EOF
}

is_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }

read_project_conf() {
  local path="$1"
  NAME=""; ENABLED=""; DOMAIN=""; PORT=""; USER=""; EXEC="";
  HEALTH_PATH=""; HEALTH_INTERVAL=""; HEALTH_TIMEOUT=""; HEALTH_RETRIES="";
  TLS_PROFILE="${TLS_PROFILE}"; APP_LOG_MODE="${APP_LOG_MODE}"
  # shellcheck disable=SC1090,SC1091
  source "$path"
  [[ -n "$NAME" ]] || { err "Missing NAME in $path"; return 1; }
  is_valid_name "$NAME" || { err "Invalid NAME '$NAME' in $path"; return 1; }
  [[ -n "${USER:-}" ]] || USER="svc-$NAME"
  [[ -n "${EXEC:-}" ]] || EXEC="$APPS_ROOT/$NAME/current/$NAME"
  [[ -n "${ENABLED:-}" ]] || ENABLED="no"
}

ensure_user() {
  local user="$1" home="$2"
  if id -u "$user" >/dev/null 2>&1; then return 0; fi
  sudo useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
}

ensure_dirs() {
  local user="$1" name="$2"
  sudo install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name"
  sudo install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name/current"
  sudo install -d -m 0750 -o "$user" -g "$user" "$APPS_ROOT/$name/releases"
  sudo install -d -m 0755 -o root  -g root  "$LOG_ROOT/$name"
  # maintenance root (static)
  sudo install -d -m 0755 -o root -g root "/var/www/maintenance/$name"
  if [[ -f "$TEMPLATES_DIR/maintenance.html" ]]; then
    sudo install -m 0644 "$TEMPLATES_DIR/maintenance.html" "/var/www/maintenance/$name/index.html"
  else
    echo "Maintenance" | sudo tee "/var/www/maintenance/$name/index.html" >/dev/null
  fi
}

write_systemd_unit() {
  local name="$1" user="$2" exec="$3" envfile="$PROJECTS_DIR/$name.env" logmode="$4"
  local unit_path="/etc/systemd/system/$name.service"
  sudo tee "$unit_path" >/dev/null <<UNIT
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

  if [[ "$logmode" == "file" ]]; then
    # systemd supports file/append outputs on modern versions
    sudo sed -i \
      -e "/^\[Service\]/a StandardOutput=append:\/${LOG_ROOT////\/}\/$name\/app.log" \
      -e "/^\[Service\]/a StandardError=append:\/${LOG_ROOT////\/}\/$name\/app.err.log" \
      "$unit_path"
  fi
}

write_nginx_site_normal() {
  local name="$1" domain="$2" port="$3"
  local site="$NGINX_AVAIL/$name.conf"
  sudo tee "$site" >/dev/null <<'NGINX'
NGINX
  sudo tee -a "$site" >/dev/null <<NGINX
# HTTP server (80): ACME + redirect to HTTPS
server {
  listen 80;
  server_name $domain;
  access_log $LOG_ROOT/$name/nginx.access.log;
  error_log  $LOG_ROOT/$name/nginx.error.log warn;

  location ^~ /.well-known/acme-challenge/ {
    root $ACME_WEBROOT;
    default_type text/plain;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

# HTTPS server (443)
server {
  listen 443 ssl http2;
  server_name $domain;

  ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
  # TLS profile configured later
  ssl_stapling on;
  ssl_stapling_verify on;
  resolver 1.1.1.1 8.8.8.8 valid=300s;
  ssl_trusted_certificate /etc/letsencrypt/live/$domain/chain.pem;
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

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

  # Inject TLS profile
  case "${TLS_PROFILE}" in
    modern)
      sudo sed -i \
        -e 's/^\s*# TLS profile configured later$/# TLS profile configured later/' \
        -e '/# TLS profile configured later/a \
  ssl_protocols TLSv1.3;\n  ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;\n  ssl_prefer_server_ciphers off;' "$site"
      ;;
    intermediate|*)
      sudo sed -i \
        -e 's/^\s*# TLS profile configured later$/# TLS profile configured later/' \
        -e '/# TLS profile configured later/a \
  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;\n  ssl_prefer_server_ciphers on;' "$site"
      ;;
  esac
}

write_nginx_site_maintenance() {
  local name="$1" domain="$2"
  local site="$NGINX_AVAIL/$name.maintenance.conf"
  sudo tee "$site" >/dev/null <<'NGINX'
NGINX
  sudo tee -a "$site" >/dev/null <<NGINX
# HTTP server (80): ACME + maintenance page
server {
  listen 80;
  server_name $domain;
  access_log $LOG_ROOT/$name/nginx.access.log;
  error_log  $LOG_ROOT/$name/nginx.error.log warn;

  location ^~ /.well-known/acme-challenge/ {
    root $ACME_WEBROOT;
    default_type text/plain;
  }

  root /var/www/maintenance/$name;
  location / { try_files /index.html =503; }
  error_page 503 /index.html;
}

# HTTPS server (443): maintenance page
server {
  listen 443 ssl http2;
  server_name $domain;

  ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
  # TLS profile configured later
  ssl_stapling on;
  ssl_stapling_verify on;
  resolver 1.1.1.1 8.8.8.8 valid=300s;
  ssl_trusted_certificate /etc/letsencrypt/live/$domain/chain.pem;
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

  access_log $LOG_ROOT/$name/nginx.access.log;
  error_log  $LOG_ROOT/$name/nginx.error.log warn;

  root /var/www/maintenance/$name;
  location / { try_files /index.html =503; }
  error_page 503 /index.html;
}
NGINX

  # Inject TLS profile
  case "${TLS_PROFILE}" in
    modern)
      sudo sed -i \
        -e 's/^\s*# TLS profile configured later$/# TLS profile configured later/' \
        -e '/# TLS profile configured later/a \
  ssl_protocols TLSv1.3;\n  ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;\n  ssl_prefer_server_ciphers off;' "$site"
      ;;
    intermediate|*)
      sudo sed -i \
        -e 's/^\s*# TLS profile configured later$/# TLS profile configured later/' \
        -e '/# TLS profile configured later/a \
  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;\n  ssl_prefer_server_ciphers on;' "$site"
      ;;
  esac
}

write_nginx_site_http_only() {
  # Temporary HTTP-only site to serve ACME challenge during first issuance
  local name="$1" domain="$2" mode="$3" # mode: normal|maintenance
  local site="$NGINX_AVAIL/$name.conf"
  sudo tee "$site" >/dev/null <<NGINX
server {
  listen 80;
  server_name $domain;
  access_log $LOG_ROOT/$name/nginx.access.log;
  error_log  $LOG_ROOT/$name/nginx.error.log warn;
  location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; default_type text/plain; }
NGINX
  if [[ "$mode" == "normal" ]]; then
    sudo tee -a "$site" >/dev/null <<'NGINX'
  location / { return 404; }
}
NGINX
  else
    sudo tee -a "$site" >/dev/null <<NGINX
  root /var/www/maintenance/$name;
  location / { try_files /index.html =503; }
  error_page 503 /index.html;
}
NGINX
  fi
}

enable_site()   { local name="$1"; sudo ln -sf "$NGINX_AVAIL/$name.conf" "$NGINX_ENABLED/$name.conf"; }
enable_maint()  { local name="$1"; sudo ln -sf "$NGINX_AVAIL/$name.maintenance.conf" "$NGINX_ENABLED/$name.conf"; }
disable_site()  { local name="$1"; sudo rm -f "$NGINX_ENABLED/$name.conf"; }

reload_nginx() { sudo nginx -t && sudo systemctl reload nginx; }

apply_project() {
  local conf="$1"; read_project_conf "$conf"
  [[ -n "${PORT:-}" ]] || { err "Project $NAME: PORT is required"; return 1; }
  need_sudo
  ensure_user "$USER" "$APPS_ROOT/$NAME"
  ensure_dirs "$USER" "$NAME"
  write_systemd_unit "$NAME" "$USER" "$EXEC" "$APP_LOG_MODE"
  # ACME webroot
  sudo install -d -m 0755 -o root -g root "$ACME_WEBROOT"

  # First write HTTP-only site for initial issuance
  local mode="normal"; [[ "$ENABLED" == "yes" ]] || mode="maintenance"
  if [[ -n "${DOMAIN:-}" ]]; then
    write_nginx_site_http_only "$NAME" "$DOMAIN" "$mode"
    enable_site "$NAME"
    reload_nginx
    if [[ -n "$CERTBOT_EMAIL" ]]; then
      local flags=("--non-interactive" "--agree-tos" "-m" "$CERTBOT_EMAIL")
      [[ "$CERTBOT_STAGING" == "yes" ]] && flags+=("--test-cert")
      log "Issuing/renewing certificate for $DOMAIN via webroot"
      sudo certbot certonly --webroot -w "$ACME_WEBROOT" -d "$DOMAIN" "${flags[@]}" --deploy-hook "nginx -t && systemctl reload nginx" || warn "Certbot failed for $DOMAIN"
    fi
    # Write final HTTPS-enabled sites
    write_nginx_site_normal "$NAME" "$DOMAIN" "$PORT"
    write_nginx_site_maintenance "$NAME" "$DOMAIN"
  else
    warn "DOMAIN not set for $NAME; configuring HTTP only without TLS"
    write_nginx_site_http_only "$NAME" "_" "$mode"
  fi
  sudo systemctl daemon-reload
  if [[ "$ENABLED" == "yes" ]]; then
    sudo systemctl enable --now "$NAME.service"
    enable_site "$NAME"
    write_logrotate "$NAME"
    if [[ -n "${HEALTH_PATH:-}" ]]; then
      local interval="${HEALTH_INTERVAL:-1min}" timeout="${HEALTH_TIMEOUT:-3}" retries="${HEALTH_RETRIES:-3}"
      write_health_probe "$NAME" "$PORT" "$HEALTH_PATH" "$interval" "$timeout" "$retries"
      sudo systemctl enable --now "$NAME-health.timer"
    fi
  else
    sudo systemctl disable --now "$NAME.service" || true
    enable_maint "$NAME"
  fi
}

render_project() {
  local conf="$1"; read_project_conf "$conf"
  cat <<OUT
- project: $NAME
  enabled: $ENABLED
  user: $USER
  domain: ${DOMAIN:-<none>}
  port: ${PORT:-<unset>}
  exec: $EXEC
  unit: /etc/systemd/system/$NAME.service
  site_normal: $NGINX_AVAIL/$NAME.conf
  site_maint:  $NGINX_AVAIL/$NAME.maintenance.conf
OUT
}

find_project_files() {
  local only="$1" dir="$PROJECTS_DIR"
  if [[ -n "$only" ]]; then echo "$dir/$only.conf"; return; fi
  ls "$dir"/*.conf 2>/dev/null || true
}

cmd_list() {
  for f in $(find_project_files ""); do
    [[ -f "$f" ]] || continue
    read_project_conf "$f" || continue
    echo "$NAME $ENABLED $DOMAIN:$PORT"
  done | sort
}

cmd_render() {
  local name="${1:-}"; local files=( $(find_project_files "$name") );
  [[ ${#files[@]} -gt 0 ]] || { err "No project configs"; exit 1; }
  for f in "${files[@]}"; do [[ -f "$f" ]] && render_project "$f"; done
}

cmd_apply() {
  local name="${1:-}"; local files=( $(find_project_files "$name") );
  [[ ${#files[@]} -gt 0 ]] || { err "No project configs"; exit 1; }
  for f in "${files[@]}"; do [[ -f "$f" ]] && apply_project "$f"; done
  reload_nginx
}

cmd_add_project() {
  local name="" domain="" port="" user="" exec="" enable="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --domain) domain="$2"; shift 2;;
      --port) port="$2"; shift 2;;
      --user) user="$2"; shift 2;;
      --exec) exec="$2"; shift 2;;
      --enable) enable="yes"; shift;;
      *) err "Unknown arg: $1"; exit 1;;
    esac
  done
  [[ -n "$name" && -n "$domain" && -n "$port" ]] || { err "--name, --domain, --port required"; exit 1; }
  is_valid_name "$name" || { err "Invalid project name"; exit 1; }
  local conf="$PROJECTS_DIR/$name.conf"
  [[ -f "$conf" ]] && { err "Config exists: $conf"; exit 1; }
  sudo tee "$conf" >/dev/null <<CONF
NAME=$name
ENABLED=$enable
DOMAIN=$domain
PORT=$port
${user:+USER=$user}
${exec:+EXEC=$exec}
# Optional health check
# HEALTH_PATH=/health
CONF
  sudo chown root:root "$conf"; sudo chmod 0644 "$conf"
  log "Project config created: $conf"
  cmd_apply "$name"
}

cmd_remove_project() {
  local name="" purge="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --purge) purge="yes"; shift;;
      *) err "Unknown arg: $1"; exit 1;;
    esac
  done
  [[ -n "$name" ]] || { err "--name required"; exit 1; }
  need_sudo
  sudo systemctl disable --now "$name.service" || true
  disable_site "$name"
  sudo rm -f "$NGINX_AVAIL/$name.conf" "$NGINX_AVAIL/$name.maintenance.conf"
  reload_nginx
  sudo rm -f "$PROJECTS_DIR/$name.conf" "$PROJECTS_DIR/$name.env" || true
  if [[ "$purge" == "yes" ]]; then
    # Danger: remove data and user
    sudo rm -rf "$APPS_ROOT/$name" "$LOG_ROOT/$name" "/var/www/maintenance/$name"
    if id -u "svc-$name" >/dev/null 2>&1; then sudo userdel -r "svc-$name" || true; fi
  fi
  log "Project $name removed${purge:+ (purged)}"
}

cmd_pause_project() {
  local name=""; while [[ $# -gt 0 ]]; do case "$1" in --name) name="$2"; shift 2;; *) err "Unknown arg: $1"; exit 1;; esac; done
  [[ -n "$name" ]] || { err "--name required"; exit 1; }
  need_sudo
  enable_maint "$name"; reload_nginx; log "Maintenance enabled for $name"
  # No change in certs needed; renewal handled by certbot timers
}

cmd_resume_project() {
  local name=""; while [[ $# -gt 0 ]]; do case "$1" in --name) name="$2"; shift 2;; *) err "Unknown arg: $1"; exit 1;; esac; done
  [[ -n "$name" ]] || { err "--name required"; exit 1; }
  need_sudo
  enable_site "$name"; reload_nginx; log "Maintenance disabled for $name"
  # No change in certs needed
}

write_logrotate() {
  local name="$1" path="/etc/logrotate.d/nginx-$1"
  sudo tee "$path" >/dev/null <<ROT
$LOG_ROOT/$name/nginx*.log {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  create 0640 root adm
  sharedscripts
  postrotate
    [ -x /usr/sbin/nginx ] && /usr/sbin/nginx -t && systemctl reload nginx > /dev/null 2>&1 || true
  endscript
}
ROT
  if [[ "${APP_LOG_MODE}" == "file" ]]; then
    sudo tee "/etc/logrotate.d/app-$1" >/dev/null <<ROT2
$LOG_ROOT/$1/app*.log {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  create 0640 $1 $1
}
ROT2
  fi
}

write_health_probe() {
  local name="$1" port="$2" path="${3:-/health}" interval="${4:-1min}" timeout="${5:-3}" retries="${6:-3}"
  local dir="/usr/local/lib/go-infra"; sudo install -d -m 0755 -o root -g root "$dir"
  sudo tee "$dir/healthcheck-$name.sh" >/dev/null <<'SH'
#!/bin/bash
set -Eeuo pipefail
NAME="$1"; PORT="$2"; PATH_="$3"; TIMEOUT="$4"; RETRIES="$5"
ok=0
for i in $(seq 1 "$RETRIES"); do
  if curl -fsS --max-time "$TIMEOUT" "http://127.0.0.1:${PORT}${PATH_}" >/dev/null; then ok=1; break; fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  logger -t go-infra "Healthcheck failed for $NAME; restarting service"
  systemctl restart "$NAME.service"
fi
SH
  sudo chmod 0755 "$dir/healthcheck-$name.sh"
  sudo tee "/etc/systemd/system/$name-health.service" >/dev/null <<UNIT
[Unit]
Description=$name HTTP health probe
After=network.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=$dir/healthcheck-$name.sh "$name" "$port" "$path" "$timeout" "$retries"
Nice=10
CPUQuota=5%%
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
UNIT
  sudo tee "/etc/systemd/system/$name-health.timer" >/dev/null <<TIMER
[Unit]
Description=Run $name health probe every $interval

[Timer]
OnBootSec=2m
OnUnitActiveSec=$interval
AccuracySec=30s

[Install]
WantedBy=timers.target
TIMER
}

cmd_create_env() {
  local name=""; while [[ $# -gt 0 ]]; do case "$1" in --name) name="$2"; shift 2;; *) err "Unknown arg: $1"; exit 1;; esac; done
  [[ -n "$name" ]] || { err "--name required"; exit 1; }
  need_sudo
  local env="$PROJECTS_DIR/$name.env"
  if [[ ! -f "$env" ]]; then
    echo "# Environment for $name" | sudo tee "$env" >/dev/null
  fi
  # Ensure only admin (owner) can modify; readable by root/systemd
  sudo chown "$SUDO_USER":root "$env" 2>/dev/null || sudo chown root:root "$env"
  sudo chmod 0640 "$env"
  echo "$env"
}

cmd_add_user() {
  local uname="" home=""; while [[ $# -gt 0 ]]; do case "$1" in --name) uname="$2"; shift 2;; --home) home="$2"; shift 2;; *) err "Unknown arg: $1"; exit 1;; esac; done
  [[ -n "$uname" ]] || { err "--name required"; exit 1; }
  need_sudo
  if id -u "$uname" >/dev/null 2>&1; then
    log "User $uname already exists"; return 0
  fi
  if [[ -n "$home" ]]; then
    sudo useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$uname"
  else
    sudo useradd --system --shell /usr/sbin/nologin "$uname"
  fi
}

main() {
  load_config
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list) cmd_list ;;
    render) cmd_render "${1:-}" ;;
    apply) cmd_apply "${1:-}" ;;
    add-project) cmd_add_project "$@" ;;
    remove-project) cmd_remove_project "$@" ;;
    pause-project) cmd_pause_project "$@" ;;
    resume-project) cmd_resume_project "$@" ;;
    create-env) cmd_create_env "$@" ;;
    add-user) cmd_add_user "$@" ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
