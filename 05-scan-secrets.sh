#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Scan the working tree for common secret patterns. Exits non-zero if any are found.

require_not_root

info "Scanning for potential secrets in repository..."

PATTERNS=(
  '-----BEGIN RSA PRIVATE KEY-----'
  '-----BEGIN OPENSSH PRIVATE KEY-----'
  '-----BEGIN EC PRIVATE KEY-----'
  'aws_secret_access_key'
  'aws_access_key_id'
  'xox[baprs]-[0-9A-Za-z-]+'
  'password\s*='
  'secret\s*='
  'token\s*='
)

FOUND=0

# search tracked files excluding binary/external dirs
GREP_OPTS=(-RIn --binary-files=without-match --exclude-dir=.git --exclude=*.png --exclude=*.jpg --exclude=*.jpeg --exclude=*.gif)

for pat in "${PATTERNS[@]}"; do
  if grep "${GREP_OPTS[@]}" -E "$pat" . >/tmp/secret_hits.txt 2>/dev/null; then
    warn "Pattern matched: $pat"
    cat /tmp/secret_hits.txt
    FOUND=1
  fi
done

rm -f /tmp/secret_hits.txt || true

if [ "$FOUND" -eq 1 ]; then
  error "Potential secrets detected. Review and remove before committing."
  exit 2
fi

log "No obvious secrets detected."

