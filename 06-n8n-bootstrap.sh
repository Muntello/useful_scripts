#!/bin/bash
#=====================================================================================
# n8n SECURE BOOTSTRAP (Ubuntu 22.04/24.04) — one‑shot, idempotent installer
#-------------------------------------------------------------------------------------
# This script prepares a production‑grade n8n server on a clean Ubuntu VM with:
#   • Hardened SSH (no root login, keys only, optional custom port)
#   • System updates + unattended‑upgrades
#   • UFW firewall (only SSH + 80/443)
#   • Fail2ban for SSH bruteforce protection
#   • Docker Engine + Compose plugin
#   • n8n + PostgreSQL behind Caddy (auto‑HTTPS via Let’s Encrypt)
#   • Optional CrowdSec IPS bouncer (host‑level web/ssh protection)
#   • AppArmor ensured active (Docker uses docker-default profile)
#
# Design goals
#   • Single file, re‑runnable (idempotent). Each step is checkpointed.
#   • Safe order of operations (don’t lock you out when changing SSH).
#   • Minimal dependencies, clear progress output.
#
# Quick start
#   1) Put this file on a fresh Ubuntu 22.04/24.04 VM.
#   2) Edit the CONFIG section below (DOMAIN, EMAIL, optional NEW_USER & SSH key).
#   3) Run as root:  bash ./n8n-bootstrap.sh
#   4) If the script schedules a reboot, re-run the same command after the VM is back.
#
# Notes
#   • DNS: create an A/AAAA record so DOMAIN resolves to this server’s public IP.
#   • Certificates: Caddy will fetch Let’s Encrypt certs automatically on first start.
#   • WAF: By default you get UFW + Fail2ban. Optionally enable CrowdSec for
#          additional, reputation-based blocking across SSH/HTTP.
#   • AppArmor: This script ensures AppArmor is enabled (usually on Ubuntu by default).
#   • Security defaults: n8n telemetry is disabled, secure cookies enabled, strong
#     secrets generated if not provided.
#
#=====================================================================================
set -Eeuo pipefail
IFS=$'\n\t'

#------------------------------------
# CONFIG — EDIT ME
#------------------------------------
DOMAIN="example.com"              # REQUIRED: your n8n public domain (e.g. automations.example.com)
EMAIL="admin@example.com"         # REQUIRED: email for Let’s Encrypt & security notices

# Optional: create a non-root sudo user and provision their SSH key
CREATE_NEW_USER=true               # true|false — recommended on fresh VMs
NEW_USER="deploy"
NEW_USER_SSH_PUBLIC_KEY=""        # paste your SSH pubkey here (ssh-ed25519 ... or ssh-rsa ...)

# SSH hardening
SSH_PORT=22                        # change to e.g. 2222 if you like; script will migrate safely
DISABLE_PASSWORD_AUTH=true         # enforce key-only auth
DISABLE_ROOT_SSH=true              # disable interactive root login

# n8n settings
N8N_VERSION="latest"              # or a pinned version like "1.64.0"
TZ="Etc/UTC"                      # your timezone, e.g. "Asia/Yerevan"
N8N_DATA_DIR="/opt/n8n"          # data lives here (compose, volumes)

# n8n security / auth
BASIC_AUTH_ENABLE=true             # HTTP Basic Auth in front of n8n (recommended)
BASIC_AUTH_USER="admin"
BASIC_AUTH_PASSWORD="changeMe"    # will be bcrypt-hashed; override or leave and we’ll randomize

# Database (PostgreSQL in Docker)
DB_NAME="n8n"
DB_USER="n8n"
DB_PASSWORD=""                    # leave empty to auto-generate a strong password

# Optional protection layer (CrowdSec IPS)
CROWDSEC_ENABLE=false              # true|false — blocks known bad IPs across services

#------------------------------------
# END CONFIG
#------------------------------------

VERSION_TAG="1.0.0"
STATE_DIR="/var/lib/n8n-bootstrap"
STEP_DIR="$STATE_DIR/steps"
LOG_FILE="$STATE_DIR/install.log"
mkdir -p "$STEP_DIR"

