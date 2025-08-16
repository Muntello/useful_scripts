# Go Infra

Two scripts for provisioning and managing small Go web apps on a single Ubuntu host using per-project users, systemd, and Nginx.

## Files
- `bootstrap.sh` (run as root): base OS hardening, key‑only admin user, Nginx/UFW/Fail2ban, Certbot, Alloy repo, infra dirs. Verifies admin sudo and prompts to test SSH before reboot.
- `manage.sh` (run as admin via sudo): add/apply/remove/pause/resume projects from `/etc/go-infra/projects.d`.
- `manage.sh` (run as admin via sudo): add/apply/remove/pause/resume projects, веб‑root TLS (HTTP‑01), HSTS/OCSP, health‑checks (systemd timer), logrotate для Nginx логов.

## Quick start
1) Copy to server and run bootstrap as root:
```
scp -r go-infra root@server:/opt/
ssh root@server
cd /opt/go-infra && vim bootstrap.sh   # set ADMIN_USER/SSH key/etc.
bash bootstrap.sh
```
2) Reconnect as the new admin user, then manage apps:
```
ssh -p <SSH_PORT> goadmin@server
/opt/go-infra/manage.sh add-project --name myapp --domain app.example.com --port 18080 --enable
/opt/go-infra/manage.sh list
/opt/go-infra/manage.sh pause-project --name myapp   # maintenance
/opt/go-infra/manage.sh resume-project --name myapp
/opt/go-infra/manage.sh remove-project --name myapp --purge
```

## Config locations
- Main: `/etc/go-infra/go-infra.conf`
- Projects: `/etc/go-infra/projects.d/*.conf` (+ optional `NAME.env`)
- Templates: `/etc/go-infra/templates/maintenance.html`
- Apps: `/srv/apps/<name>/current/<name>` (default EXEC)
- Env: `/etc/go-infra/projects.d/<name>.env` (owner: admin; 0640)
- ACME: `/var/www/acme` (webroot для HTTP‑01)

## Notes
- HTTPS: webroot‑режим. При `CERTBOT_EMAIL` сначала создается HTTP‑only конфиг, затем выпуск `certbot certonly --webroot -w /var/www/acme -d <domain>`, после — полноценный HTTPS (HSTS/OCSP) и reload Nginx. Для тестов `CERTBOT_STAGING=yes`. Профиль `TLS_PROFILE=modern|intermediate`.
- Health‑check: укажите `HEALTH_PATH=/health` и опционально `HEALTH_INTERVAL=1min`, `HEALTH_TIMEOUT=3`, `HEALTH_RETRIES=3` — создается таймер `NAME-health.timer`, который проверяет URL и перезапускает сервис при сбоях.
- Logrotate: всегда `/etc/logrotate.d/nginx-<name>`; если `APP_LOG_MODE=file`, добавляется `/etc/logrotate.d/app-<name>`.
- Global toggles: в `/etc/go-infra/go-infra.conf` — `TLS_PROFILE`, `APP_LOG_MODE`.
- Deleting with `--purge` removes user data; use with care.
