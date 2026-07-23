output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.app.domain_name
  description = "The CloudFront URL to visit the deployed app"
}

output "logs_bucket_name" {
  value       = aws_s3_bucket.logs.bucket
  description = "The S3 bucket where CloudFront access logs are stored"
}

output "cloudfront_distribution_id" {
  value       = aws_cloudfront_distribution.app.id
  description = "The CloudFront distribution ID, useful for CLI operations like cache invalidation"
}

output "app_bucket_name" {
  value       = aws_s3_bucket.app.bucket
  description = "The S3 bucket where teh app code is deployed"
}

