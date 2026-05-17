#!/usr/bin/env bash
# One-shot helper: prompts (hidden) for PHALA_CLOUD_API_KEY and writes it into
# scripts/.env without echoing it anywhere. Run once after generating the key
# at cloud.phala.com → API Tokens.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f scripts/.env ]]; then
  echo "ERROR: scripts/.env not found. Run scripts/run.sh first to create it." >&2
  exit 1
fi

printf "Phala Cloud API key (paste — input hidden): "
IFS= read -rs key
printf "\n"

if [[ -z "$key" ]]; then
  echo "ERROR: empty input. Aborted." >&2
  exit 1
fi

# Use a unique delimiter unlikely to appear in a base64-ish key.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk -v k="$key" '
  /^PHALA_CLOUD_API_KEY=/ { print "PHALA_CLOUD_API_KEY=" k; next }
  { print }
' scripts/.env > "$tmp"
chmod 600 "$tmp"
mv "$tmp" scripts/.env
chmod 600 scripts/.env

mask="${key:0:4}…${key: -4}"
unset key
echo "✓ Wrote PHALA_CLOUD_API_KEY=${mask} to scripts/.env"
echo "  Now run: bash scripts/run.sh"
