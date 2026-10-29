# Ship your Auth0 ACUL login to AWS with Terraform — a copy‑paste quick start

*Get a hosted home for your Universal Login bundle (private S3 + CloudFront, with
the CORS that ACUL needs and a keyless CI deploy role) in about 15 minutes — by
copying one folder and changing three values.*

> ### ⚠️ Sample only — not for production
> The Terraform here is a **starting point** that shows the shape of a working
> setup. Review every resource, add remote state + logging + change control, and
> tighten IAM before anything real. See [Security notes](#security-notes).

---

## The hurdle this removes

ACUL lets you render Auth0's login screen with your own React bundle — but the
moment you leave local dev, people hit a wall:

- A secure login page **can't load assets from `localhost`** (browsers block it),
  so you must host the bundle on real HTTPS.
- ACUL loads as **ES modules**, which browsers always fetch *cross‑origin*, so
  your host has to return `Access-Control-Allow-Origin` for your Auth0 domain —
  or the scripts are silently blocked.

Clicking through the AWS console to get S3 + CloudFront + OAC + a CORS policy +
an IAM role *correct* is where most people stall. Terraform turns all of that
into `terraform apply`. This guide walks you through it.

### What you'll have at the end

- A **private, versioned, encrypted S3 bucket** holding your bundle.
- A **CloudFront** distribution serving it over HTTPS, with a **CORS policy
  scoped to your Auth0 origins** (the piece that makes the modules load).
- A **GitHub OIDC role** so CI deploys with **no long‑lived AWS keys**.
- Four outputs that map 1:1 to the GitHub secrets your deploy pipeline needs.

---

## Before you start (5‑minute checklist)

```bash
# AWS CLI + credentials with rights to create S3 / CloudFront / IAM
aws configure
aws sts get-caller-identity          # should print your account — proves creds work

# Terraform >= 1.5
terraform -version
```

On the Auth0 side you also need (used later, not by Terraform):

- A **custom domain** on your tenant — advanced rendering requires it.
- A **Machine‑to‑Machine app** authorized for the Management API with
  `read:prompts` + `update:prompts`. Note its **Domain / Client ID / Secret** —
  these become GitHub secrets, **never** committed.

---

## Step 1 — Grab the Terraform

Everything lives in [`infra/terraform/`](../infra/terraform/). Clone this repo (or
copy that one folder into your own):

```bash
git clone https://github.com/YOUR-ORG/auth0-acul-quickstart.git
cd auth0-acul-quickstart/infra/terraform
```

Four files do the work — you don't edit them:

| File | What it creates |
|---|---|
| `main.tf` | S3 (private/versioned/encrypted), CloudFront + OAC, the **CORS policy**, and the **GitHub OIDC deploy role**. |
| `variables.tf` | Inputs, with validations that reject unsafe values (wildcard CORS, `http://`, wildcard OIDC). |
| `outputs.tf` | The four values you feed to GitHub. |
| `versions.tf` | Provider pins + a commented remote‑state backend stub. |

---

## Step 2 — Fill in three values

This is the **only** file you touch. Copy the pre‑filled example and change the
three marked values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# terraform.tfvars  — git‑ignored; never commit real values

aws_region  = "us-east-1"

# 1) A GLOBALLY UNIQUE bucket name. Make something up.
bucket_name = "acme-acul-assets-7f3k9"          # ← change

# 2) Your Universal Login origins — the ONLY tenant‑specific gotcha.
#    List BOTH your custom domain AND the tenant canonical domain.
#    https://, no trailing slash, never "*".
allowed_origins = [                              # ← change
  "https://login.example.com",                   #   your custom domain
  "https://your-tenant.us.auth0.com",            #   tenant canonical domain
]

# 3) The GitHub repo allowed to deploy via OIDC (owner/name, exact).
github_repo = "your-org/auth0-acul-quickstart"   # ← change

# Leave this true unless your AWS account already has the GitHub OIDC provider.
create_github_oidc_provider = true
```

> ⚠️ **The #1 thing people get wrong is `allowed_origins`.** If you list only the
> custom domain (or forget the `*.us.auth0.com` canonical one), the login page
> loads but every `assets/*.js` request fails CORS and you get a blank screen.
> List **both**, with `https://` and no trailing slash. You can add more later and
> re‑apply.

---

## Step 3 — Create the infrastructure

```bash
terraform init          # downloads the AWS provider
terraform plan          # review what it will create — always look first
terraform apply         # type "yes" to create it
```

First apply takes a few minutes (CloudFront is slow to roll out). When it
finishes, print your outputs:

```bash
terraform output
```

```text
aws_region              = "us-east-1"
bucket_name             = "acme-acul-assets-7f3k9"
cdn_url                 = "https://d1xxxxxxxxxxxx.cloudfront.net"
distribution_id         = "E2XXXXXXXXXXXX"
github_actions_role_arn = "arn:aws:iam::123456789012:role/acme-acul-assets-7f3k9-github-deploy"
```

That `cdn_url` is the one URL your login will point at. You never hand‑write the
hashed `/assets/...` paths — the deploy pipeline appends them.

---

## Step 4 — Hand the outputs to your pipeline

Add these in **GitHub → Settings → Secrets and variables → Actions**. The four
from Terraform map 1:1:

| Terraform output | GitHub secret |
|---|---|
| `bucket_name` | `S3_BUCKET_NAME` |
| `cdn_url` | `S3_CDN_URL` *(no trailing slash)* |
| `github_actions_role_arn` | `AWS_S3_ARN` |
| `aws_region` | `AWS_REGION` |

Plus your Auth0 M2M app (Terraform does **not** manage these — add them yourself,
and never put them in `terraform.tfvars` or source):

| Secret | Value |
|---|---|
| `AUTH0_DOMAIN` | your tenant domain, e.g. `your-tenant.us.auth0.com` |
| `AUTH0_CLIENT_ID` | M2M app Client ID |
| `AUTH0_CLIENT_SECRET` | M2M app Client Secret |

---

## Step 5 — Deploy and verify

Run your deploy workflow (see the repo's
[`README`](../README.md#part-4--wire-up-github) — the sample pipeline builds,
syncs `dist/` to S3, and points each Auth0 screen at your CloudFront URL).

Then open your app's login and check **DevTools → Network**:

- the `assets/...` JS/CSS load **200** from `*.cloudfront.net`, **and**
- each response carries an **`access-control-allow-origin`** header matching your
  Auth0 origin.

That header is the whole game. If it's there, you're hosted correctly.

---

## The hurdles people actually hit

| Symptom | Fix |
|---|---|
| `terraform apply` → **BucketAlreadyExists** | `bucket_name` must be globally unique across all of AWS. Pick a more distinctive name. |
| apply → **EntityAlreadyExists** on the OIDC provider | Your account already has the GitHub OIDC provider (it's account‑wide). Set `create_github_oidc_provider = false` and re‑apply. |
| Login page blank, console **CORS error** on `assets/*.js` | A Universal Login origin isn't in `allowed_origins`. Add the **custom _and_ canonical** domain, `terraform apply`, redeploy. |
| **403** on assets from CloudFront | The bucket is private by design; CloudFront reads it via OAC. Confirm `apply` succeeded and don't "fix" it by making the bucket public. |
| Auth0 says a **custom domain is required** | Advanced rendering needs a verified custom domain on the tenant — set that up first. |
| New deploy, **stale bundle** | Filenames are content‑hashed, so new builds get new URLs automatically. No CloudFront invalidation needed. |

---

## Reuse the same bucket for another tenant

Point a second Auth0 tenant at this **same** CloudFront bundle: add that tenant's
custom + canonical domains to `allowed_origins`, `terraform apply`, then run the
deploy against its credentials. No second AWS environment needed. (For hard
prod/compliance isolation, run this Terraform again with its own `bucket_name` —
a separate environment.)

---

## Level up: production hardening (one flag at a time)

The quick start above is deliberately minimal. Everything here is **off by
default** so the happy path stays simple — turn each on in `terraform.tfvars`
(or `backend.tf`) and `terraform apply` again.

### Put a WAF in front of CloudFront

```hcl
enable_waf     = true
waf_rate_limit = 2000   # requests / 5 min / IP before blocking
```

Attaches a WAFv2 web ACL: a per‑IP rate limit plus the AWS managed **Common** and
**Known Bad Inputs** rule groups. CLOUDFRONT‑scoped ACLs must live in us‑east‑1 —
the config does that for you with a second provider alias.

### Turn on access logs

```hcl
enable_access_logs = true
log_retention_days = 90
```

Delivers CloudFront access logs to a **private, encrypted** log bucket that
auto‑expires them — useful for debugging a bad deploy or an audit trail.

### Move state off your laptop

Local `terraform.tfstate` is fine for a solo experiment, but it holds a full
record of your infrastructure (and can contain sensitive values) — never commit
it, and for anything shared, put it in S3 with locking. Create a state bucket
once (commands are in [`backend.tf.example`](../infra/terraform/backend.tf.example)),
then:

```bash
cp backend.tf.example backend.tf     # fill in your state bucket name
terraform init -migrate-state
```

`use_lockfile = true` gives you **S3‑native state locking** on Terraform ≥ 1.10 —
no DynamoDB table to manage.

### Cap the deploy role

```hcl
github_role_permissions_boundary = "arn:aws:iam::<account-id>:policy/<boundary>"
```

Adds an IAM **permissions boundary** so the CI role can never exceed it, even if
its policy is later widened — defense in depth for your most privileged
automation.

### Gate the deploy itself

On the CI side, the sample workflow runs in a GitHub **`environment: production`**.
Add required reviewers (Settings → Environments) and keep the `AUTH0_*` secrets in
that environment — so a deploy needs a human approval and only approved runs can
read the credentials. The workflow also pins its actions to commit SHAs and the
Auth0 CLI to a fixed version (supply‑chain hygiene).

### What's still on you

A dedicated deploy account, SCPs / AWS Config / drift detection, cost‑allocation
tags, and a custom CDN domain + ACM cert if you don't want the
`*.cloudfront.net` URL. This repo gets you a **secure, working baseline** — not a
finished platform.

---

## Tear it down

```bash
# The bucket is versioned, so empty it first (including old versions):
aws s3 rm "s3://$(terraform output -raw bucket_name)" --recursive
terraform destroy
```

---

## Security notes

This sample is deliberately conservative — keep it that way:

- **Never commit secrets or state.** `.gitignore` excludes `*.tfvars`,
  `*.tfstate`, and `.env*`. State can hold sensitive values in plain text; use a
  **remote backend** (encrypted + locked) for anything shared — stub in
  `versions.tf`.
- **No long‑lived AWS keys in CI** — the OIDC role issues short‑lived creds, and
  its trust is scoped to **your repo and branch**. Don't widen it to a wildcard.
- **The bucket stays private** (public access fully blocked; CloudFront reads via
  OAC). A 403 means fix the OAC/policy, not open the bucket.
- **CORS is explicit** — only your Auth0 origins, never `*` (a variable
  validation enforces this).
- **Least‑privilege IAM** — the deploy role can only put/get/delete objects in the
  one bucket.

Full resource‑by‑resource breakdown: [`infra/terraform/README.md`](../infra/terraform/README.md).
Start‑to‑finish ACUL setup (scaffold → local dev → deploy):
[the main README](../README.md).
