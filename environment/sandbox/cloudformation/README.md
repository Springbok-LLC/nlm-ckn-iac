# Sandbox CloudFormation

Self-contained CloudFormation for the NIH **`sandbox`** account. Unlike the
shared `platform/` + `services/` tiers, the sandbox account has constraints those
templates can't satisfy, so its infrastructure lives here and is deployed on its
own — not through `platform/main.yaml`. See
[`../../README.md`](../README.md#sandbox-sandbox) for context.

Access to the account requires NIH credentials and the NCBI web proxy, and is
obtained by logging into
[https://iam.nih.gov](https://iam.nih.gov/identityiq/home.jsf).

## Ownership

The sandbox infrastructure is **owned by the NIH team**, who manage it from their
own GitLab instance — the source of truth is the `cell-kn` repo at
<https://gitlab.nlm.nih.gov/ncbi/cell-kn.git>
(`cloudformation/environment/`). The copies here are a read-only snapshot for
reference; changes should be made upstream in GitLab, not in this repo.

## Provenance

These templates were **exported from the live stacks actually deployed** in the
sandbox account, captured **2026-07-08** via:

```bash
aws cloudformation get-template --profile <sandbox-profile> \
  --stack-name <stack> --query TemplateBody --output text
```

They were originally authored in the `cell-kn` GitLab repo
(`cell-kn/cloudformation/environment/`), but the copies here are the deployed
bodies, so they reflect **reality including any drift** from that source repo —
not the source-repo versions. Several deployed stacks had diverged from their
source template (see [Drift](#drift-from-source-repo)).

## Stacks

| Template | Deployed stack | Provisions |
|----------|----------------|------------|
| `nlm-backend-ecs-cluster.yaml` | `NLM-SBOX-vpc-101-cell-kn-backend-ecs-cluster` | ECR repository + ECS cluster (EC2 capacity, defined AMI) |
| `alb.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-loadbalancer` | Application Load Balancer + backend/ArangoDB target groups |
| `alb-s3-bucket.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-alb-s3-bucket` | S3 bucket for ALB access logs |
| `alb-s3-lambda-execution-role.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-alb-s3-lambda-role` | IAM role for the S3-content Lambda (S3 read + CW Logs) |
| `alb-s3-lambda-target-group.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-alb-s3-lambda-target-group` | Lambda function + ALB target group serving S3 content |
| `arangodb.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-arangodb` | ArangoDB EC2 instance, EBS persistence, S3 restore |
| `arangodb-role.yaml` | `NLM-SBOX-CELL-KN-arangodb-role` | IAM instance role for the ArangoDB EC2 host |
| `arangodb-s3-buckets.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-arangodb-buckets` | S3 buckets for ArangoDB templates + state |
| `cell-kn-backend-role.yaml` | `NLM-SBOX-CELL-KN-ecs-role` | ECS backend task IAM role + policies |
| `cell-kn-loggroups.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-loggroup` | CloudWatch log groups (ArangoDB DB + EC2) |
| `frontend-s3-bucket.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-frontend-s3-bucket` | Frontend S3 bucket (+ CloudFront wiring) |
| `secrets.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-secrets` | Secrets Manager: ArangoDB password, Django key, CloudFront origin secret |
| `service-discovery.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-svc-deiscovery` | Cloud Map service-discovery namespace |
| `sns-notification-topic.yaml` | `NLM-SBOX-vpc-101-CELL-KN-notification` | SNS application-status notification topic |
| `ssm-params.yaml` | `NLM-SBOX-CELL-KN-vpc-101-cellkn-ssm-param` | SSM parameters (bucket name, DB user, dataset version, ECR URL) |
| `lambda-role.yaml` | `NLM-SBOX-CELL-KN-lambda-role` | Lambda execution IAM role (`secrete-lambda`) — **no counterpart in the source repo**; exported only from the live stack |

## Drift from source repo

The exported bodies differ from `cell-kn/cloudformation/environment/` by varying
amounts. Notable:

- **`cell-kn-backend-role.yaml`** (`ecs-role`): significantly diverged. The
  deployed version uses newer parameters (`pAWSAccount`, `pAppNameLC`) whereas
  the source-repo file still used `ProjectName` / `Environment`. The version
  here is the deployed one.
- **`alb-s3-lambda-target-group.yaml`**, **`arangodb-role.yaml`**,
  **`nlm-backend-ecs-cluster.yaml`**: moderate drift from source.
- **`alb.yaml`**, **`arangodb.yaml`**, **`alb-s3-bucket.yaml`**,
  **`frontend-s3-bucket.yaml`**: minor drift.
- The remaining templates matched their source exactly at capture time.

## Not included

Templates that exist in the source repo but were **never deployed** to sandbox
(and so are excluded): `bootstrap.yaml`, `shared-resources.yaml`,
`ecs-cluster.yaml`, `backend.yaml`, `nlm-arangodb.yaml`, `cell-kn-route53.yaml`,
`frontend.yaml`, `frontend-ruote53.yaml`, `security-groups.yaml`, and the
`main.yaml` orchestrator. The account's VPC/NACL/security-group, Neo4j
(`vpc-102`), and log-subscription stacks come from other repos, not this folder.

Parameter values used for these stacks live in the source repo at
`cell-kn/cloudformation/parameters/sandbox.json` (not copied here).

## Notes

- `cfn-lint` reports only **E9101** ("missing required tag(s):
  `Owner`/`Repository`/`Project`/`ManagedBy`") against these files. That is this
  repo's tagging-governance rule (`.cfnlintrc.yaml`); these templates predate it
  because they came from a different repo. There are no structural/parse errors
  — the templates are valid and currently deployed. Tagging has **not** yet been
  reconciled to nlm-ckn-iac standards.

## Refreshing this export

To re-capture after changes are made in the account, re-run `get-template` for
each stack in the table above and overwrite the corresponding file.
