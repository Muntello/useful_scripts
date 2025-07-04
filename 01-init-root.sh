#!/bin/bash

# This script should be run as root
# Usage: Run this script on a fresh Ubuntu server to set up a new user with SSH access
# Ensure you have the public SSH key ready to be added for the new user
# To copy this script to your server, you can use: scp 01-init-root.sh root@<server-ip>:/root/01-init-root.sh
# After copying chmod +x /root/01-init-root.sh
# Then run it /root/01-init-root.sh
# Then use ssh -i ~/.ssh/<keyname> example-user@<server-ip>
set -e

NEW_USER="example-user"
USER_HOME="/home/$NEW_USER"

# Public SSH key for the new user
# IMPORTANT: Replace this with your actual public SSH key!
PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... # <-- Replace with your public key"

echo "[*] Creating user: $NEW_USER"
adduser --disabled-password --gecos "" "$NEW_USER"

echo "[*] Adding to sudo group"
usermod -aG sudo "$NEW_USER"

echo "[*] Setting up SSH key"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

echo "[*] Disabling password authentication and root login"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "[*] Configuring passwordless sudo"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
chmod 440 "/etc/sudoers.d/90-$NEW_USER"

echo "[*] Restarting SSH service"
systemctl restart ssh

echo "[+] Done! Try logging in as: ssh $NEW_USER@your.server.ip"