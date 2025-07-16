#!/bin/bash

# Script to validate Lambda function dependencies
# This script checks if all required dependencies are included in the Lambda deployment package

set -e

echo "🔍 Validating Lambda Function Dependencies..."

# Get the current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Function to check if AWS CLI is available
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo "❌ AWS CLI not found. Please install AWS CLI first."
        exit 1
    fi
}

# Function to get Lambda function info
get_lambda_info() {
    local function_name="$1"
    echo "📋 Getting Lambda function information for: $function_name"
    
    aws lambda get-function \
        --function-name "$function_name" \
        --query 'Code.Location' \
        --output text \
        --profile personal 2>/dev/null || {
        echo "❌ Failed to get Lambda function info. Check function name and AWS credentials."
        exit 1
    }
}

# Function to download and inspect Lambda package
inspect_lambda_package() {
    local download_url="$1"
    local temp_dir="/tmp/lambda-inspection-$$"
    
    echo "📦 Downloading Lambda package for inspection..."
    mkdir -p "$temp_dir"
    
    # Download the Lambda package
    curl -s "$download_url" -o "$temp_dir/lambda_function.zip" || {
        echo "❌ Failed to download Lambda package"
        rm -rf "$temp_dir"
        exit 1
    }
    
    # Extract the package
    cd "$temp_dir"
    unzip -q lambda_function.zip || {
        echo "❌ Failed to extract Lambda package"
        rm -rf "$temp_dir"
        exit 1
    }
    
    echo "🔍 Inspecting Lambda package contents..."
    
    # Check for required dependencies
    local required_deps=("httpx" "boto3" "botocore" "lambda_function.py")
    local missing_deps=()
    
    for dep in "${required_deps[@]}"; do
        if [ -e "$dep" ] || [ -d "$dep" ]; then
            echo "✅ Found: $dep"
            
            # If it's httpx, show version info
            if [ "$dep" = "httpx" ] && [ -d "httpx" ]; then
                if [ -d "httpx-"*".dist-info" ]; then
                    local version_dir=$(ls -d httpx-*.dist-info 2>/dev/null | head -1)
                    if [ -f "$version_dir/METADATA" ]; then
                        local version=$(grep "^Version:" "$version_dir/METADATA" | cut -d' ' -f2)
                        echo "   📌 httpx version: $version"
                    fi
                fi
                
                # Check if httpx can be imported
                if [ -f "httpx/__init__.py" ]; then
                    echo "   📌 httpx module structure looks valid"
                else
                    echo "   ⚠️  httpx directory exists but __init__.py missing"
                fi
            fi
        else
            echo "❌ Missing: $dep"
            missing_deps+=("$dep")
        fi
    done
    
    # Show package size
    local package_size=$(du -sh . | cut -f1)
    echo "📏 Package size: $package_size"
    
    # List all top-level contents
    echo "📁 Top-level contents:"
    ls -la | head -20
    
    # Check if there are any Python import issues
    echo "🐍 Testing Python imports..."
    if command -v python3 &> /dev/null; then
        # Create a simple test script
        cat > test_imports.py << 'EOF'
import sys
import os
sys.path.insert(0, os.getcwd())

try:
    import httpx
    print("✅ httpx import successful")
    print(f"   httpx version: {httpx.__version__}")
except ImportError as e:
    print(f"❌ httpx import failed: {e}")

try:
    import boto3
    print("✅ boto3 import successful")
except ImportError as e:
    print(f"❌ boto3 import failed: {e}")

try:
    import lambda_function
    print("✅ lambda_function import successful")
except ImportError as e:
    print(f"❌ lambda_function import failed: {e}")
EOF
        
        python3 test_imports.py
    else
        echo "⚠️  Python3 not available for import testing"
    fi
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        echo "✅ All required dependencies are present in the Lambda package!"
        return 0
    else
        echo "❌ Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
}

# Function to validate local package
validate_local_package() {
    local lambda_dir="$PROJECT_ROOT/lambda/python"
    local package_dir="$lambda_dir/package"
    
    echo "🔍 Validating local Lambda package..."
    
    if [ ! -d "$package_dir" ]; then
        echo "❌ Local package directory not found: $package_dir"
        return 1
    fi
    
    cd "$package_dir"
    
    echo "📁 Local package contents:"
    ls -la | head -10
    
    # Check for httpx specifically
    if [ -d "httpx" ]; then
        echo "✅ httpx directory found in local package"
        if [ -f "httpx/__init__.py" ]; then
            echo "✅ httpx/__init__.py found"
        else
            echo "❌ httpx/__init__.py missing"
        fi
    else
        echo "❌ httpx directory not found in local package"
    fi
    
    # Check requirements
    if [ -f "$lambda_dir/requirements.txt" ]; then
        echo "📋 Requirements from requirements.txt:"
        cat "$lambda_dir/requirements.txt"
    fi
    
    cd - > /dev/null
}

# Function to rebuild Lambda package
rebuild_package() {
    echo "🔄 Rebuilding Lambda package with proper dependencies..."
    
    local lambda_dir="$PROJECT_ROOT/lambda/python"
    cd "$lambda_dir"
    
    # Clean up
    echo "🧹 Cleaning up existing package..."
    rm -rf package
    rm -f ../../terraform/lambda_function.zip
    
    # Create package directory
    mkdir package
    
    # Install dependencies with more verbose output
    echo "📦 Installing dependencies..."
    pip3 install -r requirements.txt -t package/ --no-cache-dir --verbose
    
    # Verify httpx installation
    if [ -d "package/httpx" ]; then
        echo "✅ httpx successfully installed"
    else
        echo "❌ httpx installation failed"
        echo "📋 Trying alternative installation method..."
        pip3 install httpx==0.27.0 -t package/ --no-cache-dir --force-reinstall
    fi
    
    # Copy lambda function
    cp lambda_function.py package/
    
    # Create zip with verbose output
    echo "📦 Creating ZIP package..."
    cd package
    zip -r ../../../terraform/lambda_function.zip . -x "*.pyc" "__pycache__/*"
    
    echo "✅ Package rebuilt successfully"
    cd - > /dev/null
}

# Main execution
main() {
    local function_name="${1:-prod-email-to-http-processor}"
    local action="${2:-check}"
    
    check_aws_cli
    
    case "$action" in
        "check")
            echo "🎯 Checking deployed Lambda function: $function_name"
            local download_url=$(get_lambda_info "$function_name")
            inspect_lambda_package "$download_url"
            ;;
        "local")
            echo "🎯 Checking local Lambda package"
            validate_local_package
            ;;
        "rebuild")
            echo "🎯 Rebuilding Lambda package"
            rebuild_package
            validate_local_package
            ;;
        "full")
            echo "🎯 Full validation: local + deployed"
            validate_local_package
            echo ""
            echo "---"
            echo ""
            local download_url=$(get_lambda_info "$function_name")
            inspect_lambda_package "$download_url"
            ;;
        *)
            echo "Usage: $0 [function-name] [check|local|rebuild|full]"
            echo ""
            echo "Actions:"
            echo "  check   - Check deployed Lambda function (default)"
            echo "  local   - Check local package directory"
            echo "  rebuild - Rebuild local package"
            echo "  full    - Check both local and deployed"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Check deployed function"
            echo "  $0 my-function check                 # Check specific function"
            echo "  $0 prod-email-to-http-processor local # Check local package"
            echo "  $0 prod-email-to-http-processor full  # Full validation"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"