# Redirect to stage

CloudFront distribution that issues **301 redirects** from `cell-kn.org` and
`nlm-ckn.org` to `https://stage.nlm-ckn.org`, preserving the request path and
query string.

## What the template creates

| Resource | Purpose |
| --- | --- |
| `AWS::CloudFront::Function` (`redirect-to-stage`) | viewer-request function that returns a `301 Moved Permanently` to `https://stage.nlm-ckn.org<uri><?query>` |
| `AWS::CloudFront::Distribution` (comment `Redirect to stage`) | distribution with aliases `cell-kn.org` and `nlm-ckn.org`, function attached to the default behavior |
| `AWS::Route53::RecordSet` ×4 | A + AAAA alias records for both apex domains pointing at the distribution |
| `AWS::Logs::LogGroup` ×2 (`/aws/route53/cell-kn.org`, `/aws/route53/nlm-ckn.org`) | Route 53 DNS query logs, one group per hosted zone |
| `AWS::Logs::ResourcePolicy` (`route53-query-logging`) | lets `route53.amazonaws.com` write to `/aws/route53/*` groups |
| `AWS::Route53::QueryLoggingConfig` ×2 | enables query logging on both hosted zones |
| `AWS::Logs::LogGroup` (`/aws/vendedlogs/cloudfront/redirect-to-stage`) | CloudFront access logs |
| `AWS::Logs::DeliverySource` / `DeliveryDestination` / `Delivery` | CloudFront standard logging (v2) from the distribution to that log group (JSON) |

All log groups use the `LogRetentionDays` parameter (default 90).

## Prerequisite — ACM certificate (not created here)

CloudFront serves these domains over HTTPS, so it needs a certificate covering
**both** apex names. ACM certs for CloudFront **must live in `us-east-1`**.

A combined cert has already been requested, DNS-validated, and issued:

```
arn:aws:acm:us-east-1:952291113202:certificate/64062cb5-af4b-4501-accb-d1008304b3a5
  domains: nlm-ckn.org, cell-kn.org   status: ISSUED   region: us-east-1
```

This ARN is already filled into `parameters.json`. (Note: a single distribution
attaches one cert covering all its aliases — the pre-existing `cell-kn.org` and
`stage.nlm-ckn.org` certs could not be combined, so this new two-SAN cert was
created. It isn't managed by this template because DNS-validated ACM certs block
CloudFormation stack creation until validation resolves.)

## Deploy

This stack **must** be deployed in `us-east-1` (CloudFront functions + certs).

Fill in `CertificateArn` in `parameters.json` (the hosted zone IDs are already
set), then:

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name redirect-to-stage \
  --template-file redirect.yaml \
  --parameter-overrides file://parameters.json
```

To update the existing stack in place (e.g. after template changes), preview
with a change set first:

```bash
aws cloudformation deploy \
  --profile springbok \
  --region us-east-1 \
  --stack-name redirect-to-stage \
  --template-file cloudformation/redirect.yaml \
  --parameter-overrides file://parameters.json \
  --no-execute-changeset
```

Hosted zones (already wired into `parameters.json`):

| Domain | Hosted Zone ID |
| --- | --- |
| `cell-kn.org` | `Z0441030102JW92C98Q3U` |
| `nlm-ckn.org` | `Z05089951YM1345O1XAHB` |

## Is this everything needed to redirect the two hostnames to stage?

Yes, for the redirect path itself — with two requirements called out:

1. **ACM certificate (us-east-1) covering both apex names** — required, supplied
   via `CertificateArn`. Without an alias-matching cert CloudFront rejects the
   request before the function runs.
2. **Apex DNS must be in Route 53** — the A/AAAA alias records assume `cell-kn.org`
   and `nlm-ckn.org` are hosted in the Route 53 zones identified by the zone-ID
   parameters. If a domain's authoritative DNS is elsewhere, point its apex at the
   CloudFront domain there instead.

Notes:
- The redirect is `https://stage.nlm-ckn.org`. The target (`stage.nlm-ckn.org`)
  must already be serving HTTPS — it is, via the existing `frontend.yaml` stack.
- `http://` hits also redirect (viewer protocol policy `allow-all`, function runs
  on every viewer request) — browsers requesting `http://cell-kn.org` get the
  301 straight to the https stage URL.
- Path and query string are preserved in the redirect Location.

## Logs

Used to correlate reported outages with what actually reached AWS:

- **DNS queries** (Route 53 resolvers asking for the apex names):
  `/aws/route53/cell-kn.org`, `/aws/route53/nlm-ckn.org` — one log stream per
  Route 53 edge location; each line has timestamp, query name/type, response
  code, edge location, and the resolver IP (plus EDNS client subnet if sent).
- **HTTP requests** reaching CloudFront: `/aws/vendedlogs/cloudfront/redirect-to-stage`
  (JSON, includes client IP, host, status, edge location). Delivery lags a few
  minutes.

If a user reports a failure, ask for the time and their public IP / resolver,
then search both groups with CloudWatch Logs Insights.
