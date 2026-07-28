#!/bin/bash
# ==============================================================================
# cutover-frontend-cdn.sh — move the domain alias to the new CloudFront distribution
# ==============================================================================
# Performs the frontend CDN cutover for an environment that already has its new
# distribution standing by (deployed alias-less). It moves the domain's alias
# from whatever distribution currently owns it onto the new one, repoints DNS,
# and reconciles the CloudFormation stack.
#
# WHY THIS EXISTS:
#   A CloudFront alternate domain name (the alias) and its Route53 record are
#   globally unique, so a brand-new distribution can't be created already
#   carrying them — it collides with the environment currently serving the
#   domain (CNAMEAlreadyExists). The frontend-cdn stack is therefore deployed in
#   two passes:
#     1. AttachAlias=false  → distribution comes up alias-less but WITH the ACM
#        cert (all associate-alias needs). This is the normal `--cdn-only` deploy.
#     2. This script         → move the alias onto it, repoint DNS, then redeploy
#        the stack with AttachAlias=true to fold the alias + record back under
#        CloudFormation management.
#
# DOWNTIME:
#   The alias move itself is atomic — there is never a moment where no
#   distribution owns the domain. But CloudFront config changes take a few
#   minutes to propagate to the edges, so the domain is effectively unavailable
#   from when the alias leaves the old distribution until the new one finishes
#   deploying and DNS is repointed (~one distribution deploy). That is roughly
#   half the old remove-then-add approach, with no ordering fragility.
#
# PREREQUISITES:
#   - The frontend-cdn stack is deployed alias-less:
#       ./deploy/02-deploy-environment.sh <env> --cdn-only
#   - The frontend bucket already has the built bundle synced
#     (nlm-ckn-ui: ./scripts/app/deploy-frontend.sh <env>).
#   - AWS CLI configured for the target account.
#
# USAGE:
#   ./deploy/cutover-frontend-cdn.sh <environment> [--auto-approve]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# CloudFront's own hosted zone id — constant for all alias records that target a
# distribution (same value the stack hard-codes in DnsRecord).
CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"

# ── Arguments ─────────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  echo "Usage: $0 <environment> [--auto-approve]"
  echo "Example: $0 stage"
  exit 1
fi

ENVIRONMENT="$1"; shift
AUTO_APPROVE=false
for arg in "$@"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE=true ;;
    *) echo -e "${RED}Error: Unknown option: $arg${NC}"; exit 1 ;;
  esac
done

if [[ ! "$ENVIRONMENT" =~ ^(dev|stage|sandbox|prod)$ ]]; then
  echo -e "${RED}Error: Environment must be dev, stage, sandbox, or prod${NC}"
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
CDN_STACK="${PROJECT_NAME}-${ENVIRONMENT}-frontend-cdn"

# ── Helper: read a cross-stack export value ───────────────────────────────────
# NOTE: no `| [0]` in the query. list-exports paginates, and the CLI applies the
# JMESPath filter PER PAGE — with `| [0]` every page that lacks the export emits
# a literal "None", so the value comes back multi-line (e.g. "None\nnlm-ckn.org").
# Filtering to .Value and taking the first non-empty line avoids that entirely.
get_export() {
  aws cloudformation list-exports \
    --region "$AWS_REGION" \
    --query "Exports[?Name=='$1'].Value" \
    --output text 2>/dev/null | awk 'NF && !seen {print; seen=1}' || true
}

