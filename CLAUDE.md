# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **AWS SES + Lambda Email-to-HTTP Bridge** that receives emails via AWS SES and forwards them as structured HTTP requests to webhook endpoints. The architecture follows: `Incoming Email → AWS SES → S3 Storage → Lambda Function → HTTP Webhook`.

## Key Architecture Components

- **AWS SES**: Handles incoming email reception and routing
- **S3 Bucket**: Stores raw email files with 30-day lifecycle policy
- **Lambda Function**: Processes emails and sends HTTP webhooks (`lambda/python/lambda_function.py`)
- **Terraform Infrastructure**: Complete IaC setup in `terraform/main.tf`
- **Receipt Rules**: Routes emails to `webhook@{domain}` through SES

## Common Development Commands

### Deployment
```bash
# Deploy complete infrastructure
./scripts/deploy.sh

# Manual Terraform commands
cd terraform
terraform init
terraform plan
terraform apply
```

### Testing
```bash
# Start local webhook receiver for testing
python3 testing/test-webhook-receiver.py --port 8080 --secret your-webhook-secret

# Test with signature verification
python3 testing/test-webhook-receiver.py --port 8080 --secret your-webhook-secret --debug
```

### Monitoring
```bash
# View Lambda logs
aws logs tail /aws/lambda/{environment}-email-to-http-processor --follow

# Check stored emails in S3
aws s3 ls s3://{bucket-name}/emails/ --recursive

# Test SES domain verification
aws ses get-identity-verification-attributes --identities yourdomain.com
```

## Production Deployment Guide

### Prerequisites
- AWS CLI configured with appropriate permissions
- Terraform >= 1.0 installed
- Domain with DNS management access
- Target HTTP endpoint ready to receive webhooks

### Step 1: Configuration
```bash
# Copy configuration template
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:
```hcl
aws_region      = "us-east-1"                    # AWS region
domain_name     = "yourdomain.com"               # Your domain
webhook_url     = "https://your-api.com/webhook" # Target endpoint
webhook_secret  = "secure-secret-key"            # HMAC secret
allowed_domains = "yourdomain.com"               # Comma-separated
environment     = "prod"                         # Environment name
```

### Step 2: Deploy Infrastructure
```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### Step 3: DNS Configuration
After deployment, add these DNS records:

**Domain Verification (TXT)**:
```
Name: _amazonses.yourdomain.com
Value: {verification-token-from-output}
```

**Email Reception (MX)**:
```
Name: yourdomain.com  
Value: 10 inbound-smtp.us-east-1.amazonaws.com
```

**DKIM Authentication (CNAME)** - for each token:
```
Name: {token}._domainkey.yourdomain.com
Value: {token}.dkim.amazonses.com
```

### Step 4: Verification
- Wait for DNS propagation (up to 72 hours)
- Send test email to `webhook@yourdomain.com`
- Monitor CloudWatch logs for processing
- Verify webhook endpoint receives payload

## Environment Variables (Lambda)

| Variable | Description | Default |
|----------|-------------|---------|
| `TARGET_WEBHOOK_URL` | Destination webhook URL | Required |
| `WEBHOOK_SECRET` | HMAC signature secret | Optional |
| `S3_BUCKET` | S3 bucket for email storage | Auto-set |
| `ALLOWED_DOMAINS` | Comma-separated allowed domains | All |
| `MAX_RETRIES` | HTTP retry attempts | 3 |
| `TIMEOUT_SECONDS` | HTTP request timeout | 30 |
| `MAX_EMAIL_SIZE_MB` | Max email size to process | 10 |

## Webhook Payload Structure

```json
{
  "event_type": "email_received",
  "timestamp": "2024-01-15T10:30:00Z",
  "message_id": "unique-message-id",
  "source": "sender@example.com", 
  "destination": ["webhook@yourdomain.com"],
  "subject": "Email Subject",
  "headers": { "date": "...", "from": [...], "to": [...] },
  "email": {
    "text_content": "Plain text content",
    "html_content": "<p>HTML content</p>",
    "attachments": [
      {
        "filename": "document.pdf",
        "content_type": "application/pdf", 
        "size": 2048
      }
    ],
    "parsed_headers": { "Content-Type": "...", "MIME-Version": "..." }
  }
}
```

## Security Features

- **HMAC Signatures**: Webhook requests include `X-Webhook-Signature` header
- **Domain Filtering**: Restrict processing to allowed domains
- **S3 Encryption**: AES256 server-side encryption
- **IAM Least Privilege**: Minimal required permissions
- **VPC Optional**: Can be deployed in VPC for additional isolation

## Key Files

- `lambda/python/lambda_function.py`: Main email processing logic
- `lambda/python/requirements.txt`: Python dependencies
- `terraform/main.tf`: Complete infrastructure definition
- `terraform/terraform.tfvars.example`: Configuration template
- `scripts/deploy.sh`: Automated deployment script
- `testing/test-webhook-receiver.py`: Local webhook testing server

## Troubleshooting

### Common Issues
1. **DNS Not Propagated**: Wait up to 72 hours, verify with `dig`
2. **Domain Not Verified**: Check TXT record is correct
3. **Lambda Timeouts**: Check webhook endpoint response time (<30s)
4. **Signature Verification Fails**: Ensure webhook secret matches

### Useful Commands
```bash
# Check domain verification status
aws ses get-identity-verification-attributes --identities yourdomain.com

# View recent Lambda errors
aws logs filter-log-events --log-group-name /aws/lambda/{function-name} --filter-pattern "ERROR"

# Test Lambda function directly
aws lambda invoke --function-name {function-name} --payload '{}' output.json
```

## Updating Lambda Code

```bash
# Make changes to lambda/python/lambda_function.py
cd lambda/python
# Update requirements.txt if needed

# Redeploy
cd ../../
./scripts/deploy.sh
```

## Resource Cleanup

```bash
cd terraform
terraform destroy
```

## Production Readiness Verification

✅ **Code Quality**: All critical issues have been fixed:
- Fixed SES event structure handling for multiple receipt actions
- Added proper error handling and logging throughout
- Implemented exponential backoff with timeout caps
- Added email size validation to prevent memory issues
- Fixed deployment script path resolution

✅ **Security**: Production-ready security features:
- HMAC webhook signature verification
- Domain filtering for email processing
- S3 server-side encryption (AES256)
- IAM least-privilege permissions
- Input validation and sanitization

✅ **Reliability**: Robust error handling and recovery:
- Exponential backoff retry logic with 60-second cap
- Comprehensive logging for troubleshooting
- Graceful handling of malformed emails
- S3 retrieval failure resilience
- Lambda timeout and memory management

✅ **Infrastructure**: Complete and tested Terraform configuration:
- All required AWS resources properly configured
- Correct SES receipt rule ordering (S3 then Lambda)
- Proper IAM roles and policies
- CloudWatch logging setup
- S3 lifecycle policies (30-day retention)

## Cost Considerations

- **Lambda**: Pay per invocation and duration (~$0.20 per 1M requests)
- **SES**: Receiving emails is free (first 1000/month), sending has costs
- **S3**: Storage costs for email files (auto-deleted after 30 days)
- **CloudWatch**: Log storage and monitoring (~$0.50/GB/month)