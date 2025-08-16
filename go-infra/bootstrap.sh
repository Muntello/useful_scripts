#!/bin/bash
set -Eeuo pipefail

# Go Infra Bootstrap: base server setup on Ubuntu and admin user creation.
# Run as root on a fresh Ubuntu server.

########################################
# Config (edit before running)
########################################

ADMIN_USER="goadmin"
ADMIN_SSH_KEY=""   # REQUIRED: paste the admin's SSH public key
SSH_PORT=22         # change if you use a non-standard port
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
ENABLE_UFW="yes"
ENABLE_FAIL2BAN="yes"
ENABLE_UNATTENDED_UPGRADES="yes"
ADMIN_NOPASSWD_SUDO="yes"  # yes => NOPASSWD:ALL, no => need password

# TLS / Let's Encrypt
CERTBOT_EMAIL=""            # REQUIRED for HTTPS issuance (e.g., admin@example.com)
CERTBOT_STAGING="no"        # yes to use Let's Encrypt staging during tests

# Grafana Cloud Loki (Alloy) — set to auto-configure log shipping
LOKI_ENDPOINT=""            # e.g., https://logs-prod-036.grafana.net/loki/api/v1/push
LOKI_USER=""                # e.g., your Stack ID (digits)
LOKI_TOKEN=""               # Access Policy token with logs:write

# Infra directories (owned by ADMIN_USER)
ETC_DIR="/etc/go-infra"
PROJECTS_DIR="$ETC_DIR/projects.d"
TEMPLATES_DIR="$ETC_DIR/templates"
APPS_ROOT="/srv/apps"
LOG_ROOT="/var/log"

########################################

