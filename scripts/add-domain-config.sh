#!/bin/bash

# Add Domain Configuration Script
# Usage: ./add-domain-config.sh DOMAIN WEBHOOK_URL WEBHOOK_SECRET [PATTERNS...]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if required arguments are provided
if [ $# -lt 3 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 DOMAIN WEBHOOK_URL WEBHOOK_SECRET [PATTERNS...]"
    echo ""
    echo "Examples:"
    echo "  $0 example.com https://api.example.com/webhook secret123"
    echo "  $0 company.org https://company.org/api/email secret456 'contact@company.org' 'support@company.org'"
    exit 1
fi

DOMAIN="$1"
WEBHOOK_URL="$2"
WEBHOOK_SECRET="$3"
shift 3

# Default patterns if none provided
if [ $# -eq 0 ]; then
    PATTERNS=("*@${DOMAIN}" "webhook@${DOMAIN}")
else
    PATTERNS=("$@")
fi

# Configuration file paths
CONFIG_DIR="$(dirname "$0")/../config"
CONFIG_FILE="${CONFIG_DIR}/domains.json"
BACKUP_FILE="${CONFIG_DIR}/domains.json.backup"

echo -e "${YELLOW}Adding domain configuration...${NC}"
echo "Domain: $DOMAIN"
echo "Webhook URL: $WEBHOOK_URL"
echo "Patterns: ${PATTERNS[*]}"

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Create default config if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}Creating new configuration file...${NC}"
    cat > "$CONFIG_FILE" << EOF
{
  "version": "1.0",
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "domains": {},
  "global_settings": {
    "default_max_retries": 3,
    "default_timeout_seconds": 30,
    "default_max_size_mb": 10,
    "enable_detailed_logging": true,
    "s3_backup_enabled": true,
    "s3_backup_retention_days": 30
  }
}
EOF
fi

# Create backup
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"

# Build patterns array for JSON
PATTERNS_JSON="["
for i in "${PATTERNS[@]}"; do
    PATTERNS_JSON+='"'$i'",'
done
PATTERNS_JSON="${PATTERNS_JSON%,}]"  # Remove trailing comma

# Use jq to add the domain configuration
if command -v jq >/dev/null 2>&1; then
    # Using jq for safe JSON manipulation
    jq --arg domain "$DOMAIN" \
       --arg webhook_url "$WEBHOOK_URL" \
       --arg webhook_secret "$WEBHOOK_SECRET" \
       --argjson patterns "$PATTERNS_JSON" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '.last_updated = $timestamp | 
        .domains[$domain] = {
          "webhook_url": $webhook_url,
          "webhook_secret": $webhook_secret,
          "patterns": $patterns,
          "filters": {
            "max_size_mb": 10,
            "allowed_senders": ["*"],
            "blocked_senders": [],
            "blocked_domains": [],
            "require_dkim": false,
            "require_spf": false
          },
          "payload_format": "standard",
          "custom_headers": {},
          "retry_config": {
            "max_retries": 3,
            "timeout_seconds": 30
          }
        }' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✅ Domain configuration added successfully!${NC}"
    
    # Validate JSON
    if jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${GREEN}✅ Configuration file is valid JSON${NC}"
    else
        echo -e "${RED}❌ Configuration file has invalid JSON. Restoring backup...${NC}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        exit 1
    fi
    
else
    echo -e "${RED}❌ jq is not installed. Please install jq to use this script.${NC}"
    echo "On macOS: brew install jq"
    echo "On Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

# Display current configuration
echo -e "${YELLOW}Current domains in configuration:${NC}"
jq -r '.domains | keys[]' "$CONFIG_FILE" | sed 's/^/  - /'

echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "1. Upload configuration to S3:"
echo "   aws s3 cp $CONFIG_FILE s3://YOUR-CONFIG-BUCKET/config/domains.json"
echo ""
echo "2. Add DNS records for domain verification:"
echo "   Check Terraform output for verification tokens"
echo ""
echo "3. Test the configuration by sending an email to one of the patterns:"
for pattern in "${PATTERNS[@]}"; do
    echo "   - $pattern"
done