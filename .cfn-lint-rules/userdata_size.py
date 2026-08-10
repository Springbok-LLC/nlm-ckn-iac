"""Custom cfn-lint rule: keep EC2 UserData under the hard API size limit.

EC2 rejects a launch outright when UserData exceeds 25600 base64-encoded bytes
(~19200 raw). Nothing in the normal validation path catches this:

  - `cfn-lint` has no size rule for the property.
  - `aws cloudformation validate-template` accepts the template.
  - A changeset dry run *also* accepts it — the changeset is created fine and
    the failure only surfaces at EXECUTE time, when CloudFormation calls the
    EC2 API. On an UPDATE that means a full rollback before you learn about it:

        Encoded User data is limited to 25600 bytes
        (Service: Ec2, Status Code: 400) HandlerErrorCode: InvalidRequest

That is exactly how nlm-ckn-dev-arangodb failed: a 112-line addition to the
UserData script pushed it ~900 bytes over, and the first signal was a rolled
back stack update. This rule moves that failure to lint time.

Loaded via `append_rules: [.cfn-lint-rules]` in .cfnlintrc.yaml.

Sizing notes:
- The size is measured on the *literal* template text. Fn::Sub placeholders are
  counted at their placeholder width unless the Fn::Sub carries a variable map
  with literal values, which are substituted before measuring; a Ref/GetAtt
  value is unknown at lint time. In practice the delta is small (tens of bytes)
  relative to the margin this rule is protecting, and it is as often negative
  as positive.
- `${!Literal}` escapes render one byte shorter (`${Literal}`) and are adjusted.
- UserData is documented as *already base64-encoded*, so a literal string value
  is the encoded payload and the raw script is what it decodes to. Only an
  Fn::Base64 wraps a raw script, and only there is the 4/3 expansion applied.
- Because of that approximation, E9103 is deliberately a hard-limit check rather
  than a tight budget check. Set WARN_RATIO below 1.0 to also get W9103, an
  early warning as a template approaches the ceiling.
"""

import math

from cfnlint.rules import CloudFormationLintRule, RuleMatch

# EC2 enforces TWO independent limits and only reports the second once the
# first is satisfied, so a fix aimed at the encoded limit alone can still be
# rejected. Both are checked here.
#
#   raw     > 16384 -> "User data is limited to 16384 bytes"
#   encoded > 25600 -> "Encoded User data is limited to 25600 bytes"
#
# 16384 raw is the binding constraint in practice: it base64-encodes to 21848,
# well under the 25600 encoded cap. Do NOT infer the raw budget from the
# encoded cap (25600 * 3/4 = 19200) — that is 2816 bytes too generous and was
# the reason nlm-ckn-dev-arangodb failed a second time.
MAX_RAW_BYTES = 16384
MAX_ENCODED_BYTES = 25600

# Emit an additional warning at this fraction of the limit. Set to e.g. 0.90 to
# be told before an edit takes the template over. 1.0 disables the warning.
WARN_RATIO = 1.0

# Where UserData lives, per resource type.
USERDATA_PATHS = {
    "AWS::EC2::Instance": ("UserData",),
    "AWS::EC2::LaunchTemplate": ("LaunchTemplateData", "UserData"),
    "AWS::AutoScaling::LaunchConfiguration": ("UserData",),
}


def _literal_size(node):
    """Best-effort byte length of the rendered UserData string.

    Understands the shapes this repo uses (Fn::Base64 wrapping a plain string,
    an Fn::Sub, or an Fn::Join) and returns None for anything it cannot size
    confidently, so unknown shapes are skipped rather than guessed at.
    """
    if isinstance(node, str):
        return len(node.encode("utf-8"))

    if not isinstance(node, dict) or len(node) != 1:
        return None

    fn, value = next(iter(node.items()))

    if fn == "Fn::Base64":
        # Size the payload; the base64 expansion is applied by the caller.
        return _literal_size(value)

    if fn == "Fn::Sub":
        # Either "text" or ["text", {vars}].
        if isinstance(value, list):
            if not value:
                return None
            text = value[0]
            variables = value[1] if len(value) > 1 else {}
        else:
            text, variables = value, {}
        if not isinstance(text, str) or not isinstance(variables, dict):
            return None
        # `${!Foo}` is an escape that renders as `${Foo}` — one byte shorter.
        # Counted on the template text, before substitution, so a substituted
        # value that happens to contain `${!` is not mistaken for an escape.
        escapes = text.count("${!")
        # Literal entries in the variable map render at their own width, so
        # substitute them rather than counting the placeholder. `${!Foo}` is
        # untouched by this: it does not contain the `${Foo}` substring.
        # Non-literal entries (Ref/GetAtt) stay at placeholder width — see the
        # sizing notes in the module docstring.
        for name, replacement in variables.items():
            if isinstance(replacement, str):
                text = text.replace("${" + name + "}", replacement)
        return len(text.encode("utf-8")) - escapes

    if fn == "Fn::Join":
        if not (isinstance(value, list) and len(value) == 2):
            return None
        delimiter, parts = value
        if not (isinstance(delimiter, str) and isinstance(parts, list)):
            return None
        total = len(delimiter.encode("utf-8")) * max(len(parts) - 1, 0)
        for part in parts:
            size = _literal_size(part)
            if size is None:
                return None
            total += size
        return total

    # Ref / Fn::ImportValue / etc. — unknowable width, and never the bulk of a
    # UserData script in practice.
    return None


