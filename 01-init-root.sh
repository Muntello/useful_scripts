#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# This script should be run as root
# Usage: Run this script on a fresh Ubuntu server to set up a new user with SSH access
# Ensure you have the public SSH key ready to be added for the new user
# To copy this script to your server, you can use: scp 01-init-root.sh root@<server-ip>:/root/01-init-root.sh
# After copying chmod +x /root/01-init-root.sh
# Then run it /root/01-init-root.sh
# Then use ssh -i ~/.ssh/<keyname> example-user@<server-ip>
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root

NEW_USER="example-user"
USER_HOME="/home/$NEW_USER"

# Public SSH key for the new user. Replace the placeholder or export PUBLIC_KEY env.
PUBLIC_KEY=${PUBLIC_KEY:-"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... # <-- Replace with your public key"}

# Guard against committing/using placeholder key
if grep -q "Replace with your public key" <<<"$PUBLIC_KEY"; then
  die "PUBLIC_KEY is not set. Export PUBLIC_KEY with your real key string before running."
fi

info "Creating user: $NEW_USER"
adduser --disabled-password --gecos "" "$NEW_USER"

info "Adding to sudo group"
usermod -aG sudo "$NEW_USER"

info "Setting up SSH key"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

info "Hardening SSH config"
ensure_kv /etc/ssh/sshd_config PermitRootLogin no
ensure_kv /etc/ssh/sshd_config PasswordAuthentication no

info "Configuring passwordless sudo"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
chmod 440 "/etc/sudoers.d/90-$NEW_USER"

info "Restarting SSH service"
systemctl restart ssh

info "Enabling 1GB swap if missing..."

if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
  log "Swap created and enabled"
else
  warn "Swap file already exists, skipping"
fi

log "Done! Try logging in as: ssh $NEW_USER@your.server.ip"
