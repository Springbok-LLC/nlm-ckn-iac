#!/usr/bin/env bash
# Exercise frontend-alb.yaml against the springbok dev environment before
# handing it to NIH. Runs alongside dev's CloudFront — it adds a :443 listener to
# dev's ALB and temporarily adds one statement to dev's frontend bucket policy
# (removed by `down`; the rest of the live policy is left as it is then).
# Public DNS is never touched: checks use curl --resolve.
#
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh up      # deploy stack + bucket policy statement
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh check   # smoke-test through the ALB (exits 1 on any mismatch)
#   AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh down    # delete stack + remove bucket policy statement
set -euo pipefail

REGION=us-east-1
PROJECT=nlm-ckn
ENV=dev
HOST=dev.nlm-ckn.org
STACK="${PROJECT}-${ENV}-frontend-alb-test"
HERE="$(cd "$(dirname "$0")" && pwd)"
SID=AllowFrontendAlbViaVpce   # Sid of the template's BucketPolicyStatement output

export AWS_REGION=$REGION

exp() {
  local v
  v=$(aws cloudformation list-exports --query "Exports[?Name=='$1'].Value" --output text) || return 1
  if [ -z "$v" ] || [ "$v" = "None" ]; then
    echo "error: CloudFormation export '$1' not found" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

BUCKET=$(exp "${PROJECT}-${ENV}-frontend-bucket")

# The bucket's live policy, minus the test statement. Falls back to an empty
# policy only when the bucket has none; any other read error aborts, so a
# later write can never replace the real statements.
current_policy_without_test() {
  local policy
  if ! policy=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>&1); then
    if [[ "$policy" != *NoSuchBucketPolicy* ]]; then
      echo "error: cannot read the bucket policy on ${BUCKET}: ${policy}" >&2
      return 1
    fi
    policy='{"Version":"2012-10-17","Statement":[]}'
  fi
  jq --arg sid "$SID" '.Statement = [.Statement[] | select(.Sid != $sid)]' <<<"$policy"
}

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

  local stmt policy
  stmt=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketPolicyStatement'].OutputValue" --output text)

  policy=$(current_policy_without_test)   # aborts here (set -e) if the read fails
  aws s3api put-bucket-policy --bucket "$BUCKET" \
    --policy "$(jq -c --argjson s "$stmt" '.Statement += [$s]' <<<"$policy")"
  echo "Deployed ${STACK}; bucket policy statement added to ${BUCKET}."
}

check() {
  local alb_dns ip base tag js plot failures=0
  alb_dns=$(exp "${PROJECT}-${ENV}-alb-dns")
  ip=$(dig +short "$alb_dns" | head -1)
  base="https://${HOST}"
  # c EXPECTED_STATUS CURL_ARGS... — prints the response summary and counts a
  # failure when the status differs (curl alone exits 0 on HTTP 4xx/5xx).
  c() {
    local want=$1 out got; shift
    out=$(curl -sS -o /dev/null --resolve "${HOST}:443:${ip}" -w "%{http_code}  %{content_type}  enc=%header{content-encoding}  %{size_download}B" "$@") || out="000  curl error"
    got=${out%% *}
    if [ "$got" = "$want" ]; then printf 'OK    %s' "$out"; else printf 'FAIL  %s' "$out"; failures=$((failures + 1)); fi
  }

  js=$(curl -sS --resolve "${HOST}:443:${ip}" "${base}/" | grep -o 'static/js/main[^"]*\.js' | head -1)
  tag=$(aws s3 ls "s3://${BUCKET}/plots/" | awk '/PRE/{print $2}' | tail -1)
  plot=$(aws s3 ls --recursive "s3://${BUCKET}/plots/${tag}" | sort -k3 -n | tail -1 | awk '{print $4}')

  echo "ALB ${alb_dns} (${ip}) as ${HOST}"
  printf '%-40s ' "/";                     c 200 "${base}/"; echo "   expect 200 text/html"
  printf '%-40s ' "/some/client/route";    c 200 "${base}/some/client/route"; echo "   expect 200 text/html (index.html)"
  printf '%-40s ' "/${js}";                c 200 "${base}/${js}"; echo "   expect 200 javascript"
  printf '%-40s ' "/${plot:0:38}";         c 200 "${base}/${plot}"; echo "   expect 200, enc=gzip (largest plot)"
  printf '%-40s ' "/does-not-exist.js";    c 403 "${base}/does-not-exist.js"; echo "   expect 403 (S3 hides misses without ListBucket)"
  printf '%-40s ' "POST /arango_api/collections/"; c 200 -X POST -H 'Content-Type: application/json' -d '{}' "${base}/arango_api/collections/"; echo "   expect 200 application/json (backend)"

  if [ "$failures" -gt 0 ]; then
    echo "${failures} check(s) failed." >&2
    exit 1
  fi
  echo "All checks passed."
}

down() {
  local policy
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
  echo "Deleted ${STACK}."
  policy=$(current_policy_without_test)
  if [ "$(jq '.Statement | length' <<<"$policy")" -eq 0 ]; then
    aws s3api delete-bucket-policy --bucket "$BUCKET"
  else
    aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(jq -c . <<<"$policy")"
  fi
  echo "Removed ${SID} from the bucket policy on ${BUCKET}."
}

case "${1:-}" in
  up) up ;;
  check) check ;;
  down) down ;;
  *) echo "usage: $0 up|check|down" >&2; exit 2 ;;
esac
