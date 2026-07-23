# In this file put all the logic to create the proper infrastructure
terraform {
  backend "s3" {
    bucket = "rdicidr-terraform-state-800174642443"
    key    = "rdicidr/terraform.tfstate"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

#configure the AWS provider and default region for all resources below
provider "aws" {
        region = "us-east-1"
    }

resource "random_id" "suffix" {
    byte_length = 4
}

#S3 bucket that stores the built React app files (private,only readable via CloudFront)
resource "aws_s3_bucket" "app" {
    bucket = "rdicidr-app-${var.environment}-${random_id.suffix.hex}"
}

#Explicitely block public access to the app bucket(CloudFront + OAC(origin access control)will be the only reader)
resource "aws_s3_bucket_public_access_block" "app"{
    bucket = aws_s3_bucket.app.id

    block_public_acls = true
    block_public_policy = true
    ignore_public_acls = true
    restrict_public_buckets = true
}

#S3 bucket to store all the CloudFront access logs(kept seperate from app files)
resource "aws_s3_bucket" "logs"{
    bucket = "rdicidr-cloudfront-access-logs-${var.environment}" 
}

#Origin Access Control: the identity Cloudfront uses to prove to S3 it's allowed to read the app bucket
resource "aws_cloudfront_origin_access_control" "app" {
    name                              = "rdicidr-oac-${var.environment}"
    origin_access_control_origin_type = "s3"
    signing_behavior                  = "always"
    signing_protocol                  = "sigv4"
}

#CloudFront Distribution: the CDN that serves the app bucket's files to users worldwide
resource "aws_cloudfront_distribution" "app" {
    depends_on = [aws_s3_bucket_acl.logs]
    #Origin: where CloudFront fetches files from (our private app bucket, via OAC)
    origin{
        domain_name              = aws_s3_bucket.app.bucket_regional_domain_name
        origin_access_control_id = aws_cloudfront_origin_access_control.app.id
        origin_id                = "app_s3_origin"
    }
    enabled = true
    default_root_object = "index.html"
    comment = "rdicidr app - ${var.environment} environment"

    #Use CloudFront's default HTTPS certificate (no custom domain in this challenge)
    viewer_certificate {
        cloudfront_default_certificate = true
    }

    #No geographic restrictions - site is accessible from anywhere
    restrictions {
        geo_restriction {
            restriction_type = "none"
            locations = []
        }
    }

    #Caching behavior: use AWS'S CachingOptimized managed policy, force HTTPS, static-file-only methods
    default_cache_behavior {
        cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
        allowed_methods = ["GET", "HEAD", "OPTIONS"]
        cached_methods  = ["GET", "HEAD"]
        target_origin_id = "app_s3_origin"
        viewer_protocol_policy = "redirect-to-https"
    }

    logging_config {
        include_cookies = false
        bucket = aws_s3_bucket.logs.bucket_domain_name
        prefix = "cloudfront/logs/"
    }
}
    # we are writing iam buckey policy for app s3 bucket to give permissions to read it's files for cloudfront
    data "aws_iam_policy_document" "app_bucket_policy"{
        statement{
            sid = "AllowCloudFrontServicePrincipalRead"
            effect = "Allow"

        principals {
            type = "Service"
            identifiers = ["cloudfront.amazonaws.com"]
        }

        actions = ["s3:GetObject"]

        resources = ["${aws_s3_bucket.app.arn}/*"]

        condition {
            test = "StringEquals"
            variable = "AWS:SourceArn"
            values = [aws_cloudfront_distribution.app.arn]
        }
    }
    }

    #We are attcahing the above policy we generated to s3 app bucket
    resource "aws_s3_bucket_policy" "app" {
        bucket = aws_s3_bucket.app.id
        policy = data.aws_iam_policy_document.app_bucket_policy.json
    }

    #Enable ACLs on the logs bucket (overrides the modern default that disables them,needed for CloudFront log delivery)
    resource "aws_s3_bucket_ownership_controls" "logs" {
        bucket = aws_s3_bucket.logs.id
        rule {
            object_ownership = "BucketOwnerPreferred"
        }
    }

    #Grant CloudFront's log-delivery service write access to the logs bucket via the special log-delivery-write ACL
    resource "aws_s3_bucket_acl" "logs" {
        depends_on = [aws_s3_bucket_ownership_controls.logs]
        bucket = aws_s3_bucket.logs.id
        acl = "log-delivery-write"
    }
