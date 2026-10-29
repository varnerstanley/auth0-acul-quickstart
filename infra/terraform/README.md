# Terraform — AWS environment for hosting an ACUL bundle

> ### ⚠️ Sample only — not for production
> This is a **starting point** that shows the shape of a working ACUL host. It is
> not hardened, audited, or opinionated about your org's controls. Read every
> resource, run `terraform plan`, and add remote state, logging, WAF, and change
> control before using it for anything real.

## What it creates

```
        ┌──────────────┐   OAC (signed)   ┌───────────────┐
        │  CloudFront  │ ───────────────► │   S3 bucket   │
        │  HTTPS + CORS│                  │  PRIVATE      │
        └──────┬───────┘                  └───────────────┘
               │  Access-Control-Allow-Origin: https://your-auth0-domain
               ▼
     Auth0 Universal Login loads your ES modules

        ┌──────────────────┐  short-lived creds   ┌──────────────┐
        │  GitHub Actions  │ ───── OIDC ────────► │  IAM role    │ ──► s3:PutObject
        └──────────────────┘   (no static keys)   └──────────────┘
```

| Resource | Why |
|---|---|
| `aws_s3_bucket` + public access block + versioning + SSE | Private, encrypted home for `dist/`. Versioning lets you roll back a bad bundle. |
| `aws_cloudfront_origin_access_control` | CloudFront reads the bucket with signed requests, so the bucket stays private. |
| `aws_cloudfront_response_headers_policy` | **The critical piece** — emits `Access-Control-Allow-Origin` for your Auth0 origins. ACUL loads as ES modules (always cross-origin); without this the browser blocks the scripts. Also sets HSTS / nosniff / referrer-policy. |
| `aws_cloudfront_distribution` | HTTPS via the default `*.cloudfront.net` cert — no ACM cert or DNS to manage. |
| `aws_s3_bucket_policy` | Allows **only this distribution** to read; explicitly denies non-TLS access. |
| `aws_iam_openid_connect_provider` + `aws_iam_role` | Lets GitHub Actions deploy with short-lived credentials — **no long-lived AWS keys in CI**. |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: bucket_name, allowed_origins, github_repo

terraform init
terraform validate
terraform fmt -check
terraform plan            # ALWAYS review first
terraform apply

terraform output          # → the four GitHub secrets
```

Tear down when you're done experimenting:

```bash
terraform destroy
```

> The bucket is versioned, so `destroy` can fail if objects remain. Empty it
> first (`aws s3 rm s3://<bucket> --recursive`), including old versions.

## Required variables

| Variable | Notes |
|---|---|
| `bucket_name` | Globally unique. **No default** — pick your own. |
| `allowed_origins` | Your Auth0 **custom domain** *and* **tenant canonical domain**. `https://`, no trailing slash, never `*`. Validated. |
| `github_repo` | Exact `owner/name`. **No default** — this is a security boundary. Wildcards rejected. |

Optional: `aws_region`, `github_ref_condition` (default: `main` only),
`create_github_oidc_provider`, `cloudfront_price_class`, `tags`.

## Outputs → GitHub secrets

| Output | Secret |
|---|---|
| `bucket_name` | `S3_BUCKET_NAME` |
| `cdn_url` | `S3_CDN_URL` (no trailing slash) |
| `github_actions_role_arn` | `AWS_S3_ARN` |
| `aws_region` | `AWS_REGION` |

Terraform does **not** manage your Auth0 M2M credentials. Add
`AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET` to GitHub Secrets
yourself — they must never appear in this repo.

## Security choices worth keeping

- **The bucket is private.** Public access is blocked four ways; CloudFront reads
  via OAC. If you hit a 403, fix the OAC/policy — **don't make the bucket public.**
- **CORS is explicit.** Only your listed Auth0 origins. `*` is rejected by a
  variable validation, not just convention.
- **No static AWS keys.** OIDC issues short-lived credentials per run.
- **The OIDC trust is scoped** to one repo *and* one ref (`sub` condition). A
  wildcard here would let any branch — including a fork's PR — assume your role.
- **IAM is least-privilege.** Object put/get/delete on one bucket, plus list. No
  `s3:*`, no `Resource: "*"`.
- **TLS enforced** at the bucket policy (`aws:SecureTransport`) and viewer
  (`redirect-to-https`).
- **Noncurrent versions expire** after 30 days (lifecycle rule), so the versioned
  bucket doesn't grow forever.
- **State is sensitive.** `*.tfstate` is git-ignored. Enable remote state with
  locking — see `backend.tf.example`.

## Production hardening (opt-in toggles)

These are **off by default** so the quick start stays simple. Flip them on in
`terraform.tfvars` when you're ready:

| Toggle | What it adds |
|---|---|
| `enable_waf = true` | A **WAFv2 web ACL** on CloudFront — per-IP rate limit (`waf_rate_limit`) plus the AWS managed *Common* and *Known Bad Inputs* rule groups. (CLOUDFRONT scope is created in us-east-1 automatically.) |
| `enable_access_logs = true` | **CloudFront access logs** to a private, encrypted, auto-expiring log bucket (`log_retention_days`). |
| `github_role_permissions_boundary = "<arn>"` | Caps the GitHub deploy role with an IAM **permissions boundary** (defense in depth). |
| `backend.tf.example` → `backend.tf` | **Remote state** in S3 with native locking (`use_lockfile`, Terraform ≥ 1.10). |

Outputs `waf_web_acl_arn` and `access_logs_bucket` report the created resources
when enabled.

## Still your responsibility before real production

- A **dedicated deploy account/role** separation and an approval gate on `apply`
  (and on CI deploys — the sample workflow's `environment: production`).
- Tag/cost allocation and your org's guardrails: SCPs, AWS Config rules, drift
  detection.
- A custom CDN domain + ACM cert if you don't want the `*.cloudfront.net` URL.
