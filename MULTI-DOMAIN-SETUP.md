# Multi-Domain Email-to-Webhook Setup Guide

This guide explains how to configure the AWS SES + Lambda Email-to-HTTP Bridge for multiple domains with different webhook endpoints and processing rules.

## Overview

The multi-domain system supports:
- Multiple domains with different webhook endpoints
- Domain-specific email patterns and filtering rules
- Dynamic configuration without redeployment
- Per-domain retry settings and custom headers
- Centralized management via JSON configuration

## Architecture

```
Email → SES → S3 (Email Storage) → Lambda → Domain Config (S3) → Webhook(s)
```

- **SES Receipt Rules**: Uses wildcards (*@domain.com) to capture all emails
- **Lambda Function**: Dynamically routes emails based on domain configuration
- **S3 Configuration**: JSON file with domain-specific settings and webhook URLs
- **Management Scripts**: Tools to add/modify domains without redeployment

## Quick Start

### 1. Deploy Infrastructure

```bash
# Copy and configure terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit terraform.tfvars - enable dynamic configuration
enable_dynamic_config = true
domains = ["domain1.com", "domain2.com"]

# Deploy
./scripts/deploy.sh
```

### 2. Configure Domains

```bash
# Add first domain configuration
./scripts/add-domain-config.sh domain1.com https://api.domain1.com/webhook secret123

# Add second domain with specific patterns
./scripts/add-domain-config.sh domain2.com https://domain2.com/api/email secret456 'contact@domain2.com' 'support@domain2.com'

# Upload configuration to S3
./scripts/upload-config.sh
```

### 3. Configure DNS

Add the DNS records shown in Terraform output for each domain:

```bash
# Get DNS configuration for all domains
terraform output domain_verification_tokens
terraform output dkim_tokens
terraform output mx_record
```

## Configuration Examples

### Basic Multi-Domain Setup

```json
{
  "version": "1.0",
  "domains": {
    "example.com": {
      "webhook_url": "https://api.example.com/webhook",
      "webhook_secret": "secret123",
      "patterns": ["*@example.com"],
      "filters": {
        "max_size_mb": 10,
        "allowed_senders": ["*"]
      }
    },
    "company.org": {
      "webhook_url": "https://company.org/api/webhooks/email",
      "webhook_secret": "company-secret",
      "patterns": ["contact@company.org", "support@company.org"],
      "filters": {
        "max_size_mb": 5,
        "allowed_senders": ["@trusted.com"],
        "blocked_domains": ["spam.com"]
      }
    }
  }
}
```

### Advanced Domain Configuration

```json
{
  "domains": {
    "secure-domain.com": {
      "webhook_url": "https://secure-api.com/webhook",
      "webhook_secret": "super-secret-key",
      "patterns": [
        "billing@secure-domain.com",
        "legal@secure-domain.com"
      ],
      "filters": {
        "max_size_mb": 2,
        "allowed_senders": ["@authorized-sender.com"],
        "blocked_senders": ["noreply@*"],
        "blocked_domains": ["suspicious.com"],
        "require_dkim": true,
        "require_spf": true
      },
      "payload_format": "custom",
      "custom_headers": {
        "Authorization": "Bearer api-token-here",
        "X-Source-Domain": "secure-domain.com",
        "X-Priority": "high"
      },
      "retry_config": {
        "max_retries": 5,
        "timeout_seconds": 45
      }
    }
  }
}
```

## Management Commands

### Add Domain Configuration
```bash
./scripts/add-domain-config.sh DOMAIN WEBHOOK_URL SECRET [PATTERNS...]

# Examples:
./scripts/add-domain-config.sh example.com https://api.example.com/webhook secret123
./scripts/add-domain-config.sh company.org https://company.org/webhook secret456 'contact@company.org' 'billing@company.org'
```

### Add Email Pattern to Existing Domain
```bash
./scripts/add-email-pattern.sh DOMAIN PATTERN

# Examples:
./scripts/add-email-pattern.sh example.com 'billing@example.com'
./scripts/add-email-pattern.sh company.org 'support-*@company.org'
```

### View Configurations
```bash
# List all domains
./scripts/list-configs.sh

# View specific domain
./scripts/list-configs.sh example.com
```

### Validate Configuration
```bash
./scripts/validate-config.sh
```

