# MetaTrader on Ubuntu Desktop (EC2)

Fully automated deployment of Ubuntu Desktop instances running MetaTrader 4 via Wine, accessible over RDP.

## What You Get

- Ubuntu 24.04 + XFCE desktop accessible via RDP
- Wine (stable) with MetaTrader 4 auto-installed
- Firefox browser
- Dedicated `trader` user with auto-login to MT4
- Idempotent deploy script (safe to re-run)
- Auto-verification — script waits for setup and retries on failure

## Quick Start

```bash
# Deploy 1 test instance
./deploy-test.sh

# Deploy 4 production instances
./deploy-test.sh 4
```

The script handles everything: AMI lookup, key pair, security group, instance launch, cloud-init wait, and service verification. When you see ✅, RDP in:

```bash
xfreerdp /v:<PUBLIC_IP> /u:trader /p:ChangeMeNow2026! /size:1920x1080
```

## Files

| File | Purpose |
|------|---------|
| `deploy-test.sh` | One-command deploy (handles infra + waits for setup) |
| `setup.sh` | Cloud-init script (desktop, Wine, Firefox, MT4, user) |
| `runbook-metatrader-ubuntu-ec2.md` | Full runbook with cost estimates and scheduling |

## Cost Estimate (us-east-1, t3a.medium)

| Strategy | Per Instance | 4 Instances |
|----------|-------------|-------------|
| On-Demand 24/7 | $29.84/mo | $119.38/mo |
| On-Demand 23×5 (scheduled) | $21.13/mo | $84.50/mo |
| + 1yr Savings Plan (no upfront) | ~$14.38/mo | ~$57.54/mo |

## Prerequisites

- AWS CLI configured with appropriate permissions
- Bash shell
- An AWS account with EC2 access in us-east-1

## Security Notes

- Change the default `trader` password before production use
- Security group restricts RDP/SSH to your current public IP
- Consider SSM port forwarding to avoid exposing RDP publicly

See the [full runbook](runbook-metatrader-ubuntu-ec2.md) for EventBridge scheduling and Savings Plan details.
