#!/usr/bin/env bash
# bootstrap-claude-telemetry.sh — configure THIS machine's Claude Code to export
# telemetry to the shared collector. Merges the `env` block from
# claude-code-telemetry-settings.json into ~/.claude/settings.json, filling in the
# shared ingest token (bearer auth) and optionally the OTLP endpoint.
#
# Usage:
#   ./bootstrap-claude-telemetry.sh <INGEST_TOKEN> [OTLP_ENDPOINT]
#
#   <INGEST_TOKEN>   required — the shared OTEL_INGEST_TOKEN (ask the stack owner)
#   [OTLP_ENDPOINT]  optional — default http://localhost:4317 (on the VM).
#                    Remote clients pass http://<VM_PUBLIC_IP>:4317 and must have
#                    their IP added to the SG allowlist (team-ips.txt + update-sg.sh).
#
# Idempotent; preserves other settings keys (e.g. "theme").
set -euo pipefail

cd "$(dirname "$0")"
TEMPLATE="claude-code-telemetry-settings.json"
DEST="$HOME/.claude/settings.json"
TOKEN="${1:-}"
ENDPOINT="${2:-}"

[[ -n "$TOKEN" ]] || { echo "ERROR: ingest token required. Usage: $0 <INGEST_TOKEN> [OTLP_ENDPOINT]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "ERROR: $TEMPLATE not found" >&2; exit 1; }

mkdir -p "$HOME/.claude"
[[ -s "$DEST" ]] || echo '{}' > "$DEST"
cp "$DEST" "$DEST.bak"

# Build the env block from the template: strip "//..." doc keys, set the bearer
# header from the token, optionally override the endpoint.
ENVBLOCK="$(jq --arg tok "$TOKEN" \
    '.env | .OTEL_EXPORTER_OTLP_HEADERS = ("Authorization=Bearer " + $tok)' "$TEMPLATE")"
if [[ -n "$ENDPOINT" ]]; then
    ENVBLOCK="$(echo "$ENVBLOCK" | jq --arg e "$ENDPOINT" '.OTEL_EXPORTER_OTLP_ENDPOINT = $e')"
fi

# Deep-merge env into existing settings.json.
jq --argjson env "$ENVBLOCK" '.env = ((.env // {}) + $env)' "$DEST.bak" > "$DEST"

echo "Merged telemetry env into $DEST (backup at $DEST.bak):"
jq '.env | .OTEL_EXPORTER_OTLP_HEADERS = "Authorization=Bearer <redacted>"' "$DEST"
echo
echo "New Claude Code sessions on this machine will now export authenticated telemetry."
