#!/bin/bash
set -euo pipefail

REGION="us-east-1"
KEY_NAME="mt-trader-key"
INSTANCE_TYPE="t3a.medium"
COUNT="${1:-1}"  # default 1, pass 4 for production
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS=()

echo "=== Deploying $COUNT MetaTrader instance(s) ==="

echo "=== Step 1: Get latest Ubuntu 24.04 AMI ==="
AMI_ID=$(aws ec2 describe-images --region $REGION \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"

echo "=== Step 2: Create/reuse security group ==="
VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=group-name,Values=mt-trader-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --region $REGION \
    --group-name mt-trader-sg \
    --description "MetaTrader RDP access" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id $SG_ID --protocol tcp --port 3389 --cidr $MY_IP
  aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id $SG_ID --protocol tcp --port 22 --cidr $MY_IP
  echo "SG created: $SG_ID (allowed $MY_IP)"
else
  echo "SG reused: $SG_ID"
fi

echo "=== Step 3: Create/reuse key pair ==="
if ! aws ec2 describe-key-pairs --region $REGION --key-names $KEY_NAME &>/dev/null; then
  aws ec2 create-key-pair --region $REGION --key-name $KEY_NAME \
    --query 'KeyMaterial' --output text > ~/${KEY_NAME}.pem
  chmod 400 ~/${KEY_NAME}.pem
  echo "Key created: ~/${KEY_NAME}.pem"
else
  echo "Key reused: $KEY_NAME"
fi

echo "=== Step 4: Launch $COUNT instance(s) ==="
INSTANCE_IDS=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --count $COUNT \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mt-trader},{Key=Project,Value=metatrader}]' \
  --user-data "file://${SCRIPT_DIR}/setup.sh" \
  --query 'Instances[].InstanceId' --output text)
echo "Instances: $INSTANCE_IDS"

echo "=== Step 5: Wait for running ==="
aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_IDS

echo "=== Step 6: Wait for cloud-init to finish ==="
for IID in $INSTANCE_IDS; do
  PUBLIC_IP=$(aws ec2 describe-instances --region $REGION \
    --instance-ids $IID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

  echo "Waiting for cloud-init on $IID ($PUBLIC_IP)..."

  # Wait for SSH to be ready
  for i in $(seq 1 30); do
    ssh -i ~/${KEY_NAME}.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      ubuntu@${PUBLIC_IP} 'true' 2>/dev/null && break
    sleep 10
  done

  # Wait for cloud-init to complete (up to 15 min)
  ssh -i ~/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${PUBLIC_IP} \
    'cloud-init status --wait' 2>/dev/null || true

  # Verify key services
  STATUS=$(ssh -i ~/${KEY_NAME}.pem ubuntu@${PUBLIC_IP} \
    'echo "cloud-init: $(cloud-init status 2>/dev/null | awk "{print \$2}")"; \
     echo "xrdp: $(systemctl is-active xrdp 2>/dev/null)"; \
     echo "trader: $(id trader &>/dev/null && echo ok || echo missing)"; \
     echo "wine: $(which wine &>/dev/null && echo ok || echo missing)"; \
     echo "firefox: $(which firefox &>/dev/null && echo ok || echo missing)"' 2>/dev/null)

  echo "$STATUS"

  # If cloud-init errored, re-run setup
  if echo "$STATUS" | grep -q "xrdp: inactive\|wine: missing"; then
    echo "⚠️  Incomplete setup detected on $IID — re-running setup.sh..."
    ssh -i ~/${KEY_NAME}.pem ubuntu@${PUBLIC_IP} \
      'sudo bash -s' < "${SCRIPT_DIR}/setup.sh" 2>/dev/null
    echo "Re-run complete."
  fi

  RESULTS+=("$IID → $PUBLIC_IP")
done

echo ""
echo "============================================"
for R in "${RESULTS[@]}"; do
  IP="${R##* }"
  echo "  $R"
  echo "    RDP: ${IP}:3389 (user: trader / pass: ChangeMeNow2026!)"
  echo ""
done
echo "  ✅ Ready — RDP in now."
echo "============================================"
