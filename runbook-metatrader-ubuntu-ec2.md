# Runbook: MetaTrader on Ubuntu Desktop (EC2) — Fully Automated

## Overview
Deploy Ubuntu Desktop instances running MetaTrader 4 via Wine, accessible over RDP.
Everything is automated — deploy script handles infra, cloud-init handles software.
Schedule: 23 hours/day × 5 days/week (Mon-Fri). On-Demand with automated start/stop.

## Cost Estimate (us-east-1)

| Strategy | Per Instance | 4 Instances | Notes |
|----------|-------------|-------------|-------|
| On-Demand 24/7 | $29.84 | $119.38 | Baseline |
| On-Demand 23×5 (scheduled) | $21.13 | $84.50 | Stop 1hr/day + weekends |
| **Savings Plan 1yr no-upfront + 23×5** | **~$14.38** | **~$57.54** | Best balance |
| Savings Plan 1yr all-upfront + 23×5 | ~$12.99 | ~$51.94 | Max savings |

> t3a.medium (2 vCPU, 4 GiB, AMD EPYC) + 30 GB gp3 EBS per instance.

---

## Step 1: Deploy

The deploy script handles everything end-to-end: AMI lookup, key pair, security group, instance launch, cloud-init wait, service verification, and auto-retry if setup fails.

```bash
# Test — 1 instance
./deploy-test.sh

# Production — 4 instances
./deploy-test.sh 4
```

The script will block until cloud-init completes and print ✅ when ready. If cloud-init hits a transient error (e.g., Ubuntu mirror 404), the script automatically re-runs setup via SSH. No manual intervention needed.

What it creates:
- Key pair `mt-trader-key` (saved to `~/mt-trader-key.pem`)
- Security group `mt-trader-sg` (RDP + SSH from your current IP)
- Ubuntu 24.04 instance(s) with cloud-init running `setup.sh`

What cloud-init installs (setup.sh):
- XFCE desktop + xrdp
- Wine (stable, with retry on transient apt failures)
- Firefox
- MetaTrader 4 (silent install + autostart on login)
- `trader` user with RDP access

Once you see ✅, RDP in immediately:
- User: `trader`
- Password: `ChangeMeNow2026!`

---

## Step 2: Automated 23×5 Schedule (EventBridge + Lambda)

Saves ~32% vs running 24/7 by stopping instances during a 1-hour daily window and all weekend.

### 2a. Create IAM Role for Lambda

```bash
cat > /tmp/lambda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role --role-name mt-scheduler-role \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam put-role-policy --role-name mt-scheduler-role \
  --policy-name ec2-startstop \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Action":["ec2:StartInstances","ec2:StopInstances","ec2:DescribeInstances"],
      "Resource":"*",
      "Condition":{"StringEquals":{"ec2:ResourceTag/Project":"metatrader"}}
    },{"Effect":"Allow","Action":"logs:*","Resource":"*"}]
  }'
```

### 2b. Lambda Function

```bash
cat > /tmp/lambda_function.py << 'PYEOF'
import boto3

EC2 = boto3.client("ec2")
FILTER = [{"Name": "tag:Project", "Values": ["metatrader"]}]

def lambda_handler(event, context):
    action = event.get("action")
    ids = [i["InstanceId"] for r in EC2.describe_instances(Filters=FILTER)["Reservations"] for i in r["Instances"]]
    if not ids:
        return "No instances found"
    if action == "start":
        EC2.start_instances(InstanceIds=ids)
    elif action == "stop":
        EC2.stop_instances(InstanceIds=ids)
    return f"{action}: {ids}"
PYEOF

cd /tmp && zip lambda.zip lambda_function.py

ROLE_ARN=$(aws iam get-role --role-name mt-scheduler-role --query 'Role.Arn' --output text)

# Wait for role propagation
sleep 10

aws lambda create-function --function-name mt-scheduler \
  --runtime python3.12 --handler lambda_function.lambda_handler \
  --role $ROLE_ARN --zip-file fileb:///tmp/lambda.zip --timeout 30
```

### 2c. EventBridge Schedules

Adjust cron times to your trading hours. Example: Mon-Fri, start 00:00 UTC, stop 23:00 UTC:

```bash
LAMBDA_ARN=$(aws lambda get-function --function-name mt-scheduler --query 'Configuration.FunctionArn' --output text)

# Start: Monday-Friday at 00:00 UTC
aws events put-rule --name mt-start \
  --schedule-expression "cron(0 0 ? * MON-FRI *)"
aws events put-targets --rule mt-start --targets "[{
  \"Id\":\"start\",\"Arn\":\"$LAMBDA_ARN\",
  \"Input\":\"{\\\"action\\\":\\\"start\\\"}\"
}]"

# Stop: Monday-Friday at 23:00 UTC
aws events put-rule --name mt-stop \
  --schedule-expression "cron(0 23 ? * MON-FRI *)"
aws events put-targets --rule mt-stop --targets "[{
  \"Id\":\"stop\",\"Arn\":\"$LAMBDA_ARN\",
  \"Input\":\"{\\\"action\\\":\\\"stop\\\"}\"
}]"

# Grant EventBridge → Lambda permissions
aws lambda add-permission --function-name mt-scheduler \
  --statement-id mt-start --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn $(aws events describe-rule --name mt-start --query 'Arn' --output text)

aws lambda add-permission --function-name mt-scheduler \
  --statement-id mt-stop --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn $(aws events describe-rule --name mt-stop --query 'Arn' --output text)
```

---

## Step 3: Savings Plan (Optional)

Purchase via Console → Cost Management → Savings Plans:
- Type: **Compute Savings Plan**
- Term: 1 year
- Payment: No upfront (~36% off) or All upfront (~43% off)
- Hourly commitment: ~$0.096 (covers 4 × t3a.medium)

---

## Step 4: Security Hardening

- [ ] Change `trader` password: `ssh -i ~/mt-trader-key.pem ubuntu@<IP> 'sudo chpasswd <<< "trader:<your-password>"'`
- [ ] Update SG if your IP changes: `aws ec2 authorize-security-group-ingress --group-id <SG_ID> --protocol tcp --port 3389 --cidr <NEW_IP>/32`
- [ ] Consider SSM port forwarding (no public IP needed):
  ```bash
  aws ssm start-session --target i-xxxxx \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["3389"],"localPortNumber":["3389"]}'
  ```

---

## Quick Reference

| Task | Command |
|------|---------|
| Deploy test (1) | `./deploy-test.sh` |
| Deploy prod (4) | `./deploy-test.sh 4` |
| RDP connect | `xfreerdp /v:<IP> /u:trader /p:ChangeMeNow2026! /size:1920x1080` |
| SSH in | `ssh -i ~/mt-trader-key.pem ubuntu@<IP>` |
| Manual start all | `aws ec2 start-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Project,Values=metatrader" "Name=instance-state-name,Values=stopped" --query 'Reservations[].Instances[].InstanceId' --output text)` |
| Manual stop all | `aws ec2 stop-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Project,Values=metatrader" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text)` |
| Terminate all | `aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Project,Values=metatrader" --query 'Reservations[].Instances[].InstanceId' --output text)` |
| Check schedule | `aws events list-rules --name-prefix mt-` |
| MT4 path | `~/.wine/drive_c/Program Files (x86)/MetaTrader 4/` |
