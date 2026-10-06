#!/usr/bin/env bash
# Exercise frontend-alb.yaml against the springbok dev environment before
# handing it to NIH. Runs alongside dev's CloudFront — it adds a :443 listener to
# dev's ALB and temporarily adds one statement to dev's frontend bucket policy
# (restored by `down`). Public DNS is never touched: checks use curl --resolve.
#
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh up      # deploy stack + bucket policy statement
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh check   # smoke-test through the ALB
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh down    # restore bucket policy + delete stack
set -euo pipefail

REGION=us-east-1
PROJECT=nlm-ckn
ENV=dev
HOST=dev.nlm-ckn.org
STACK="${PROJECT}-${ENV}-frontend-alb-test"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${HERE}/.dev-test-state"   # holds the original bucket policy (git-ignored)
mkdir -p "$STATE"

export AWS_REGION=$REGION

exp() {
  aws cloudformation list-exports --query "Exports[?Name=='$1'].Value" --output text
}

BUCKET=$(exp "${PROJECT}-${ENV}-frontend-bucket")

up() {
  local subnets
  subnets=$(jq -r '.[] | select(.ParameterKey=="PrivateSubnetIds") | .ParameterValue' \
    "${HERE}/../../environment/parameters/${ENV}.json")

  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "${HERE}/cloudformation/frontend-alb.yaml" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      ProjectName=$PROJECT Environment=$ENV \
      VpcId="$(jq -r '.[] | select(.ParameterKey=="VpcId") | .ParameterValue' "${HERE}/../../environment/parameters/${ENV}.json")" \
      EndpointSubnetIds="$subnets" \
      LoadBalancerArn="$(exp ${PROJECT}-${ENV}-alb-arn)" \
      LoadBalancerSecurityGroupId="$(exp ${PROJECT}-${ENV}-alb-sg-id)" \
      BackendTargetGroupArn="$(exp ${PROJECT}-${ENV}-backend-tg-arn)" \
      FrontendBucketName="$BUCKET" \
      CertificateArn="$(exp ${PROJECT}-${ENV}-acm-cert-arn)"

  local stmt
  stmt=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketPolicyStatement'].OutputValue" --output text)

  if [ ! -f "${STATE}/original-policy.json" ]; then
    aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text > "${STATE}/original-policy.json"
  fi
  jq --argjson s "$stmt" '.Statement = ([.Statement[] | select(.Sid != $s.Sid)] + [$s])' \
    "${STATE}/original-policy.json" > "${STATE}/test-policy.json"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${STATE}/test-policy.json"
  echo "Deployed ${STACK}; bucket policy statement added to ${BUCKET}."
}

check() {
  local alb_dns ip base tag js plot
  alb_dns=$(exp "${PROJECT}-${ENV}-alb-dns")
  ip=$(dig +short "$alb_dns" | head -1)
  base="https://${HOST}"
  c() { curl -sS -o /dev/null --resolve "${HOST}:443:${ip}" -w "%{http_code}  %{content_type}  enc=%header{content-encoding}  %{size_download}B" "$@"; }

  js=$(curl -sS --resolve "${HOST}:443:${ip}" "${base}/" | grep -o 'static/js/main[^"]*\.js' | head -1)
  tag=$(aws s3 ls "s3://${BUCKET}/plots/" | awk '/PRE/{print $2}' | tail -1)
  plot=$(aws s3 ls --recursive "s3://${BUCKET}/plots/${tag}" | sort -k3 -n | tail -1 | awk '{print $4}')

  echo "ALB ${alb_dns} (${ip}) as ${HOST}"
  printf '%-40s ' "/";                     c "${base}/"; echo "   expect 200 text/html"
  printf '%-40s ' "/some/client/route";    c "${base}/some/client/route"; echo "   expect 200 text/html (index.html)"
  printf '%-40s ' "/${js}";                c "${base}/${js}"; echo "   expect 200 javascript"
  printf '%-40s ' "/${plot:0:38}";         c "${base}/${plot}"; echo "   expect 200, enc=gzip (largest plot)"
  printf '%-40s ' "/does-not-exist.js";    c "${base}/does-not-exist.js"; echo "   expect 403 (S3 hides misses without ListBucket)"
  printf '%-40s ' "POST /arango_api/collections/"; c -X POST -H 'Content-Type: application/json' -d '{}' "${base}/arango_api/collections/"; echo "   expect 200 application/json (backend)"
}

down() {
  if [ -f "${STATE}/original-policy.json" ]; then
    aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${STATE}/original-policy.json"
    rm -f "${STATE}/original-policy.json" "${STATE}/test-policy.json"
    echo "Restored original bucket policy on ${BUCKET}."
  fi
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
  echo "Deleted ${STACK}."
}

case "${1:-}" in
  up) up ;;
  check) check ;;
  down) down ;;
  *) echo "usage: $0 up|check|down" >&2; exit 2 ;;
esac
