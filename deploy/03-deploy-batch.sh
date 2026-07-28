#!/usr/bin/env bash
# deploy-batch.sh — deploy the NLM-CKN Batch release stack.
#
# Steps:
#   1. Deploy etl/cloudformation/ecr.yaml        (creates/updates the ECR repos)
#   2. Confirm the pipeline image tag exists in ECR (does NOT build it)
#   3. Deploy etl/cloudformation/batch.yaml      (creates/updates nlm-ckn-etl-batch)
#
# This script does NOT build or push container images. Images are built and
# pushed by the nlm-ckn-etl repo's CI (.github/workflows/build-image.yml) into
# the ECR repos this script provisions. If the pipeline image tag is missing at
# step 2, the script prints copy/re-tag guidance and pauses so you can push the
# image (in another shell), then continues when you press Enter. (Note: the
# pipeline image is typically tagged with a release version like v1.5.0-rc.1
# rather than 'latest' — set IMAGE_TAG or re-tag an existing image accordingly.)
#
# Prerequisites:
#   - pipeline image pushed to ECR (nlm-ckn-etl CI, or re-tagged from an existing image)
#   - etl/cloudformation/fetch.yaml already deployed (provides NCBI SSM + Secrets Manager)
#   - AWS credentials with CloudFormation, ECR, IAM, Batch, EC2, and Logs permissions
#
# Config file (gitignored):
#   .env  — all required values, loaded automatically if present
#
# .env format (KEY=value, no quotes required):
#   VPC_ID=vpc-abc123
#   SUBNET_IDS=subnet-aaa,subnet-bbb
#   NCBI_API_KEY_SECRET_ARN=arn:aws:secretsmanager:...
#
# Required values (from .env or env vars):
#   VPC_ID                    VPC ID for the Batch compute environment
#   SUBNET_IDS                Comma-separated private subnet IDs with NAT gateway
#   NCBI_API_KEY_SECRET_ARN   Secrets Manager ARN from the fetch stack output
#
# The S3 bucket is no longer a required value here — batch.yaml resolves it
# live from SSM (see the S3Bucket parameter in that template). This script
# always passes S3Bucket explicitly (rather than relying on
# UsePreviousValue/Default) because the nlm-ckn rename cutover
# (docs/cutover-to-nlm-ckn.md) hasn't completed: /nlm-ckn/shared/arangodb-bucket-name
# doesn't exist yet, so the template Default would fail. Once deploy/01-deploy-account-setup.sh
# has been rerun and the new SSM parameter exists, set S3_BUCKET_SSM_PARAM to
# switch over.
#
# Optional env vars:
#   GITHUB_TOKEN         GitHub token for deployment status updates. When set,
#                        stored/updated in Secrets Manager (nlm-ckn/github-token)
#                        and injected into Batch jobs via the job definition secrets
#                        rather than as a plain environment variable.
#   AWS_REGION           AWS region (default: from AWS CLI config)
#   ECR_STACK_NAME       CloudFormation stack name for ECR (default: nlm-ckn-etl-ecr)
#   IMAGE_TAG            Pipeline image tag to deploy (default: latest)
#   BATCH_STACK_NAME     CloudFormation stack name for Batch (default: nlm-ckn-etl-batch)
#   FETCH_STACK_NAME     CloudFormation stack name for fetch (default: nlm-ckn-etl-fetch)
#                        When set, NCBI_API_KEY_SECRET_ARN is auto-resolved from outputs.
#   INSTANCE_TYPES       Comma-separated EC2 types (default: r5.4xlarge,r5.2xlarge)
#   MAX_VCPUS            Max vCPUs for the compute environment (default: 16)
#   EBS_VOLUME_GIB       Root EBS volume size in GiB (default: 200)
#   S3_BUCKET_SSM_PARAM  SSM parameter name holding the dataset bucket
#                        (default: /cell-kn/shared/arangodb-bucket-name — the
#                        pre-cutover name; see docs/cutover-to-nlm-ckn.md)
#
# Usage:
#   bash deploy/03-deploy-batch.sh

set -euo pipefail

# ── Resolve repo root and load .env ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# PROJECT_NAME comes from the shared constant (single source of truth) and is
# passed to every etl stack, which now declare ProjectName as a required param.
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${ENV_FILE}"; set +o allexport
fi

# ── Config ────────────────────────────────────────────────────────────────────
ECR_STACK_NAME="${ECR_STACK_NAME:-nlm-ckn-etl-ecr}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BATCH_STACK_NAME="${BATCH_STACK_NAME:-nlm-ckn-etl-batch}"
FETCH_STACK_NAME="${FETCH_STACK_NAME:-nlm-ckn-etl-fetch}"
INSTANCE_TYPES="${INSTANCE_TYPES:-r5.4xlarge,r5.2xlarge}"
MAX_VCPUS="${MAX_VCPUS:-16}"
EBS_VOLUME_GIB="${EBS_VOLUME_GIB:-200}"
S3_BUCKET_SSM_PARAM="${S3_BUCKET_SSM_PARAM:-/cell-kn/shared/arangodb-bucket-name}"