### Upload to S3
```bash
./scripts/upload-config.sh [S3_BUCKET]
```

## Email Patterns

The system supports flexible email patterns using wildcards:

- `*@domain.com` - All emails to domain.com
- `contact@domain.com` - Exact match only
- `support-*@domain.com` - Prefix matching (support-tickets@, support-billing@, etc.)
- `*-admin@domain.com` - Suffix matching (user-admin@, system-admin@, etc.)

## Filtering Options

### Sender Filtering
```json
{
  "filters": {
    "allowed_senders": ["@trusted.com", "admin@any-domain.com"],
    "blocked_senders": ["noreply@*", "marketing@*"],
    "blocked_domains": ["spam.com", "malware.net"]
  }
}
```

### Size and Security
```json
{
  "filters": {
    "max_size_mb": 5,
    "require_dkim": true,
    "require_spf": true
  }
}
```

## Webhook Payload Formats

### Standard Format
```json
{
  "event_type": "email_received",
  "metadata": {
    "message_id": "00000141-f23a-4c28-9837-fcadd2b2e543",
    "timestamp": "2024-01-15T10:30:00Z",
    "from_address": "sender@example.com",
    "to_addresses": ["contact@yourdomain.com"],
    "subject": "Email Subject",
    "correlation_id": "uuid-here"
  },
  "content": {
    "text": "Plain text content",
    "html": "<p>HTML content</p>"
  }
}
```

### Custom Headers
Domains can include custom headers in webhook requests:

```json
{
  "custom_headers": {
    "Authorization": "Bearer your-api-token",
    "X-Source-Domain": "yourdomain.com",
    "X-Environment": "production"
  }
}
```

## Monitoring and Troubleshooting

### View Lambda Logs
```bash
# Get function name from Terraform
FUNCTION_NAME=$(terraform output -raw lambda_function_name)

# Tail logs
aws logs tail /aws/lambda/$FUNCTION_NAME --follow
```

### Common Issues

1. **Domain not verified**: Check DNS records are properly configured
2. **Webhook not receiving**: Verify webhook URL is accessible and returns 200/201/202
3. **Configuration not updating**: Wait 5 minutes for Lambda cache refresh or restart function
4. **Email size limits**: Check domain-specific max_size_mb settings

### Debug Configuration
```bash
# Validate configuration file
./scripts/validate-config.sh

# Check current S3 configuration
aws s3 cp s3://YOUR-CONFIG-BUCKET/config/domains.json - | jq .

# Test webhook connectivity
curl -X POST -H "Content-Type: application/json" -d '{"test": true}' YOUR_WEBHOOK_URL
```

## Migration from Single Domain

If you have an existing single-domain setup:

1. **Backup**: Keep your existing terraform.tfvars as backup
2. **Enable dynamic config**: Set `enable_dynamic_config = true`
3. **Migrate configuration**: Use add-domain-config.sh to recreate your domain
4. **Update DNS**: May need to update SES receipt rules
5. **Test**: Verify emails are still processed correctly

```bash
# Migrate existing single domain setup
./scripts/add-domain-config.sh your-existing-domain.com $WEBHOOK_URL $WEBHOOK_SECRET
./scripts/upload-config.sh
```

## Performance Considerations

- **Configuration caching**: Lambda caches config for 5 minutes
- **Email size limits**: Set appropriate max_size_mb per domain
- **Retry settings**: Configure based on webhook endpoint reliability
- **Concurrent processing**: Lambda handles multiple emails concurrently

## Security Best Practices

1. **Use HTTPS webhooks only**
2. **Implement webhook signature verification**
3. **Set appropriate sender filtering**
4. **Enable DKIM/SPF verification for sensitive domains**
5. **Use strong webhook secrets**
6. **Monitor for unusual email patterns**

## Cost Optimization

- **Email retention**: S3 lifecycle deletes emails after 30 days
- **Lambda duration**: Optimized for fast processing
- **SES receiving**: First 1000 emails/month are free
- **S3 costs**: Minimal for configuration storage

## Support

For issues or questions:
1. Check CloudWatch logs for detailed error messages
2. Validate configuration with ./scripts/validate-config.sh
3. Test webhook endpoints independently
4. Review DNS configuration for domain verification