# Repository Guidelines

This repository contains shell scripts to provision and configure a server in four ordered steps. Follow these conventions to contribute safely and consistently.

## Project Structure & Module Organization
- Root scripts: `01-init-root.sh`, `02-setup-environment.sh`, `03-setup-app.sh`, `04-setup-nginx.sh` (run in order).
- Support: `.gitignore`, `README.md`, `AGENTS.md`, and shared lib `lib/common.sh` (logging, privilege checks, file helpers).
- Naming pattern: `NN-action-target.sh` (e.g., `02-setup-environment.sh`).

## Build, Test, and Development Commands
- Syntax check: `bash -n 02-setup-environment.sh` — parse without executing.
- Lint: `shellcheck -x 0*-*.sh` or `shellcheck 03-setup-app.sh` — static analysis for Bash issues.
- Run locally: `chmod +x 04-setup-nginx.sh && ./04-setup-nginx.sh` — execute a single step.
- Trace runs: `bash -x 01-init-root.sh` — verbose execution for debugging (use a disposable VM).

## Coding Style & Naming Conventions
- Shebang: keep `#!/bin/bash` at line 1.
- Safety flags: prefer `set -e`; consider `set -Eeuo pipefail` for stricter scripts.
- Indentation: 2 spaces; wrap long commands with `\` aligned under the first argument.
- Quoting: double-quote variable expansions; use `readonly VAR=value` for constants.
- Shared lib: `source lib/common.sh` for `log`, privilege checks, and file helpers.

## Testing Guidelines
- Platform: test on a fresh Ubuntu VM/container.
- Order: run scripts sequentially (01 → 04). Do not run `01-*` as a non-root user.
- Dry runs: guard destructive commands (e.g., `if [ -f ... ]`).
- Verification: confirm services and network: `systemctl status <svc>`, `ufw status`, `curl -I https://DOMAIN`.

## Commit & Pull Request Guidelines
- Commits: imperative, concise, scoped (e.g., `setup: add swap file`, `nginx: enable https redirect`).
- Pull requests: include purpose, what changed, run order, test evidence (logs/screenshots), and required configuration (`DOMAIN`, `REPO_SSH`, etc.). Link related issues.

## Security & Configuration Tips
- Replace placeholders before running: `PUBLIC_KEY`, `REPO_SSH`, `DEPLOY_KEY`, `DOMAIN`, and Certbot email.
- Least privilege: only `01-*` requires root; others run as target user with `sudo` as needed.
- Secrets: do not commit private keys; reference paths only.
- Idempotency: scripts must safely re-run.
- Secret scanning: install `hooks/pre-commit`; run `./05-scan-secrets.sh` for manual checks.

