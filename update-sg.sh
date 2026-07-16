#!/bin/bash
# update-sg.sh — reconcile the AWS security group to a desired allowlist.
# For OPS-235 telemetry VM (ops-claude-code-telemetry).
#
# Desired state per port:
#   - the OPERATOR's current public IP (this machine) on ALL ports
#   - every entry in team-ips.txt on the TELEMETRY ports only (4317/4318)
#
# It reconciles (adds missing / removes stale) rather than wiping and re-adding,
# so re-running when the operator's cellular IP rotates does NOT evict teammates.
set -euo pipefail

cd "$(dirname "$0")"

SG_ID="sg-0c10615c3983e2f47"
REGION="us-east-1"
PORTS=(22 3000 4317 4318)
TELEMETRY_PORTS=" 4317 4318 "   # team IPs are allowed on these only
TEAM_FILE="team-ips.txt"

port_desc() {
    case "$1" in
        22)   echo "SSH access" ;;
        3000) echo "Grafana dashboard" ;;
        4317) echo "Claude Code gRPC telemetry" ;;
        4318) echo "Claude Code HTTP telemetry" ;;
        *)    echo "managed by update-sg.sh" ;;
    esac
}

# Force IPv4 — checkip resolves over IPv6 on dual-stack networks otherwise.
MY_IP="$(curl -4 -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
if ! [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
    echo "ERROR: could not determine a valid IPv4 address (got '$MY_IP')" >&2
    exit 1
fi

# Emit desired "CIDR<TAB>DESC" lines for a port.
desired_for_port() {
    local port="$1"
    printf '%s\t%s\n' "$MY_IP" "operator: $(port_desc "$port")"
    if [[ "$TELEMETRY_PORTS" == *" $port "* && -f "$TEAM_FILE" ]]; then
        # each line: "<ip-or-cidr>  <description...>"; skip blanks/comments.
        # `|| true`: grep exits 1 when the file is all comments (no matches),
        # which would otherwise trip `set -e`/pipefail and abort the reconcile.
        { grep -vE '^[[:space:]]*(#|$)' "$TEAM_FILE" || true; } | while read -r ip desc; do
            [[ "$ip" == */* ]] || ip="$ip/32"
            printf '%s\t%s\n' "$ip" "team: ${desc:-teammate}"
        done
    fi
}

echo "Operator IP: $MY_IP"
echo "Reconciling security group: $SG_ID"

for PORT in "${PORTS[@]}"; do
    DESIRED="$(desired_for_port "$PORT")"
    DESIRED_CIDRS="$(printf '%s\n' "$DESIRED" | cut -f1 | sort -u)"

    CURRENT_JSON="$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$PORT\`].IpRanges[]" --output json)"
    CURRENT_CIDRS="$(printf '%s' "$CURRENT_JSON" | jq -r '.[].CidrIp' | sort -u)"

    # Revoke rules present but no longer desired (e.g. the operator's old IP).
    comm -23 <(printf '%s\n' "$CURRENT_CIDRS") <(printf '%s\n' "$DESIRED_CIDRS") | while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        d="$(printf '%s' "$CURRENT_JSON" | jq -r --arg c "$cidr" '.[]|select(.CidrIp==$c)|.Description // ""' | head -1)"
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
            --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$cidr,Description=\"$d\"}]" >/dev/null
        echo "  [$PORT] revoked $cidr"
    done

    # Authorize desired rules not yet present.
    comm -13 <(printf '%s\n' "$CURRENT_CIDRS") <(printf '%s\n' "$DESIRED_CIDRS") | while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        d="$(printf '%s\n' "$DESIRED" | awk -F'\t' -v c="$cidr" '$1==c{print $2; exit}')"
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
            --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$cidr,Description=\"$d\"}]" >/dev/null
        echo "  [$PORT] authorized $cidr ($d)"
    done
done

echo "Done. Operator on all ports; team-ips.txt entries on 4317/4318."
