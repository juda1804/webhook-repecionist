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

variable "domains" {
  description = "List of domains to configure for email receiving"
  type        = list(string)
  default     = []
}

variable "domain_name" {
  description = "Primary domain name for email receiving (backward compatibility)"
  type        = string
  default     = ""
}

variable "webhook_url" {
  description = "Target webhook URL (backward compatibility)"
  type        = string
  default     = ""
}

variable "webhook_secret" {
  description = "Webhook secret for signature validation (backward compatibility)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "allowed_domains" {
  description = "Comma-separated list of allowed domains (backward compatibility)"
  type        = string
  default     = ""
}

variable "enable_dynamic_config" {
  description = "Enable dynamic configuration from S3"
  type        = bool
  default     = true
}

variable "config_s3_key" {
  description = "S3 key for dynamic configuration file"
  type        = string
  default     = "config/domains.json"
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

# S3 Bucket for dynamic configuration (when enabled)
resource "aws_s3_bucket" "config_storage" {
  count  = var.enable_dynamic_config ? 1 : 0
  bucket = "${var.environment}-ses-email-config-${random_id.config_bucket_suffix.hex}"
}

resource "random_id" "config_bucket_suffix" {
  byte_length = 4
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

# Configuration for the config bucket
resource "aws_s3_bucket_versioning" "config_storage_versioning" {
  count  = var.enable_dynamic_config ? 1 : 0
  bucket = aws_s3_bucket.config_storage[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_storage_encryption" {
  count  = var.enable_dynamic_config ? 1 : 0
  bucket = aws_s3_bucket.config_storage[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
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
    Statement = concat([
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
    ], var.enable_dynamic_config ? [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.config_storage[0].arn}/*"
      }
    ] : [])
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
  source_code_hash = filebase64sha256("lambda_function.zip")
  runtime         = "python3.11"
  timeout         = 60

  environment {
    variables = merge({
      S3_BUCKET         = aws_s3_bucket.email_storage.bucket
      MAX_RETRIES       = "3"
      TIMEOUT_SECONDS   = "30"
      MAX_EMAIL_SIZE_MB = "10"
      ENABLE_DYNAMIC_CONFIG = var.enable_dynamic_config ? "true" : "false"
    }, var.enable_dynamic_config ? {
      CONFIG_S3_BUCKET = aws_s3_bucket.config_storage[0].bucket
      CONFIG_S3_KEY    = var.config_s3_key
    } : {
      # Backward compatibility environment variables
      TARGET_WEBHOOK_URL = var.webhook_url
      WEBHOOK_SECRET     = var.webhook_secret
      DOMAIN_NAME        = var.domain_name
      ALLOWED_DOMAINS    = var.allowed_domains  
    })
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_logs,
  ]
}

# Lambda deployment package (manually created)
# Note: lambda_function.zip is created manually with correct structure

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

# Determine all domains to configure
locals {
  all_domains = var.enable_dynamic_config ? var.domains : (var.domain_name != "" ? [var.domain_name] : [])
}

# SES Domain Identity for each domain
resource "aws_ses_domain_identity" "domains" {
  for_each = toset(local.all_domains)
  domain   = each.key
}

# SES Domain DKIM for each domain
resource "aws_ses_domain_dkim" "domains_dkim" {
  for_each = toset(local.all_domains)
  domain   = aws_ses_domain_identity.domains[each.key].domain
}

# SES Receipt Rule Set
resource "aws_ses_receipt_rule_set" "email_to_http" {
  rule_set_name = "${var.environment}-email-to-http-bridge"
}

# SES Receipt Rule for multi-domain support
resource "aws_ses_receipt_rule" "email_processor_rule" {
  name          = "process-emails-multi-domain"
  rule_set_name = aws_ses_receipt_rule_set.email_to_http.rule_set_name
  recipients    = var.enable_dynamic_config ? flatten([for domain in local.all_domains : ["*@${domain}"]]) : ["webhook@${var.domain_name}"]
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
output "domain_verification_tokens" {
  description = "Domain verification tokens for DNS (key = domain, value = token)"
  value       = { for domain, identity in aws_ses_domain_identity.domains : domain => identity.verification_token }
}

output "dkim_tokens" {
  description = "DKIM tokens for DNS configuration (key = domain, value = tokens)"
  value       = { for domain, dkim in aws_ses_domain_dkim.domains_dkim : domain => dkim.dkim_tokens }
}

output "s3_email_bucket_name" {
  description = "S3 bucket name for email storage"
  value       = aws_s3_bucket.email_storage.bucket
}

output "s3_config_bucket_name" {
  description = "S3 bucket name for configuration storage (if enabled)"
  value       = var.enable_dynamic_config ? aws_s3_bucket.config_storage[0].bucket : null
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.email_processor.function_name
}

output "mx_record" {
  description = "MX record to add to your domain DNS"
  value       = "10 inbound-smtp.${var.aws_region}.amazonaws.com"
}

output "configured_domains" {
  description = "List of domains being configured"
  value       = local.all_domains
}

output "receipt_rule_recipients" {
  description = "Email patterns configured in SES receipt rule"
  value       = aws_ses_receipt_rule.email_processor_rule.recipients
}

# Backward compatibility outputs
output "domain_verification_token" {
  description = "Domain verification token for DNS (backward compatibility)"
  value       = length(local.all_domains) > 0 ? aws_ses_domain_identity.domains[local.all_domains[0]].verification_token : null
}

output "domain_name" {
  description = "Primary domain name being configured (backward compatibility)"
  value       = length(local.all_domains) > 0 ? local.all_domains[0] : null
} 