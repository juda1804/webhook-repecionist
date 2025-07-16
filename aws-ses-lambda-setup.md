# AWS SES + Lambda Email-to-HTTP Bridge Setup Guide

## Overview
This guide helps you set up an AWS SES + Lambda solution that receives emails and forwards them as HTTP requests to your designated endpoints.

## Architecture
```
Incoming Email → AWS SES → Lambda Function → HTTP Request → Your API/Webhook
```

## Prerequisites
- AWS CLI configured with appropriate permissions
- A domain you can configure DNS records for
- Target HTTP endpoint to receive email data

## Step 1: Domain Setup and SES Configuration

### 1.1 Verify Domain in SES
```bash
# Replace 'yourdomain.com' with your actual domain
aws ses verify-domain-identity --domain yourdomain.com
```

### 1.2 Add DNS Records
Add these DNS records to your domain:
- **TXT Record**: `_amazonses.yourdomain.com` with the verification token from Step 1.1
- **MX Record**: `yourdomain.com` pointing to `inbound-smtp.us-east-1.amazonaws.com` (adjust region as needed)

### 1.3 Configure DKIM (Recommended)
```bash
aws ses put-identity-dkim-attributes --identity yourdomain.com --dkim-enabled
```

## Step 2: IAM Role for Lambda

### 2.1 Create Lambda Execution Role
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 2.2 Attach Policies
- `AWSLambdaBasicExecutionRole` (for CloudWatch logs)
- Custom policy for SES access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::your-ses-email-bucket/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    }
  ]
}
```

## Step 3: S3 Bucket for Email Storage

### 3.1 Create S3 Bucket
```bash
aws s3 mb s3://your-ses-email-bucket
```

### 3.2 Configure Bucket Policy
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSESPuts",
      "Effect": "Allow",
      "Principal": {
        "Service": "ses.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::your-ses-email-bucket/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceAccount": "YOUR_ACCOUNT_ID"
        }
      }
    }
  ]
}
```

## Step 4: SES Receipt Rule Configuration

### 4.1 Create Receipt Rule Set
```bash
aws ses create-receipt-rule-set --rule-set-name email-to-http-bridge
aws ses set-active-receipt-rule-set --rule-set-name email-to-http-bridge
```

### 4.2 Create Receipt Rule
```bash
aws ses create-receipt-rule \
  --rule-set-name email-to-http-bridge \
  --rule '{
    "Name": "process-emails",
    "Enabled": true,
    "Recipients": ["webhook@yourdomain.com"],
    "Actions": [
      {
        "S3Action": {
          "BucketName": "your-ses-email-bucket",
          "ObjectKeyPrefix": "emails/"
        }
      },
      {
        "LambdaAction": {
          "FunctionName": "email-to-http-processor"
        }
      }
    ]
  }'
```

## Step 5: Environment Variables Configuration

Create a `.env` file for local development:
```env
# AWS Configuration
AWS_REGION=us-east-1
S3_BUCKET=your-ses-email-bucket

# HTTP Endpoint Configuration
TARGET_WEBHOOK_URL=https://your-api.com/webhook
WEBHOOK_SECRET=your-webhook-secret
MAX_RETRIES=3
TIMEOUT_SECONDS=30

# Email Processing
ALLOWED_DOMAINS=yourdomain.com,anotherdomain.com
MAX_EMAIL_SIZE_MB=10
```

## Next Steps
1. Deploy the Lambda function (see `lambda/` directory)
2. Test the email flow
3. Set up monitoring and alerting
4. Configure error handling and dead letter queues

## Security Considerations
- Use VPC endpoints for S3 access if possible
- Implement proper input validation in Lambda
- Set up CloudWatch alarms for failures
- Use AWS KMS for encryption at rest
- Implement rate limiting on your HTTP endpoints 