# ── Validate required env vars ────────────────────────────────────────────────
missing=()
[[ -z "${VPC_ID:-}"       ]] && missing+=(VPC_ID)
[[ -z "${SUBNET_IDS:-}"   ]] && missing+=(SUBNET_IDS)

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required env vars: ${missing[*]}" >&2
  echo "See the header of this script for usage." >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[deploy-batch] $*"; }

cfn_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks \
    --stack-name "${stack}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

# ── Resolve region early so all AWS CLI calls target the same region ──────────
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
export AWS_DEFAULT_REGION="${REGION}"

# ── Step 1: Deploy ECR stack ──────────────────────────────────────────────────
log "Deploying ECR stack (${ECR_STACK_NAME})..."
aws cloudformation deploy \
  --template-file "${REPO_ROOT}/etl/cloudformation/ecr.yaml" \
  --stack-name    "${ECR_STACK_NAME}" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ProjectName="${PROJECT_NAME}"

log "ECR stack ready."

# ── Step 2: Confirm the pipeline image tag exists (no build) ─────────────────
PIPELINE_REPO_URI="$(cfn_output "${ECR_STACK_NAME}" PipelineRepositoryUri)"
PIPELINE_REPO_NAME="$(cfn_output "${ECR_STACK_NAME}" PipelineRepositoryName)"
if [[ -z "${PIPELINE_REPO_URI}" || -z "${PIPELINE_REPO_NAME}" ]]; then
  echo "ERROR: CloudFormation outputs Pipeline{RepositoryUri,RepositoryName} not found in stack ${ECR_STACK_NAME}" >&2
  exit 1
fi

log "Pipeline ECR URI: ${PIPELINE_REPO_URI}:${IMAGE_TAG}"
wait_for_ecr_image "${PIPELINE_REPO_NAME}" "${IMAGE_TAG}" "${REGION}"

# ── Step 3: Resolve NCBI API key secret ARN ───────────────────────────────────
# Prefer an explicit env var; fall back to reading from the fetch stack outputs.
if [[ -z "${NCBI_API_KEY_SECRET_ARN:-}" ]]; then
  log "NCBI_API_KEY_SECRET_ARN not set — reading from fetch stack (${FETCH_STACK_NAME})..."
  NCBI_API_KEY_SECRET_ARN="$(cfn_output "${FETCH_STACK_NAME}" NcbiApiKeySecretArn)"
fi

if [[ -z "${NCBI_API_KEY_SECRET_ARN:-}" ]]; then
  echo "ERROR: NCBI_API_KEY_SECRET_ARN could not be resolved." >&2
  echo "Either set it explicitly or ensure ${FETCH_STACK_NAME} is deployed." >&2
  exit 1
fi

log "NCBI API key secret ARN: ${NCBI_API_KEY_SECRET_ARN}"

# ── Step 3b: Store GitHub token in Secrets Manager (optional) ─────────────────
# When GITHUB_TOKEN is set, create or update the secret so the Batch job can
# post deployment status updates without the token appearing in job env vars.
GITHUB_TOKEN_SECRET_ARN=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  SECRET_NAME="nlm-ckn/github-token"
  GITHUB_TOKEN_SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "${SECRET_NAME}" \
    --query 'ARN' --output text 2>/dev/null) || true

  if [[ -z "${GITHUB_TOKEN_SECRET_ARN}" ]]; then
    log "Creating GitHub token secret (${SECRET_NAME})..."
    GITHUB_TOKEN_SECRET_ARN=$(aws secretsmanager create-secret \
      --name "${SECRET_NAME}" \
      --description "GitHub token for deployment status updates in nlm-ckn-etl Batch jobs" \
      --secret-string "${GITHUB_TOKEN}" \
      --query ARN --output text)
  else
    log "Updating GitHub token secret (${SECRET_NAME})..."
    aws secretsmanager put-secret-value \
      --secret-id "${SECRET_NAME}" \
      --secret-string "${GITHUB_TOKEN}" > /dev/null
  fi
  log "GitHub token secret ARN: ${GITHUB_TOKEN_SECRET_ARN}"
fi

# ── Step 4: Deploy Batch stack ────────────────────────────────────────────────
log "Deploying Batch stack (${BATCH_STACK_NAME})..."
aws cloudformation deploy \
  --template-file "${REPO_ROOT}/etl/cloudformation/batch.yaml" \
  --stack-name    "${BATCH_STACK_NAME}" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ProjectName="${PROJECT_NAME}" \
    S3Bucket="${S3_BUCKET_SSM_PARAM}" \
    EcrImageUri="${PIPELINE_REPO_URI}:${IMAGE_TAG}" \
    NcbiApiKeySecretArn="${NCBI_API_KEY_SECRET_ARN}" \
    GithubTokenSecretArn="${GITHUB_TOKEN_SECRET_ARN}" \
    VpcId="${VPC_ID}" \
    SubnetIds="${SUBNET_IDS}" \
    InstanceTypes="${INSTANCE_TYPES}" \
    MaxvCpus="${MAX_VCPUS}" \
    EbsVolumeGiB="${EBS_VOLUME_GIB}"

log "Batch stack ready."
log "Done. Trigger a release with:"
log "  bash src/main/shell/trigger-release.sh --nlm-ckn-tag <tag>"
