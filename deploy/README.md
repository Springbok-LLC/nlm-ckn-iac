# Deploy scripts

Every script here runs `aws cloudformation deploy` against templates living
elsewhere in this repo, organized by service/component. This folder just holds
the entry points, numbered by dependency order.

Sandbox-account promotion (`deploy-sandbox.sh`) isn't here — it manages a
plain-docker-on-EC2 deployment via SSM, not a CloudFormation stack, so it
stays with the other application-promotion scripts in
`nlm-ckn-ui/scripts/sandbox/`.

**The number is a wave, not a strict sequence.** Scripts sharing a number don't
depend on each other and can be run in parallel; each wave only depends on
waves with a lower number having finished.

| # | Script | Depends on |
|---|--------|------------|
| 1 | `01-deploy-account-setup.sh` | nothing (bootstrap + shared, once per AWS account) |
| 2 | `02-deploy-environment.sh <env>` | wave 1 (templates bucket, ArangoDB dataset bucket) |
| 2 | `02-deploy-fetch.sh` | wave 1 (ArangoDB dataset bucket, via SSM) |
| 3 | `03-deploy-batch.sh` | wave 2's `02-deploy-fetch.sh` (NCBI secret ARN output) |
| 3 | `03-deploy-monitoring.sh <env>` | wave 2's `02-deploy-environment.sh` (arangodb/ALB outputs) |

`etl/cloudformation/github-oidc.yaml` has no wrapper script here — it's deployed
manually, once per account, per the command in its own header — so it isn't
part of the numbered sequence above.

See the [top-level README](../README.md) for the full directory layout and
[docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md) for the detailed walkthrough.
