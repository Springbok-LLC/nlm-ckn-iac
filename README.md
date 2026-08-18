# nlm-ckn-iac

CloudFormation infrastructure and deployment scripts for the NLM-CKN project,
consolidated from `nlm-ckn-ui` and `nlm-ckn-etl` into one repo (with commit
history preserved from both). Organized by service/component rather than by
"cloudformation/" vs "scripts/", so each AWS-deployable unit is self-contained.

Application code lives elsewhere:
- [nlm-ckn-ui](https://github.com/Springbok-LLC/nlm-ckn-ui) — Django backend + React frontend
- [nlm-ckn-etl](https://github.com/Springbok-LLC/nlm-ckn-etl) — data pipeline

Those repos keep their own `scripts/app/` build-and-ship scripts — including
`nlm-ckn-ui/scripts/sandbox/`, which promotes application code/data to the
NIH sandbox account and isn't a CloudFormation deploy, so it stays there too.
Everything here only talks to them through the CloudFormation API
(`describe-stacks`, `list-exports`) or SSM — never by reading files across
repos.

## Directory structure

All deploy scripts live together in `deploy/`, numbered by the order they need
to run — same number means they don't depend on each other and can run in
parallel. `environment/` holds the per-environment infrastructure — the shared
platform tier + service stacks (for `dev`/`stage`) plus a self-contained
`sandbox/` for the NIH sandbox account; `prod` is managed by the NIH team
outside this repo. `manual/` holds out-of-band stacks with no deploy wrapper
(deployed by hand, rarely). Templates and non-deploy operator scripts
(tunnels/dashboards) stay organized by service/component within those roots.

```
nlm-ckn-iac/
├── deploy/                            # All deploy scripts, numbered by dependency wave
│   ├── 01-deploy-account-setup.sh     # wave 1: bootstrap + shared + static-assets (once per account)
│   ├── 02-deploy-environment.sh       # wave 2: platform tier + frontend/arangodb/backend
│   ├── 02-deploy-fetch.sh             # wave 2: etl ECR + fetch (parallel with the above)
│   ├── 03-deploy-batch.sh             # wave 3: etl batch (needs 02-deploy-fetch's outputs)
│   └── 03-deploy-monitoring.sh        # wave 3: needs 02-deploy-environment's outputs
├── account/            # One-time per-AWS-account setup: S3 buckets, GitHub OIDC, IAM role
│   └── cloudformation/bootstrap.yaml
├── shared/              # Cross-environment resources: ECR repo, ArangoDB dataset S3 bucket
│   └── cloudformation/
│       ├── shared-resources.yaml   # ECR repo + ArangoDB dataset S3 bucket
│       └── static-assets.yaml      # Plot asset S3 bucket + nlm-ckn GitHub OIDC push role
├── environment/          # Per-environment infra: dev/stage here; sandbox separate; prod is NIH-managed
│   ├── parameters/{dev,stage,stage-vpc}.json
│   ├── platform/         # Shared dev/stage infra tier (secrets, security groups,
│   │                     # ECS cluster, Cloud Map, ALB) plus the main.yaml orchestrator
│   │   └── cloudformation/{main,secrets,security-groups,ecs-cluster,service-discovery,alb}.yaml
│   ├── services/                                       # Shared dev/stage service stacks
│   │   ├── frontend/cloudformation/frontend.yaml       # S3 + CloudFront + ACM
│   │   ├── backend/cloudformation/backend.yaml         # ECS service, auto-scaling
│   │   ├── arangodb/cloudformation/arangodb.yaml       # EC2 + EBS instance
│   │   └── monitoring/                                 # Wedge-detection / CloudWatch alarms
│   │       ├── cloudformation/monitoring.yaml
│   │       └── scripts/{create-monitor-user,put-dashboard}.sh
│   └── sandbox/          # NIH sandbox account: separate, self-contained CFN, deployed on its own
│       └── cloudformation/                             # (prod infra is managed by NIH, outside this repo)
├── etl/                 # From nlm-ckn-etl: ECR, NCBI fetch, and Batch release stacks
│   └── cloudformation/{ecr,fetch,batch,github-oidc}.yaml
├── manual/               # Out-of-band stacks, deployed by hand, no deploy/ wrapper
│   ├── network/          # VPC (mostly unused — VPC/subnets are normally NIH-provided params)
│   │   └── cloudformation/vpc.yaml
│   └── redirect/         # Standalone CloudFront redirect (cell-kn.org/nlm-ckn.org → stage)
│       ├── cloudformation/redirect.yaml
│       └── parameters.json
├── ops/                  # Cross-cutting operator scripts
│   └── scripts/smoke-test.sh
└── docs/                 # Cutover runbook (old cell-kn → nlm-ckn)
```

Two areas have their own architecture docs, each with a diagram of what it
provisions and how the pieces connect:

- [`environment/README.md`](environment/README.md) — the running-application
  tier (CloudFront, ALB, ECS backend, EC2 ArangoDB, and the platform stacks).
- [`etl/README.md`](etl/README.md) — the data pipeline (scheduled Fargate fetch
  and the AWS Batch release job that publishes the ArangoDB dataset).

## Deployment order

- **Wave 1** — `./deploy/01-deploy-account-setup.sh` — once per AWS account (bootstrap, shared, static-assets)
- **Wave 2** (parallel) — `./deploy/02-deploy-environment.sh <env>` (platform tier, then frontend/arangodb/backend service stacks) and `./deploy/02-deploy-fetch.sh` (etl ECR + fetch)
- **Wave 3** (parallel) — `./deploy/03-deploy-batch.sh` (needs the fetch stack), `./deploy/03-deploy-monitoring.sh <env>` (needs the environment stack, optional)
- Then, in `nlm-ckn-ui`: `./scripts/app/deploy-backend.sh`, `deploy-frontend.sh`, `deploy-dataset.sh` to ship application code onto the provisioned infrastructure (dev/stage), or `./scripts/sandbox/deploy-sandbox.sh` for the sandbox account

Three stacks fall outside the numbered waves entirely — rare, manual, singleton
operations rather than routine per-account/per-env provisioning. Two of them
live under `manual/`, which holds exactly this kind of out-of-band stack (no
`deploy/` wrapper):

- `etl/cloudformation/github-oidc.yaml` has no wrapper script (deployed
  manually, once per account — see its own header for the command); run it
  whenever GitHub Actions needs a new/updated OIDC role.
- `manual/network/cloudformation/vpc.yaml` — an alternative to an NIH-provided
  VPC, currently only used for `stage`. Deployed manually per
  [`environment/parameters/stage-vpc.md`](environment/parameters/stage-vpc.md);
  its outputs (`VpcId`, subnet IDs, `VpcCidr`) feed into
  `environment/parameters/<env>.json` before running Wave 2.
- `manual/redirect/cloudformation/redirect.yaml` — account-wide singleton
  CloudFront redirect (`cell-kn.org`/`nlm-ckn.org` → stage). Deployed manually
  per [`manual/redirect/README.md`](manual/redirect/README.md), once a Wave-2
  environment (currently `stage`) is already serving the redirect target and
  an ACM cert covering both apex domains exists.

See [deploy/README.md](deploy/README.md) for the deploy-script reference — the deployment waves, what each stack depends on, and how each one is run.

## Migrating from the old `cell-kn` deployment

This repo deploys `nlm-ckn`-named resources (`ProjectName=nlm-ckn`). The project
was originally deployed under the old name `cell-kn`; replacing that deployment
is a parallel-stack cutover — deploy the new `nlm-ckn-*` stacks alongside the
old ones, verify, switch traffic, then decommission. See the step-by-step
runbook in [docs/cutover-to-nlm-ckn.md](docs/cutover-to-nlm-ckn.md).

## Prerequisites

- AWS CLI configured with appropriate credentials
- `cfn-lint` (optional, used by `deploy-environment.sh` if present)