log()   { echo "[bootstrap] $*"; }
warn()  { echo "[bootstrap][warn] $*"; }
err()   { echo "[bootstrap][error] $*" >&2; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root"; exit 1; fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

write_file() { # write_file <path> <mode> <owner> <group>
  local path="$1" mode="$2" owner="$3" group="$4"
  install -m "$mode" -o "$owner" -g "$group" /dev/stdin "$path"
}

create_admin_user() {
  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    log "Admin user $ADMIN_USER already exists"
  else
    log "Creating admin user $ADMIN_USER"
    adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi

  usermod -aG sudo "$ADMIN_USER"
  if [[ "$ADMIN_NOPASSWD_SUDO" == "yes" ]]; then
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-$ADMIN_USER
    chmod 440 /etc/sudoers.d/90-$ADMIN_USER
  fi

  local ssh_dir="/home/$ADMIN_USER/.ssh"
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ssh_dir"
  if [[ -n "$ADMIN_SSH_KEY" ]]; then
    log "Installing admin authorized_key"
    echo "$ADMIN_SSH_KEY" | write_file "$ssh_dir/authorized_keys" 0600 "$ADMIN_USER" "$ADMIN_USER"
  else
    warn "ADMIN_SSH_KEY is empty. SSH key not installed."
  fi
}

hardening_ssh() {
  log "Hardening SSH daemon"
  sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
  sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  if systemctl restart ssh 2>/dev/null; then
    :
  elif systemctl restart sshd 2>/dev/null; then
    :
  else
    warn "SSH service not found (ssh/sshd)."
  fi
}

setup_packages() {
  log "Updating apt cache and upgrading"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

  log "Installing core packages"
  apt_install ca-certificates curl git unzip software-properties-common gnupg
  apt_install openssh-server
  apt_install nginx ufw
  # TLS issuance
  apt_install certbot python3-certbot-nginx
  if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then apt_install fail2ban; fi
  if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then apt_install unattended-upgrades; fi

  timedatectl set-timezone "$TIMEZONE" || true
  update-locale LANG="$LOCALE" || true
}

configure_nginx() {
  log "Configuring Nginx"
  # Turn off default site if present
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl enable --now nginx
}

install_alloy() {
  log "Installing Grafana Alloy"
  # Repo setup per Grafana docs (Ubuntu 24.04+ convention)
  install -d -m 0755 -o root -g root /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor >/etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" >/etc/apt/sources.list.d/grafana.list
  apt-get update -y
  # Install Alloy (preferred package name); fallback to grafana-alloy if needed
  if ! apt_install alloy; then
    warn "Package 'alloy' not found, trying 'grafana-alloy'"
    apt_install grafana-alloy || warn "Failed to install Grafana Alloy package."
  fi

  # Place a skeleton config (disabled by default until edited)
  install -d -m 0755 -o root -g root /etc/alloy || true
  if [[ -n "$LOKI_ENDPOINT" && -n "$LOKI_USER" && -n "$LOKI_TOKEN" ]]; then
    log "Writing Alloy config for Grafana Cloud Loki"
    cat >/etc/alloy/config.alloy <<ALLOY
loki.write "grafanacloud" {
  endpoint {
    url = "$LOKI_ENDPOINT"
    basic_auth {
      username = "$LOKI_USER"
      password = "$LOKI_TOKEN"
    }
  }
}

# Basic system logs; extend as needed
loki.source.file "system_logs" {
  targets = [
    { __path__ = "/var/log/syslog",   job = "syslog" },
    { __path__ = "/var/log/auth.log", job = "auth" },
    { __path__ = "/var/log/kern.log", job = "kernel" },
  ]
  forward_to = [loki.write.grafanacloud.receiver]
}
ALLOY
    # Ensure Alloy can read config
    chgrp alloy /etc/alloy/config.alloy 2>/dev/null || true
    chmod 0640 /etc/alloy/config.alloy
  else
    if [[ ! -f /etc/alloy/config.alloy ]]; then
      cat >/etc/alloy/config.alloy <<'ALLOY'
// Example Alloy config for Grafana Cloud Loki
// Fill LOKI_ENDPOINT/LOKI_USER/LOKI_TOKEN in bootstrap config and rerun, or edit below.
loki.write "grafanacloud" {
  endpoint {
    url = "https://logs-prod-xxx.grafana.net/loki/api/v1/push"
    basic_auth { username = "<stack_id>" password = "<token>" }
  }
}
// loki.source.file "system_logs" {
//   targets = [ { __path__ = "/var/log/syslog", job = "syslog" } ]
//   forward_to = [loki.write.grafanacloud.receiver]
// }
ALLOY
      chgrp alloy /etc/alloy/config.alloy 2>/dev/null || true
      chmod 0640 /etc/alloy/config.alloy
    fi
  fi
  # Ensure service environment points to the config path expected by the unit
  if [[ ! -f /etc/default/alloy ]]; then
    cat >/etc/default/alloy <<ENV
# Environment for Grafana Alloy service
# Path to River config file
CONFIG_FILE=/etc/alloy/config.alloy
# Extra CLI args (optional)
CUSTOM_ARGS=
ENV
  fi
  # Ensure storage path exists with appropriate ownership
  install -d -m 0755 -o root -g root /var/lib/alloy/data
  if id -u alloy >/dev/null 2>&1; then
    chown -R alloy:alloy /var/lib/alloy
    # Allow reading system log files (Ubuntu: group 'adm' reads /var/log)
    usermod -a -G adm alloy || true
    # Optionally read journald (uncomment journal source in config if needed)
    usermod -a -G systemd-journal alloy || true
  fi
  # Try to disable service until configured; service name may vary
  systemctl disable alloy || true
  systemctl disable grafana-alloy || true

  # Auto-enable if credentials provided
  if [[ -n "$LOKI_ENDPOINT" && -n "$LOKI_USER" && -n "$LOKI_TOKEN" ]]; then
    systemctl daemon-reload
    if systemctl enable --now alloy 2>/dev/null; then
      log "Alloy service enabled and started"
    elif systemctl enable --now grafana-alloy 2>/dev/null; then
      log "Grafana-Alloy service enabled and started"
    else
      warn "Failed to start Alloy service; check unit name and config"
    fi
  else
    warn "Alloy left disabled (LOKI_* variables not set)."
  fi
}

configure_firewall() {
  [[ "$ENABLE_UFW" == "yes" ]] || { warn "UFW disabled by config"; return; }
  log "Configuring UFW"
  ufw allow "$SSH_PORT/tcp"
  ufw allow "Nginx Full"
  ufw --force enable
}

configure_fail2ban() {
  [[ "$ENABLE_FAIL2BAN" == "yes" ]] || return
  log "Configuring fail2ban"
  local jail=/etc/fail2ban/jail.d/99-go-infra.local
  cat >"$jail" <<'JAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
JAIL
  systemctl enable --now fail2ban || true
}

configure_unattended() {
  [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]] || return
  log "Enabling unattended upgrades"
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  systemctl enable --now unattended-upgrades || true
}

