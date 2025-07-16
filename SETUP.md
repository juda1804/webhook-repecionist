# AWS SES + Lambda Email-to-HTTP Bridge - Setup Information

**Deployment Date**: July 16, 2025  
**Domain**: mail.gestioncitas.services (subdomain)  
**Environment**: Production

## 🎉 Deployment Successful

The AWS infrastructure has been successfully deployed for the email-to-HTTP bridge system.

## 📧 Email Configuration

**Target Email Address**: `webhook@mail.gestioncitas.services`  
**Webhook Endpoint**: `https://chatbot-n8n.s8qib7.easypanel.host/webhook/email`  
**Webhook Secret**: `7122771ed9f208c5d8faa2883ed78e2872564a3203238935cc6ae5fa25589ee1`

## 🏗️ AWS Resources Created

| Resource Type | Name/ID | Purpose |
|---------------|---------|---------|
| Lambda Function | `prod-email-to-http-processor` | Email processing and HTTP forwarding |
| S3 Bucket | `prod-ses-email-storage-cc7212ef3928585b` | Email storage (30-day retention) |
| SES Domain Identity | `mail.gestioncitas.services` | Email reception configuration |
| SES Receipt Rule Set | `prod-email-to-http-bridge` | Email routing rules |
| IAM Role | `prod-email-processor-lambda-role` | Lambda execution permissions |
| CloudWatch Log Group | `/aws/lambda/prod-email-to-http-processor` | Function logs (14-day retention) |

## 🌐 DNS Records Configuration

**CRITICAL**: Add these DNS records to your domain provider for the system to work.

### 1. Domain Verification (TXT Record)
```
Type: TXT
Name: _amazonses.mail.gestioncitas.services
Value: 2qGfSaVi68o95mlNCuf+zW5xKr6LIVw92Aa+jYxXxUg=
TTL: 300 (or your provider's default)
```

### 2. Email Reception (MX Record)
```
Type: MX
Name: mail.gestioncitas.services
Value: inbound-smtp.us-east-1.amazonaws.com
Priority: 10
TTL: 300 (or your provider's default)
```

### 3. DKIM Authentication (CNAME Records) - Recommended for Better Deliverability
```
Type: CNAME
Name: 7s6gjhb5jxaxnoevwqv6x77npfyhhcip._domainkey.mail.gestioncitas.services
Value: 7s6gjhb5jxaxnoevwqv6x77npfyhhcip.dkim.amazonses.com
TTL: 300

Type: CNAME
Name: cho43gveva26tzglzt4amqlwydxkgt4s._domainkey.mail.gestioncitas.services  
Value: cho43gveva26tzglzt4amqlwydxkgt4s.dkim.amazonses.com
TTL: 300

Type: CNAME
Name: srnpoqso5emsnrduv2y4v4jenuqbh2we._domainkey.mail.gestioncitas.services
Value: srnpoqso5emsnrduv2y4v4jenuqbh2we.dkim.amazonses.com
TTL: 300
```

## 🔍 Monitoring and Troubleshooting

### View Lambda Logs
```bash
aws logs tail /aws/lambda/prod-email-to-http-processor --follow --profile personal
```

### Check S3 Email Storage
```bash
aws s3 ls s3://prod-ses-email-storage-cc7212ef3928585b/emails/ --profile personal
```

### Verify Domain Status
```bash
aws ses get-identity-verification-attributes --identities mail.gestioncitas.services --profile personal
```

### Test Email Processing
Send a test email to: `webhook@mail.gestioncitas.services`

## 📋 Email Processing Flow

1. **Email Received** → AWS SES receives email for `webhook@mail.gestioncitas.services`
2. **Storage** → Raw email stored in S3 bucket (`emails/` prefix)
3. **Processing** → Lambda function triggered automatically
4. **Parsing** → Email content extracted (text, HTML, attachments metadata)
5. **Webhook** → HTTP POST sent to n8n endpoint with structured JSON
6. **Signature** → HMAC-SHA256 signature in `X-Webhook-Signature` header

## 🔐 Security Features

- ✅ HMAC webhook signature verification
- ✅ Domain filtering (`mail.gestioncitas.services`, `gmail.com` allowed)
- ✅ S3 server-side encryption (AES256)
- ✅ IAM least-privilege permissions
- ✅ Email size validation (10MB limit)
- ✅ Exponential backoff retry logic

## 🚨 Important Notes

1. **DNS Propagation**: Can take 5 minutes to 72 hours
2. **Domain Verification**: Must complete before email reception works
3. **Webhook Endpoint**: Must respond within 30 seconds
4. **Email Retention**: Emails auto-deleted from S3 after 30 days
5. **Logs Retention**: Lambda logs retained for 14 days

## 🔄 Next Steps

1. **Add DNS Records** (see above)
2. **Wait for Propagation** (check with `dig MX mail.gestioncitas.services`)
3. **Verify Domain** in AWS SES console
4. **Test Email Flow** by sending to `webhook@mail.gestioncitas.services`
5. **Monitor Processing** via CloudWatch logs
6. **Configure n8n** to handle incoming webhook payloads

## 📞 Emergency Procedures

### If Emails Stop Working
1. Check DNS records are still in place
2. Verify Lambda function is not throwing errors
3. Check S3 bucket permissions
4. Verify webhook endpoint is responding

### Access AWS Console
- **Region**: us-east-1
- **Profile**: personal
- **Lambda**: Search for `prod-email-to-http-processor`
- **S3**: Search for `prod-ses-email-storage-cc7212ef3928585b`
- **SES**: Check domain `mail.gestioncitas.services`

---

**System Status**: ✅ Deployed and Ready  
**Last Updated**: July 16, 2025  
**Terraform State**: Saved in `/terraform/terraform.tfstate`