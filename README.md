# AWS SES + Lambda Email-to-HTTP Bridge

A complete solution for receiving emails via AWS SES and forwarding them as HTTP requests to your webhook endpoints.

## 🏗️ Architecture

```
Incoming Email → AWS SES → S3 Storage → Lambda Function → HTTP Webhook → Your API
```

## ✨ Features

- **Email Reception**: Receive emails for your domain via AWS SES
- **HTTP Forwarding**: Convert emails to structured HTTP requests
- **Signature Verification**: Secure webhook delivery with HMAC signatures
- **Email Parsing**: Extract text, HTML content, and attachment metadata
- **Domain Filtering**: Restrict email processing to allowed domains
- **Retry Logic**: Automatic retry with exponential backoff
- **Infrastructure as Code**: Complete Terraform configuration
- **Monitoring**: CloudWatch logs and metrics

## 📋 Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- Python 3.11+
- A domain you can configure DNS records for
- Target HTTP endpoint to receive email data

## 🚀 Quick Start

### 1. Clone and Configure

```bash
# Clone the repository
git clone <repository-url>
cd webhook-recepcionist

# Copy and configure variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` with your configuration:

```hcl
domain_name     = "yourdomain.com"
webhook_url     = "https://your-api.com/webhook/email"
webhook_secret  = "your-secure-secret-here"
allowed_domains = "yourdomain.com"
environment     = "prod"
```

### 2. Deploy Infrastructure

```bash
# Make deploy script executable
chmod +x scripts/deploy.sh

# Deploy everything
./scripts/deploy.sh
```

### 3. Configure DNS

After deployment, add the DNS records shown in the output:

```bash
# TXT Record for domain verification
_amazonses.yourdomain.com → "verification-token-from-output"

# MX Record for email receiving  
yourdomain.com → "10 inbound-smtp.us-east-1.amazonaws.com"

# DKIM CNAME Records (recommended)
token1._domainkey.yourdomain.com → token1.dkim.amazonses.com
token2._domainkey.yourdomain.com → token2.dkim.amazonses.com
token3._domainkey.yourdomain.com → token3.dkim.amazonses.com
```

### 4. Test Your Setup

Start the test webhook receiver:

```bash
# Install test dependencies (if needed)
pip3 install -r testing/requirements.txt

# Start test receiver
python3 testing/test-webhook-receiver.py --port 8080 --secret your-webhook-secret

# In another terminal, use ngrok to expose your local server
ngrok http 8080
```

Update your `webhook_url` in `terraform.tfvars` to the ngrok URL and redeploy.

Send a test email to `webhook@yourdomain.com` and watch the output!

## 📁 Project Structure

```
├── README.md                           # This file
├── aws-ses-lambda-setup.md            # Detailed setup guide
├── lambda/
│   └── python/
│       ├── lambda_function.py         # Main Lambda function
│       └── requirements.txt           # Python dependencies
├── terraform/
│   ├── main.tf                        # Infrastructure configuration
│   └── terraform.tfvars.example       # Configuration template
├── scripts/
│   └── deploy.sh                      # Deployment script
└── testing/
    └── test-webhook-receiver.py       # Test webhook receiver
```

## 🔧 Configuration Options

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TARGET_WEBHOOK_URL` | Your webhook endpoint URL | Required |
| `WEBHOOK_SECRET` | Secret for HMAC signature | Optional |
| `ALLOWED_DOMAINS` | Comma-separated allowed domains | All domains |
| `MAX_RETRIES` | Number of retry attempts | 3 |
| `TIMEOUT_SECONDS` | HTTP request timeout | 30 |
| `MAX_EMAIL_SIZE_MB` | Maximum email size to process | 10 |

### Webhook Payload Format

Your webhook will receive JSON payloads like this:

```json
{
  "event_type": "email_received",
  "timestamp": "2024-01-15T10:30:00Z",
  "message_id": "0000014a-f4d4-4f0c-a7c4-5c1b69cd8f5b",
  "source": "sender@example.com",
  "destination": ["webhook@yourdomain.com"],
  "subject": "Test Email",
  "headers": {
    "date": "Mon, 15 Jan 2024 10:30:00 +0000",
    "subject": "Test Email",
    "from": ["sender@example.com"],
    "to": ["webhook@yourdomain.com"]
  },
  "email": {
    "text_content": "This is the plain text content of the email.",
    "html_content": "<p>This is the HTML content of the email.</p>",
    "attachments": [
      {
        "filename": "document.pdf",
        "content_type": "application/pdf",
        "size": 2048
      }
    ],
    "parsed_headers": {
      "Content-Type": "multipart/mixed",
      "MIME-Version": "1.0"
    }
  }
}
```

## 🔐 Security Features

### Signature Verification

When `WEBHOOK_SECRET` is configured, each request includes an `X-Webhook-Signature` header:

```python
import hmac
import hashlib

def verify_signature(payload, signature_header, secret):
    if not signature_header.startswith('sha256='):
        return False
    
    received_sig = signature_header[7:]  # Remove 'sha256=' prefix
    expected_sig = hmac.new(
        secret.encode('utf-8'),
        payload.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()
    
    return hmac.compare_digest(received_sig, expected_sig)
```

### Domain Filtering

Configure `ALLOWED_DOMAINS` to restrict email processing:

```bash
# Only process emails to specific domains
ALLOWED_DOMAINS="yourdomain.com,anotherdomain.com"
```

## 📊 Monitoring and Troubleshooting

### CloudWatch Logs

View Lambda execution logs:

```bash
aws logs tail /aws/lambda/your-function-name --follow
```

### S3 Email Storage

Check stored emails:

```bash
aws s3 ls s3://your-bucket-name/emails/ --recursive
```

### Common Issues

1. **DNS Not Propagated**: Wait up to 72 hours for DNS changes
2. **Domain Not Verified**: Check TXT record is correctly added
3. **Lambda Errors**: Check CloudWatch logs for detailed error messages
4. **Webhook Timeouts**: Ensure your endpoint responds within 30 seconds

## 🔄 Updating the Solution

To update Lambda function code:

```bash
# Update the Lambda function
cd lambda/python
# Make your changes to lambda_function.py

# Redeploy
cd ../../
./scripts/deploy.sh
```

## 🧹 Cleanup

To destroy all resources:

```bash
cd terraform
terraform destroy
```

## 📚 Additional Resources

- [AWS SES Developer Guide](https://docs.aws.amazon.com/ses/)
- [AWS Lambda Python Documentation](https://docs.aws.amazon.com/lambda/latest/dg/python-programming-model.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## ⚠️ Important Notes

- **AWS Costs**: This solution uses AWS Lambda, SES, S3, and CloudWatch which may incur charges
- **Email Limits**: AWS SES has sending/receiving limits in sandbox mode
- **Security**: Always use HTTPS endpoints and webhook secrets in production
- **Compliance**: Ensure your email handling complies with relevant regulations (GDPR, CAN-SPAM, etc.) 