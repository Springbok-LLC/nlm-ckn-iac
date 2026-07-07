# Deployment Scripts

Carried over from `nlm-ckn-ui/scripts/README.md` when the CloudFormation
templates and infrastructure scripts moved into this repo. The **Infrastructure
Scripts** and **Operations Scripts** sections below describe scripts that now
live here. The **Application Scripts** section describes scripts that stayed in
`nlm-ckn-ui` (they ship code to already-provisioned infrastructure and call
this repo's stacks only via the CloudFormation API, e.g. `describe-stacks`)
— kept here for context but paths under `scripts/app/` are relative to that repo.

```
nlm-ckn-iac/
  deploy/                            # all deploy scripts, numbered by dependency wave
  environment/services/*/scripts/    # per-service operator scripts (not deploys)
  ops/scripts/                       # cross-cutting operator scripts
```

Sandbox-account promotion (`deploy-sandbox.sh`, `alb-tunnel.sh`, `resolve-env.sh`)
isn't in this repo — it's application-promotion tooling (plain-docker-on-EC2 via
SSM, not a CloudFormation deploy), so it stays in `nlm-ckn-ui/scripts/sandbox/`.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Docker installed and running (for backend deployment)
- Node.js and npm installed (for frontend deployment)
- CloudFormation infrastructure deployed

## Infrastructure Scripts (`deploy/`)

These scripts create or update AWS infrastructure via CloudFormation. Run them when provisioning a new environment or changing infrastructure resources.

### `01-deploy-account-setup.sh` - Account Setup
```bash
./deploy/01-deploy-account-setup.sh
```

One-time setup per AWS account. Creates the S3 template bucket, GitHub Actions OIDC role, ECR repository, and ArangoDB dataset S3 bucket.

### `02-deploy-environment.sh` - Environment Stack
```bash
./deploy/02-deploy-environment.sh <environment>
```

Deploys the complete environment (dev/staging/prod) with all nested stacks. See script header for details.

## Application Scripts (`scripts/app/` in `nlm-ckn-ui`)

These scripts build and deploy application code to existing infrastructure. Use these for routine code releases — no CloudFormation changes. They live in the `nlm-ckn-ui` repo, not here.

### `app/deploy-backend.sh` - Backend Application
```bash
./scripts/app/deploy-backend.sh <environment>
```

Builds and pushes backend Docker image to ECR, updates ECS service.

### `app/deploy-frontend.sh` - Frontend Application
```bash
./scripts/app/deploy-frontend.sh <environment>
```

Builds React app and deploys to S3/CloudFront.

### `app/deploy-dataset.sh` - ArangoDB Dataset
```bash
./scripts/app/deploy-dataset.sh <environment> <s3-key>
```

Deploys ArangoDB dataset version. Example: `./scripts/app/deploy-dataset.sh dev datasets/2024-02-17-v1.2.3.tar.gz`

### `app/deploy-all.sh` - Full Application Deployment
```bash
./scripts/app/deploy-all.sh
```

Deploys both backend and frontend in sequence.

### `app/push-backend-image.sh` - Push Backend Image Only
```bash
./scripts/app/push-backend-image.sh
```

Builds and pushes the backend Docker image without updating the ECS service. Useful before the first environment deploy.

## Operations Scripts

### ArangoDB monitoring + wedge detection (`environment/services/monitoring/scripts/`)

Follow-up #2 from the 2026-06-15 stage outage postmortem (tracked in
[Springbok-LLC/upptime#2](https://github.com/Springbok-LLC/upptime/issues/2)).
That outage's earliest signal was failed `deploy-stage` SSM steps **before**
upptime caught the user-facing 504 — the host's userspace had wedged (SSM
`ConnectionLost`, CloudWatch agent silent) while EC2 status checks stayed
`ok/ok` and the running container kept serving. These tools add the two signals
that were missing.

```bash
# 1. Deploy the monitoring stack (shows a changeset; operator executes it)
AWS_PROFILE=springbok ./deploy/03-deploy-monitoring.sh stage
# optional: ALARM_EMAIL=you@example.com AUTO_REMEDIATE=false SCHEDULE_EXPRESSION='rate(1 minute)'

# 2. Create the read-only ArangoDB monitoring user (over SSM; do NOT use root)
AWS_PROFILE=springbok ./environment/services/monitoring/scripts/create-monitor-user.sh stage

# 3. Add the cache + wedge widgets to the correlation dashboard
AWS_PROFILE=springbok ./environment/services/monitoring/scripts/put-dashboard.sh stage
```

What the stack (`nlm-ckn-<env>-monitoring`,
[monitoring.yaml](../environment/services/monitoring/cloudformation/monitoring.yaml)) deploys:

- **MetricsScraper** (in-VPC Lambda) — scrapes ArangoDB `/_admin/metrics/v2`
  on `arangodb.nlm-ckn-<env>.local:8529` and pushes leading-signal RocksDB
  series to CloudWatch `CellKN/ArangoDB`
  (`rocksdb_cache_hit_rate_recent`, `rocksdb_block_cache_usage`/`_capacity`,
  `arangodb_search_columns_cache_size`). A sustained drop in recent hit rate is
  the early "cold/slow DB" warning. Authenticates as the read-only `monitor`
  user (password in Secrets Manager at
  `/nlm-ckn/<env>/secrets/arangodb-monitor-password`).
- **WedgeDetector** (Lambda) — every minute flags the outage signature: SSM
  `PingStatus = ConnectionLost` **while** EC2 status checks are `ok/ok`. Emits
  `CellKN/Monitoring` metrics + an SNS alert. Auto-remediation
  (`ec2 reboot-instances`) is gated behind `AutoRemediate` and **defaults off**.
- **Alarms** — `…-arango-host-wedge` (page on the wedge signature) and
  `…-arango-cache-hit-rate-low` (early cold-cache warning). Plus conservative
  host-resource defaults `…-arango-host-cpu-high` and `…-arango-host-memory-high`
  (avg ≥ 90% sustained 15 min; thresholds overridable via `CpuAlarmThreshold` /
  `MemoryAlarmThreshold`). These need the arango `InstanceId`, which the deploy
  script resolves automatically — but the id changes on instance replacement, so
  **re-run `deploy-monitoring.sh` after any arango stack change** to re-point
  them (same model as `put-dashboard.sh`). Also `…-alb-5xx-high` (ALB-generated
  5XX/504 count — the user-facing symptom from the outage) and
  `…-alb-response-time-high` (target response time p90 sustained); both
  overridable via `Alb5xxAlarmThreshold` / `AlbResponseTimeAlarmThreshold`. The
  ALB dimension is stable across deploys, so these don't need re-pointing — the
  deploy script resolves it from the `nlm-ckn-<env>-alb` load balancer (skipped
  if there's no ALB).
- **Shared alert topic** (`nlm-ckn-<env>-alerts`) — the environment's
  general-purpose reporting topic, not wedge-only. Both alarms above publish to
  it, and other stacks can route their own alarms here by importing
  `nlm-ckn-<env>-monitoring-alert-topic-arn` and adding it to their
  `AlarmActions`. Its topic policy authorises CloudWatch and EventBridge in the
  account to publish, e.g.:

  ```yaml
  SomeAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      # ...
      AlarmActions:
        - !ImportValue
            Fn::Sub: '${ProjectName}-${Environment}-monitoring-alert-topic-arn'
  ```

Adding the ingress rule to the ArangoDB SG consumes one SG rule slot — note the
near-quota state of the non-dev ArangoDB SG. The stack is **not** wired into
`main.yaml`; deploy it explicitly per the steps above.

## Deployment Order

### Initial Setup
```bash
# 1. Account setup (one-time per AWS account)
./deploy/01-deploy-account-setup.sh

# 2. Push initial backend image (before first environment deploy)
./scripts/app/push-backend-image.sh

# 3. Configure parameters
cp environment/parameters/dev.json.example environment/parameters/dev.json
# Edit environment/parameters/dev.json

# 4. Deploy environment infrastructure
./deploy/02-deploy-environment.sh dev

# 5. Deploy applications
./scripts/app/deploy-all.sh
```

### Subsequent Deployments
```bash
# Deploy only what changed
./scripts/app/deploy-backend.sh dev   # Backend only
./scripts/app/deploy-frontend.sh dev  # Frontend only
./scripts/app/deploy-dataset.sh dev datasets/new.tar.gz  # Dataset only
```

## Documentation

All scripts have comprehensive headers with:
- Usage instructions
- What it does (step-by-step)
- Prerequisites
- Examples
- Troubleshooting tips

View any script header: `head -50 scripts/app/deploy-backend.sh`

**For more information:**
- Deployment guide: `docs/DEPLOYMENT.md`
- CloudFormation infrastructure: `docs/cloudformation-overview.md`
