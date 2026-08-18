#!/bin/bash
# ==============================================================================
# deploy-account-setup.sh - One-time account setup
# ==============================================================================
# Deploys the bootstrap and shared resource stacks. Run once per AWS account
# before deploying any environments.
#
# USAGE:
#   ./deploy/01-deploy-account-setup.sh
#
# WHAT IT DOES:
#   1. Deploys bootstrap stack (S3 buckets, GitHub OIDC, IAM role)
#   2. Deploys shared stack (ECR repository, ArangoDB S3 bucket)
#   3. Deploys static-assets stack (plot asset S3 bucket, nlm-ckn push role)
#   4. Stores shared outputs in SSM Parameter Store
#
# PREREQUISITES:
#   - AWS CLI configured with appropriate credentials
#   - IAM permissions to create S3, IAM, ECR, SSM resources
# ==============================================================================
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
# PROJECT_NAME comes from the shared constant (single source of truth).
source "$(dirname "$0")/lib/common.sh"
GITHUB_ORG="Springbok-LLC"
GITHUB_REPO="nlm-ckn-ui"
AWS_REGION=${AWS_REGION:-us-east-1}
# AWS allows only one OIDC provider per URL per account. Leave unset to
# auto-detect, or force with CREATE_OIDC_PROVIDER=true|false.
CREATE_OIDC_PROVIDER=${CREATE_OIDC_PROVIDER:-}

# Change to repo root (script lives in deploy/)
cd "$(dirname "$0")/.."

# Resolve current AWS identity
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "(no alias)")
AWS_IAM_ARN=$(aws sts get-caller-identity --query Arn --output text)

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  Deployment Target${NC}"
echo -e "${YELLOW}========================================${NC}"
echo "  Account ID:    $AWS_ACCOUNT_ID"
echo "  Account Alias: $AWS_ACCOUNT_ALIAS"
echo "  IAM Principal: $AWS_IAM_ARN"
echo "  Region:        $AWS_REGION"
echo "  Stacks:        ${PROJECT_NAME}-bootstrap, ${PROJECT_NAME}-shared, ${PROJECT_NAME}-static-assets"
echo -e "${YELLOW}========================================${NC}"
echo ""
read -r -p "Deploy to this account? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ============================================================================
# Bootstrap stack
# ============================================================================
# Auto-detect an existing GitHub OIDC provider unless explicitly overridden.
# AWS permits only one provider per URL per account, so creating a second fails.
if [[ -z "$CREATE_OIDC_PROVIDER" ]]; then
  OIDC_URL="token.actions.githubusercontent.com"
  EXISTING_OIDC=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_URL')].Arn" \
    --output text 2>/dev/null || true)
  if [[ -n "$EXISTING_OIDC" ]]; then
    CREATE_OIDC_PROVIDER=false
    echo -e "${YELLOW}  GitHub OIDC provider already exists; reusing it${NC}"
    echo "    $EXISTING_OIDC"
  else
    CREATE_OIDC_PROVIDER=true
  fi
fi

echo -e "${GREEN}==> Deploying Bootstrap Stack${NC}"
echo "  GitHub: $GITHUB_ORG/$GITHUB_REPO"
echo "  Create OIDC provider: $CREATE_OIDC_PROVIDER"
echo ""

aws cloudformation deploy \
  --template-file account/cloudformation/bootstrap.yaml \
  --stack-name ${PROJECT_NAME}-bootstrap \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName=$PROJECT_NAME \
    GitHubOrg=$GITHUB_ORG \
    GitHubRepo=$GITHUB_REPO \
    CreateOIDCProvider=$CREATE_OIDC_PROVIDER \
  --region $AWS_REGION

echo -e "\n${GREEN}✓ Bootstrap stack deployed${NC}\n"

# ============================================================================
# Shared resources stack
# ============================================================================
echo -e "${GREEN}==> Deploying Shared Resources Stack${NC}"
echo ""

aws cloudformation deploy \
  --template-file shared/cloudformation/shared-resources.yaml \
  --stack-name ${PROJECT_NAME}-shared \
  --parameter-overrides \
    ProjectName=$PROJECT_NAME \
  --region $AWS_REGION

echo -e "\n${GREEN}✓ Shared resources stack deployed${NC}\n"

# ============================================================================
# Static assets stack
# ============================================================================
# Plot asset bucket + the GitHub OIDC role nlm-ckn's publish workflow assumes.
# Deployed after bootstrap because it references the OIDC provider that stack
# owns. CAPABILITY_NAMED_IAM: the role has an explicit RoleName.
echo -e "${GREEN}==> Deploying Static Assets Stack${NC}"
echo ""

aws cloudformation deploy \
  --template-file shared/cloudformation/static-assets.yaml \
  --stack-name ${PROJECT_NAME}-static-assets \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName=$PROJECT_NAME \
  --region $AWS_REGION

echo -e "\n${GREEN}✓ Static assets stack deployed${NC}\n"

# ============================================================================
# Collect and store outputs
# ============================================================================
echo -e "${GREEN}==> Stack Outputs${NC}"

GITHUB_ACTIONS_ROLE=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-bootstrap \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`GitHubActionsRoleArn`].OutputValue' \
  --output text)

ECR_URL=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-shared \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`EcrRepositoryUrl`].OutputValue' \
  --output text)

S3_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-shared \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`ArangoDbS3BucketName`].OutputValue' \
  --output text)

# The static-assets stack publishes its own bucket name to SSM
# (/${PROJECT_NAME}/shared/static-assets-bucket-name) as a CloudFormation
# resource, so these are read only to print below.
ASSETS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-static-assets \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`StaticAssetsBucketName`].OutputValue' \
  --output text)

ASSET_PUSH_ROLE=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-static-assets \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`AssetPushRoleArn`].OutputValue' \
  --output text)

# Store shared outputs in SSM for easy reference by other scripts
aws ssm put-parameter \
  --name "/${PROJECT_NAME}/shared/ecr-url" \
  --value "$ECR_URL" \
  --type String \
  --overwrite \
  --region $AWS_REGION 2>/dev/null || true

aws ssm put-parameter \
  --name "/${PROJECT_NAME}/shared/arangodb-bucket-name" \
  --value "$S3_BUCKET" \
  --type String \
  --overwrite \
  --region $AWS_REGION 2>/dev/null || true

echo "  GitHub Actions Role:  $GITHUB_ACTIONS_ROLE"
echo "  ECR URL:              $ECR_URL"
echo "  ArangoDB S3 Bucket:   $S3_BUCKET"
echo "  Static Assets Bucket: $ASSETS_BUCKET"
echo "  Asset Push Role:      $ASSET_PUSH_ROLE"

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Configure GitHub Actions to use the IAM role:"
echo "   $GITHUB_ACTIONS_ROLE"
echo ""
echo "2. Set the nlm-ckn repo's AWS_ASSET_PUSH_ROLE_ARN Actions secret to:"
echo "   $ASSET_PUSH_ROLE"
echo ""
echo "3. Deploy an environment:"
echo "   ./deploy/02-deploy-environment.sh dev"