def _encoded_size(raw_bytes):
    """base64 length for a payload of raw_bytes."""
    return math.ceil(raw_bytes / 3) * 4


def _decoded_size(encoded_bytes):
    """Raw payload length behind a base64 string of encoded_bytes."""
    return encoded_bytes // 4 * 3


def _userdata_sizes(node):
    """(raw, encoded) sizes for a UserData property value, or None.

    Only Fn::Base64 wraps a *raw* script, so that is the one shape where the
    4/3 expansion applies. Every other shape is the already-encoded form EC2
    receives verbatim — its literal text is the encoded payload, and the raw
    script is what that decodes to. Measuring those as raw and expanding them
    again would overstate the payload by a third.
    """
    if isinstance(node, dict) and len(node) == 1 and "Fn::Base64" in node:
        raw = _literal_size(node["Fn::Base64"])
        return None if raw is None else (raw, _encoded_size(raw))

    encoded = _literal_size(node)
    return None if encoded is None else (_decoded_size(encoded), encoded)


def _walk(properties, path):
    node = properties
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def _iter_userdata(cfn):
    """Yield (resource name, template path, raw bytes, encoded bytes)."""
    resources = cfn.template.get("Resources", {})
    if not isinstance(resources, dict):
        return

    for name, resource in resources.items():
        if not isinstance(resource, dict):
            continue
        path = USERDATA_PATHS.get(resource.get("Type"))
        if path is None:
            continue

        properties = resource.get("Properties")
        if not isinstance(properties, dict):
            continue

        node = _walk(properties, path)
        if node is None:
            continue

        sizes = _userdata_sizes(node)
        if sizes is None:
            continue

        raw, encoded = sizes
        yield name, ["Resources", name, "Properties"] + list(path), raw, encoded


class UserDataSize(CloudFormationLintRule):
    """Fail when EC2 UserData would exceed the 25600-byte encoded API limit."""

    id = "E9103"
    shortdesc = "UserData within EC2 size limit"
    description = (
        "EC2 rejects UserData larger than {0} base64-encoded bytes. Neither "
        "validate-template nor a changeset dry run catches this, so it is "
        "enforced at lint time.".format(MAX_ENCODED_BYTES)
    )
    tags = ["resources", "ec2", "userdata", "limits"]

    def match(self, cfn):
        matches = []

        for name, location, raw, encoded in _iter_userdata(cfn):
            remedy = (
                "EC2 rejects the launch with InvalidRequest and CloudFormation "
                "rolls the stack back. Move the bulk of the script out of "
                "UserData (S3 object fetched by a small bootstrap, or "
                "AWS::CloudFormation::Init metadata via cfn-init); stripping "
                "comments only buys a few hundred bytes."
            )

            # Raw first: it is the tighter of the two and the one EC2 reports
            # last, so surfacing it first avoids a second failed deploy.
            if raw > MAX_RAW_BYTES:
                matches.append(
                    RuleMatch(
                        location,
                        "{0} UserData is ~{1} raw bytes, over the EC2 raw limit "
                        "of {2} by {3}. {4}".format(
                            name, raw, MAX_RAW_BYTES, raw - MAX_RAW_BYTES, remedy
                        ),
                    )
                )
            elif encoded > MAX_ENCODED_BYTES:
                matches.append(
                    RuleMatch(
                        location,
                        "{0} UserData is ~{1} base64 bytes, over the EC2 encoded "
                        "limit of {2} by {3}. {4}".format(
                            name, encoded, MAX_ENCODED_BYTES,
                            encoded - MAX_ENCODED_BYTES, remedy,
                        ),
                    )
                )

        return matches


class UserDataSizeApproaching(CloudFormationLintRule):
    """Warn as EC2 UserData approaches the size limit, before it breaks."""

    id = "W9103"
    shortdesc = "UserData approaching EC2 size limit"
    description = (
        "Warn once UserData reaches {0:.0%} of the EC2 raw limit of {1} bytes, "
        "so the ceiling is hit at lint time rather than mid-update. A payload "
        "within the limit is still valid — E9103 owns the hard "
        "failures.".format(WARN_RATIO, MAX_RAW_BYTES)
    )
    tags = ["resources", "ec2", "userdata", "limits"]

    def match(self, cfn):
        matches = []

        # 1.0 disables the early warning entirely: a payload sitting exactly on
        # the limit is legal, and everything past it is E9103's to report.
        if WARN_RATIO >= 1.0:
            return matches

        for name, location, raw, encoded in _iter_userdata(cfn):
            if raw > MAX_RAW_BYTES or encoded > MAX_ENCODED_BYTES:
                continue
            if raw / MAX_RAW_BYTES < WARN_RATIO:
                continue
            matches.append(
                RuleMatch(
                    location,
                    "{0} UserData is ~{1} raw bytes — {2:.0%} of the EC2 raw "
                    "limit of {3}, leaving only {4} bytes of headroom.".format(
                        name, raw, raw / MAX_RAW_BYTES, MAX_RAW_BYTES,
                        MAX_RAW_BYTES - raw,
                    ),
                )
            )

        return matches
