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

  # SAMPLE: consider enabling access logging + WAF for production.
  # logging_config { bucket = "...", prefix = "cloudfront/" }
  # web_acl_id = "..."
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
