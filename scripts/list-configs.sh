#!/bin/bash

# List Domain Configurations Script
# Usage: ./list-configs.sh [DOMAIN]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DOMAIN="$1"

# Configuration file paths
CONFIG_DIR="$(dirname "$0")/../config"
CONFIG_FILE="${CONFIG_DIR}/domains.json"

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

echo -e "${BLUE}📧 Email-to-Webhook Configuration${NC}"
echo "=================================="

# Display global settings
echo -e "${YELLOW}Global Settings:${NC}"
jq -r '.global_settings | to_entries[] | "  \(.key): \(.value)"' "$CONFIG_FILE"
echo ""

# Display last updated
LAST_UPDATED=$(jq -r '.last_updated' "$CONFIG_FILE")
echo -e "${YELLOW}Last Updated:${NC} $LAST_UPDATED"
echo ""

if [ -n "$DOMAIN" ]; then
    # Show specific domain configuration
    if jq -e ".domains.\"$DOMAIN\"" "$CONFIG_FILE" > /dev/null; then
        echo -e "${GREEN}Domain: $DOMAIN${NC}"
        echo "$(printf '%.0s-' {1..50})"
        
        WEBHOOK_URL=$(jq -r ".domains.\"$DOMAIN\".webhook_url" "$CONFIG_FILE")
        PAYLOAD_FORMAT=$(jq -r ".domains.\"$DOMAIN\".payload_format // \"standard\"" "$CONFIG_FILE")
        
        echo -e "${YELLOW}Webhook URL:${NC} $WEBHOOK_URL"
        echo -e "${YELLOW}Payload Format:${NC} $PAYLOAD_FORMAT"
        echo -e "${YELLOW}Webhook Secret:${NC} $(jq -r ".domains.\"$DOMAIN\".webhook_secret" "$CONFIG_FILE" | sed 's/./*/g')"
        
        echo ""
        echo -e "${YELLOW}Email Patterns:${NC}"
        jq -r ".domains.\"$DOMAIN\".patterns[]" "$CONFIG_FILE" | sed 's/^/  ✉️  /'
        
        echo ""
        echo -e "${YELLOW}Filters:${NC}"
        jq -r ".domains.\"$DOMAIN\".filters | to_entries[] | \"  \(.key): \(.value)\"" "$CONFIG_FILE"
        
        echo ""
        echo -e "${YELLOW}Retry Configuration:${NC}"
        jq -r ".domains.\"$DOMAIN\".retry_config // {} | to_entries[] | \"  \(.key): \(.value)\"" "$CONFIG_FILE"
        
        # Show custom headers if any
        CUSTOM_HEADERS=$(jq -r ".domains.\"$DOMAIN\".custom_headers // {} | length" "$CONFIG_FILE")
        if [ "$CUSTOM_HEADERS" -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Custom Headers:${NC}"
            jq -r ".domains.\"$DOMAIN\".custom_headers | to_entries[] | \"  \(.key): \(.value)\"" "$CONFIG_FILE"
        fi
        
    else
        echo -e "${RED}❌ Domain '$DOMAIN' not found in configuration${NC}"
        echo ""
        echo "Available domains:"
        jq -r '.domains | keys[]' "$CONFIG_FILE" | sed 's/^/  - /'
        exit 1
    fi
else
    # Show all domains summary
    DOMAIN_COUNT=$(jq -r '.domains | length' "$CONFIG_FILE")
    echo -e "${GREEN}Configured Domains: $DOMAIN_COUNT${NC}"
    
    if [ "$DOMAIN_COUNT" -eq 0 ]; then
        echo "No domains configured yet."
        echo ""
        echo "Add a domain using: ./add-domain-config.sh DOMAIN WEBHOOK_URL WEBHOOK_SECRET"
    else
        echo ""
        
        # List each domain with basic info
        jq -r '.domains | keys[]' "$CONFIG_FILE" | while read -r domain; do
            webhook_url=$(jq -r ".domains.\"$domain\".webhook_url" "$CONFIG_FILE")
            pattern_count=$(jq -r ".domains.\"$domain\".patterns | length" "$CONFIG_FILE")
            
            echo -e "${GREEN}📧 $domain${NC}"
            echo "   Webhook: $webhook_url"
            echo "   Patterns: $pattern_count configured"
            
            # Show first few patterns
            if [ "$pattern_count" -gt 0 ]; then
                echo "   Examples:"
                jq -r ".domains.\"$domain\".patterns | .[0:3][]" "$CONFIG_FILE" | sed 's/^/     - /'
                if [ "$pattern_count" -gt 3 ]; then
                    echo "     ... and $((pattern_count - 3)) more"
                fi
            fi
            echo ""
        done
        
        echo "Use './list-configs.sh DOMAIN' to see detailed configuration for a specific domain."
    fi
fi

echo ""
echo -e "${BLUE}Management Commands:${NC}"
echo "  Add domain:     ./add-domain-config.sh DOMAIN WEBHOOK_URL SECRET"
echo "  Add pattern:    ./add-email-pattern.sh DOMAIN PATTERN" 
echo "  Upload to S3:   ./upload-config.sh"
echo "  Validate:       ./validate-config.sh"