"""Custom cfn-lint rule: require tag propagation on resources that launch
tasks/instances (ADR 0004 tag-based identity).

A `Tags` block on an ECS service, a Batch job definition, or an EventBridge
Scheduler ECS target only tags the *definition* — the tasks/instances it
launches stay untagged unless propagation is explicitly enabled. E9101 checks
that the tags are present; this rule (E9102) checks that they actually reach
the launched resources.

Companion to required_tags.py; loaded via `append_rules: [.cfn-lint-rules]`.
"""

from cfnlint.rules import CloudFormationLintRule, RuleMatch


def _is_true(val):
    return val is True or (isinstance(val, str) and val.lower() == "true")


class TagPropagation(CloudFormationLintRule):
    """Require tag propagation on task/instance-launching resources."""

    id = "E9102"
    shortdesc = "Tag propagation enabled"
    description = (
        "ECS services, Batch job definitions, and Scheduler ECS targets must "
        "enable tag propagation so the ADR 0004 tag set reaches the launched "
        "tasks/instances, not just the definition."
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
            rtype = resource.get("Type")
            props = resource.get("Properties", {})
            if not isinstance(props, dict):
                props = {}

            if rtype == "AWS::ECS::Service":
                val = props.get("PropagateTags")
                if val not in ("SERVICE", "TASK_DEFINITION"):
                    matches.append(
                        RuleMatch(
                            ["Resources", name, "Properties", "PropagateTags"],
                            "{0} (AWS::ECS::Service) must set PropagateTags to "
                            "SERVICE or TASK_DEFINITION so tags reach its tasks "
                            "(currently {1!r})".format(name, val),
                        )
                    )

            elif rtype == "AWS::Batch::JobDefinition":
                val = props.get("PropagateTags")
                if not _is_true(val):
                    matches.append(
                        RuleMatch(
                            ["Resources", name, "Properties", "PropagateTags"],
                            "{0} (AWS::Batch::JobDefinition) must set "
                            "PropagateTags: true so tags reach the ECS task "
                            "(currently {1!r})".format(name, val),
                        )
                    )

            elif rtype == "AWS::Scheduler::Schedule":
                target = props.get("Target", {})
                ecs = target.get("EcsParameters") if isinstance(target, dict) else None
                # Only ECS targets have anything to propagate.
                if isinstance(ecs, dict):
                    val = ecs.get("PropagateTags")
                    if val != "TASK_DEFINITION":
                        matches.append(
                            RuleMatch(
                                [
                                    "Resources", name, "Properties",
                                    "Target", "EcsParameters", "PropagateTags",
                                ],
                                "{0} (AWS::Scheduler::Schedule ECS target) must "
                                "set EcsParameters.PropagateTags: TASK_DEFINITION "
                                "(currently {1!r})".format(name, val),
                            )
                        )
        return matches
