#!/usr/bin/env bash
# deploy-batch.sh — deploy the NLM-CKN Batch release stack end-to-end.
#
# Steps:
#   1. Deploy cloudformation/ecr.yaml        (creates/updates nlm-ckn-etl-ecr)
#   2. Build the pipeline Docker image       (--target pipeline, includes JRE)
#   3. Push the image to ECR
#   4. Deploy cloudformation/batch.yaml      (creates/updates nlm-ckn-etl-batch)
#
# Prerequisites:
#   - cloudformation/fetch.yaml already deployed (provides NCBI SSM + Secrets Manager)
#   - AWS credentials with CloudFormation, ECR, IAM, Batch, EC2, and Logs permissions
#
# Config file (gitignored):
#   .env  — all required values, loaded automatically if present
#
# .env format (KEY=value, no quotes required):
#   S3_BUCKET=my-bucket
#   VPC_ID=vpc-abc123
#   SUBNET_IDS=subnet-aaa,subnet-bbb
#   NCBI_API_KEY_SECRET_ARN=arn:aws:secretsmanager:...
#
# Required values (from .env or env vars):
#   S3_BUCKET                 S3 bucket for cache and run artifacts
#   VPC_ID                    VPC ID for the Batch compute environment
#   SUBNET_IDS                Comma-separated private subnet IDs with NAT gateway
#   NCBI_API_KEY_SECRET_ARN   Secrets Manager ARN from the fetch stack output
#
# Optional env vars:
#   GITHUB_TOKEN         GitHub token for deployment status updates. When set,
#                        stored/updated in Secrets Manager (nlm-ckn/github-token)
#                        and injected into Batch jobs via the job definition secrets
#                        rather than as a plain environment variable.
#   AWS_REGION           AWS region (default: from AWS CLI config)
#   ECR_STACK_NAME       CloudFormation stack name for ECR (default: nlm-ckn-etl-ecr)
#   BATCH_STACK_NAME     CloudFormation stack name for Batch (default: nlm-ckn-etl-batch)
#   FETCH_STACK_NAME     CloudFormation stack name for fetch (default: nlm-ckn-etl-fetch)
#                        When set, NCBI_API_KEY_SECRET_ARN is auto-resolved from outputs.
#   INSTANCE_TYPES       Comma-separated EC2 types (default: r5.4xlarge,r5.2xlarge)
#   MAX_VCPUS            Max vCPUs for the compute environment (default: 16)
#   EBS_VOLUME_GIB       Root EBS volume size in GiB (default: 200)
#
# Usage:
#   bash src/main/shell/deploy-batch.sh

set -euo pipefail

# ── Resolve repo root and load .env ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${ENV_FILE}"; set +o allexport
fi

# ── Config ────────────────────────────────────────────────────────────────────
ECR_STACK_NAME="${ECR_STACK_NAME:-nlm-ckn-etl-ecr}"
BATCH_STACK_NAME="${BATCH_STACK_NAME:-nlm-ckn-etl-batch}"
FETCH_STACK_NAME="${FETCH_STACK_NAME:-nlm-ckn-etl-fetch}"
INSTANCE_TYPES="${INSTANCE_TYPES:-r5.4xlarge,r5.2xlarge}"
MAX_VCPUS="${MAX_VCPUS:-16}"
EBS_VOLUME_GIB="${EBS_VOLUME_GIB:-200}"

# ── Validate required env vars ────────────────────────────────────────────────
missing=()
[[ -z "${S3_BUCKET:-}"    ]] && missing+=(S3_BUCKET)
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
  --template-file "${REPO_ROOT}/cloudformation/ecr.yaml" \
  --stack-name    "${ECR_STACK_NAME}" \
  --no-fail-on-empty-changeset

log "ECR stack ready."

# ── Step 2: Resolve ECR details ───────────────────────────────────────────────
PIPELINE_REPO_URI="$(cfn_output "${ECR_STACK_NAME}" PipelineRepositoryUri)"
if [[ -z "${PIPELINE_REPO_URI}" ]]; then
  echo "ERROR: CloudFormation output PipelineRepositoryUri not found in stack ${ECR_STACK_NAME}" >&2
  exit 1
fi
REGISTRY="${PIPELINE_REPO_URI%%/*}"   # account.dkr.ecr.region.amazonaws.com

log "Pipeline ECR URI: ${PIPELINE_REPO_URI}"

# ── Step 3: Build pipeline image ──────────────────────────────────────────────
log "Building pipeline image (--target pipeline)..."
docker build \
  --platform linux/amd64 \
  --target pipeline \
  -t "${PIPELINE_REPO_URI}:latest" \
  "${REPO_ROOT}"

# ── Step 4: Push to ECR ───────────────────────────────────────────────────────
log "Logging in to ECR (${REGISTRY})..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

log "Pushing pipeline image..."
docker push "${PIPELINE_REPO_URI}:latest"

# ── Step 5: Resolve NCBI API key secret ARN ───────────────────────────────────
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

# ── Step 5b: Store GitHub token in Secrets Manager (optional) ─────────────────
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

# ── Step 6: Deploy Batch stack ────────────────────────────────────────────────
log "Deploying Batch stack (${BATCH_STACK_NAME})..."
aws cloudformation deploy \
  --template-file "${REPO_ROOT}/cloudformation/batch.yaml" \
  --stack-name    "${BATCH_STACK_NAME}" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    S3Bucket="${S3_BUCKET}" \
    EcrImageUri="${PIPELINE_REPO_URI}:latest" \
    NcbiApiKeySecretArn="${NCBI_API_KEY_SECRET_ARN}" \
    GithubTokenSecretArn="${GITHUB_TOKEN_SECRET_ARN}" \
    VpcId="${VPC_ID}" \
    SubnetIds="${SUBNET_IDS}" \
    InstanceTypes="${INSTANCE_TYPES}" \
    MaxvCpus="${MAX_VCPUS}" \
    EbsVolumeGiB="${EBS_VOLUME_GIB}"

log "Batch stack ready."
log "Done. Trigger a release with:"
log "  bash src/main/shell/trigger-release.sh --tag <tag>"
