# Auth0 ACUL Quick Start — from zero to a custom login screen in production

A high-level, copy-paste-able walkthrough for standing up **Auth0 Advanced
Customization for Universal Login (ACUL)**: scaffold a React project with the
Auth0 CLI, run it locally against your tenant, then host the bundle on AWS
(S3 + CloudFront) via Terraform and deploy it with GitHub Actions.

> ### ⚠️ Sample only — not for production
> This repository is a **learning scaffold**. The Terraform in `infra/terraform/`
> is a starting point that demonstrates the *shape* of a working setup — it is
> **not hardened for production**. Review every resource, tighten IAM, add remote
> state with locking, logging, and change control before any real deployment.
> **No real credentials, tenant names, client IDs, or account IDs appear in this
> repo — and none should ever be committed to it.** See [Security notes](#security-notes).

---

## What you'll have at the end

- A React ACUL project generated from Auth0's official template.
- That project rendering as your **real Universal Login screen**, locally.
- An **AWS environment** (private S3 + CloudFront over HTTPS with correct CORS)
  provisioned by Terraform.
- A **GitHub Actions pipeline** that builds, uploads, and points Auth0 at your
  CDN — with no long-lived AWS keys.

## How ACUL works (the 30-second version)

Auth0 keeps running the security (tokens, MFA, passkeys, bot detection). You
supply the **screen**: your own React bundle, hosted by you, rendered inside
Universal Login. Auth0 loads your JS/CSS via `head_tags` that point at your CDN,
and hands your code a context object (`window.universal_login_context`) with the
transaction, screen, and client details.

Two consequences drive this entire guide:

1. **You must host the bundle over HTTPS.** Browsers block a secure login page
   from loading `localhost` assets, so `localhost` is dev-only.
2. **Your host must send CORS headers.** ACUL loads as ES modules, which are
   always fetched cross-origin — without `Access-Control-Allow-Origin` for your
   Universal Login domain, the scripts are blocked. This is why the Terraform
   includes a CloudFront CORS response-headers policy.

---

# Part 0 — Zero machine setup

Everything you need on a fresh machine.

### Accounts & tenant requirements

| Requirement | Notes |
|---|---|
| **Auth0 tenant** | A **dev/stage tenant** — never test connected mode against production. |
| **Custom domain** | **Required** for advanced rendering. Configure it in the Auth0 Dashboard first. |
| **Identifier First** | Enable the Identifier First authentication profile (drives `login-id` → `login-password`). |
| **First-party application** | The app you'll actually log into. Note its **Client ID**. |
| **AWS account** | With rights to create S3, CloudFront, and IAM resources. |
| **GitHub repository** | Where your screens live and Actions can run. |

### Local tooling

```bash
# Node 22 (via nvm, or install however you prefer)
nvm install 22 && nvm use 22
node -v                      # → v22.x

# Auth0 CLI
brew tap auth0/auth0-cli && brew install auth0
auth0 --version

# Terraform >= 1.5
brew install terraform
terraform -version

# AWS CLI + credentials
brew install awscli
aws configure                # access key, secret, default region
aws sts get-caller-identity  # verify it works
```

### Auth0 Machine-to-Machine app (for CI)

Dashboard → **Applications** → **Create Application** → *Machine to Machine*.
Authorize the **Auth0 Management API** with:

- `read:prompts`, `update:prompts` — required (sets screen rendering)
- `read:branding`, `update:branding` — if you also deploy a page template
- `read:custom_domains` — recommended

Note its **Domain**, **Client ID**, and **Client Secret**. These go into GitHub
Secrets later — **never into this repo**.

---

# Part 1 — Scaffold and run locally

```bash
# 1. Authenticate the CLI against your tenant
auth0 login

# 2. Generate a project (pick the screens you want)
auth0 acul init my-acul-app \
  --template react \
  --screens login-id,login-password,signup-id

cd my-acul-app
npm install
```

> Run `auth0 acul init --help` to see available templates/screens, or run it
> interactively and choose *React (with ACUL React SDK)*.

### Develop with mock data (no tenant needed)

```bash
auth0 acul dev --port 3000
```

Opens a local inspector where you pick a screen and a **mock context** variant.
This is the fast loop — edit code, see it instantly, no Auth0 round trip.

### Develop connected to your tenant

```bash
auth0 acul dev --connected (optional: --screens login-id)
```

Points your **real tenant's** screen at your local build so you can test the
actual flow.

> ⚠️ Connected mode rewrites the screen's `head_tags` to `localhost`. It's for
> **dev/stage tenants only**, and you **must stop it** before/after deploying —
> otherwise the tenant keeps pointing at your laptop and the screen breaks for
> everyone else. See [Part 5](#part-5--stop-the-dev-connector).

### Test the flow

```bash
auth0 test login
```

---

# Part 2 — What the CLI generated

The CLI produces a complete Vite + React project. **`←` marks what you actually
edit to customize a screen** — in practice: the form, the header, the footer, the
social buttons, and the copy. Everything else is either SDK wiring (leave it
alone) or dev-only scaffolding.

```
my-acul-app/
├── public/                               #   Dev-only. Not an editing target.
│   ├── manifest.json                     #   Screen registry for the local inspector
│   └── screens/
│       └── login-id/
│           └── login-id/
│               ├── default.json          #   Mock context — a fake Auth0 payload
│               └── with-errors.json      #   Another mock state to preview against
├── src/
│   ├── components/                       #   Pre-built Universal Login theme components
│   │   ├── ULThemeCountryCodePicker.tsx  #   Country code button
│   │   ├── ULThemeSocialProviderButton.tsx #  Social login button
│   │   └── ...
│   └── screens/
│       └── login-id/
│           ├── index.tsx                 # ← Screen root: layout + composition
│           ├── components/
│           │   ├── LoginIdForm.tsx       # ← The form
│           │   ├── Header.tsx            # ← Logo / title
│           │   ├── Footer.tsx            # ← Links / legal
│           │   └── AlternativeLogins.tsx # ← Social + passkey buttons
│           ├── hooks/
│           │   └── useLoginIdManager.ts  #   SDK wrapper — DON'T rewrite the auth logic
│           ├── locales/
│           │   └── en.json               # ← UI strings (change copy here, not in JSX)
│           └── __tests__/                #   Screen tests
├── package.json
└── vite.config.ts
```

### How to think about each piece

| Piece | What it is | Rule of thumb |
|---|---|---|
| `screens/<screen>/components/*.tsx` | The form, header, footer, social buttons. | **This is where your customization lives.** Restyle freely; keep the SDK calls. |
| `screens/<screen>/index.tsx` | The screen root — layout and composition. | Edit when you're changing the *layout*, not just styling. |
| `screens/<screen>/locales/en.json` | UI strings. | Override copy here, not in JSX. |
| `screens/<screen>/hooks/use*Manager.ts` | Thin wrapper over the ACUL SDK. | **Don't rewrite the auth logic.** |
| `components/ULTheme*` | Shared themeable primitives. | Reuse before building new. |
| `public/screens/**/*.json` | Mock context — a stand-in for the real `window.universal_login_context`. | **Leave it alone.** Dev-only fixture; Auth0 injects the real one in production. |

> **On `public/screens/**/*.json`:** these ship with the CLI template and exist
> only so `auth0 acul dev` can render a screen locally without a tenant.
> Customizing a screen does **not** involve touching them.

### The golden rule

**Change the presentation; don't rewrite the SDK wiring.** Calls like `login()`,
`signup()`, `federatedLogin()`, `passkeyLogin()`, and `changeLanguage()` — plus
anything driven by `transaction.alternateConnections` — are what make the screen
a real, secure login. Restyle around them.

The SDK is dynamic on purpose: which social providers appear, whether passkeys
show, which identifiers are allowed — all come from the **tenant**, at runtime.
Read them from the context; don't hardcode them.

---

# Part 3 — Provision AWS with Terraform

The sample lives in [`infra/terraform/`](infra/terraform/) — see its
[README](infra/terraform/README.md) for the full resource-by-resource breakdown.

> **Prefer a narrated, copy‑paste walkthrough?** See
> [Ship your ACUL login to AWS with Terraform](docs/deploy-acul-to-aws-with-terraform.md)
> — a blog‑style quick start: copy the folder, change three values, `terraform
> apply`, hand the outputs to CI.

It creates:

- **S3 bucket** — private, versioned, encrypted, all public access blocked.
- **CloudFront** — HTTPS in front of the bucket via **Origin Access Control**
  (the bucket is never public), using the default `*.cloudfront.net` cert.
- **CORS response-headers policy** — emits `Access-Control-Allow-Origin` for
  *your Auth0 origins only*. This is the piece that makes the ES modules load.
- **GitHub OIDC role** — lets Actions upload to S3 with **no long-lived AWS
  keys**, scoped to your repo and branch.

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: bucket_name, allowed_origins, github_repo
terraform init
terraform validate
terraform plan          # review before applying
terraform apply
```

### Outputs map 1:1 to GitHub secrets

| Terraform output | GitHub secret |
|---|---|
| `bucket_name` | `S3_BUCKET_NAME` |
| `cdn_url` (e.g. `https://d123.cloudfront.net`) | `S3_CDN_URL` |
| `github_actions_role_arn` | `AWS_S3_ARN` |
| `aws_region` | `AWS_REGION` |

```bash
terraform output          # print them all
```

> ⚠️ **`allowed_origins` must list every domain your Universal Login page is
> served from** — your **custom domain** *and* the **tenant canonical domain**:
> ```hcl
> allowed_origins = [
>   "https://login.example.com",          # your custom domain
>   "https://YOUR-TENANT.us.auth0.com",   # tenant canonical domain
> ]
> ```
> Use `https://`, no trailing slash. A missing origin = CORS error on the assets.

---

# Part 4 — Wire up GitHub

### Secrets
**Repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|---|---|
| `AWS_S3_ARN` | `github_actions_role_arn` output |
| `S3_BUCKET_NAME` | `bucket_name` output |
| `AWS_REGION` | `aws_region` output |
| `S3_CDN_URL` | `cdn_url` output (**no trailing slash**) |
| `AUTH0_DOMAIN` | Your tenant domain, e.g. `YOUR-TENANT.us.auth0.com` |
| `AUTH0_CLIENT_ID` | M2M app Client ID |
| `AUTH0_CLIENT_SECRET` | M2M app Client Secret |
| `RENDERING_CLIENT_IDS` | *(optional)* Comma-separated client IDs to scope advanced rendering to only those apps. Omit to apply tenant-wide. |

> Secrets go in **GitHub Secrets** — never in the repo, never in `terraform.tfvars`,
> never in source. Client IDs are not secret, but keep them in **Variables**/env
> rather than hardcoded.

### Deploy

```bash
git push origin main      # or: Actions tab → "ACUL Deploy" → Run workflow
```

A reference pipeline is in
[`.github/workflows/acul-deploy.example.yml`](.github/workflows/acul-deploy.example.yml).
**Copy it into _your_ ACUL project** (the one `auth0 acul init` generated and you
designed) and rename it to `acul-deploy.yml` — that project has the
`package.json` / `npm run build` / `dist/assets/…` this workflow needs. This
quick-start repo is the guide + infrastructure; it has no app of its own. It:

1. **builds** (`npm run build`),
2. **syncs** `dist/` to S3 (immutable cache on content-hashed files),
3. **logs in** the Auth0 CLI with the M2M credentials,
4. **sets each screen** to advanced rendering — it **discovers** the real
   content-hashed assets from `dist/` and writes `head_tags` pointing at your
   CloudFront URL (never hardcoded filenames), plus a `filters.includes_any`
   block if `RENDERING_CLIENT_IDS` is set so only those apps get the custom
   screens.

**Security built into the sample workflow:** OIDC into AWS (no long-lived keys),
least-privilege `permissions`, third-party actions **pinned to commit SHAs**, a
**pinned Auth0 CLI version**, `persist-credentials: false`, and a deploy
`environment: production` you should gate with **required reviewers** (Settings →
Environments) — put the `AUTH0_*` secrets in that environment so only approved
runs can read them.

The run summary lists each screen as *configured*.

---

# Part 5 — Stop the dev connector

Stop any `auth0 acul dev --connected` session. In connected mode it rewrites
`head_tags` back to `localhost`, which re-breaks the tenant. After the deploy,
the tenant should point at CloudFront.

---

# Part 6 — Verify

Open your app's login (or `auth0 test login`). In DevTools:

- **Network** → the `assets/...` JS/CSS load **200** from `*.cloudfront.net`, and
  each response carries an `access-control-allow-origin` header.
- Your custom screen renders (and, if you scoped with `RENDERING_CLIENT_IDS`,
  only for those applications).

```bash
# Confirm what the tenant actually has configured
auth0 acul config list
auth0 acul config get login-id
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Blank page; console mentions **loopback address space** | `head_tags` still point at `localhost`. Stop `auth0 acul dev --connected` and re-run the deploy. |
| **CORS error** on `assets/*.js` | The Universal Login origin isn't in `allowed_origins`. Add it (**custom *and* canonical** domain), `terraform apply`, redeploy. |
| **403** on assets from CloudFront | Bucket policy / OAC — confirm `terraform apply` succeeded and the distribution's OAC is attached. |
| Screens still show the **default UI** | Advanced rendering didn't apply. Check the Actions log for "configured", the M2M scopes (`update:prompts`), and that the app you're testing is in `RENDERING_CLIENT_IDS` (or unset it for tenant-wide). |
| **Stale bundle** after redeploy | Filenames are content-hashed, so new deploys use new URLs automatically — no CloudFront invalidation needed. |
| `auth0 acul` says a **custom domain** is required | Advanced rendering requires a verified custom domain on the tenant. |

---

## Security notes

This sample is deliberately conservative. Keep it that way:

- **Never commit secrets.** The M2M client secret, AWS keys, and any tokens
  belong in GitHub Secrets. `.gitignore` already excludes `.env*`,
  `*.tfvars`, and Terraform state.
- **Never commit Terraform state.** `*.tfstate` records your infrastructure and
  can contain sensitive values in plain text. Use a **remote backend** (S3 +
  encryption + DynamoDB locking) for anything shared — see `versions.tf`.
- **No long-lived AWS keys in CI.** The GitHub OIDC role issues short-lived
  credentials. Scope its trust to **your repo and branch** (`github_repo`,
  `github_ref_condition`) — a wildcard here lets other repos assume your role.
- **The S3 bucket is private.** Public access is fully blocked; CloudFront reads
  it through OAC. Don't "fix" a 403 by making the bucket public.
- **Scope CORS narrowly.** List only your Auth0 origins in `allowed_origins`.
  Never use `*`.
- **Least-privilege IAM.** The deploy role can only put/get/delete objects in the
  one bucket. Don't broaden it to `s3:*` or `Resource: "*"`.
- **Use a dev/stage tenant** for connected mode. Never point production at a
  laptop.
- **Scope rendering while testing.** `RENDERING_CLIENT_IDS` limits advanced
  rendering to specific apps so a bad deploy can't take down every login.
- **Review before apply.** Always `terraform plan` first.

## Reference

- [ACUL deployment workflow](https://auth0.com/docs/customize/login-pages/advanced-customizations/deployment-workflow)
- [Advanced Customization for Universal Login](https://auth0.com/docs/customize/login-pages/advanced-customizations)
- [ACUL React SDK reference](https://auth0.com/docs/libraries/acul/react-sdk)
- [Customize page templates](https://auth0.com/docs/customize/login-pages/universal-login/customize-templates)
