"""Custom cfn-lint rule: enforce the ADR 0004 standard tag set.

Every taggable resource must carry the required identity tags so that
grouping, querying, and cost allocation key off tags rather than parsed
physical names (docs/architecture/decisions ADR 0004).

Loaded via `append_rules: [.cfn-lint-rules]` in .cfnlintrc.yaml. The CI
(.github/workflows/cfn-validate.yml) only lints *changed* templates, so this
enforces the standard on new/edited templates without a repo-wide retrofit.

Notes:
- Both tag shapes are handled: the list form (``- Key: .. / Value: ..``) used
  by most resources, and the map form (``Project: ..``) required by
  AWS::SSM::Parameter and the AWS::Batch::* resources.
- Only the resource types in TAGGABLE_TYPES are checked, to keep false
  positives at zero. Add a type here when a template starts using it.
"""

from cfnlint.rules import CloudFormationLintRule, RuleMatch

# ADR 0004 required tag keys. `Environment` is intentionally omitted because
# some stacks (shared / etl) are not per-environment; add it here if the repo
# decides to require it everywhere.
REQUIRED_TAGS = ["Project", "Owner", "ManagedBy", "Repository"]

# Resource types that support a top-level `Properties.Tags` and that this repo
# expects to be tagged. Types that don't take `Properties.Tags` (e.g.
# AWS::IAM::Policy, AWS::IAM::InstanceProfile, AWS::EC2::LaunchTemplate,
# AWS::Scheduler::Schedule) are deliberately excluded.
TAGGABLE_TYPES = {
    "AWS::Batch::ComputeEnvironment",
    "AWS::Batch::JobDefinition",
    "AWS::Batch::JobQueue",
    "AWS::CloudFront::Distribution",
    "AWS::EC2::SecurityGroup",
    "AWS::EC2::Subnet",
    "AWS::EC2::VPC",
    "AWS::ECR::Repository",
    "AWS::ECS::Cluster",
    "AWS::ECS::Service",
    "AWS::ECS::TaskDefinition",
    "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "AWS::ElasticLoadBalancingV2::TargetGroup",
    "AWS::IAM::OIDCProvider",
    "AWS::IAM::Role",
    "AWS::Lambda::Function",
    "AWS::Logs::LogGroup",
    "AWS::S3::Bucket",
    "AWS::SNS::Topic",
    "AWS::SSM::Parameter",
    "AWS::SecretsManager::Secret",
}


def _present_tag_keys(tags):
    """Return the set of literal tag keys declared on a resource.

    Handles both the list form (list of {Key, Value}) and the map form
    (dict of key -> value). Non-string / intrinsic keys are ignored.
    """
    keys = set()
    if isinstance(tags, list):
        for item in tags:
            if isinstance(item, dict):
                key = item.get("Key")
                if isinstance(key, str):
                    keys.add(key)
    elif isinstance(tags, dict):
        for key in tags:
            if isinstance(key, str):
                keys.add(key)
    return keys


class RequiredTags(CloudFormationLintRule):
    """Require the ADR 0004 standard tag set on every taggable resource."""

    id = "E9101"
    shortdesc = "Required tags present"
    description = (
        "Every taggable resource must carry the ADR 0004 standard tag set "
        "(" + ", ".join(REQUIRED_TAGS) + ")."
    )
    tags = ["resources", "tags"]

    def match(self, cfn):
        matches = []
        resources = cfn.template.get("Resources", {})
        if not isinstance(resources, dict):
            return matches

        for name, resource in resources.items():
            if not isinstance(resource, dict):
                continue
            if resource.get("Type") not in TAGGABLE_TYPES:
                continue

            properties = resource.get("Properties", {})
            tags = properties.get("Tags") if isinstance(properties, dict) else None
            present = _present_tag_keys(tags)
            missing = [t for t in REQUIRED_TAGS if t not in present]
            if missing:
                matches.append(
                    RuleMatch(
                        ["Resources", name, "Properties", "Tags"],
                        "{0} ({1}) is missing required tag(s): {2}".format(
                            name, resource.get("Type"), ", ".join(missing)
                        ),
                    )
                )
        return matches
