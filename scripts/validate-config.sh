#!/bin/bash

# Validate Configuration Script
# Usage: ./validate-config.sh [CONFIG_FILE]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths
CONFIG_DIR="$(dirname "$0")/../config"
DEFAULT_CONFIG_FILE="${CONFIG_DIR}/domains.json"
SCHEMA_FILE="${CONFIG_DIR}/domains-schema.json"

CONFIG_FILE="${1:-$DEFAULT_CONFIG_FILE}"

echo -e "${BLUE}🔍 Configuration Validation${NC}"
echo "=================================="
echo "Config file: $CONFIG_FILE"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq is not installed. Please install jq to use this script.${NC}"
    echo "On macOS: brew install jq"
    echo "On Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

ERRORS=0
WARNINGS=0

# Function to report error
report_error() {
    echo -e "${RED}❌ ERROR: $1${NC}"
    ((ERRORS++))
}

# Function to report warning
report_warning() {
    echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
    ((WARNINGS++))
}

# Function to report success
report_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

echo -e "${YELLOW}Running validation checks...${NC}"
echo ""

# 1. JSON Syntax Validation
echo -n "Checking JSON syntax... "
if jq empty "$CONFIG_FILE" 2>/dev/null; then
    report_success "Valid JSON"
else
    report_error "Invalid JSON syntax"
fi

# 2. Schema Validation (if schema file exists)
if [ -f "$SCHEMA_FILE" ]; then
    echo -n "Validating against schema... "
    if command -v ajv >/dev/null 2>&1; then
        if ajv validate -s "$SCHEMA_FILE" -d "$CONFIG_FILE" >/dev/null 2>&1; then
            report_success "Schema validation passed"
        else
            report_error "Schema validation failed"
            echo "  Run: ajv validate -s $SCHEMA_FILE -d $CONFIG_FILE"
        fi
    else
        report_warning "ajv-cli not installed, skipping schema validation"
        echo "  Install with: npm install -g ajv-cli"
    fi
else
    report_warning "Schema file not found: $SCHEMA_FILE"
fi

# 3. Required Fields Validation
echo -n "Checking required fields... "
REQUIRED_FIELDS_OK=true

if ! jq -e '.version' "$CONFIG_FILE" >/dev/null; then
    report_error "Missing required field: version"
    REQUIRED_FIELDS_OK=false
fi

if ! jq -e '.domains' "$CONFIG_FILE" >/dev/null; then
    report_error "Missing required field: domains"
    REQUIRED_FIELDS_OK=false
fi

if [ "$REQUIRED_FIELDS_OK" = true ]; then
    report_success "All required fields present"
fi

# 4. Domain Configuration Validation
echo -n "Validating domain configurations... "
DOMAIN_COUNT=$(jq -r '.domains | length' "$CONFIG_FILE")

if [ "$DOMAIN_COUNT" -eq 0 ]; then
    report_warning "No domains configured"
else
    DOMAIN_ERRORS=0
    
    # Check each domain
    jq -r '.domains | keys[]' "$CONFIG_FILE" | while read -r domain; do
        # Check required domain fields
        if ! jq -e ".domains.\"$domain\".webhook_url" "$CONFIG_FILE" >/dev/null; then
            echo -e "${RED}❌ Domain '$domain': Missing webhook_url${NC}"
            ((DOMAIN_ERRORS++))
        fi
        
        if ! jq -e ".domains.\"$domain\".patterns" "$CONFIG_FILE" >/dev/null; then
            echo -e "${RED}❌ Domain '$domain': Missing patterns${NC}"
            ((DOMAIN_ERRORS++))
        fi
        
        # Validate webhook URL format
        WEBHOOK_URL=$(jq -r ".domains.\"$domain\".webhook_url // \"\"" "$CONFIG_FILE")
        if [ -n "$WEBHOOK_URL" ] && [[ ! "$WEBHOOK_URL" =~ ^https?:// ]]; then
            echo -e "${YELLOW}⚠️  Domain '$domain': Webhook URL should start with http:// or https://${NC}"
        fi
        
        # Check pattern count
        PATTERN_COUNT=$(jq -r ".domains.\"$domain\".patterns | length // 0" "$CONFIG_FILE")
        if [ "$PATTERN_COUNT" -eq 0 ]; then
            echo -e "${YELLOW}⚠️  Domain '$domain': No email patterns configured${NC}"
        fi
    done
    
    if [ "$DOMAIN_ERRORS" -eq 0 ]; then
        report_success "Domain configurations valid ($DOMAIN_COUNT domains)"
    fi
fi

# 5. Email Pattern Validation
echo -n "Validating email patterns... "
PATTERN_ERRORS=0

jq -r '.domains | to_entries[] | "\(.key):\(.value.patterns[])"' "$CONFIG_FILE" | while IFS=: read -r domain pattern; do
    # Check for basic email pattern format
    if [[ ! "$pattern" =~ @.+\..+ ]]; then
        echo -e "${YELLOW}⚠️  Domain '$domain': Pattern '$pattern' may not be a valid email pattern${NC}"
    fi
    
    # Check for potentially problematic patterns
    if [[ "$pattern" == "*@*" ]]; then
        echo -e "${YELLOW}⚠️  Domain '$domain': Pattern '$pattern' will match ALL emails${NC}"
    fi
done

report_success "Email pattern format check completed"

# 6. Webhook URL Accessibility (optional check)
echo -n "Testing webhook connectivity... "
if command -v curl >/dev/null 2>&1; then
    WEBHOOK_ERRORS=0
    
    jq -r '.domains | to_entries[] | "\(.key):\(.value.webhook_url)"' "$CONFIG_FILE" | while IFS=: read -r domain webhook_url; do
        # Skip if webhook_url is empty
        if [ -z "$webhook_url" ] || [ "$webhook_url" = "null" ]; then
            continue
        fi
        
        # Test connectivity (timeout after 5 seconds)
        if curl -s --max-time 5 --head "$webhook_url" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Domain '$domain': Webhook accessible${NC}"
        else
            echo -e "${YELLOW}⚠️  Domain '$domain': Webhook not accessible (may be normal for local/internal URLs)${NC}"
        fi
    done
    
    report_success "Webhook connectivity check completed"
else
    report_warning "curl not available, skipping webhook connectivity check"
fi

# 7. Size and Limits Check
echo -n "Checking configuration size and limits... "
CONFIG_SIZE=$(wc -c < "$CONFIG_FILE" | tr -d ' ')
MAX_SIZE=$((1024 * 1024))  # 1MB limit

if [ "$CONFIG_SIZE" -gt "$MAX_SIZE" ]; then
    report_warning "Configuration file is large (${CONFIG_SIZE} bytes). Consider optimizing."
else
    report_success "Configuration size OK (${CONFIG_SIZE} bytes)"
fi

# Summary
echo ""
echo -e "${BLUE}Validation Summary${NC}"
echo "==================="

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}🎉 Configuration is valid and ready to use!${NC}"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "${YELLOW}✅ Configuration is valid with $WARNINGS warning(s)${NC}"
    echo "You can proceed, but consider addressing the warnings."
    exit 0
else
    echo -e "${RED}❌ Configuration has $ERRORS error(s) and $WARNINGS warning(s)${NC}"
    echo "Please fix the errors before deploying."
    exit 1
fi