log()   { printf "[n8n-bootstrap] %s\n" "$*" | tee -a "$LOG_FILE"; }
info()  { log "➡  $*"; }
success(){ log "✔  $*"; }
warn()  { log "!  $*"; }
fail()  { log "✖  $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Please run as root (use sudo)."; exit 1
  fi
}

step_done() { [[ -f "$STEP_DIR/$1.done" ]]; }
mark_done() { touch "$STEP_DIR/$1.done"; success "$2"; }

abort_if_placeholder_domain() {
  if [[ "$DOMAIN" == "example.com" || -z "$DOMAIN" ]]; then
    fail "DOMAIN is not set. Edit this script’s CONFIG section first."; exit 1
  fi
  if [[ "$EMAIL" == "admin@example.com" || -z "$EMAIL" ]]; then
    fail "EMAIL is not set. Edit this script’s CONFIG section first."; exit 1
  fi
}

random_base64() { openssl rand -base64 "$1" | tr -d '\n' | tr -d '=' | tr '+/' '-_'; }
random_hex()    { openssl rand -hex "$1"; }

# Ensure we have common tools early
bootstrap_packages() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release jq \
    software-properties-common ufw fail2ban unzip dnsutils \
    apparmor apparmor-utils needrestart
}

# Verify DNS points to this server (warn only)
check_dns() {
  local pub_ip; pub_ip=$(curl -s https://api.ipify.org || true)
  if [[ -z "$pub_ip" ]]; then warn "Could not detect public IP; skipping DNS check"; return; fi
  local a_ip; a_ip=$(dig +short A "$DOMAIN" | tail -n1 || true)
  if [[ "$a_ip" != "$pub_ip" ]]; then
    warn "DNS for $DOMAIN does not seem to point to this server ($a_ip != $pub_ip). SSL issuance may fail until DNS propagates."
  else
    success "DNS A record for $DOMAIN appears correct ($a_ip)."
  fi
}

#-------------------------------------------------------------------------------------
# STEP 00: Preflight
#-------------------------------------------------------------------------------------
step_00_preflight() {
  local step="00_preflight"
  step_done "$step" && return
  require_root
  abort_if_placeholder_domain
  info "Starting n8n secure bootstrap v$VERSION_TAG"
  info "Logging to $LOG_FILE"
  bootstrap_packages
  mark_done "$step" "Preflight checks & base tools installed"
}

#-------------------------------------------------------------------------------------
# STEP 10: Create non-root sudo user with SSH key (optional)
#-------------------------------------------------------------------------------------
step_10_user() {
  local step="10_user"
  step_done "$step" && return
  if [[ "$CREATE_NEW_USER" == "true" ]]; then
    if id -u "$NEW_USER" >/dev/null 2>&1; then
      success "User $NEW_USER already exists"
    else
      info "Creating user $NEW_USER and adding to sudo"
      adduser --disabled-password --gecos "" "$NEW_USER"
      usermod -aG sudo "$NEW_USER"
    fi
    if [[ -n "$NEW_USER_SSH_PUBLIC_KEY" ]]; then
      info "Provisioning SSH key for $NEW_USER"
      local ssh_dir="/home/$NEW_USER/.ssh"
      mkdir -p "$ssh_dir"; chmod 700 "$ssh_dir"; chown "$NEW_USER:$NEW_USER" "$ssh_dir"
      echo "$NEW_USER_SSH_PUBLIC_KEY" > "$ssh_dir/authorized_keys"
      chmod 600 "$ssh_dir/authorized_keys"; chown "$NEW_USER:$NEW_USER" "$ssh_dir/authorized_keys"
    else
      warn "NEW_USER_SSH_PUBLIC_KEY is empty — add your key ASAP to avoid lockout when password auth is disabled."
    fi
    # Allow new user to use docker without sudo (optional quality of life)
    if getent group docker >/dev/null 2>&1; then usermod -aG docker "$NEW_USER" || true; fi
  else
    info "CREATE_NEW_USER=false — skipping user creation"
  fi
  mark_done "$step" "User setup completed"
}

#-------------------------------------------------------------------------------------
# STEP 20: System updates + unattended-upgrades
#-------------------------------------------------------------------------------------
step_20_updates() {
  local step="20_updates"
  step_done "$step" && return
  info "Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
  # Enable unattended security upgrades explicitly (noninteractive)
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  apt-get install -y unattended-upgrades
  # If a reboot is required (kernel, libc, etc.), note it
  if [ -f /var/run/reboot-required ]; then
    warn "Reboot required after upgrades"
    touch "$STATE_DIR/reboot_required"
  fi
  apt-get autoremove -y
  mark_done "$step" "System updated & unattended-upgrades enabled"
}

#-------------------------------------------------------------------------------------
# STEP 30: UFW firewall (open only SSH + 80/443)
#-------------------------------------------------------------------------------------
step_30_ufw() {
  local step="30_ufw"
  step_done "$step" && return
  info "Configuring UFW"
  ufw --force reset || true
  ufw default deny incoming
  ufw default allow outgoing
  # Allow SSH (current and new port if different to avoid lockout during migration)
  ufw allow "$SSH_PORT"/tcp
  if [[ "$SSH_PORT" -ne 22 ]]; then ufw allow 22/tcp; fi
  # Web ports
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  mark_done "$step" "UFW active (SSH:$SSH_PORT, 80, 443)"
}

#-------------------------------------------------------------------------------------
# STEP 40: SSH hardening
#-------------------------------------------------------------------------------------
step_40_ssh() {
  local step="40_ssh"
  step_done "$step" && return
  info "Hardening SSH configuration"
  local cfg="/etc/ssh/sshd_config"
  local bak="/etc/ssh/sshd_config.pre-n8n-bootstrap"
  [[ -f "$bak" ]] || cp "$cfg" "$bak"

  # Set or replace options
  declare -A opts=(
    ["Port"]="$SSH_PORT"
    ["PasswordAuthentication"]=$([[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && echo "no" || echo "yes")
    ["PermitRootLogin"]=$([[ "$DISABLE_ROOT_SSH" == "true" ]] && echo "no" || echo "prohibit-password")
    ["PubkeyAuthentication"]="yes"
    ["ChallengeResponseAuthentication"]="no"
    ["UsePAM"]="yes"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["X11Forwarding"]="no"
    ["PermitEmptyPasswords"]="no"
    ["LoginGraceTime"]="30"
    ["MaxAuthTries"]="3"
  )

  for k in "${!opts[@]}"; do
    if grep -qE "^\s*${k}\b" "$cfg"; then
      sed -i "s/^\s*${k}.*/${k} ${opts[$k]}/" "$cfg"
    else
      echo "${k} ${opts[$k]}" >> "$cfg"
    fi
  done

  sshd -t
  systemctl reload sshd
  success "sshd reloaded on port $SSH_PORT"

  # If we migrated away from 22, drop it from UFW now
  if ufw status | grep -q "22/tcp" && [[ "$SSH_PORT" -ne 22 ]]; then
    ufw delete allow 22/tcp || true
    success "Closed port 22 in UFW after successful SSH migration"
  fi

  mark_done "$step" "SSH hardened"
}

#-------------------------------------------------------------------------------------
# STEP 50: Fail2ban (sshd jail)
#-------------------------------------------------------------------------------------
step_50_fail2ban() {
  local step="50_fail2ban"
  step_done "$step" && return
  info "Configuring Fail2ban for sshd"
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
mode    = aggressive
port    = $SSH_PORT
maxretry = 4
findtime = 15m
bantime  = 24h
EOF
  systemctl enable --now fail2ban
  mark_done "$step" "Fail2ban enabled"
}

#-------------------------------------------------------------------------------------
# STEP 60: Ensure AppArmor active
#-------------------------------------------------------------------------------------
step_60_apparmor() {
  local step="60_apparmor"
  step_done "$step" && return
  if command -v aa-status >/dev/null 2>&1; then
    if aa-status | grep -q "profiles are in enforce mode"; then
      success "AppArmor is active"
    else
      warn "AppArmor seems inactive — enabling at boot"
      sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 apparmor=1 security=apparmor"/' /etc/default/grub || true
      update-grub || true
      warn "A reboot is required to fully enable AppArmor. Reboot will be scheduled at the end, then re-run this script."
      touch "$STATE_DIR/reboot_required"
    fi
  else
    warn "aa-status not found; AppArmor packages should have been installed."
  fi
  mark_done "$step" "AppArmor checked"
}

#-------------------------------------------------------------------------------------
# STEP 70: Install Docker Engine + Compose
#-------------------------------------------------------------------------------------
step_70_docker() {
  local step="70_docker"
  step_done "$step" && return
  info "Installing Docker Engine"
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    success "Docker already installed"
  fi
  # Add primary user to docker group for convenience if exists
  if [[ "$CREATE_NEW_USER" == "true" ]] && id -u "$NEW_USER" >/dev/null 2>&1; then
    usermod -aG docker "$NEW_USER" || true
  fi
  mark_done "$step" "Docker Engine ready"
}

#-------------------------------------------------------------------------------------
# STEP 80: Optional CrowdSec IPS (host-level protection)
#-------------------------------------------------------------------------------------
step_80_crowdsec() {
  local step="80_crowdsec"
  step_done "$step" && return
  if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
    info "Installing CrowdSec + firewall bouncer"
    if ! command -v crowdsec >/dev/null 2>&1; then
      # Official repository via packagecloud
      curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
      DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables
      systemctl enable --now crowdsec
      systemctl enable --now crowdsec-firewall-bouncer
    else
      success "CrowdSec already installed"
    fi
  else
    info "CROWDSEC_ENABLE=false — skipping CrowdSec"
  fi
  mark_done "$step" "CrowdSec step completed"
}

#-------------------------------------------------------------------------------------
# STEP 90: Prepare secrets, directories, compose stack (n8n + Postgres + Caddy)
#-------------------------------------------------------------------------------------
step_90_stack() {
  local step="90_stack"
  step_done "$step" && return

  mkdir -p "$N8N_DATA_DIR" "$N8N_DATA_DIR/postgres" "$N8N_DATA_DIR/data" "$N8N_DATA_DIR/caddy"

  # Secrets generation (only if empty)
  if [[ -z "$DB_PASSWORD" ]]; then DB_PASSWORD=$(random_base64 24); info "Generated DB password"; fi
  if [[ "$BASIC_AUTH_ENABLE" == "true" && ( -z "$BASIC_AUTH_PASSWORD" || "$BASIC_AUTH_PASSWORD" == "changeMe" ) ]]; then
    BASIC_AUTH_PASSWORD="$(random_base64 18)"; info "Generated Basic Auth password for $BASIC_AUTH_USER";
  fi
  # n8n secrets
  local N8N_ENCRYPTION_KEY_FILE="$N8N_DATA_DIR/.n8n_encryption_key"
  if [[ ! -s "$N8N_ENCRYPTION_KEY_FILE" ]]; then
    random_hex 32 > "$N8N_ENCRYPTION_KEY_FILE"
    chmod 600 "$N8N_ENCRYPTION_KEY_FILE"
  fi
  local N8N_ENCRYPTION_KEY; N8N_ENCRYPTION_KEY=$(cat "$N8N_ENCRYPTION_KEY_FILE")

  # Compute Basic Auth hash via Caddy (bcrypt)
  local BASIC_AUTH_HASH=""
  if [[ "$BASIC_AUTH_ENABLE" == "true" ]]; then
    BASIC_AUTH_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$BASIC_AUTH_PASSWORD")
  fi

  # Compose file
  cat >"$N8N_DATA_DIR/docker-compose.yml" <<'YML'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ./postgres:/var/lib/postgresql/data

  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      - TZ=${TZ}
      - N8N_HOST=${DOMAIN}
      - WEBHOOK_URL=https://${DOMAIN}/
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}/
      - N8N_SECURE_COOKIE=true
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${DB_NAME}
      - DB_POSTGRESDB_USER=${DB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - ./data:/home/node/.n8n

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on:
      - n8n
    ports:
      - "80:80"
      - "443:443"
    environment:
      DOMAIN: ${DOMAIN}
      EMAIL: ${EMAIL}
      BASIC_AUTH_ENABLE: ${BASIC_AUTH_ENABLE}
      BASIC_AUTH_USER: ${BASIC_AUTH_USER}
      BASIC_AUTH_HASH: ${BASIC_AUTH_HASH}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
YML

  # Caddyfile — generate variant with/without Basic Auth
  if [[ "$BASIC_AUTH_ENABLE" == "true" ]]; then
    cat >"$N8N_DATA_DIR/caddy/Caddyfile" <<CADDY
{$DOMAIN} {
  encode zstd gzip
  tls {$EMAIL}

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Frame-Options "DENY"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
  }

  basicauth /* {
    {$BASIC_AUTH_USER} {$BASIC_AUTH_HASH}
  }

  reverse_proxy n8n:5678
}
CADDY
  else
    cat >"$N8N_DATA_DIR/caddy/Caddyfile" <<'CADDY'
{$DOMAIN} {
  encode zstd gzip
  tls {$EMAIL}
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Frame-Options "DENY"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
  }
  reverse_proxy n8n:5678
}
CADDY
  fi

  # Compose .env for variable interpolation
  cat >"$N8N_DATA_DIR/.env" <<ENV
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
BASIC_AUTH_ENABLE=${BASIC_AUTH_ENABLE}
BASIC_AUTH_USER=${BASIC_AUTH_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
N8N_VERSION=${N8N_VERSION}
TZ=${TZ}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
ENV

  # Ownership for n8n container user (UID 1000)
  chown -R 1000:1000 "$N8N_DATA_DIR/data" || true

  mark_done "$step" "Stack files prepared in $N8N_DATA_DIR"
}

#-------------------------------------------------------------------------------------
# STEP 100: Launch stack
#-------------------------------------------------------------------------------------
step_100_launch() {
  local step="100_launch"
  step_done "$step" && return
  info "Launching n8n stack via Docker Compose"
  (cd "$N8N_DATA_DIR" && docker compose --env-file ./.env up -d)
  sleep 3
  (cd "$N8N_DATA_DIR" && docker compose ps || true)
  mark_done "$step" "n8n is starting. First TLS issuance may take ~30–60s."
}

#-------------------------------------------------------------------------------------
# STEP 110: Post‑checks and summary
#-------------------------------------------------------------------------------------
step_110_summary() {
  local step="110_summary"
  step_done "$step" && return
  check_dns || true
  local url="https://${DOMAIN}/"
  info "\n=== INSTALL SUMMARY ==="
  info "Domain:      $DOMAIN"
  info "Email:       $EMAIL"
  info "SSH port:    $SSH_PORT"
  info "Data dir:    $N8N_DATA_DIR"
  info "Stack:       n8n + PostgreSQL + Caddy"
  if [[ "$BASIC_AUTH_ENABLE" == "true" ]]; then
    info "Basic Auth:  enabled (user: $BASIC_AUTH_USER)"
  else
    info "Basic Auth:  disabled"
  fi
  info "CrowdSec:    $CROWDSEC_ENABLE"
  info "Open this after TLS is ready: $url"
  info "Docker logs:  cd $N8N_DATA_DIR && docker compose logs -f caddy n8n"
  info "Backups tip:  snapshot $N8N_DATA_DIR and the VM, or add pg_dump cron."
  mark_done "$step" "Summary printed"
}

#-------------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------------
main() {
  # Trap errors for visibility
  trap 'rc=$?; fail "An error occurred (exit $rc). See $LOG_FILE for details."; exit $rc' ERR

  step_00_preflight
  step_10_user
  step_20_updates
  step_30_ufw
  step_40_ssh
  step_50_fail2ban
  step_60_apparmor
  step_70_docker
  step_80_crowdsec
  step_90_stack

  # If a reboot is pending (kernel/AppArmor), do it once and resume later
  if [[ -f "$STATE_DIR/reboot_required" ]]; then
    warn "Rebooting system to apply critical changes..."
    rm -f "$STATE_DIR/reboot_required"
    # Create a systemd service to auto-resume once after reboot
    cat >/etc/systemd/system/n8n-bootstrap-resume.service <<SVC
[Unit]
Description=n8n bootstrap resume
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "${BASH_SOURCE[0]}"
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable n8n-bootstrap-resume.service
    sleep 2
    reboot
  fi

  step_100_launch
  step_110_summary

  # Disable auto-resume service if present
  if systemctl is-enabled n8n-bootstrap-resume.service >/dev/null 2>&1; then
    systemctl disable n8n-bootstrap-resume.service || true
    rm -f /etc/systemd/system/n8n-bootstrap-resume.service
    systemctl daemon-reload || true
  fi

  success "All done!"
}

main "$@"

