#!/bin/bash
# ==============================================================================
# 03-deploy-preview-platform.sh - Deploy the nlm-ckn-ui PR preview platform
# ==============================================================================
# Wave 3 (needs 02-deploy-environment.sh's infra + frontend-cdn exports).
#
#   1. Lints environment/preview/cloudformation/*.yaml (cfn-lint errors abort).
#   2. Deploys preview-platform.yaml as the stack
#        nlm-ckn-<env>-preview-platform        (us-east-1 only)
#   3. Uploads preview-pr.yaml to the templates bucket at
#        s3://<templates bucket>/preview/preview-pr-<git sha>.yaml
#      and writes its https URL to SSM
#        /nlm-ckn/<env>/preview/pr-template-url
#      which nlm-ckn-ui's preview.yml passes to `create-change-set
#      --template-url`. The preview CI role may only create change sets from
#      that preview/ prefix, so publishing a template version is an explicit
#      iac step: UI PRs pick it up on their next push.
#
# nlm-ckn-ui side (not in this repo): preview.yml's job must run in a
# protected GitHub environment named `preview` (required reviewers) — the CI
# role trusts only repo:Springbok-LLC/nlm-ckn-ui:environment:preview — and it
# builds the PR's backend image and pushes it to the preview ECR repo
# (<project>-<env>-preview-backend; the CI role can push nowhere else).
#
# The per-PR template is keyed by the commit SHA, so the working tree must be
# clean. There is deliberately no override: every object under preview/ is
# usable by the preview CI role (its TemplateUrl condition), so only committed
# templates are ever published there.
#
# AFTER the first deploy, seed the basic-auth credential (never committed):
#
#   KVS_ARN=$(aws cloudformation describe-stacks --region us-east-1 \
#     --stack-name nlm-ckn-<env>-preview-platform \
#     --query "Stacks[0].Outputs[?OutputKey=='PreviewAuthStoreArn'].OutputValue" --output text)
#   ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store \
#     --kvs-arn "$KVS_ARN" --query ETag --output text)
#   aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS_ARN" --if-match "$ETAG" \
#     --key basic-auth --value "$(printf '%s' '<user>:<password>' | base64)"
#
# Rotating it is the same put-key; no redeploy. Until it is seeded every
# preview request gets 401.
#
# The environment's ECS cluster must have the FARGATE_SPOT capacity provider
# (ecs-cluster.yaml, deployed by 02-deploy-environment.sh --infra-only).
#
# USAGE:
#   AWS_PROFILE=springbok ./deploy/03-deploy-preview-platform.sh <env> [--auto-approve]
#     env: dev (default) or stage
# ==============================================================================
set -euo pipefail

# Change to repo root (script lives in deploy/) so relative paths resolve.
cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-dev}"
AUTO_APPROVE=false
for arg in "${@:2}"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE=true ;;
    *) echo "Error: unknown option: $arg (valid: --auto-approve)" >&2; exit 1 ;;
  esac
done

# PROJECT_NAME comes from the shared constant (single source of truth).
source deploy/lib/common.sh
# CloudFront viewer certificates and CLOUDFRONT-scope web ACLs live in us-east-1.
export AWS_REGION=us-east-1
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}-preview-platform"
TEMPLATE_DIR="environment/preview/cloudformation"
PLATFORM_TEMPLATE="${TEMPLATE_DIR}/preview-platform.yaml"
PR_TEMPLATE="${TEMPLATE_DIR}/preview-pr.yaml"
TEMPLATE_PARAM="/${PROJECT_NAME}/${ENVIRONMENT}/preview/pr-template-url"

if [[ ! "$ENVIRONMENT" =~ ^(dev|stage)$ ]]; then
  echo "Error: environment must be dev or stage" >&2
  exit 1
fi

# ── Template version (git SHA) ───────────────────────────────────────────────
GIT_SHA=$(git rev-parse --short=12 HEAD)
if [ -n "$(git status --porcelain -- "$TEMPLATE_DIR")" ]; then
  echo "Error: uncommitted changes under ${TEMPLATE_DIR}; commit first" >&2
  exit 1
fi

