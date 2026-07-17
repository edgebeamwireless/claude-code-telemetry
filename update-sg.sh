#!/bin/bash
# update-sg.sh — reconcile the AWS security group to a desired allowlist.
# For OPS-235 telemetry VM (ops-claude-code-telemetry).
#
# Desired state per port:
#   - the OPERATOR's current public IP (this machine) on ALL ports
#   - every entry in team-ips.txt on the TELEMETRY ports only (4317/4318)
#
# Safety (OPS-408):
#   - verifies the AWS account before ANY mutation
#   - validates every CIDR (well-formed, /24 or narrower, never 0.0.0.0/0)
#   - AUTHORIZES new rules and confirms them BEFORE revoking stale ones (no lockout)
#   - --dry-run previews changes; --status just prints current rules
set -euo pipefail
cd "$(dirname "$0")"

SG_ID="sg-0c10615c3983e2f47"
REGION="us-east-1"
EXPECTED_ACCOUNT="027654771904"
PORTS=(22 3000 4317 4318)
TELEMETRY_PORTS=" 4317 4318 "   # team IPs are allowed on these only
TEAM_FILE="team-ips.txt"

DRY_RUN=false
STATUS_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --status)  STATUS_ONLY=true ;;
        -h|--help) echo "usage: $0 [--dry-run | --status]"; exit 0 ;;
        *) echo "unknown argument: $arg (use --dry-run, --status, or --help)" >&2; exit 2 ;;
    esac
done

port_desc() {
    case "$1" in
        22)   echo "SSH access" ;;
        3000) echo "Grafana dashboard" ;;
        4317) echo "Claude Code gRPC telemetry" ;;
        4318) echo "Claude Code HTTP telemetry" ;;
        *)    echo "managed by update-sg.sh" ;;
    esac
}

# validate_cidr <cidr> — 0 if a well-formed IPv4 CIDR, /24 or narrower, not 0.0.0.0/0.
validate_cidr() {
    local cidr="$1"
    if ! [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        echo "  ! invalid CIDR format: $cidr" >&2; return 1
    fi
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" p="${BASH_REMATCH[5]}"
    local o
    for o in "$o1" "$o2" "$o3" "$o4"; do
        if (( 10#$o > 255 )); then echo "  ! octet >255 in $cidr" >&2; return 1; fi
    done
    if (( 10#$p > 32 )); then echo "  ! prefix >32 in $cidr" >&2; return 1; fi
    if [[ "$cidr" == "0.0.0.0/0" ]]; then echo "  ! refusing 0.0.0.0/0 (open to the world)" >&2; return 1; fi
    if (( 10#$p < 24 )); then echo "  ! refusing CIDR wider than /24: $cidr" >&2; return 1; fi
    return 0
}

verify_account() {
    local acct
    acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    if [[ "$acct" != "$EXPECTED_ACCOUNT" ]]; then
        echo "ERROR: AWS account is '${acct:-unknown}', expected $EXPECTED_ACCOUNT. Aborting." >&2
        exit 1
    fi
    echo "AWS account verified: $acct"
}

describe_port() {  # $1=port -> JSON array of that port's IpRanges
    aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$1\`].IpRanges[]" --output json
}

# --- --status: show current rules and exit (read-only) ---
if $STATUS_ONLY; then
    echo "Current ingress for $SG_ID ($REGION):"
    for PORT in "${PORTS[@]}"; do
        echo "  port $PORT:"
        describe_port "$PORT" | jq -r '.[] | "    " + .CidrIp + "  (" + (.Description // "") + ")"'
    done
    exit 0
fi

# --- discover operator IP (fail hard if it cannot be resolved) ---
MY_IP="$(curl -4 -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
if ! validate_cidr "$MY_IP"; then
    echo "ERROR: discovered operator IP is not a valid /24-or-narrower CIDR: '$MY_IP'" >&2; exit 1
fi

# desired "CIDR<TAB>DESC" lines for a port (operator on all; validated team IPs on telemetry ports)
desired_for_port() {
    local port="$1"
    printf '%s\t%s\n' "$MY_IP" "operator: $(port_desc "$port")"
    if [[ "$TELEMETRY_PORTS" == *" $port "* && -f "$TEAM_FILE" ]]; then
        { grep -vE '^[[:space:]]*(#|$)' "$TEAM_FILE" || true; } | while read -r ip desc; do
            [[ "$ip" == */* ]] || ip="$ip/32"
            if validate_cidr "$ip" >/dev/null 2>&1; then
                printf '%s\t%s\n' "$ip" "team: ${desc:-teammate}"
            else
                echo "  ! skipping invalid team-ips.txt entry: $ip" >&2
            fi
        done
    fi
}

verify_account   # before ANY mutation

echo "Operator IP: $MY_IP"
$DRY_RUN && echo "(dry-run: no changes will be applied)"
echo "Reconciling $SG_ID ..."

for PORT in "${PORTS[@]}"; do
    DESIRED="$(desired_for_port "$PORT")"
    DESIRED_CIDRS="$(printf '%s\n' "$DESIRED" | cut -f1 | sort -u)"
    CURRENT_JSON="$(describe_port "$PORT")"
    CURRENT_CIDRS="$(printf '%s' "$CURRENT_JSON" | jq -r '.[].CidrIp' | sort -u)"

    TO_ADD="$(comm -13 <(printf '%s\n' "$CURRENT_CIDRS") <(printf '%s\n' "$DESIRED_CIDRS"))"
    TO_REVOKE="$(comm -23 <(printf '%s\n' "$CURRENT_CIDRS") <(printf '%s\n' "$DESIRED_CIDRS"))"

    # 1) AUTHORIZE new rules first (never leave the operator without access).
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        d="$(printf '%s\n' "$DESIRED" | awk -F'\t' -v c="$cidr" '$1==c{print $2; exit}')"
        d="${d//\"/}"   # strip double quotes so they can't break the --ip-permissions string
        if $DRY_RUN; then echo "  [$PORT] + would authorize $cidr ($d)"; continue; fi
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
            --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$cidr,Description=\"$d\"}]" >/dev/null
        echo "  [$PORT] authorized $cidr ($d)"
    done <<< "$TO_ADD"

    # 2) VERIFY new rules are present BEFORE revoking anything on this port.
    if ! $DRY_RUN && [[ -n "$TO_ADD" ]]; then
        NOW_CIDRS="$(describe_port "$PORT" | jq -r '.[].CidrIp' | sort -u)"
        while read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if ! grep -qxF "$cidr" <<< "$NOW_CIDRS"; then
                echo "ERROR: authorized $cidr on $PORT but it is not present — NOT revoking anything on this port." >&2
                continue 2   # skip revoke step for this port
            fi
        done <<< "$TO_ADD"
    fi

    # 3) REVOKE stale rules (only after new ones are confirmed).
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        d="$(printf '%s' "$CURRENT_JSON" | jq -r --arg c "$cidr" '.[]|select(.CidrIp==$c)|.Description // ""' | head -1)"
        d="${d//\"/}"   # strip double quotes so they can't break the --ip-permissions string
        if $DRY_RUN; then echo "  [$PORT] - would revoke $cidr"; continue; fi
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
            --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$cidr,Description=\"$d\"}]" >/dev/null
        echo "  [$PORT] revoked $cidr"
    done <<< "$TO_REVOKE"
done

$DRY_RUN && echo "Dry-run complete (no changes applied)." || echo "Done."
