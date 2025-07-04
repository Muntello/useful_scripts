#!/bin/bash
set -e

# --- Configuration ---

DOMAIN="yourdomain.com"  # ← Replace with your actual domain
APP_PORT="8080"   # ← Port your Go app listens on

# --- Install dependencies ---

echo "🌐 Installing Nginx and Certbot..."
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx

# --- Configure Nginx ---

echo "📝 Creating Nginx config for $DOMAIN..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable the site
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

echo "🔄 Reloading Nginx to apply config..."
sudo nginx -t
sudo systemctl reload nginx

# --- Obtain SSL cert + enable redirect ---

echo "🔐 Requesting SSL certificate for $DOMAIN with redirect..."
sudo certbot --nginx --redirect --non-interactive --agree-tos -m your-email@example.com -d "$DOMAIN"

# --- Enable auto-renewal (already done by Certbot with systemd) ---

echo ""
echo "✅ HTTPS is enabled with automatic redirection from HTTP."
echo "You can test with: curl -I http://$DOMAIN"