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
parallel. `environment/` holds everything provisioned once per environment
(platform tier + service stacks + their parameter files); `manual/` holds
out-of-band stacks with no deploy wrapper (deployed by hand, rarely). Templates
and non-deploy operator scripts (tunnels/dashboards) stay organized by
service/component within those roots.

```
nlm-ckn-iac/
├── deploy/                            # All deploy scripts, numbered by dependency wave
│   ├── 01-deploy-account-setup.sh     # wave 1: bootstrap + shared (once per account)
│   ├── 02-deploy-environment.sh       # wave 2: platform tier + frontend/arangodb/backend
│   ├── 02-deploy-fetch.sh             # wave 2: etl ECR + fetch (parallel with the above)
│   ├── 03-deploy-batch.sh             # wave 3: etl batch (needs 02-deploy-fetch's outputs)
│   └── 03-deploy-monitoring.sh        # wave 3: needs 02-deploy-environment's outputs
├── account/            # One-time per-AWS-account setup: S3 buckets, GitHub OIDC, IAM role
│   └── cloudformation/bootstrap.yaml
├── shared/              # Cross-environment resources: ECR repo, ArangoDB dataset S3 bucket
│   └── cloudformation/shared-resources.yaml
├── environment/          # Everything provisioned once per environment (dev/stage/sandbox/prod)
│   ├── parameters/{dev,stage,stage-vpc}.json
│   ├── platform/         # Per-environment infra tier (secrets, security groups, ECS cluster,
│   │                     # Cloud Map, ALB) plus the main.yaml orchestrator
│   │   └── cloudformation/{main,secrets,security-groups,ecs-cluster,service-discovery,alb}.yaml
│   └── services/
│       ├── frontend/cloudformation/frontend.yaml       # S3 + CloudFront + ACM
│       ├── backend/cloudformation/backend.yaml         # ECS service, auto-scaling
│       ├── arangodb/cloudformation/arangodb.yaml       # EC2 + EBS instance
│       └── monitoring/                                 # Wedge-detection / CloudWatch alarms
│           ├── cloudformation/monitoring.yaml
│           └── scripts/{create-monitor-user,put-dashboard}.sh
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
└── docs/                 # Carried-over deployment/troubleshooting notes (see below)
```

## Deployment order

- **Wave 1** — `./deploy/01-deploy-account-setup.sh` — once per AWS account
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

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full walkthrough (including NIH sandbox/prod account restrictions) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues.

## Naming: still `cell-kn`, pending rename to `nlm-ckn`

The project renamed from Cell-KN to NLM-CKN, but the UI-side stacks were
originally deployed under the old name — every template already
parameterizes on `ProjectName`, but scripts and `environment/parameters/*.json`
still hardcode `"cell-kn"`. `DomainName` is already `nlm-ckn.org`, so DNS is
unaffected. Since S3 bucket names and stack names can't be renamed in place,
this is a parallel-stack cutover, not an in-place edit. The ETL-side stacks
themselves (`nlm-ckn-etl-*`, `nlm-ckn-fetch`, `nlm-ckn-release`) are already
named `nlm-ckn-*` and don't need renaming — but they still need attention
below because they consume a resource (the shared dataset bucket) that *is*
moving.

Checklist, in order:

1. **Deploy the new account/shared/platform stacks** under `ProjectName=nlm-ckn`
   (`deploy/01-deploy-account-setup.sh`, then
   `deploy/02-deploy-environment.sh <env>`) — this creates a *new* S3
   templates bucket, state bucket, and ArangoDB dataset bucket
   (`nlm-ckn-arangodb-data-<account-id>`) alongside the existing `cell-kn-*`
   ones; nothing old is touched yet.
2. **Update `PROJECT_NAME="cell-kn"` to `"nlm-ckn"`** in the `nlm-ckn-ui`
   app scripts (`scripts/app/*.sh`) and in this repo's own scripts/parameter
   files, and update the CI `role-to-assume` ARN
   (`cell-kn-github-actions` → `nlm-ckn-github-actions`).
3. **Redeploy the ETL stacks with the new bucket.** `etl/cloudformation/{batch,fetch,github-oidc}.yaml`
   resolve their S3 bucket from an SSM parameter (`AWS::SSM::Parameter::Value<String>`,
   see `S3Bucket`/`S3BucketName` in those templates) rather than a
   hand-typed name, specifically so this step is a one-line change: update
   each template's `Default` from `/cell-kn/shared/arangodb-bucket-name` to
   `/nlm-ckn/shared/arangodb-bucket-name`, then redeploy
   (`deploy/03-deploy-batch.sh`, `deploy-fetch.sh`, and `github-oidc.yaml`
   manually per its own header). This is still a manual, deliberate step —
   CloudFormation only re-resolves the SSM value at deploy time, and only
   once you're pointed at the new parameter name.
4. **Verify, then cut over** DNS/ALB traffic to the new environment stack,
   smoke test, and only then decommission the `cell-kn-*` stacks (including
   the old dataset bucket, once nothing references it — S3 buckets must be
   emptied before they can be deleted).

## Prerequisites

- AWS CLI configured with appropriate credentials
- `cfn-lint` (optional, used by `deploy-environment.sh` if present)
