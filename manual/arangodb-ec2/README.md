# ArangoDB on EC2 (standalone)

A single CloudFormation stack that runs the NLM-CKN ArangoDB on one EC2
instance, for an account this repo doesn't manage. NIH deploys it. Every
account-specific value is a parameter, and nothing is imported from other
stacks.

It's derived from the dev/stage template,
[`environment/services/arangodb/cloudformation/arangodb.yaml`](../../environment/services/arangodb/cloudformation/arangodb.yaml),
and its bootstrap script is the same apart from parameter wiring. If the
bootstrap script changes in one template, make the same change in the other.

## Why not the sandbox template?

[`environment/sandbox/cloudformation/arangodb.yaml`](../../environment/sandbox/cloudformation/arangodb.yaml)
only works in the sandbox account:

- **Hardcoded sandbox resources:** a personal SSH key pair, a subnet, security
  groups, an instance profile, the account ID, secret and SSM paths, and a
  target-group export name.
- **A specific machine image:** it assumes an AMI that already has Docker,
  nginx and firewalld installed.
- **Fragile behavior:**
  - The data disk is recreated empty whenever the instance is replaced.
  - A failure before the readiness check leaves the stack waiting the full
    20-minute timeout.
  - There's no read-only database user.
  - The ALB is pointed at nginx's default page instead of ArangoDB.

This template fixes all of those.

## What the stack creates

| Resource | Notes |
|---|---|
| EC2 instance (Amazon Linux 2023 + Docker) | No SSH key; use SSM Session Manager. IMDSv2 is required. Defaults to arm64 `m7g.large`. A template rule rejects an instance type that doesn't match the CPU architecture. |
| Data volume (gp3, encrypted, **retained**) | A separate resource that the instance attaches itself at boot. When the instance is replaced, the same volume is reattached. It is kept if the stack is deleted. |
| Two password secrets (**retained**, optional) | `/<Project>/<Env>/secrets/arangodb-root-password` (root) and `/<Project>/<Env>/secrets/arangodb-password` (read-only user, also read by the backend). Generated passwords. Skip with `CreatePasswordSecrets=false` if they already exist. |
| Two SSM parameters | `/<Project>/<Env>/arango/db-user` and `/<Project>/<Env>/arango/dataset-version` |
| Cloud Map service | The instance registers itself at boot, removes stale registrations, and deregisters on shutdown. The backend connects to `<CloudMapServiceName>.<namespace>:8529`. |
| CloudWatch log group | `/ec2/<Project>-<Env>-arangodb`: the setup log plus the ArangoDB container log |
| IAM role + instance profile (optional) | Skipped if `InstanceProfileArn` is given. The `InstanceRole` resource then serves as the permission spec for the pre-created role. |

## What happens at boot

Any failure signals CloudFormation right away, and the reason is in the setup
log.

1. Installs Docker and the CloudWatch agent.
2. Attaches and mounts the data volume. A blank volume is formatted; a volume
   with data is never wiped.
3. Starts ArangoDB, with cache sizes based on the instance's RAM.
4. Downloads the archive named in `DatasetVersion` from `DatasetBucketName`
   and restores it, unless the volume already holds that version.
5. Creates or updates the read-only user (`ArangoDbUser`, default `nlm_ro`)
   with read-only access to `Cell-KN-Ontologies` and `Cell-KN-Phenotypes`.
6. Registers in Cloud Map, and in the ALB target group if one is given.

## Before deploying, please confirm

1. **Network access from the subnet.** The instance needs outbound access to S3,
   Secrets Manager, SSM, CloudWatch Logs, Cloud Map/EC2/ELB APIs and the
   container registry, through a NAT gateway or VPC endpoints.
2. **Docker Hub.** If the account can't reach Docker Hub, mirror
   `arangodb:3.12` to ECR and set `ArangoImage`. The instance role then also
   needs ECR pull permission.
3. **Security group.** The group in `SecurityGroupId` must allow 8529 from the
   backend, and from the ALB if one is used.
4. **The dataset archive is in your bucket.** The archive (`DatasetVersion`, for
   example `runs/v1.8.0-rc.1/06-golden-dump.tar.gz`) must be in
   `DatasetBucketName`.
5. **IAM.** If app stacks can't create IAM roles, pre-create the instance
   profile with the permissions from `InstanceRole` and pass
   `InstanceProfileArn`.
6. **Machine image.** The default AMI is the latest public Amazon Linux 2023. A
   hardened replacement (`ImageIdOverride`) must be based on Amazon Linux 2023.

## Deploy

```bash
aws ec2 describe-subnets --subnet-ids <SubnetId> --query 'Subnets[0].AvailabilityZone' --output text   # → AvailabilityZone
```

Fill in `parameters.example.json`, then deploy:

```bash
aws cloudformation deploy \
  --stack-name nlm-ckn-prod-arangodb-ec2 \
  --template-file cloudformation/arangodb-ec2.yaml \
  --parameter-overrides file://parameters.example.json \
  --capabilities CAPABILITY_IAM
```

A first deploy with a dataset takes about 10–15 minutes. The stack only
completes after ArangoDB is up, the dataset is restored and the read-only user
exists.

## Verify

From a Session Manager shell on the instance (`InstanceId` output):

```bash
PW=$(aws secretsmanager get-secret-value --secret-id /nlm-ckn/prod/secrets/arangodb-password --query SecretString --output text)
curl -s -u "nlm_ro:$PW" "http://localhost:8529/_db/Cell-KN-Ontologies/_api/collection?excludeSystem=true" | head -c 300
```

The setup log is in CloudWatch under `/ec2/<Project>-<Env>-arangodb`, stream
`setup/<instance-id>`.

## Later dataset updates

The bootstrap only runs on first boot. To load a new dataset, use the
SSM Run Command restore from `nlm-ckn-ui` (`scripts/app/deploy-dataset.sh`,
the same process as sandbox and dev). It swaps in the new version without
downtime and then advances `/<Project>/<Env>/arango/dataset-version`.

Leave the `DatasetVersion` stack parameter unchanged on stack updates. Changing
it rewrites the SSM parameter and could point it back at an older version.

## Operational notes

- **Instance replacement keeps the data.** The latest-AMI lookup runs on every
  deploy, so a deploy after AWS publishes a new AL2023 image replaces the
  instance. The data volume is reattached, and the restore is skipped because
  the version already matches.
- **Deleting the stack keeps the data volume and the secrets.** Delete them by
  hand if you really mean to remove the database.

## Testing in springbok dev

`test-in-dev.sh` deploys a separate copy alongside dev's ArangoDB:
`Environment=devtest`, with Cloud Map service `arangodb-devtest` in dev's
namespace. It restores the same dataset version dev runs, then queries it as
the read-only user over SSM Run Command.

```bash
AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh up
AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh check
AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh down   # also deletes the test volume + secrets
```
