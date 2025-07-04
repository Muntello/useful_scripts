#!/bin/bash
# Before running this script, ensure you have:
# 1. A valid SSH key added to your GitHub account.
# 2. The SSH key is stored at $HOME/.ssh/github_actions_key.
set -e

# Path to the directory where the repo will be cloned
APP_DIR="$HOME/app-src"

# Path to the compiled binary
APP_BIN="$HOME/app"

# Git repo SSH URL
REPO_SSH="git@github.com:YourUsername/your-repo.git"  # Replace with your repository

# Deploy key path
DEPLOY_KEY="$HOME/.ssh/github_actions_key"

echo "📦 Installing dependencies for Go build (gcc, stdlib.h)..."
sudo apt update
sudo apt install -y build-essential

echo "🐙 Cloning the application repository..."
if [ ! -d "$APP_DIR" ]; then
  GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes" git clone "$REPO_SSH" "$APP_DIR"
else
  echo "⚠️  Repository already exists at $APP_DIR — skipping clone."
fi

echo "📁 Creating deploy.sh script..."
cat <<'EOF' > "$APP_DIR/deploy.sh"
#!/bin/bash
set -e

cd "$(dirname "$0")" || exit 1

echo "[*] Pulling latest code..."
git pull origin main

echo "[*] Building Go application..."
go build -o ~/app main.go

echo "[*] Restarting systemd service..."
sudo systemctl restart app

echo "[+] Deploy complete!"
EOF

chmod +x "$APP_DIR/deploy.sh"

echo "🛠 Creating systemd service..."
sudo tee /etc/systemd/system/app.service > /dev/null <<EOF
[Unit]
Description=Go web app
After=network.target

[Service]
User=example-user
WorkingDirectory=$APP_DIR
ExecStart=$APP_BIN
Restart=on-failure
Environment=GIN_MODE=release
StandardOutput=append:/var/log/app.log
StandardError=append:/var/log/app.err

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling and starting systemd service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now app

echo ""
echo "✅ Setup complete!"
echo "Application source:    $APP_DIR"
echo "Compiled binary path:  $APP_BIN"
echo "Deploy script:         $APP_DIR/deploy.sh"
echo "Systemd service:       app.service"
echo ""
echo "View logs: sudo journalctl -u app -f"