# ── Lint ─────────────────────────────────────────────────────────────────────
if command -v cfn-lint &>/dev/null; then
  echo "==> Linting ${TEMPLATE_DIR}/*.yaml"
  # cfn-lint exit code is a bitmask: 2 = error, 4 = warning, 8 = info.
  rc=0
  cfn-lint "${TEMPLATE_DIR}"/*.yaml || rc=$?
  if (( rc & 2 )); then
    echo "Error: cfn-lint reported errors" >&2
    exit 1
  fi
  (( rc != 0 )) && echo "  (cfn-lint warnings; non-blocking)"
else
  echo "==> cfn-lint not installed; skipping lint"
fi

# ── Inputs ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # backticks are a JMESPath literal, not shell
TEMPLATES_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-bootstrap" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TemplatesBucketName`].OutputValue' \
  --output text)
[ -n "$TEMPLATES_BUCKET" ] && [ "$TEMPLATES_BUCKET" != "None" ] || {
  echo "Error: could not read TemplatesBucketName from ${PROJECT_NAME}-bootstrap" >&2; exit 1; }

CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
if ! aws ecs describe-clusters --clusters "$CLUSTER" --region "$AWS_REGION" \
    --query 'clusters[0].capacityProviders' --output text | grep -qw FARGATE_SPOT; then
  echo "Warning: ${CLUSTER} has no FARGATE_SPOT capacity provider; preview stacks will fail" >&2
  echo "         until ./deploy/02-deploy-environment.sh ${ENVIRONMENT} --infra-only is run." >&2
fi

PR_TEMPLATE_KEY="preview/preview-pr-${GIT_SHA}.yaml"
PR_TEMPLATE_URI="s3://${TEMPLATES_BUCKET}/${PR_TEMPLATE_KEY}"
# Virtual-hosted regional form; matches the CI role's TemplateUrl condition.
PR_TEMPLATE_URL="https://${TEMPLATES_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${PR_TEMPLATE_KEY}"

echo "========================================"
echo "  Account:   $(aws sts get-caller-identity --query Account --output text)"
echo "  Region:    ${AWS_REGION}"
echo "  Stack:     ${STACK_NAME}"
echo "  PR tmpl:   ${PR_TEMPLATE_URL}"
echo "  SSM param: ${TEMPLATE_PARAM}"
echo "========================================"

if [ "$AUTO_APPROVE" != true ]; then
  read -r -p "Deploy? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Platform stack ───────────────────────────────────────────────────────────
echo "==> Deploying ${STACK_NAME} (first create waits on ACM validation + CloudFront, ~10-20 min)"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$PLATFORM_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$AWS_REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ProjectName="$PROJECT_NAME" \
    Environment="$ENVIRONMENT" \
  --tags \
    Project="$PROJECT_NAME" \
    Environment="$ENVIRONMENT" \
    ManagedBy=CloudFormation \
    Owner=springbok \
    Repository=nlm-ckn-iac

# ── Publish the per-PR template ──────────────────────────────────────────────
echo "==> Uploading ${PR_TEMPLATE} → ${PR_TEMPLATE_URI}"
aws s3 cp "$PR_TEMPLATE" "$PR_TEMPLATE_URI" --region "$AWS_REGION"

echo "==> Pointing ${TEMPLATE_PARAM} at it"
aws ssm put-parameter --region "$AWS_REGION" \
  --name "$TEMPLATE_PARAM" --type String --overwrite \
  --description "TemplateURL of the preview-pr.yaml version nlm-ckn-ui PR previews deploy (set by 03-deploy-preview-platform.sh)" \
  --value "$PR_TEMPLATE_URL" >/dev/null
# put-parameter cannot combine --overwrite with --tags; tag separately (idempotent).
aws ssm add-tags-to-resource --region "$AWS_REGION" \
  --resource-type Parameter --resource-id "$TEMPLATE_PARAM" \
  --tags Key=Project,Value="$PROJECT_NAME" Key=Environment,Value="$ENVIRONMENT" \
         Key=ManagedBy,Value=deploy-script Key=Owner,Value=springbok Key=Repository,Value=nlm-ckn-iac

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
echo ""
echo "Set these as nlm-ckn-ui repository variables for preview.yml:"
echo "  PreviewCiRoleArn, PreviewServiceRoleArn, PreviewBucketName, PreviewDistributionId,"
echo "  PreviewEcrRepositoryUri (above)"
echo ""
echo "If not yet done, seed the basic-auth credential in the KeyValueStore"
echo "(see the header of this script: aws cloudfront-keyvaluestore put-key ... --key basic-auth)."
