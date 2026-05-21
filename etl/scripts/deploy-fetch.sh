#!/usr/bin/env bash
# deploy-fetch.sh — deploy the NLM-CKN fetch stack end-to-end
#
# Steps:
#   1. Deploy cloudformation/ecr.yaml  (creates/updates nlm-ckn-ecr stack)
#   2. Build the fetcher Docker image  (--target fetcher)
#   3. Push the image to ECR
#   4. Deploy cloudformation/fetch.yaml (creates/updates nlm-ckn-fetch stack)
#
# Config file (gitignored):
#   .env  — all required values, loaded automatically if present
#
# .env format (KEY=value, no quotes required):
#   S3_BUCKET=my-bucket
#   NCBI_EMAIL=user@example.com
#   NCBI_API_KEY=mykey
#   VPC_ID=vpc-abc123
#   SUBNET_IDS=subnet-aaa,subnet-bbb
#
# Required values (from .env or env vars):
#   S3_BUCKET      S3 bucket for external cache and run artifacts
#   NCBI_EMAIL     NCBI E-Utilities email address
#   NCBI_API_KEY   NCBI E-Utilities API key (stored in Secrets Manager)
#   VPC_ID         VPC ID for the Fargate task
#   SUBNET_IDS     Comma-separated private subnet IDs (e.g. subnet-aaa,subnet-bbb)
#
# Optional env vars:
#   AWS_REGION           AWS region (default: from AWS CLI config)
#   AWS_PROFILE          AWS CLI profile (default: from environment)
#   ECR_STACK_NAME       CloudFormation stack name for ECR (default: nlm-ckn-etl-ecr)
#   FETCH_STACK_NAME     CloudFormation stack name for fetch (default: nlm-ckn-etl-fetch)
#   SCHEDULE_EXPRESSION  EventBridge cron expression (default: cron(0 2 * * ? *))
#   CKN_RUN              Run name passed to fetch.py (default: latest)
#   TASK_CPU             Fargate vCPU units (default: 2048)
#   TASK_MEMORY_MIB      Fargate memory in MiB (default: 8192)
#
# Usage:
#   bash src/main/shell/deploy-fetch.sh

set -euo pipefail

# ── Resolve repo root ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ── Load .env (S3 bucket + NCBI credentials) ─────────────────────────────────
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${ENV_FILE}"; set +o allexport
fi

# ── Config ───────────────────────────────────────────────────────────────────
ECR_STACK_NAME="${ECR_STACK_NAME:-nlm-ckn-etl-ecr}"
FETCH_STACK_NAME="${FETCH_STACK_NAME:-nlm-ckn-etl-fetch}"
SCHEDULE_EXPRESSION="${SCHEDULE_EXPRESSION:-cron(0 2 * * ? *)}"
CKN_RUN="${CKN_RUN:-latest}"
TASK_CPU="${TASK_CPU:-2048}"
TASK_MEMORY_MIB="${TASK_MEMORY_MIB:-8192}"

# ── Validate required env vars ───────────────────────────────────────────────
missing=()
[[ -z "${S3_BUCKET:-}"    ]] && missing+=(S3_BUCKET)
[[ -z "${NCBI_EMAIL:-}"   ]] && missing+=(NCBI_EMAIL)
[[ -z "${NCBI_API_KEY:-}" ]] && missing+=(NCBI_API_KEY)
[[ -z "${VPC_ID:-}"       ]] && missing+=(VPC_ID)
[[ -z "${SUBNET_IDS:-}"   ]] && missing+=(SUBNET_IDS)

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required env vars: ${missing[*]}" >&2
  echo "See the header of this script for usage." >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[deploy-fetch] $*"; }

cfn_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks \
    --stack-name "${stack}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

# ── Resolve region early so all AWS CLI calls target the same region ─────────
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
export AWS_DEFAULT_REGION="${REGION}"

# ── Step 1: Deploy ECR stack ─────────────────────────────────────────────────
log "Deploying ECR stack (${ECR_STACK_NAME})..."
aws cloudformation deploy \
  --template-file "${REPO_ROOT}/cloudformation/ecr.yaml" \
  --stack-name "${ECR_STACK_NAME}" \
  --no-fail-on-empty-changeset

log "ECR stack ready."

# ── Step 2: Resolve ECR details ──────────────────────────────────────────────
FETCHER_REPO_URI="$(cfn_output "${ECR_STACK_NAME}" FetcherRepositoryUri)"
if [[ -z "${FETCHER_REPO_URI}" ]]; then
  echo "ERROR: CloudFormation output FetcherRepositoryUri not found in stack ${ECR_STACK_NAME}" >&2
  exit 1
fi
REGISTRY="${FETCHER_REPO_URI%%/*}"   # account.dkr.ecr.region.amazonaws.com

log "Fetcher ECR URI: ${FETCHER_REPO_URI}"

# ── Step 3: Build fetcher image ───────────────────────────────────────────────
log "Building fetcher image (--target fetcher)..."
docker build \
  --platform linux/amd64 \
  --target fetcher \
  -t "${FETCHER_REPO_URI}:latest" \
  "${REPO_ROOT}"

# ── Step 4: Push to ECR ───────────────────────────────────────────────────────
log "Logging in to ECR (${REGISTRY})..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

log "Pushing fetcher image..."
docker push "${FETCHER_REPO_URI}:latest"

# ── Step 5: Deploy fetch stack ────────────────────────────────────────────────
log "Deploying fetch stack (${FETCH_STACK_NAME})..."
aws cloudformation deploy \
  --template-file "${REPO_ROOT}/cloudformation/fetch.yaml" \
  --stack-name "${FETCH_STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    S3Bucket="${S3_BUCKET}" \
    EcrImageUri="${FETCHER_REPO_URI}:latest" \
    NcbiEmail="${NCBI_EMAIL}" \
    NcbiApiKey="${NCBI_API_KEY}" \
    VpcId="${VPC_ID}" \
    SubnetIds="${SUBNET_IDS}" \
    ScheduleExpression="${SCHEDULE_EXPRESSION}" \
    CknRun="${CKN_RUN}" \
    TaskCpu="${TASK_CPU}" \
    TaskMemoryMiB="${TASK_MEMORY_MIB}"

log "Fetch stack ready."
log "Done."
