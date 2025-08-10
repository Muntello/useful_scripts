#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# Before running this script, ensure you have:
# 1. A valid SSH key added to your GitHub account.
# 2. The SSH key is stored at $HOME/.ssh/github_actions_key.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

# Path to the directory where the repo will be cloned
APP_DIR="$HOME/app-src"

# Path to the compiled binary
APP_BIN="$HOME/app"

# Git repo SSH URL
REPO_SSH="git@github.com:YourUsername/your-repo.git"  # Replace with your repository

# Deploy key path
DEPLOY_KEY="$HOME/.ssh/github_actions_key"

info "Installing dependencies for Go build (gcc, stdlib.h)..."
sudo apt update
sudo apt install -y build-essential

info "Cloning the application repository..."
if [ ! -d "$APP_DIR" ]; then
  GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes" git clone "$REPO_SSH" "$APP_DIR"
else
  warn "Repository already exists at $APP_DIR — skipping clone."
fi

info "Creating deploy.sh script..."
cat <<'EOF' > "$APP_DIR/deploy.sh"
#!/bin/bash
set -e

cd "$(dirname "$0")" || exit 1

# Load Go into PATH
export PATH=$PATH:/usr/local/go/bin

echo "[*] Pulling latest code..."
git pull origin main

echo "[*] Building Go application..."
go build -o ~/app main.go

echo "[*] Restarting systemd service..."
sudo systemctl restart app

echo "[+] Deploy complete!"
EOF

chmod +x "$APP_DIR/deploy.sh"

info "Building the application for the first time..."
cd "$APP_DIR"
echo "Current directory: $(pwd)"
echo "Files in directory:"
ls -la

# Load Go into PATH
export PATH=$PATH:/usr/local/go/bin
echo "Go version: $(go version)"

# Check if main.go exists
if [ ! -f "main.go" ]; then
  error "main.go not found in the repository!"
  echo "Available files:"
  find . -name "*.go" -type f
  exit 1
fi

# Build the application
echo "Building Go application..."
go build -o "$APP_BIN" main.go

if [ ! -f "$APP_BIN" ]; then
  error "Failed to build the application!"
  exit 1
fi

log "Application built successfully at $APP_BIN"

info "Creating systemd service..."
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

info "Enabling and starting systemd service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now app

echo ""
log "Setup complete!"
echo "Application source:    $APP_DIR"
echo "Compiled binary path:  $APP_BIN"
echo "Deploy script:         $APP_DIR/deploy.sh"
echo "Systemd service:       app.service"
echo ""
echo "View logs: sudo journalctl -u app -f"
