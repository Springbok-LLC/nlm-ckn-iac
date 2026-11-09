# Frontend via ALB (no CloudFront)

A single CloudFormation stack that serves the NLM-CKN site from an **existing
Application Load Balancer** for accounts where CloudFront isn't available.
NIH deploys it in their account. This repo never deploys it outside the dev
test below.

```
browser ──HTTPS──▶ ALB :443
                     ├─ /arango_api/*          → existing backend target group
                     ├─ extension-less paths   → /index.html ─┐
                     │  (client-side routes)                  ├─▶ S3 interface endpoint ─▶ frontend bucket
                     └─ everything else        → as-is ───────┘   (private, IP targets)
```

## Why this design

The frontend bucket holds the React build **and** the plot assets
(`plots/<tag>/`, about 2,850 files and 500 MB per release, stored
gzip-compressed). Many plots are several MB, and the largest is about 9 MB
compressed.

- **ALB → Lambda → S3** (the sandbox `alb-s3-lambda-target-group` approach) is
  limited to 1 MB responses. It also mangles the gzip-encoded plots.
- **nginx with the files built into the image** doesn't work for 500 MB of
  plots per release.
- **ALB → S3 interface endpoint** adds no compute. S3 returns each object with
  its stored headers (including `Content-Encoding: gzip`), with no size limit.
  ALB rule transforms do the two jobs CloudFront did: send app routes to
  `index.html`, and set the Host header to the bucket.

## What the stack creates

| Resource | Notes |
|---|---|
| S3 interface VPC endpoint + security group | Private DNS **off**, so other S3 traffic in the VPC is unaffected. The endpoint policy allows only `s3:GetObject` on the frontend bucket. The security group allows 443 only from the ALB's security group. Skipped if `ExistingS3EndpointId` is set. |
| IP target group (HTTPS 443) | Targets are the endpoint's private IPs. |
| Lambda custom resource + IAM role | Registers those IPs in the target group. It runs only during stack create, update and delete. It needs `CAPABILITY_IAM`. |
| HTTPS listener (port 443) | Default action is 404. Skipped if `ExistingHttpsListenerArn` is set; the rules attach to that listener instead. |
| 3 listener rules | `/arango_api/*` → backend; app routes → `/index.html`; everything else → S3. |
| *(optional)* HTTP→HTTPS redirect rule | Only if `HttpListenerArn` is set. |
| *(optional)* Regional WAF web ACL | Only if `CreateWebAcl=true`. Same rules as the CloudFront deployment: rate limit on `/arango_api/*` plus AWS managed rules. |

Nothing existing is modified. The backend target group and any other listeners
are left alone.

## Before deploying — please confirm

1. **S3 interface endpoints are allowed in the VPC.** If the VPC already has an
   S3 *interface* endpoint, you can reuse it by passing its ID in
   `ExistingS3EndpointId`. A *gateway* endpoint can't be used, because ALB
   targets need IPs.
2. **The frontend bucket uses SSE-S3 (AES256), not SSE-KMS.** The ALB's
   requests are unsigned, so they can't decrypt KMS-encrypted objects.
3. **Whether the ALB already has a WAF web ACL** (for example, one from Firewall
   Manager). An ALB can have only one. Leave `CreateWebAcl=false` if it does.
4. **Whether the ALB already has a listener on 443.** If so, pass its ARN in
   `ExistingHttpsListenerArn`.

## Deploy

1. **Fill in `parameters.example.json`.** All values are existing resources in
   your account. Then deploy in the same region as the ALB and the bucket:

   ```bash
   aws cloudformation deploy \
     --stack-name nlm-ckn-prod-frontend-alb \
     --template-file cloudformation/frontend-alb.yaml \
     --parameter-overrides file://parameters.example.json \
     --capabilities CAPABILITY_IAM
   ```

2. **Add the bucket policy statement.** Copy the stack's `BucketPolicyStatement`
   output into the frontend bucket's existing policy (the `Statement` array) in
   whichever stack owns that bucket. It allows anonymous `s3:GetObject`
   **only** through this stack's endpoint (`aws:SourceVpce`). S3 Block Public
   Access treats that as non-public, so Block Public Access can stay fully on.

   ```bash
   aws cloudformation describe-stacks --stack-name nlm-ckn-prod-frontend-alb \
     --query "Stacks[0].Outputs[?OutputKey=='BucketPolicyStatement'].OutputValue" --output text
   ```

3. **Update the ALB security group.**
   - Inbound: 443 from clients.
   - Outbound: 443 to the endpoint security group. This is already true if
     outbound traffic is unrestricted.

4. **Update DNS.** Point the site hostname at the ALB (an alias A record). The
   certificate in `CertificateArn` must cover that hostname.

## Verify

Replace `<site>` with the hostname:

```bash
curl -sI https://<site>/                      # 200, text/html
curl -sI https://<site>/some/client/route     # 200, text/html (index.html)
curl -sI https://<site>/static/js/main.<hash>.js   # 200, application/javascript
curl -sI https://<site>/plots/<tag>/<file>.svg     # 200, content-encoding: gzip
curl -s -X POST -H "Content-Type: application/json" -d "{}" https://<site>/arango_api/collections/   # 200, JSON list from the backend
```

A missing file returns **403** rather than 404, because S3 hides missing keys
from callers that can't list the bucket. That's expected, and it doesn't
affect app routes, which always get `index.html`.

## Differences from the CloudFront deployment

- **No edge caching and no compression on the fly.** Objects are served with
  whatever `Cache-Control` they were uploaded with. The React bundle is
  uploaded uncompressed (about 850 KB), so first loads are slower than through
  CloudFront. The plots are already compressed.
- **No CloudFront secret-header check** on this path. The new 443 listener is
  meant to be public. The existing 8000/8529 listeners keep their header
  rules.

## Rollback

Delete the stack, then remove the `AllowFrontendAlbViaVpce` statement from the
bucket policy. The stack doesn't change anything outside itself, so deleting it
returns the ALB to its previous state.

## Testing in springbok dev

`test-in-dev.sh` deploys this template against dev's ALB, backend and bucket,
alongside dev's CloudFront. It temporarily adds the bucket policy statement,
and `down` restores the original policy. Public DNS is never touched; the
checks use `curl --resolve`.

```bash
AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh up
AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh check
AWS_PROFILE=springbok ./manual/frontend-alb/test-in-dev.sh down
```
