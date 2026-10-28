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
| 3 | `03-deploy-preview-platform.sh <env>` | wave 2's `02-deploy-environment.sh` incl. the CDN stack (ALB listener, cluster, web ACL exports) |

`03-deploy-preview-platform.sh` also publishes `preview-pr.yaml` (versioned by
git SHA) to the templates bucket and points SSM
`/nlm-ckn/<env>/preview/pr-template-url` at its https URL; nlm-ckn-ui's preview
workflow creates per-PR change sets from that URL (its CI role may use no other
template, may not push images, and is trusted only from the protected `preview`
GitHub environment). It also seeds a random
session-cookie signing key in the preview KeyValueStore (`session-key`) if none
exists; nlm-ckn-ui's `scripts/ops/preview-login.sh <pr>` signs a link with it, and rotating
it (command in the script's header) signs everyone out. Nothing secret is
committed.

`etl/cloudformation/github-oidc.yaml` has no wrapper script here — it's deployed
manually, once per account, per the command in its own header — so it isn't
part of the numbered sequence above.

See the [top-level README](../README.md) for the full directory layout, and the
per-area `README.md` files ([`environment/`](../environment/README.md),
[`etl/`](../etl/README.md)) for the architecture each wave provisions.
