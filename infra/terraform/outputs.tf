# These map 1:1 to the GitHub Actions secrets the deploy workflow needs.
# Print them with: terraform output

output "bucket_name" {
  description = "S3 bucket holding the ACUL bundle. → GitHub secret S3_BUCKET_NAME"
  value       = aws_s3_bucket.assets.id
}

output "cdn_url" {
  description = "CloudFront HTTPS base URL used for head_tags (no trailing slash). → GitHub secret S3_CDN_URL"
  value       = "https://${aws_cloudfront_distribution.assets.domain_name}"
}

output "github_actions_role_arn" {
  description = "IAM role the CI pipeline assumes via OIDC. → GitHub secret AWS_S3_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "aws_region" {
  description = "Region. → GitHub secret AWS_REGION"
  value       = var.aws_region
}

output "distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation, rarely needed — filenames are content-hashed)."
  value       = aws_cloudfront_distribution.assets.id
}

output "waf_web_acl_arn" {
  description = "WAFv2 web ACL ARN (null unless enable_waf)."
  value       = var.enable_waf ? aws_wafv2_web_acl.cdn[0].arn : null
}

output "access_logs_bucket" {
  description = "CloudFront access-log bucket (null unless enable_access_logs)."
  value       = var.enable_access_logs ? aws_s3_bucket.logs[0].id : null
}

output "next_steps" {
  description = "Reminder of what to do with these outputs."
  value       = <<-EOT
    Add these as GitHub Actions secrets (Settings → Secrets and variables → Actions):
      S3_BUCKET_NAME = bucket_name
      S3_CDN_URL     = cdn_url            (no trailing slash)
      AWS_S3_ARN     = github_actions_role_arn
      AWS_REGION     = aws_region
    Then add your Auth0 M2M values (NOT managed by Terraform, never commit them):
      AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET
  EOT
}