setup_infra_dirs() {
  log "Preparing infra directories"
  install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ETC_DIR" "$PROJECTS_DIR" "$TEMPLATES_DIR"
  install -d -m 0755 -o root -g root "$APPS_ROOT"

  # Config skeleton
  if [[ ! -f "$ETC_DIR/go-infra.conf" ]]; then
    cat >"$ETC_DIR/go-infra.conf" <<CONF
# Go Infra main config
PROJECTS_DIR="$PROJECTS_DIR"
APPS_ROOT="$APPS_ROOT"
LOG_ROOT="$LOG_ROOT"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
# TLS / Let's Encrypt
CERTBOT_EMAIL=""        # set to enable automatic issuance
CERTBOT_STAGING="no"    # yes for dry-run certificates
# TLS security profile for Nginx: modern|intermediate
TLS_PROFILE="intermediate"
# App log mode: journal|file (file => /var/log/<name>/app*.log + logrotate)
APP_LOG_MODE="journal"
CONF
    chown "$ADMIN_USER":"$ADMIN_USER" "$ETC_DIR/go-infra.conf"
  fi

  # Example project config
  if [[ ! -f "$PROJECTS_DIR/example.conf" ]]; then
    cat >"$PROJECTS_DIR/example.conf" <<'EXAMPLE'
NAME=myapp
ENABLED=yes
DOMAIN=myapp.example.com
PORT=18080
# Optional overrides
# USER=svc-myapp
# EXEC=/srv/apps/myapp/current/myapp
EXAMPLE
    chown "$ADMIN_USER":"$ADMIN_USER" "$PROJECTS_DIR/example.conf"
  fi

  # Maintenance HTML template
  cat >"$TEMPLATES_DIR/maintenance.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Maintenance</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;display:flex;align-items:center;justify-content:center;height:100vh;background:#0b132b;color:#e0e1dd} .card{background:#1c2541;padding:2rem 2.5rem;border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.25)} h1{margin:0 0 .5rem;font-size:1.6rem} p{margin:0;opacity:.9}</style>
</head><body><div class="card"><h1>Maintenance</h1><p>We’ll be back shortly.</p></div></body></html>
HTML
  chown "$ADMIN_USER":"$ADMIN_USER" "$TEMPLATES_DIR/maintenance.html"
}

preflight_checks() {
  log "Running preflight checks"
  nginx -t
  systemctl is-active --quiet nginx && log "Nginx active"
  if [[ "$ENABLE_UFW" == "yes" ]]; then ufw status verbose || true; fi
  if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then systemctl status --no-pager fail2ban || true; fi
}

prompt_reboot() {
  log "Bootstrap complete. It's recommended to reboot now."
  read -r -p "Reboot now? [y/N] " ans || true
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl reboot
  else
    log "Skipping reboot. Reboot manually later."
  fi
}

main() {
  need_root
  setup_packages
  create_admin_user
  hardening_ssh
  configure_nginx
  install_alloy
  configure_firewall
  configure_fail2ban
  configure_unattended
  setup_infra_dirs
  # ACME webroot for HTTP-01 challenges
  install -d -m 0755 -o root -g root /var/www/acme
  preflight_checks
  # Verify admin can sudo without password
  if [[ -n "$ADMIN_SSH_KEY" ]]; then
    if su - "$ADMIN_USER" -c 'sudo -n true' 2>/dev/null; then
      log "Admin sudo NOPASSWD verified via su test"
    else
      warn "Admin sudo NOPASSWD not verified; check /etc/sudoers.d/90-$ADMIN_USER"
    fi
  fi
  echo
  echo "Before reboot: open a NEW terminal and confirm you can SSH as $ADMIN_USER on port $SSH_PORT using the provided key."
  echo "Also run: sudo -n true (should succeed without password)."
  read -r -p "Have you verified login and sudo for $ADMIN_USER? [y/N] " ok || true
  if [[ "$ok" =~ ^[Yy]$ ]]; then
    prompt_reboot
  else
    warn "Skipping reboot confirmation; you can reboot manually later."
  fi
}

main "$@"
