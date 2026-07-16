#!/usr/bin/env bash
# Pull live n8n workflows from the REST API for backup/analysis.
# Credentials are STRIPPED from exports by n8n (see docs/access-and-sync.md §3),
# so this script is for diffing/analysis only, not for restoring credential links.
# For credential-safe two-way sync use n8n Source Control (docs §5).
#
# Usage:
#   N8N_API_KEY=<key> ./scripts/pull-workflows.sh
#   ./scripts/pull-workflows.sh   (reads N8N_API_KEY from .env if present)
#
# Requires: curl, jq

set -euo pipefail

N8N_BASE="${N8N_BASE:-https://n8n.andrianarison.com}"
OUT_DIR="${OUT_DIR:-workflows}"
ID_MAP=(
  "E6zR3WkUfXjCdeE6:telegram-ollama-chatbot.json"
  "me7ect2HVlIIo4us:ovh-email-operations.json"
)

if [[ -z "${N8N_API_KEY:-}" && -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${N8N_API_KEY:-}" ]]; then
  echo "ERROR: N8N_API_KEY is not set. Export it or put it in .env" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

for entry in "${ID_MAP[@]}"; do
  id="${entry%%:*}"
  file="${entry##*:}"
  echo "Pulling $id -> $OUT_DIR/$file"
  curl -sf -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    "${N8N_BASE}/api/v1/workflows/${id}" \
    | jq '.' > "$OUT_DIR/$file"
done

echo "Done. Note: credential references are not included in this export."
