#!/bin/bash

# This script shouldn't be run as root
# To copy this script to your server, you can use: scp -i ~/.ssh/<keyname> 02-setup-environment.sh example-user@<server-ip>:~/
# After copying chmod +x 02-setup-environment.sh
set -e

echo "📦 Updating and installing base packages..."
sudo apt update && sudo apt upgrade -y

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

echo "✅ Base tools installed."

# === Go installation ===
GO_VERSION="1.22.3"  # <– при необходимости обнови до актуальной версии
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"

echo "🐹 Installing Go ${GO_VERSION}..."
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
echo "✅ Go installed."

# === UFW Firewall ===
echo "🛡️  Configuring UFW firewall..."
sudo ufw allow OpenSSH
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable
sudo ufw status verbose

# === Fail2ban ===
echo "🛡️  Enabling fail2ban..."
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban | head -n 10

# === Check nginx ===
echo "🧪 Checking nginx..."
sudo systemctl enable --now nginx
sudo systemctl status nginx | head -n 10

echo "🎉 Environment setup complete!"