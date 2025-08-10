#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# This script shouldn't be run as root
# To copy this script to your server, you can use: scp -i ~/.ssh/<keyname> 02-setup-environment.sh example-user@<server-ip>:~/
# After copying chmod +x 02-setup-environment.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

info "Updating package index and upgrading..."
sudo apt update && sudo apt upgrade -y

info "Installing base packages..."
sudo apt install -y \
    htop \
    git \
    curl \
    ufw \
    net-tools \
    fail2ban \
    software-properties-common \
    nginx \
    certbot \
    python3-certbot-nginx

log "Base tools installed."

# === Go installation ===
GO_VERSION="1.22.3"  # <– при необходимости обнови до актуальной версии
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"

info "Installing Go ${GO_VERSION}..."
cd /tmp
curl -OL "https://go.dev/dl/${GO_TAR}"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "${GO_TAR}"

# Добавим Go в PATH (если ещё не добавлен)
PROFILE_FILE="$HOME/.profile"
if ! grep -q "/usr/local/go/bin" "$PROFILE_FILE"; then
  echo 'export PATH=$PATH:/usr/local/go/bin' >> "$PROFILE_FILE"
  export PATH=$PATH:/usr/local/go/bin
fi

go version
log "Go installed."

# === UFW Firewall ===
info "Configuring UFW firewall..."
sudo ufw allow OpenSSH
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable
sudo ufw status verbose || true

# === Fail2ban ===
info "Enabling fail2ban..."
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban | head -n 10 || true

# === Check nginx ===
info "Checking nginx..."
sudo systemctl enable --now nginx
sudo systemctl status nginx | head -n 10 || true

log "Environment setup complete!"