confirm() {
  $AUTO_APPROVE && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ── 1. Resolve the target (new) distribution ─────────────────────────────────
echo -e "${GREEN}Resolving the new distribution from $CDN_STACK...${NC}"
NEW_DIST_ID=$(aws cloudformation describe-stacks \
  --stack-name "$CDN_STACK" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionId`].OutputValue' \
  --output text 2>/dev/null || true)

if [ -z "$NEW_DIST_ID" ] || [ "$NEW_DIST_ID" = "None" ]; then
  echo -e "${RED}Error: could not read CloudFrontDistributionId from $CDN_STACK.${NC}"
  echo "Deploy the distribution alias-less first:"
  echo "  ./deploy/02-deploy-environment.sh ${ENVIRONMENT} --cdn-only"
  exit 1
fi

NEW_DIST_DOMAIN=$(aws cloudfront get-distribution \
  --id "$NEW_DIST_ID" --region "$AWS_REGION" \
  --query 'Distribution.DomainName' --output text)

# ── 2. Resolve the alias domain + hosted zone ─────────────────────────────────
BASE_DOMAIN=$(get_export "${PROJECT_NAME}-${ENVIRONMENT}-domain-name")
HOSTED_ZONE_ID=$(get_export "${PROJECT_NAME}-${ENVIRONMENT}-hosted-zone-id")
if [ -z "$BASE_DOMAIN" ] || [ "$BASE_DOMAIN" = "None" ] || [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
  echo -e "${RED}Error: missing domain-name / hosted-zone-id exports for ${ENVIRONMENT}.${NC}"
  exit 1
fi

if [ "$ENVIRONMENT" = "prod" ]; then
  ALIAS_DOMAIN="$BASE_DOMAIN"          # apex for prod
else
  ALIAS_DOMAIN="${ENVIRONMENT}.${BASE_DOMAIN}"
fi

# Guard: a malformed domain (whitespace/newlines, empty labels) must never flow
# into associate-alias / Route53 / the owner check. Require a clean hostname.
# The explicit whitespace test is needed because bash's `$` anchor can match at
# an embedded newline, letting a multi-line value slip past the pattern alone.
if [[ "$ALIAS_DOMAIN" =~ [[:space:]] ]] || \
   [[ ! "$ALIAS_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
  echo -e "${RED}Error: resolved alias domain is not a valid hostname: '${ALIAS_DOMAIN}'${NC}"
  echo "Check the ${PROJECT_NAME}-${ENVIRONMENT}-domain-name export."
  exit 1
fi

# ── 3. Find who currently owns the alias ──────────────────────────────────────
# Same pagination caveat as get_export: no `| [0]` in the query — filter, then
# take the first non-empty line so a paginated response can't inject "None".
# The `Aliases.Items &&` guard is REQUIRED: distributions with no alternate
# domain names have a null Aliases.Items, and contains(null, ...) is a hard
# JMESPath error that would abort the query (and our own alias-less distribution
# is one such distribution). `&&` short-circuits, skipping contains() for them.
CURRENT_OWNER=$(aws cloudfront list-distributions \
  --region "$AWS_REGION" \
  --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${ALIAS_DOMAIN}')].Id" \
  --output text 2>/dev/null | awk 'NF && !seen {print; seen=1}' || true)

echo ""
echo -e "${BLUE}Cutover plan${NC}"
echo "  Environment:        $ENVIRONMENT"
echo "  Alias (domain):     $ALIAS_DOMAIN"
echo "  New distribution:   $NEW_DIST_ID ($NEW_DIST_DOMAIN)"
echo "  Current alias owner: ${CURRENT_OWNER:-<none — alias is unclaimed>}"
echo ""

if [ "$CURRENT_OWNER" = "$NEW_DIST_ID" ]; then
  echo -e "${YELLOW}The alias is already on the new distribution — skipping the move.${NC}"
elif [ -z "$CURRENT_OWNER" ]; then
  echo -e "${YELLOW}No distribution currently owns $ALIAS_DOMAIN. It will be attached${NC}"
  echo -e "${YELLOW}to the new distribution directly by the reconcile deploy (no move needed).${NC}"
else
  echo -e "${YELLOW}This will move $ALIAS_DOMAIN from $CURRENT_OWNER to $NEW_DIST_ID.${NC}"
  echo -e "${YELLOW}The domain will be briefly unavailable while CloudFront propagates (~minutes).${NC}"
  confirm "Proceed with the alias move?" || { echo "Aborted."; exit 1; }

  # ── 4. Alias move ───────────────────────────────────────────────────────────
  # AssociateAlias enforces an ownership-verification TXT record — even for
  # same-account moves via the CLI/SDK (the console skips it; the API does not,
  # which surfaces as "IllegalUpdate: Invalid or missing alias DNS TXT records").
  # Per AWS docs the record is "_<alias>" for a subdomain, "_.<apex>" for an apex,
  # with the target distribution's domain as the value. We create it, move the
  # alias, then remove it (an EXIT trap guarantees cleanup even on failure).
  if [ "$ENVIRONMENT" = "prod" ]; then
    TXT_NAME="_.${ALIAS_DOMAIN}"     # apex
  else
    TXT_NAME="_${ALIAS_DOMAIN}"      # subdomain
  fi
  TXT_CREATED=false

  txt_change_batch() {  # $1 = UPSERT | DELETE
    cat <<JSON
{
  "Comment": "cutover-frontend-cdn: AssociateAlias ownership verification",
  "Changes": [{
    "Action": "$1",
    "ResourceRecordSet": {
      "Name": "${TXT_NAME}",
      "Type": "TXT",
      "TTL": 60,
      "ResourceRecords": [{ "Value": "\"${NEW_DIST_DOMAIN}\"" }]
    }
  }]
}
JSON
  }
  cleanup_txt() {
    [ "${TXT_CREATED}" = true ] || return 0
    echo -e "${GREEN}Removing the verification TXT record ${TXT_NAME}...${NC}"
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "$(txt_change_batch DELETE)" >/dev/null 2>&1 \
      || echo -e "${YELLOW}Could not delete TXT record ${TXT_NAME} — remove it manually.${NC}"
    TXT_CREATED=false
  }
  trap cleanup_txt EXIT

  echo -e "\n${GREEN}Creating verification TXT record ${TXT_NAME} → ${NEW_DIST_DOMAIN}...${NC}"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$(txt_change_batch UPSERT)" >/dev/null
  TXT_CREATED=true

  echo -e "${GREEN}Moving the alias to $NEW_DIST_ID (retries while the TXT record propagates)...${NC}"
  ASSOC_ERR="$(mktemp)"
  moved=false
  for attempt in $(seq 1 12); do
    if aws cloudfront associate-alias \
         --alias "$ALIAS_DOMAIN" \
         --target-distribution-id "$NEW_DIST_ID" \
         --region "$AWS_REGION" 2>"$ASSOC_ERR"; then
      moved=true; break
    fi
    if grep -qi "TXT record" "$ASSOC_ERR"; then
      echo -e "${YELLOW}  TXT record not visible to CloudFront yet; retrying in 15s (${attempt}/12)...${NC}"
      sleep 15
    else
      echo -e "${RED}associate-alias failed:${NC}"; cat "$ASSOC_ERR" >&2
      rm -f "$ASSOC_ERR"; exit 1
    fi
  done
  rm -f "$ASSOC_ERR"
  if [ "$moved" != true ]; then
    echo -e "${RED}associate-alias did not succeed after retries (TXT propagation).${NC}"
    echo "Verify the record resolves:  dig +short TXT ${TXT_NAME}"
    exit 1
  fi
  cleanup_txt
fi

# ── 5. Attach the alias to the new distribution (CloudFormation reconcile) ─────
# This runs BEFORE the DNS switch, and it must:
#   - move case:      assert the alias already put on the distribution by
#                     associate-alias (idempotent update).
#   - unclaimed case: actually attach the alias here (nothing else does). DNS
#                     must never point at a distribution that can't answer for
#                     the domain, so this precedes the Route53 UPSERT below.
# CloudFormation no longer manages the Route53 record (see frontend-cdn.yaml),
# so this update cannot collide on "record already exists".
echo ""
echo -e "${BLUE}Attaching the alias to the new distribution (CloudFormation reconcile)...${NC}"
echo "  Runs: ./deploy/02-deploy-environment.sh ${ENVIRONMENT} --cdn-only --attach-alias"
if ! confirm "Run the reconcile deploy now?"; then
  echo -e "${YELLOW}Aborted before attaching the alias — DNS was NOT repointed.${NC}"
  echo "  Re-run this script when ready (nothing below has changed)."
  exit 1
fi
RECONCILE_ARGS=(--cdn-only --attach-alias)
$AUTO_APPROVE && RECONCILE_ARGS+=(--auto-approve)
"$SCRIPT_DIR/02-deploy-environment.sh" "$ENVIRONMENT" "${RECONCILE_ARGS[@]}"

# ── 6. Wait for the distribution to serve the alias, then point DNS at it ──────
echo -e "\n${GREEN}Waiting for the new distribution to finish deploying...${NC}"
aws cloudfront wait distribution-deployed --id "$NEW_DIST_ID" --region "$AWS_REGION"

echo -e "${GREEN}Pointing $ALIAS_DOMAIN at the new distribution (Route53 UPSERT)...${NC}"
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$(cat <<JSON
{
  "Comment": "cutover-frontend-cdn: point ${ALIAS_DOMAIN} at ${NEW_DIST_ID}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${ALIAS_DOMAIN}",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "${NEW_DIST_DOMAIN}",
        "HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
JSON
)" >/dev/null

# ── 7. Verify serving ─────────────────────────────────────────────────────────
echo -e "\n${GREEN}Verifying $ALIAS_DOMAIN...${NC}"
echo "  dig: $(dig +short "$ALIAS_DOMAIN" | head -1)"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${ALIAS_DOMAIN}/" || echo "000")
echo "  https://${ALIAS_DOMAIN}/ → HTTP $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo -e "${YELLOW}Not 200 yet — DNS/edge may still be propagating. Re-check in a minute.${NC}"
fi

echo ""
echo -e "${GREEN}✓ Cutover complete for ${ENVIRONMENT}.${NC}"
echo ""
echo -e "${YELLOW}Decommissioning the OLD environment:${NC}"
echo "  The old distribution no longer owns the alias or the live DNS record. The"
echo "  Route53 record is now script-managed (owned by no stack). If an OLD stack"
echo "  still declares a record for this domain, remove/retain it before deleting"
echo "  that stack so it can't delete the live record. Then disable + delete the"
echo "  old distribution${CURRENT_OWNER:+ ($CURRENT_OWNER)}."
