#!/bin/bash

# Upload Configuration to S3 Script
# Usage: ./upload-config.sh [S3_BUCKET]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths
CONFIG_DIR="$(dirname "$0")/../config"
CONFIG_FILE="${CONFIG_DIR}/domains.json"
TERRAFORM_DIR="$(dirname "$0")/../terraform"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    echo "Please create a domain configuration first using add-domain-config.sh"
    exit 1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq is not installed. Please install jq to use this script.${NC}"
    exit 1
fi

# Validate configuration file
echo -e "${YELLOW}Validating configuration file...${NC}"
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${RED}❌ Configuration file has invalid JSON${NC}"
    exit 1
fi

# Determine S3 bucket
S3_BUCKET="$1"

if [ -z "$S3_BUCKET" ]; then
    # Try to get from Terraform output
    if [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
        echo -e "${YELLOW}Getting S3 bucket from Terraform state...${NC}"
        S3_BUCKET=$(terraform -chdir="$TERRAFORM_DIR" output -raw s3_config_bucket_name 2>/dev/null || echo "")
        
        if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "null" ]; then
            # Fall back to email bucket if config bucket not available
            S3_BUCKET=$(terraform -chdir="$TERRAFORM_DIR" output -raw s3_email_bucket_name 2>/dev/null || echo "")
        fi
    fi
    
    if [ -z "$S3_BUCKET" ]; then
        echo -e "${RED}❌ S3 bucket not specified and couldn't determine from Terraform${NC}"
        echo "Usage: $0 S3_BUCKET_NAME"
        echo ""
        echo "Or run from a directory with Terraform state that includes s3_config_bucket_name output"
        exit 1
    fi
fi

S3_KEY="config/domains.json"
S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

echo -e "${BLUE}📤 Uploading Configuration${NC}"
echo "=================================="
echo "Local file: $CONFIG_FILE"
echo "S3 location: $S3_URI"
echo ""

# Show configuration summary
DOMAIN_COUNT=$(jq -r '.domains | length' "$CONFIG_FILE")
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "  Domains configured: $DOMAIN_COUNT"
if [ "$DOMAIN_COUNT" -gt 0 ]; then
    echo "  Domains:"
    jq -r '.domains | keys[]' "$CONFIG_FILE" | sed 's/^/    - /'
fi
echo ""

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    echo -e "${RED}❌ AWS CLI is not installed${NC}"
    echo "Please install AWS CLI and configure credentials"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${RED}❌ AWS credentials not configured or invalid${NC}"
    echo "Please run 'aws configure' to set up credentials"
    exit 1
fi

# Create a backup of current S3 config (if exists)
echo -e "${YELLOW}Checking for existing configuration...${NC}"
BACKUP_FILE="${CONFIG_DIR}/s3-backup-$(date +%Y%m%d-%H%M%S).json"

if aws s3 ls "$S3_URI" >/dev/null 2>&1; then
    echo -e "${YELLOW}Backing up existing S3 configuration...${NC}"
    aws s3 cp "$S3_URI" "$BACKUP_FILE"
    echo -e "${GREEN}Backup saved to: $BACKUP_FILE${NC}"
else
    echo "No existing configuration found in S3"
fi

# Upload new configuration
echo -e "${YELLOW}Uploading new configuration...${NC}"
if aws s3 cp "$CONFIG_FILE" "$S3_URI" --content-type "application/json"; then
    echo -e "${GREEN}✅ Configuration uploaded successfully!${NC}"
else
    echo -e "${RED}❌ Failed to upload configuration${NC}"
    exit 1
fi

# Verify upload
echo -e "${YELLOW}Verifying upload...${NC}"
if aws s3 ls "$S3_URI" >/dev/null 2>&1; then
    REMOTE_SIZE=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --query 'ContentLength' --output text)
    LOCAL_SIZE=$(wc -c < "$CONFIG_FILE" | tr -d ' ')
    
    if [ "$REMOTE_SIZE" -eq "$LOCAL_SIZE" ]; then
        echo -e "${GREEN}✅ Upload verified (size: $LOCAL_SIZE bytes)${NC}"
    else
        echo -e "${YELLOW}⚠️  Size mismatch: local=$LOCAL_SIZE, remote=$REMOTE_SIZE${NC}"
    fi
else
    echo -e "${RED}❌ Could not verify upload${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 Configuration deployment complete!${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. The Lambda function will automatically pick up the new configuration within 5 minutes"
echo "2. Test the configuration by sending emails to your configured patterns"
echo "3. Monitor CloudWatch logs for processing details"
echo ""
echo -e "${YELLOW}Configured email patterns:${NC}"
jq -r '.domains | to_entries[] | "  \(.key):" as $domain | .value.patterns[] | "    - \(.)"' "$CONFIG_FILE"

# Show CloudWatch logs command
if [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
    LAMBDA_FUNCTION=$(terraform -chdir="$TERRAFORM_DIR" output -raw lambda_function_name 2>/dev/null || echo "")
    if [ -n "$LAMBDA_FUNCTION" ] && [ "$LAMBDA_FUNCTION" != "null" ]; then
        echo ""
        echo -e "${BLUE}Monitor Lambda logs:${NC}"
        echo "  aws logs tail /aws/lambda/$LAMBDA_FUNCTION --follow"
    fi
fi