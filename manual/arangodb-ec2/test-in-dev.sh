#!/usr/bin/env bash
# Exercise arangodb-ec2.yaml in the springbok dev account before handing it to
# NIH. Deploys a SEPARATE ArangoDB alongside dev's (Environment=devtest, Cloud
# Map service arangodb-devtest in dev's namespace), so nothing dev uses changes.
# It restores the same dataset version dev is running.
#
#   AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh up      # deploy (~10-15 min)
#   AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh check   # query as the read-only user
#   AWS_PROFILE=springbok ./manual/arangodb-ec2/test-in-dev.sh down    # delete stack + retained volume/secrets
set -euo pipefail

export AWS_REGION=us-east-1
PROJECT=nlm-ckn
SRC_ENV=dev          # borrow network, namespace and dataset from here
ENV=devtest          # names everything this test creates
STACK="${PROJECT}-${ENV}-arangodb-ec2"
HERE="$(cd "$(dirname "$0")" && pwd)"

exp() { aws cloudformation list-exports --query "Exports[?Name=='$1'].Value" --output text; }
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

up() {
  local subnet az bucket version
  subnet=$(jq -r '.[] | select(.ParameterKey=="PrivateSubnetIds") | .ParameterValue' \
    "${HERE}/../../environment/parameters/${SRC_ENV}.json" | cut -d, -f1)
  az=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].AvailabilityZone' --output text)
  bucket=$(aws ssm get-parameter --name "/${PROJECT}/shared/arangodb-bucket-name" --query Parameter.Value --output text)
  version=$(aws ssm get-parameter --name "/${PROJECT}/${SRC_ENV}/arango/dataset-version" --query Parameter.Value --output text)
  echo "subnet=$subnet az=$az bucket=$bucket dataset=$version"

  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "${HERE}/cloudformation/arangodb-ec2.yaml" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      ProjectName=$PROJECT Environment=$ENV \
      SubnetId="$subnet" AvailabilityZone="$az" \
      SecurityGroupId="$(exp ${PROJECT}-${SRC_ENV}-arangodb-sg-id)" \
      CloudMapNamespaceId="$(exp ${PROJECT}-${SRC_ENV}-namespace-id)" \
      CloudMapServiceName=arangodb-${ENV} \
      Architecture=arm64 InstanceType=t4g.medium \
      DatasetBucketName="$bucket" DatasetVersion="$version"
  echo "Deployed ${STACK} (instance $(out InstanceId))."
}

check() {
  local iid cmd_id
  iid=$(out InstanceId)
  echo "Cloud Map registrations:"
  aws servicediscovery list-instances --service-id "$(out CloudMapServiceId)" \
    --query 'Instances[].[Id,Attributes.AWS_INSTANCE_IPV4]' --output text

  # Runs on the instance: authenticate as the read-only user, count collections
  # in each app database, and confirm a write is refused.
  local remote params
  remote=$(cat <<REMOTE
PW=\$(aws secretsmanager get-secret-value --region ${AWS_REGION} --secret-id /${PROJECT}/${ENV}/secrets/arangodb-password --query SecretString --output text)
for db in Cell-KN-Ontologies Cell-KN-Phenotypes; do
  n=\$(curl -s -u "nlm_ro:\$PW" "http://localhost:8529/_db/\$db/_api/collection?excludeSystem=true" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  echo "\$db collections: \$n   (expect > 0)"
done
code=\$(curl -s -o /dev/null -w '%{http_code}' -u "nlm_ro:\$PW" -X POST -d '{"name":"rotest"}' http://localhost:8529/_db/Cell-KN-Ontologies/_api/collection)
echo "write as nlm_ro: \$code   (expect 401/403)"
echo "restored dataset: \$(cat /var/lib/arangodb3/.dataset-version)"
REMOTE
)
  params=$(mktemp)
  jq -n --arg s "$remote" '{commands: [$s]}' > "$params"
  cmd_id=$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "file://$params" --query Command.CommandId --output text)
  rm -f "$params"
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$iid" || true
  echo "Run Command status: $(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" --query Status --output text)"
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
}

down() {
  local vol
  vol=$(out DataVolumeId 2>/dev/null || true)
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
  echo "Deleted ${STACK}."
  # Retained by design in real deployments; this test's copies are throwaway.
  if [ -n "$vol" ] && [ "$vol" != "None" ]; then
    aws ec2 wait volume-available --volume-ids "$vol"
    aws ec2 delete-volume --volume-id "$vol" && echo "Deleted test data volume $vol."
  fi
  for s in arangodb-root-password arangodb-password; do
    aws secretsmanager delete-secret --secret-id "/${PROJECT}/${ENV}/secrets/$s" \
      --force-delete-without-recovery >/dev/null && echo "Deleted test secret /${PROJECT}/${ENV}/secrets/$s."
  done
}

case "${1:-}" in
  up) up ;;
  check) check ;;
  down) down ;;
  *) echo "usage: $0 up|check|down" >&2; exit 2 ;;
esac
