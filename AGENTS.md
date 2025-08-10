# Repository Guidelines

## Project Structure & Module Organization
- Root scripts: `01-init-root.sh`, `02-setup-environment.sh`, `03-setup-app.sh`, `04-setup-nginx.sh` run in order (see `README.md`).
- Support files: `.gitignore`, `README.md`.
- Naming pattern: `NN-action-target.sh` (two‑digit step, hyphenated action and target).

## Build, Test, and Development Commands
- Syntax check: `bash -n 02-setup-environment.sh` — parse without executing.
- Lint: `shellcheck 03-setup-app.sh` — static analysis for Bash issues.
- Run locally: `chmod +x 04-setup-nginx.sh && ./04-setup-nginx.sh` — execute step script.
- Trace runs: `bash -x 01-init-root.sh` — verbose execution for debugging in a disposable VM.

## Coding Style & Naming Conventions
- Interpreter: keep `#!/bin/bash` at line 1.
- Safety flags: prefer `set -e` (existing) and consider `set -Eeuo pipefail` for stricter scripts.
- Indentation: 2 spaces; wrap long commands with `\` aligned under the first argument.
- Quoting: double‑quote variable expansions; use `readonly VAR=value` for constants.
- Messages: concise, action‑oriented logs (existing emoji usage is acceptable but optional).
 - Shared lib: source `lib/common.sh` for logging, privilege checks, and file helpers.

## Testing Guidelines
- Platform: test on a fresh Ubuntu VM/container; these scripts change system state.
- Order: run scripts sequentially (01 → 04). Do not run 01 as a non‑root user.
- Linting: `shellcheck -x 0*-*.sh` should pass before submitting.
- Dry runs: validate destructive commands with guards (e.g., `if [ -f ... ]`).
- Verification: confirm services with `systemctl status`, firewall with `ufw status`, and TLS via `curl -I https://domain`.

## Commit & Pull Request Guidelines
- Commits: imperative, concise, scoped. Example: `setup: add swap file`, `nginx: enable https redirect`.
- PRs: include purpose, what changed, run order, test evidence (logs or screenshots), and any required configuration (e.g., `DOMAIN`, `REPO_SSH`). Link related issues.

## Security & Configuration Tips
- Replace placeholders before running: `PUBLIC_KEY`, `REPO_SSH`, `DEPLOY_KEY`, `DOMAIN`, email in Certbot.
- Principle of least privilege: only `01-*` requires root; others run as the target user with `sudo` as needed.
- Secrets: do not commit private keys; reference paths only.
- Idempotency: scripts should safely re‑run (check for existing files/services before creating).
 - Pre-commit: install `hooks/pre-commit` to block secret patterns; use `./05-scan-secrets.sh` for manual scans.
