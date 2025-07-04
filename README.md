# useful_scripts
Useful scripts for server deployment and automation

## Scripts

### 01-init-root.sh
Script for initial Ubuntu server setup. Must be run as root.

**What it does:**
- Creates a new user `example-user`
- Adds the user to the sudo group
- Sets up SSH key for the new user
- Disables password authentication
- Disables root login
- Configures passwordless sudo for the new user

**Usage:**
1. Copy the script to the server:
   ```bash
   scp 01-init-root.sh root@your.server.ip:/root/01-init-root.sh
   ```

2. Make the script executable:
   ```bash
   chmod +x /root/01-init-root.sh
   ```

3. Run the script:
   ```bash
   /root/01-init-root.sh
   ```

4. After execution, connect as:
   ```bash
   ssh example-user@your.server.ip
   ```

**Important:** Make sure you have the SSH private key corresponding to the public key in the script before running it.

### 02-setup-environment.sh
Script for setting up the development and production environment on Ubuntu server. Should be run as a regular user (not root) after completing the initial setup with `01-init-root.sh`.

**What it does:**
- Updates the system packages
- Installs essential tools: `htop`, `git`, `curl`, `net-tools`
- Installs and configures security tools: `ufw`, `fail2ban`
- Installs web server: `nginx`
- Installs SSL certificate tools: `certbot`, `python3-certbot-nginx`
- Installs Go programming language (version 1.22.3)
- Configures UFW firewall (allows SSH, HTTP, HTTPS)
- Enables and starts fail2ban for intrusion prevention
- Enables and starts nginx web server

**Usage:**
1. Copy the script to the server:
   ```bash
   scp -i ~/.ssh/your_key 02-setup-environment.sh example-user@your.server.ip:~/
   ```

2. Connect to the server:
   ```bash
   ssh -i ~/.ssh/your_key example-user@your.server.ip
   ```

3. Make the script executable:
   ```bash
   chmod +x 02-setup-environment.sh
   ```

4. Run the script:
   ```bash
   ./02-setup-environment.sh
   ```

**Note:** This script should be run after `01-init-root.sh` and as the regular user (example-user), not as root.

### 03-setup-app.sh
Script for setting up and deploying a Go web application from GitHub. Should be run as a regular user after completing the environment setup with `02-setup-environment.sh`.

**Prerequisites:**
- A valid SSH key added to your GitHub account
- The SSH deploy key stored at `$HOME/.ssh/github_actions_key`
- Go development environment (installed by the previous script)

**What it does:**
- Clones the Go web application repository from GitHub
- Creates a deployment script (`deploy.sh`) for easy updates
- Sets up a systemd service for the application
- Configures the service to run as the `example-user` user
- Enables automatic restart on failure
- Sets up logging to `/var/log/app.log` and `/var/log/app.err`
- Starts the application service

**Usage:**
1. Set up your GitHub SSH deploy key:
   ```bash
   # Generate a new key (if needed)
   ssh-keygen -t ed25519 -f ~/.ssh/github_actions_key
   
   # Add the public key to your GitHub repository's deploy keys
   cat ~/.ssh/github_actions_key.pub
   ```

2. Copy the script to the server:
   ```bash
   scp -i ~/.ssh/your_key 03-setup-app.sh example-user@your.server.ip:~/
   ```

3. Connect to the server:
   ```bash
   ssh -i ~/.ssh/your_key example-user@your.server.ip
   ```

4. Make the script executable and run it:
   ```bash
   chmod +x 03-setup-app.sh
   ./03-setup-app.sh
   ```

**After setup:**
- View logs: `sudo journalctl -u app -f`
- Restart service: `sudo systemctl restart app`
- Deploy updates: `cd ~/app-src && ./deploy.sh`
- Check service status: `sudo systemctl status app`

**Note:** This script is configured for the repository `git@github.com:YourUsername/your-repo.git`. Update the `REPO_SSH` variable if you're using a different repository.

### 04-setup-nginx.sh
Script for configuring Nginx as a reverse proxy and setting up SSL certificates for your Go web application. Should be run as a regular user after the application is deployed with `03-setup-app.sh`.

**Prerequisites:**
- Domain name pointing to your server's IP address
- Go application running on a specific port (default: 8080)
- Email address for SSL certificate registration

**What it does:**
- Installs/updates Nginx and Certbot
- Creates Nginx configuration file for your domain
- Sets up reverse proxy to forward requests to your Go application
- Configures proper proxy headers for client information
- Enables the site configuration
- Obtains SSL certificate from Let's Encrypt
- Configures automatic HTTP to HTTPS redirection
- Sets up automatic certificate renewal

**Configuration:**
Before running the script, update these variables:
- `DOMAIN`: Your domain name (default: "yourdomain.com")
- `APP_PORT`: Port your Go app listens on (default: "8080")
- Email address in the certbot command (replace "your-email@example.com")

**Usage:**
1. Update the configuration in the script:
   ```bash
   nano 04-setup-nginx.sh
   # Edit DOMAIN and APP_PORT variables
   # Edit email address in the certbot command
   ```

2. Copy the script to the server:
   ```bash
   scp -i ~/.ssh/your_key 04-setup-nginx.sh example-user@your.server.ip:~/
   ```

3. Connect to the server:
   ```bash
   ssh -i ~/.ssh/your_key example-user@your.server.ip
   ```

4. Make the script executable and run it:
   ```bash
   chmod +x 04-setup-nginx.sh
   ./04-setup-nginx.sh
   ```

**After setup:**
- Test HTTP redirect: `curl -I http://yourdomain.com`
- Test HTTPS: `curl -I https://yourdomain.com`
- Check Nginx status: `sudo systemctl status nginx`
- View Nginx logs: `sudo tail -f /var/log/nginx/access.log`
- Check SSL certificate: `sudo certbot certificates`

**Note:** Make sure your domain's DNS A record points to your server's IP address before running this script, as SSL certificate verification requires domain accessibility.
