##############################################################################
# SAMPLE — NOT FOR PRODUCTION
#
# Provisions the minimum AWS environment to host an Auth0 ACUL bundle:
#   private S3  ->  CloudFront (OAC, HTTPS, CORS)  ->  Universal Login
# plus a GitHub Actions OIDC role so CI can deploy without long-lived keys.
#
# Review every resource before using this for anything real.
##############################################################################

##############################################################################
# S3 bucket — private, versioned, encrypted. Holds dist/ (the ACUL bundle).
# The bucket is NEVER public; CloudFront reads it through Origin Access Control.
##############################################################################

resource "aws_s3_bucket" "assets" {
  bucket = var.bucket_name
}

# Disable ACLs entirely — the bucket owner owns every object.
resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Belt and braces: block every avenue to public access.
resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning lets you roll back a bad bundle.
resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is kept for rollback, but old versions shouldn't pile up forever.
# Expire noncurrent versions and clean up incomplete multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.assets]
}

##############################################################################
# CloudFront — HTTPS in front of the private bucket via Origin Access Control.
#
# The CORS response-headers policy is the critical piece: ACUL loads as ES
# modules, which are always fetched cross-origin, so the assets must return
# Access-Control-Allow-Origin for your Universal Login domain or the browser
# blocks them.
##############################################################################

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for the ACUL asset bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "cors" {
  name    = "${var.bucket_name}-acul-cors"
  comment = "Allow the Auth0 Universal Login origins to load the ACUL assets"

  cors_config {
    origin_override                  = true
    access_control_allow_credentials = false

    # Scoped to your Auth0 domains only — never "*". See variables.tf.
    access_control_allow_origins {
      items = var.allowed_origins
    }
    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }
    access_control_allow_headers {
      items = ["*"]
    }
    access_control_expose_headers {
      items = ["*"]
    }
    access_control_max_age_sec = 86400
  }

  # Sensible baseline security headers for static assets.
  security_headers_config {
    content_type_options {
      override = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

# Managed AWS cache policy — honors the immutable max-age on content-hashed files.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "assets" {
  enabled      = true
  comment      = "ACUL bundle (sample)"
  price_class  = var.cloudfront_price_class
  http_version = "http2and3"

  # Optional WAFv2 web ACL (var.enable_waf). CLOUDFRONT-scoped ACLs live in
  # us-east-1; this references its ARN regardless of var.aws_region.
  web_acl_id = var.enable_waf ? aws_wafv2_web_acl.cdn[0].arn : null

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.assets.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-${aws_s3_bucket.assets.id}"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD", "OPTIONS"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.cors.id
  }

  # Optional access logging to a private log bucket (var.enable_access_logs).
  dynamic "logging_config" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      bucket          = aws_s3_bucket.logs[0].bucket_domain_name
      prefix          = "cloudfront/"
      include_cookies = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Uses the default *.cloudfront.net certificate, so you get HTTPS with no ACM
  # certificate or custom CDN domain to manage.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

##############################################################################
# OPTIONAL — production hardening, all off by default so the quick start stays
# simple. Flip the toggles in terraform.tfvars to enable.
##############################################################################

# --- WAFv2 web ACL (var.enable_waf): rate limiting + AWS managed rule groups --
# CLOUDFRONT scope requires the us-east-1 provider.
resource "aws_wafv2_web_acl" "cdn" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.us_east_1

  name        = "${var.bucket_name}-acul"
  description = "Managed protections for the ACUL CDN"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Per-IP rate limit (requests per 5-minute window).
  rule {
    name     = "rate-limit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.bucket_name}-rate"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed baseline rules.
  rule {
    name     = "aws-common"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.bucket_name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-bad-inputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.bucket_name}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.bucket_name}-acul"
    sampled_requests_enabled   = true
  }
}

# --- CloudFront access logs (var.enable_access_logs) → private log bucket ------
data "aws_canonical_user_id" "current" {
  count = var.enable_access_logs ? 1 : 0
}

resource "aws_s3_bucket" "logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = "${var.bucket_name}-logs"
}

# CloudFront standard logging delivers via ACLs, so this bucket (unlike the
# asset bucket) allows bucket-owner-preferred ownership + a delivery grant.
resource "aws_s3_bucket_ownership_controls" "logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count                   = var.enable_access_logs ? 1 : 0
  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
  }
}

# Grant the CloudFront log-delivery account write access (well-known canonical
# user id, the same for all AWS accounts).
resource "aws_s3_bucket_acl" "logs" {
  count      = var.enable_access_logs ? 1 : 0
  depends_on = [aws_s3_bucket_ownership_controls.logs]
  bucket     = aws_s3_bucket.logs[0].id

  access_control_policy {
    owner {
      id = data.aws_canonical_user_id.current[0].id
    }
    grant {
      grantee {
        type = "CanonicalUser"
        id   = "c4c1ede66af53448b93c283ce9448c4ba468c9432aa01d700d3878632f77d2d0"
      }
      permission = "FULL_CONTROL"
    }
    grant {
      grantee {
        type = "CanonicalUser"
        id   = data.aws_canonical_user_id.current[0].id
      }
      permission = "FULL_CONTROL"
    }
  }
}

# Bucket policy: only THIS CloudFront distribution may read objects.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontReadViaOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.assets.arn]
    }
  }

  # Reject any non-TLS access outright.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.assets]
}

##############################################################################
# GitHub Actions OIDC role — lets CI sync the build to S3 using short-lived
# credentials instead of long-lived AWS access keys. Its ARN becomes the
# AWS_S3_ARN repo secret.
##############################################################################

# The OIDC provider is account-wide: create it once, or reuse an existing one.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS now validates GitHub's certificate against its trust store, so this
  # thumbprint is legacy but still required by the API.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Trust policy: ONLY the named repo, on the named ref, may assume this role.
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoping `sub` is what stops other repos/branches assuming the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:${var.github_ref_condition}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.bucket_name}-github-deploy"
  description          = "Least-privilege role for GitHub Actions to sync the ACUL bundle to S3"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
  # Optional defense-in-depth cap on what this role can ever do.
  permissions_boundary = var.github_role_permissions_boundary
}

# Least privilege: object-level writes to this one bucket. Nothing else.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "SyncObjects"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.assets.arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "s3-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
