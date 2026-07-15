#!/bin/bash
# update-sg.sh — updates AWS security group with current public IP
# For OPS-235 telemetry VM (ops-claude-code-telemetry)

SG_ID="sg-0c10615c3983e2f47"
PORTS=(22 3000 4317 4318)
MY_IP=$(curl -s ifconfig.me)/32

echo "Current IP: $MY_IP"
echo "Updating security group: $SG_ID"

for PORT in "${PORTS[@]}"; do
    # Remove old rules for this port
    OLD_IPS=$(aws ec2 describe-security-groups --group-ids $SG_ID \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$PORT\`].IpRanges[].CidrIp" \
        --output text --region us-east-1)
    for OLD_IP in $OLD_IPS; do
        aws ec2 revoke-security-group-ingress --group-id $SG_ID \
            --protocol tcp --port $PORT --cidr $OLD_IP --region us-east-1 2>/dev/null
        echo "  Removed $OLD_IP from port $PORT"
    done
    # Add current IP
    aws ec2 authorize-security-group-ingress --group-id $SG_ID \
        --protocol tcp --port $PORT --cidr $MY_IP --region us-east-1
    echo "  Added $MY_IP to port $PORT"
done

echo "Done. All ports updated to $MY_IP"
