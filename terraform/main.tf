# AWS SES + Lambda Email-to-HTTP Bridge Infrastructure
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain name for email receiving"
  type        = string
}

variable "webhook_url" {
  description = "Target webhook URL"
  type        = string
}

variable "webhook_secret" {
  description = "Webhook secret for signature validation"
  type        = string
  sensitive   = true
}

variable "allowed_domains" {
  description = "Comma-separated list of allowed domains"
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

# S3 Bucket for email storage
resource "aws_s3_bucket" "email_storage" {
  bucket = "${var.environment}-ses-email-storage-${random_id.bucket_suffix.hex}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

resource "aws_s3_bucket_versioning" "email_storage_versioning" {
  bucket = aws_s3_bucket.email_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "email_storage_encryption" {
  bucket = aws_s3_bucket.email_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "email_storage_lifecycle" {
  bucket = aws_s3_bucket.email_storage.id

  rule {
    id     = "delete_old_emails"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# S3 Bucket Policy for SES
resource "aws_s3_bucket_policy" "email_storage_policy" {
  bucket = aws_s3_bucket.email_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSESPuts"
        Effect = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.email_storage.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_execution_role" {
  name = "${var.environment}-email-processor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.environment}-email-processor-lambda-policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.email_storage.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach basic execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

# Lambda function
resource "aws_lambda_function" "email_processor" {
  filename         = "lambda_function.zip"
  function_name    = "${var.environment}-email-to-http-processor"
  role            = aws_iam_role.lambda_execution_role.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime         = "python3.11"
  timeout         = 60

  environment {
    variables = {
      TARGET_WEBHOOK_URL = var.webhook_url
      WEBHOOK_SECRET     = var.webhook_secret
      S3_BUCKET         = aws_s3_bucket.email_storage.bucket
      ALLOWED_DOMAINS   = var.allowed_domains
      MAX_RETRIES       = "3"
      TIMEOUT_SECONDS   = "30"
      MAX_EMAIL_SIZE_MB = "10"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_logs,
  ]
}

# Create Lambda deployment package
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "lambda_function.zip"
  source_dir  = "../lambda/python"
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.environment}-email-to-http-processor"
  retention_in_days = 14
}

# Lambda permission for SES
resource "aws_lambda_permission" "allow_ses" {
  statement_id  = "AllowExecutionFromSES"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_processor.function_name
  principal     = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# SES Domain Identity
resource "aws_ses_domain_identity" "domain" {
  domain = var.domain_name
}

# SES Domain DKIM
resource "aws_ses_domain_dkim" "domain_dkim" {
  domain = aws_ses_domain_identity.domain.domain
}

# SES Receipt Rule Set
resource "aws_ses_receipt_rule_set" "email_to_http" {
  rule_set_name = "${var.environment}-email-to-http-bridge"
}

# SES Receipt Rule
resource "aws_ses_receipt_rule" "email_processor_rule" {
  name          = "process-emails"
  rule_set_name = aws_ses_receipt_rule_set.email_to_http.rule_set_name
  recipients    = ["webhook@${var.domain_name}"]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name       = aws_s3_bucket.email_storage.bucket
    object_key_prefix = "emails/"
    position          = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.email_processor.arn
    invocation_type = "Event"
    position        = 2
  }

  depends_on = [aws_lambda_permission.allow_ses]
}

# Set active rule set
resource "aws_ses_active_receipt_rule_set" "active" {
  rule_set_name = aws_ses_receipt_rule_set.email_to_http.rule_set_name
}

# Data sources
data "aws_caller_identity" "current" {}

# Outputs
output "domain_verification_token" {
  description = "Domain verification token for DNS"
  value       = aws_ses_domain_identity.domain.verification_token
}

output "dkim_tokens" {
  description = "DKIM tokens for DNS configuration"
  value       = aws_ses_domain_dkim.domain_dkim.dkim_tokens
}

output "s3_bucket_name" {
  description = "S3 bucket name for email storage"
  value       = aws_s3_bucket.email_storage.bucket
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.email_processor.function_name
}

output "mx_record" {
  description = "MX record to add to your domain DNS"
  value       = "inbound-smtp.${var.aws_region}.amazonaws.com"
}

output "domain_name" {
  description = "Domain name being configured"
  value       = var.domain_name
} 