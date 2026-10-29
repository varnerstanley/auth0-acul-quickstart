# Security policy

This repository is an **educational sample**, not a maintained product. The
Terraform and workflow demonstrate a secure-by-default *shape*; review and harden
everything before production use (see the Security notes in the README and
`infra/terraform/README.md`).

## Reporting a vulnerability

If you find a security issue **in this sample** (e.g. an insecure default that
could mislead someone copying it), please open a private report via GitHub
Security Advisories ("Report a vulnerability") on this repository, or open a
regular issue if it is not sensitive. Please do not include real credentials,
account IDs, or tenant details in any report.

Vulnerabilities in **Auth0** or **AWS** themselves should go to those vendors'
disclosure programs, not here.

## If you think you committed a secret

Act as if it is compromised:

1. **Rotate it immediately** — revoke the Auth0 M2M client secret / rotate AWS
   credentials at the source. Removing a commit does not un-leak a pushed secret.
2. Purge it from history (e.g. `git filter-repo`) and force-push, then confirm
   it is gone from forks and caches.

This repo's `.gitignore` already excludes `.env*`, `*.tfvars`, and Terraform
state to make this hard to do by accident.
