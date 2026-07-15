#!/bin/bash
# update-sg.sh — updates AWS security group with current public IP
# For OPS-235 telemetry VM (ops-claude-code-telemetry)
set -euo pipefail

SG_ID="sg-0c10615c3983e2f47"
REGION="us-east-1"
PORTS=(22 3000 4317 4318)

# Descriptions to attach to the re-created rules, keyed by port.
# (case statement instead of an associative array for bash 3.2 / macOS compat)
port_desc() {
    case "$1" in
        22)   echo "SSH access" ;;
        3000) echo "Grafana dashboard" ;;
        4317) echo "Claude Code gRPC telemetry" ;;
        4318) echo "Claude Code HTTP telemetry" ;;
        *)    echo "managed by update-sg.sh" ;;
    esac
}

# Force IPv4 — ifconfig.me/checkip resolve over IPv6 on dual-stack networks,
# which would produce a malformed "<ipv6>/32" CIDR.
MY_IP="$(curl -4 -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"

# Sanity-check we actually got an IPv4 address before touching the SG.
if ! [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
    echo "ERROR: could not determine a valid IPv4 address (got '$MY_IP')" >&2
    exit 1
fi

echo "Current IP: $MY_IP"
echo "Updating security group: $SG_ID"

for PORT in "${PORTS[@]}"; do
    DESC="$(port_desc "$PORT")"

    # Remove ALL existing IPv4 rules for this port. We revoke via --ip-permissions
    # with the exact CidrIp + Description so rules that carry a description are
    # matched and removed reliably.
    OLD_RULES="$(aws ec2 describe-security-groups \
        --group-ids "$SG_ID" --region "$REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$PORT\`].IpRanges[]" \
        --output json)"

    echo "$OLD_RULES" | jq -c '.[]' | while read -r RANGE; do
        OLD_IP="$(echo "$RANGE" | jq -r '.CidrIp')"
        OLD_DESC="$(echo "$RANGE" | jq -r '.Description // ""')"
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
            --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$OLD_IP,Description=\"$OLD_DESC\"}]" \
            >/dev/null
        echo "  Removed $OLD_IP (\"$OLD_DESC\") from port $PORT"
    done

    # Add current IP (with description), unless it is already present.
    if aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
        --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$MY_IP,Description=\"$DESC\"}]" \
        >/dev/null 2>&1; then
        echo "  Added $MY_IP (\"$DESC\") to port $PORT"
    else
        echo "  $MY_IP already present on port $PORT (skipped)"
    fi
done

echo "Done. All ports updated to $MY_IP"
