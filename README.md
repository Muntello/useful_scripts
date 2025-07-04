# useful_scripts
Useful scripts for server deployment and automation

## Scripts

### 01-init-root.sh
Script for initial Ubuntu server setup. Must be run as root.

**What it does:**
- Creates a new user `muntello`
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
   ssh muntello@your.server.ip
   ```

**Important:** Make sure you have the SSH private key corresponding to the public key in the script before running it.
