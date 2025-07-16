#!/bin/bash

# AWS SES + Lambda Email-to-HTTP Bridge Deployment Script
set -e

echo "🚀 Deploying AWS SES + Lambda Email-to-HTTP Bridge..."

# Check if terraform.tfvars exists
if [ ! -f "terraform/terraform.tfvars" ]; then
    echo "❌ Error: terraform.tfvars not found!"
    echo "Please copy terraform/terraform.tfvars.example to terraform/terraform.tfvars and configure your values."
    exit 1
fi

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ Error: AWS CLI not configured or credentials invalid"
    echo "Please run 'aws configure' to set up your credentials"
    exit 1
fi

# Check if required tools are installed
command -v terraform >/dev/null 2>&1 || { echo "❌ Error: terraform not installed" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "❌ Error: python3 not installed" >&2; exit 1; }
command -v pip3 >/dev/null 2>&1 || { echo "❌ Error: pip3 not installed" >&2; exit 1; }

echo "✅ Prerequisites check passed"

# Create Lambda deployment package
echo "📦 Creating Lambda deployment package..."
cd lambda/python

# Install dependencies in a temporary directory
if [ -d "package" ]; then
    rm -rf package
fi
mkdir package

pip3 install -r requirements.txt -t package/
cp lambda_function.py package/

# Create zip file
cd package
zip -r ../../terraform/lambda_function.zip .
cd ../../

echo "✅ Lambda package created"

# Deploy with Terraform
echo "🏗️  Deploying infrastructure with Terraform..."
cd terraform

# Initialize Terraform
terraform init

# Plan deployment
echo "📋 Terraform plan:"
terraform plan

# Apply with confirmation
echo ""
read -p "Do you want to apply these changes? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    terraform apply -auto-approve
    
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo ""
    echo "📝 Next steps:"
    echo "1. Add the following DNS records to your domain:"
    echo ""
    
    # Extract outputs
    DOMAIN_TOKEN=$(terraform output -raw domain_verification_token)
    MX_RECORD=$(terraform output -raw mx_record)
    
    echo "   TXT Record:"
    echo "   Name: _amazonses.$(terraform output -raw domain_name)"
    echo "   Value: $DOMAIN_TOKEN"
    echo ""
    echo "   MX Record:"
    echo "   Name: $(terraform output -raw domain_name)"
    echo "   Value: 10 $MX_RECORD"
    echo ""
    
    # Check if DKIM tokens are available
    if terraform output dkim_tokens &> /dev/null; then
        echo "   DKIM CNAME Records (recommended):"
        DKIM_TOKENS=$(terraform output -json dkim_tokens | jq -r '.[]')
        for token in $DKIM_TOKENS; do
            echo "   Name: ${token}._domainkey.$(terraform output -raw domain_name)"
            echo "   Value: ${token}.dkim.amazonses.com"
            echo ""
        done
    fi
    
    echo "2. Wait for DNS propagation (may take up to 72 hours)"
    echo "3. Test email sending to webhook@$(terraform output -raw domain_name)"
    echo "4. Monitor Lambda logs in CloudWatch"
    echo ""
    
    S3_BUCKET=$(terraform output -raw s3_bucket_name)
    LAMBDA_FUNCTION=$(terraform output -raw lambda_function_name)
    
    echo "📊 Resources created:"
    echo "   S3 Bucket: $S3_BUCKET"
    echo "   Lambda Function: $LAMBDA_FUNCTION"
    echo ""
    echo "🔍 Useful AWS CLI commands:"
    echo "   View Lambda logs: aws logs tail /aws/lambda/$LAMBDA_FUNCTION --follow"
    echo "   Check S3 emails: aws s3 ls s3://$S3_BUCKET/emails/"
    echo ""
    
else
    echo "Deployment cancelled."
    exit 1
fi

cd ..

echo "✅ Deployment script completed!" 