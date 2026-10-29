variable "aws_region" {
  description = "AWS region for the S3 bucket."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = <<-EOT
    Globally-unique S3 bucket name that will hold the ACUL bundle.
    No default on purpose — you must choose your own.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Must be a valid S3 bucket name (lowercase letters, numbers, hyphens; 3-63 chars)."
  }
}

variable "allowed_origins" {
  description = <<-EOT
    Origins allowed to load the ACUL assets cross-origin — i.e. the Universal
    Login domains. CloudFront returns Access-Control-Allow-Origin for these.
    Include BOTH your Auth0 custom domain AND the tenant canonical domain:

      ["https://login.example.com", "https://YOUR-TENANT.us.auth0.com"]

    Use https://, no trailing slash. Never use "*".
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_origins) > 0
    error_message = "Provide at least one Auth0 origin — the ES-module scripts need Access-Control-Allow-Origin."
  }

  validation {
    condition     = alltrue([for o in var.allowed_origins : can(regex("^https://", o))])
    error_message = "Every origin must start with https://."
  }

  validation {
    condition     = alltrue([for o in var.allowed_origins : !can(regex("/$", o))])
    error_message = "Origins must not have a trailing slash."
  }

  validation {
    condition     = !contains(var.allowed_origins, "*")
    error_message = "Wildcard origins are not allowed. List your Auth0 domains explicitly."
  }
}

variable "github_repo" {
  description = <<-EOT
    GitHub repository (owner/name) allowed to assume the deploy role via OIDC.
    No default on purpose — a wrong or overly broad value here would let another
    repository assume your AWS role.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^/*]+/[^/*]+$", var.github_repo))
    error_message = "Use the exact owner/name form (no wildcards), e.g. my-org/my-acul-app."
  }
}

variable "github_ref_condition" {
  description = <<-EOT
    OIDC subject condition scoping which git ref may assume the deploy role.
    Defaults to the main branch only. Widen deliberately, never to "*".
    Examples: "ref:refs/heads/main", "environment:production"
  EOT
  type        = string
  default     = "ref:refs/heads/main"

  validation {
    condition     = var.github_ref_condition != "*"
    error_message = "Refusing a wildcard: that would let any branch/PR in the repo assume the role."
  }
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub Actions OIDC provider in this account.
    Set false if it already exists (it is account-wide — only one can exist).
  EOT
  type        = bool
  default     = true
}

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 is the cheapest (NA/EU)."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project = "acul-quickstart"
    Managed = "terraform"
    Note    = "sample-not-for-production"
  }
}

# ---------------------------------------------------------------------------
# Optional production hardening — all off by default so the quick start stays
# simple. Flip these on in terraform.tfvars when you're ready.
# ---------------------------------------------------------------------------

variable "enable_waf" {
  description = "Attach an AWS WAFv2 web ACL (rate limit + AWS managed rule groups) to CloudFront. Adds cost."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5-minute window, per IP, before WAF blocks (when enable_waf)."
  type        = number
  default     = 2000
}

variable "enable_access_logs" {
  description = "Deliver CloudFront access logs to a private, encrypted log bucket."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Days to keep CloudFront access logs before expiry (when enable_access_logs)."
  type        = number
  default     = 90
}

variable "github_role_permissions_boundary" {
  description = "Optional IAM permissions-boundary ARN to cap the GitHub deploy role (defense in depth). null = none."
  type        = string
  default     = null
}
