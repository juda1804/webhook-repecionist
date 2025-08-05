#!/bin/bash

# Add Email Pattern to Existing Domain Script
# Usage: ./add-email-pattern.sh DOMAIN PATTERN

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if required arguments are provided
if [ $# -ne 2 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 DOMAIN PATTERN"
    echo ""
    echo "Examples:"
    echo "  $0 example.com 'billing@example.com'"
    echo "  $0 company.org 'support-*@company.org'"
    exit 1
fi

DOMAIN="$1"
PATTERN="$2"

# Configuration file paths
CONFIG_DIR="$(dirname "$0")/../config"
CONFIG_FILE="${CONFIG_DIR}/domains.json"
BACKUP_FILE="${CONFIG_DIR}/domains.json.backup"

echo -e "${YELLOW}Adding email pattern to domain...${NC}"
echo "Domain: $DOMAIN"
echo "Pattern: $PATTERN"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    echo "Please create a domain configuration first using add-domain-config.sh"
    exit 1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq is not installed. Please install jq to use this script.${NC}"
    echo "On macOS: brew install jq"
    echo "On Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

# Check if domain exists in configuration
if ! jq -e ".domains.\"$DOMAIN\"" "$CONFIG_FILE" > /dev/null; then
    echo -e "${RED}❌ Domain '$DOMAIN' not found in configuration${NC}"
    echo "Available domains:"
    jq -r '.domains | keys[]' "$CONFIG_FILE" | sed 's/^/  - /'
    echo ""
    echo "Add the domain first using: ./add-domain-config.sh $DOMAIN WEBHOOK_URL WEBHOOK_SECRET"
    exit 1
fi

# Check if pattern already exists
if jq -e ".domains.\"$DOMAIN\".patterns | map(select(. == \"$PATTERN\")) | length > 0" "$CONFIG_FILE" > /dev/null; then
    echo -e "${YELLOW}⚠️  Pattern '$PATTERN' already exists for domain '$DOMAIN'${NC}"
    exit 0
fi

# Create backup
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"

# Add pattern to domain configuration
jq --arg domain "$DOMAIN" \
   --arg pattern "$PATTERN" \
   --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
   '.last_updated = $timestamp | 
    .domains[$domain].patterns += [$pattern]' \
   "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# Validate JSON
if jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${GREEN}✅ Email pattern added successfully!${NC}"
else
    echo -e "${RED}❌ Configuration file has invalid JSON. Restoring backup...${NC}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    exit 1
fi

# Display current patterns for the domain
echo -e "${YELLOW}Current patterns for '$DOMAIN':${NC}"
jq -r ".domains.\"$DOMAIN\".patterns[]" "$CONFIG_FILE" | sed 's/^/  - /'

echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "1. Upload updated configuration to S3:"
echo "   aws s3 cp $CONFIG_FILE s3://YOUR-CONFIG-BUCKET/config/domains.json"
echo ""
echo "2. Test the new pattern by sending an email to:"
echo "   $PATTERN"