# Cutover: replacing the old `cell-kn` deployment with `nlm-ckn`

This repo now provisions **`nlm-ckn`-named** resources — every template defaults
`ProjectName` to `nlm-ckn`, and the scripts and `environment/parameters/*.json`
set it to `nlm-ckn`. `DomainName` is already `nlm-ckn.org`, so DNS naming is
unaffected by this change.

The project was originally deployed under the old name `cell-kn`. Because S3
bucket names and CloudFormation stack names **can't be renamed in place**,
switching over is a **parallel-stack cutover**, not an in-place edit: you stand
up the new `nlm-ckn-*` stacks alongside the existing `cell-kn-*` ones, verify,
switch traffic, and only then decommission the old stacks.

The ETL-side stacks (`nlm-ckn-etl-*`, `nlm-ckn-fetch`, `nlm-ckn-release`) were
already named `nlm-ckn-*` and don't need renaming — but they still need a
redeploy below because they consume a resource (the shared dataset bucket) whose
SSM pointer moved from `/cell-kn/…` to `/nlm-ckn/…`.

> The one thing that intentionally still references `cell-kn` is
> [`manual/redirect/`](../manual/redirect/): the `cell-kn.org` apex domain is a
> legacy domain the CloudFront distribution 301-redirects to `nlm-ckn.org`. That
> is a domain, not a project resource — leave it as-is.

## Checklist, in order

1. **Deploy the new `nlm-ckn` stacks.** Run
   [`deploy/01-deploy-account-setup.sh`](../deploy/01-deploy-account-setup.sh),
   then [`deploy/02-deploy-environment.sh <env>`](../deploy/02-deploy-environment.sh).
   This creates a *new* S3 templates bucket, state bucket, ArangoDB dataset
   bucket (`nlm-ckn-arangodb-data-<account-id>`), and the
   `nlm-ckn-github-actions` OIDC role, all alongside the existing `cell-kn-*`
   resources — nothing old is touched yet.

2. **Update the application repo.** In `nlm-ckn-ui`, set `PROJECT_NAME="nlm-ckn"`
   in the `scripts/app/*.sh` build-and-ship scripts, and update the CI
   `role-to-assume` ARN (`cell-kn-github-actions` → `nlm-ckn-github-actions`).
   *(This IaC repo's own scripts and parameter files already use `nlm-ckn`.)*

3. **Redeploy the ETL stacks against the new bucket.** This repo's
   `etl/cloudformation/{batch,fetch,github-oidc}.yaml` already resolve the shared
   dataset bucket from `/nlm-ckn/shared/arangodb-bucket-name` (an
   `AWS::SSM::Parameter::Value<String>` default — see `S3Bucket`/`S3BucketName`
   in those templates). Redeploy [`deploy/02-deploy-fetch.sh`](../deploy/02-deploy-fetch.sh),
   [`deploy/03-deploy-batch.sh`](../deploy/03-deploy-batch.sh), and
   `etl/cloudformation/github-oidc.yaml` (manually, per its own header) so they
   re-resolve the new SSM value. CloudFormation only re-resolves an SSM parameter
   at deploy time, so this is a deliberate, manual step.

4. **Verify, then cut over and decommission.** Smoke-test the new environment,
   switch DNS/ALB traffic to the new `nlm-ckn-*` environment stack, then — and
   only then — decommission the `cell-kn-*` stacks, including the old dataset
   bucket once nothing references it (S3 buckets must be emptied before they can
   be deleted).

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full deployment walkthrough and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.
