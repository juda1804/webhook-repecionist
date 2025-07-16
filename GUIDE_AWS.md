Complete Step-by-Step AWS Deployment Guide

  Phase 1: Prerequisites & Setup

  1. Install Required Tools

  # Install AWS CLI (if not already installed)
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install

  # Install Terraform >= 1.0
  wget https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
  unzip terraform_1.6.6_linux_amd64.zip
  sudo mv terraform /usr/local/bin/

  # Verify Python 3.11+ is installed
  python3 --version

  2. Configure AWS Credentials

  # Configure AWS CLI with your credentials
  aws configure

  # Required permissions for your AWS user/role:
  # - SES full access
  # - S3 full access
  # - Lambda full access
  # - IAM role creation
  # - CloudWatch logs

  3. Prepare Your Domain & Webhook Endpoint

  - Domain: You need a domain where you can modify DNS records
  - Webhook Endpoint: A running HTTP server that can receive POST requests
  - Webhook Secret: Generate a secure random string for HMAC verification

  Phase 2: Repository Setup

  4. Clone and Configure

  # Navigate to your projects directory
  cd ~/projects

  # Clone this repository (replace with your actual repo URL)
  git clone <your-repo-url>
  cd webhook-recepcionist

  # Copy configuration template
  cp terraform/terraform.tfvars.example terraform/terraform.tfvars

  5. Edit Configuration

  Edit terraform/terraform.tfvars with your specific values:

  # AWS Configuration
  aws_region = "us-east-1"  # Choose your preferred region

  # Domain Configuration
  domain_name = "example.com"  # Your actual domain

  # Webhook Configuration
  webhook_url    = "https://api.example.com/webhook/email"  # Your endpoint
  webhook_secret = "your-super-secure-secret-key-here"      # Generate strong secret

  # Email Filtering (optional - leave empty to accept all domains)
  allowed_domains = "example.com,anotherdomain.com"

  # Environment
  environment = "prod"  # or "staging", "dev", etc.

  Phase 3: AWS Infrastructure Deployment

  6. Deploy Infrastructure

  # Make deploy script executable
  chmod +x scripts/deploy.sh

  # Run the deployment script
  ./scripts/deploy.sh

  What this does:
  - Creates Lambda deployment package with dependencies
  - Initializes Terraform
  - Shows you the deployment plan
  - Asks for confirmation before applying
  - Creates all AWS resources:
    - S3 bucket for email storage
    - Lambda function for email processing
    - SES domain identity and receipt rules
    - IAM roles and policies
    - CloudWatch log groups

  7. Note the DNS Records

  After successful deployment, the script will display DNS records you need to add:

  📝 Next steps:
  1. Add the following DNS records to your domain:

     TXT Record:
     Name: _amazonses.example.com
     Value: ABC123XYZ...

     MX Record:
     Name: example.com
     Value: 10 inbound-smtp.us-east-1.amazonaws.com

     DKIM CNAME Records (recommended):
     Name: token1._domainkey.example.com
     Value: token1.dkim.amazonses.com

     Name: token2._domainkey.example.com
     Value: token2.dkim.amazonses.com

     Name: token3._domainkey.example.com
     Value: token3.dkim.amazonses.com

  Phase 4: DNS Configuration

  8. Add DNS Records

  In your domain's DNS management panel (e.g., Route 53, Cloudflare, GoDaddy):

  TXT Record (for domain verification):
  - Name: _amazonses.example.com
  - Value: The verification token from deployment output

  MX Record (for email receiving):
  - Name: example.com (or @ for root domain)
  - Value: 10 inbound-smtp.us-east-1.amazonaws.com
  - Priority: 10

  DKIM CNAME Records (for email authentication - recommended):
  - Add all 3 DKIM records as shown in deployment output

  9. Wait for DNS Propagation

  - DNS changes can take 5 minutes to 72 hours to propagate
  - You can check propagation with: dig MX example.com and dig TXT _amazonses.example.com

  Phase 5: Testing & Verification

  10. Test Your Webhook Endpoint (Optional)

  # Start local test receiver (in another terminal)
  python3 testing/test-webhook-receiver.py --port 8080 --secret your-webhook-secret

  # If testing locally, use ngrok to expose your endpoint
  ngrok http 8080
  # Then update webhook_url in terraform.tfvars and redeploy

  11. Verify Domain in AWS Console

  # Check domain verification status
  aws ses get-identity-verification-attributes --identities example.com

  12. Send Test Email

  Once DNS has propagated:
  # Send test email to your configured address
  echo "Test email body" | mail -s "Test Subject" webhook@example.com

  13. Monitor Processing

  # View Lambda logs in real-time
  aws logs tail /aws/lambda/prod-email-to-http-processor --follow

  # Check S3 for stored emails
  aws s3 ls s3://your-bucket-name/emails/

  Phase 6: Production Monitoring

  14. Set Up Monitoring

  - CloudWatch Dashboards: Monitor Lambda invocations, errors, duration
  - CloudWatch Alarms: Alert on Lambda failures or high error rates
  - S3 Metrics: Monitor email storage usage
  - SES Metrics: Track email reception rates

  15. Security Verification

  # Verify webhook signature in your endpoint code
  import hmac
  import hashlib

  def verify_signature(payload, signature_header, secret):
      if not signature_header.startswith('sha256='):
          return False

      received_sig = signature_header[7:]
      expected_sig = hmac.new(
          secret.encode('utf-8'),
          payload.encode('utf-8'),
          hashlib.sha256
      ).hexdigest()

      return hmac.compare_digest(received_sig, expected_sig)

  Production Checklist ✅

  - AWS credentials configured with proper permissions
  - Domain DNS records added and propagated
  - Webhook endpoint ready to receive POST requests
  - HMAC signature verification implemented
  - Lambda function deployed and logging properly
  - Test email successfully processed
  - Monitoring and alerting configured
  - Security best practices implemented

  Troubleshooting Common Issues

  Domain not verified: Check TXT record is correctly added
  Emails not received: Verify MX record and DNS propagationLambda errors: Check CloudWatch logs for
  detailed error messages
  Webhook failures: Ensure endpoint responds within 30 seconds
  Signature verification fails: Verify webhook secret matches configuration

  The infrastructure is now production-ready and will automatically process incoming emails and
  forward them as HTTP webhooks with enterprise-grade reliability!