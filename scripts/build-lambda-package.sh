#!/bin/bash

# Script to build Lambda deployment package with correct structure
# This script ensures dependencies are in the root and validates the package

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LAMBDA_DIR="$PROJECT_ROOT/lambda/python"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_info() {
    print_status "$BLUE" "ℹ️  $1"
}

print_success() {
    print_status "$GREEN" "✅ $1"
}

print_warning() {
    print_status "$YELLOW" "⚠️  $1"
}

print_error() {
    print_status "$RED" "❌ $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Build Lambda deployment package with correct dependency structure"
    echo ""
    echo "Options:"
    echo "  --clean               Clean build directory before building"
    echo "  --no-install          Skip dependency installation (use existing build)"
    echo "  --validate-only       Only validate existing package without rebuilding"
    echo "  --output-path PATH    Custom output path for ZIP file"
    echo "  --requirements PATH   Custom requirements.txt path"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Standard build"
    echo "  $0 --clean            # Clean build from scratch"
    echo "  $0 --validate-only    # Just validate existing package"
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        print_error "Python3 not found. Please install Python3 first."
        exit 1
    fi
    
    # Check pip
    if ! command -v pip3 &> /dev/null; then
        print_error "pip3 not found. Please install pip3 first."
        exit 1
    fi
    
    # Check zip
    if ! command -v zip &> /dev/null; then
        print_error "zip not found. Please install zip utility first."
        exit 1
    fi
    
    # Check lambda directory exists
    if [ ! -d "$LAMBDA_DIR" ]; then
        print_error "Lambda directory not found: $LAMBDA_DIR"
        exit 1
    fi
    
    # Check requirements.txt exists
    if [ ! -f "$LAMBDA_DIR/requirements.txt" ]; then
        print_error "requirements.txt not found: $LAMBDA_DIR/requirements.txt"
        exit 1
    fi
    
    # Check lambda_function.py exists
    if [ ! -f "$LAMBDA_DIR/lambda_function.py" ]; then
        print_error "lambda_function.py not found: $LAMBDA_DIR/lambda_function.py"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to clean build directory
clean_build() {
    print_info "Cleaning build directory..."
    cd "$LAMBDA_DIR"
    
    if [ -d "build" ]; then
        rm -rf build
        print_success "Removed existing build directory"
    fi
    
    if [ -d "package" ]; then
        rm -rf package
        print_success "Removed existing package directory"
    fi
}

# Function to install dependencies
install_dependencies() {
    local requirements_file=$1
    
    print_info "Installing Python dependencies..."
    cd "$LAMBDA_DIR"
    
    # Create build directory
    mkdir -p build
    
    # Install dependencies directly to build directory (root level)
    print_info "Running: pip3 install -r $requirements_file -t build/ --no-cache-dir"
    pip3 install -r "$requirements_file" -t build/ --no-cache-dir
    
    if [ $? -eq 0 ]; then
        print_success "Dependencies installed successfully"
    else
        print_error "Failed to install dependencies"
        exit 1
    fi
}

# Function to copy lambda function
copy_lambda_function() {
    print_info "Copying Lambda function..."
    cd "$LAMBDA_DIR"
    
    cp lambda_function.py build/
    
    if [ $? -eq 0 ]; then
        print_success "Lambda function copied successfully"
    else
        print_error "Failed to copy Lambda function"
        exit 1
    fi
}

# Function to validate package structure
validate_package() {
    local build_dir="$LAMBDA_DIR/build"
    
    print_info "Validating package structure..."
    
    if [ ! -d "$build_dir" ]; then
        print_error "Build directory not found: $build_dir"
        return 1
    fi
    
    cd "$build_dir"
    
    # Check for required files/directories
    local required_items=("lambda_function.py" "httpx" "boto3" "botocore")
    local missing_items=()
    
    for item in "${required_items[@]}"; do
        if [ -e "$item" ]; then
            print_success "Found: $item"
        else
            print_error "Missing: $item"
            missing_items+=("$item")
        fi
    done
    
    # Check httpx specifically
    if [ -d "httpx" ]; then
        if [ -f "httpx/__init__.py" ]; then
            print_success "httpx module structure is valid"
        else
            print_error "httpx/__init__.py missing"
            missing_items+=("httpx/__init__.py")
        fi
    fi
    
    # Test imports locally
    print_info "Testing Python imports..."
    if command -v python3 &> /dev/null; then
        local import_test=$(python3 -c "
import sys
import os
sys.path.insert(0, os.getcwd())

try:
    import httpx
    print('✅ httpx import successful')
    print(f'   httpx version: {httpx.__version__}')
except ImportError as e:
    print(f'❌ httpx import failed: {e}')
    sys.exit(1)

try:
    import boto3
    print('✅ boto3 import successful')
except ImportError as e:
    print(f'❌ boto3 import failed: {e}')
    sys.exit(1)

try:
    import lambda_function
    print('✅ lambda_function import successful')
except ImportError as e:
    print(f'❌ lambda_function import failed: {e}')
    sys.exit(1)
" 2>&1)
        
        echo "$import_test"
        
        if echo "$import_test" | grep -q "❌"; then
            missing_items+=("import_test_failed")
        fi
    else
        print_warning "Python3 not available for import testing"
    fi
    
    # Check package size
    local package_size=$(du -sh . | cut -f1)
    print_info "Package size: $package_size"
    
    if [ ${#missing_items[@]} -eq 0 ]; then
        print_success "Package structure validation passed"
        return 0
    else
        print_error "Package validation failed. Missing items: ${missing_items[*]}"
        return 1
    fi
}

# Function to create ZIP package
create_zip_package() {
    local output_path=$1
    local build_dir="$LAMBDA_DIR/build"
    
    print_info "Creating ZIP package..."
    
    if [ ! -d "$build_dir" ]; then
        print_error "Build directory not found: $build_dir"
        exit 1
    fi
    
    cd "$build_dir"
    
    # Remove existing ZIP if it exists
    if [ -f "$output_path" ]; then
        rm -f "$output_path"
        print_info "Removed existing ZIP file"
    fi
    
    # Create ZIP with correct structure (all files in root)
    print_info "Creating ZIP from build directory..."
    zip -r "$output_path" . -x "*.pyc" "__pycache__/*" "*.DS_Store"
    
    if [ $? -eq 0 ]; then
        print_success "ZIP package created: $output_path"
        
        # Show ZIP contents summary
        local zip_size=$(du -sh "$output_path" | cut -f1)
        local file_count=$(unzip -l "$output_path" | tail -1 | awk '{print $2}')
        print_info "ZIP size: $zip_size"
        print_info "File count: $file_count"
        
        return 0
    else
        print_error "Failed to create ZIP package"
        exit 1
    fi
}

# Function to validate ZIP package
validate_zip_package() {
    local zip_path=$1
    
    print_info "Validating ZIP package structure..."
    
    if [ ! -f "$zip_path" ]; then
        print_error "ZIP file not found: $zip_path"
        return 1
    fi
    
    # Check ZIP integrity
    if ! unzip -t "$zip_path" &> /dev/null; then
        print_error "ZIP file is corrupted"
        return 1
    fi
    
    # Check for required files in ZIP
    local required_in_zip=("lambda_function.py" "httpx/" "boto3/")
    local missing_in_zip=()
    
    for item in "${required_in_zip[@]}"; do
        if unzip -l "$zip_path" | grep -q "$item"; then
            print_success "Found in ZIP: $item"
        else
            print_error "Missing in ZIP: $item"
            missing_in_zip+=("$item")
        fi
    done
    
    # Verify httpx is in root (not in package/ subdirectory)
    if unzip -l "$zip_path" | grep -q "package/httpx/"; then
        print_error "httpx found in package/ subdirectory - this will cause import errors"
        missing_in_zip+=("httpx_wrong_location")
    fi
    
    if [ ${#missing_in_zip[@]} -eq 0 ]; then
        print_success "ZIP package validation passed"
        return 0
    else
        print_error "ZIP validation failed. Issues: ${missing_in_zip[*]}"
        return 1
    fi
}

# Function to generate build report
generate_report() {
    local zip_path=$1
    local validation_passed=$2
    
    echo ""
    print_info "=== BUILD REPORT ==="
    echo "Timestamp: $(date)"
    echo "Lambda directory: $LAMBDA_DIR"
    echo "Output ZIP: $zip_path"
    echo ""
    
    if [ -f "$zip_path" ]; then
        local zip_size=$(du -sh "$zip_path" | cut -f1)
        local file_count=$(unzip -l "$zip_path" | tail -1 | awk '{print $2}')
        echo "📦 Package Info:"
        echo "   Size: $zip_size"
        echo "   Files: $file_count"
        echo ""
    fi
    
    if [ "$validation_passed" = "true" ]; then
        echo "✅ Build Status: SUCCESS"
        echo "   • All dependencies installed correctly"
        echo "   • Package structure is valid"
        echo "   • ZIP package created successfully"
        echo "   • Ready for deployment"
    else
        echo "❌ Build Status: FAILED"
        echo "   • Check error messages above for details"
        echo "   • Fix issues before deployment"
    fi
    
    echo ""
    echo "📋 Next Steps:"
    echo "   • Deploy with: terraform apply"
    echo "   • Test with: ./scripts/test-email-processing.sh"
}

# Main function
main() {
    local clean_build=false
    local no_install=false
    local validate_only=false
    local output_path="$TERRAFORM_DIR/lambda_function.zip"
    local requirements_file="requirements.txt"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                clean_build=true
                shift
                ;;
            --no-install)
                no_install=true
                shift
                ;;
            --validate-only)
                validate_only=true
                shift
                ;;
            --output-path)
                output_path="$2"
                shift 2
                ;;
            --requirements)
                requirements_file="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    print_info "Building Lambda Deployment Package"
    print_info "================================="
    
    # Check prerequisites
    check_prerequisites
    
    # Validate only mode
    if [ "$validate_only" = "true" ]; then
        print_info "Validation-only mode"
        if validate_package && validate_zip_package "$output_path"; then
            generate_report "$output_path" "true"
            exit 0
        else
            generate_report "$output_path" "false"
            exit 1
        fi
    fi
    
    # Clean build if requested
    if [ "$clean_build" = "true" ]; then
        clean_build
    fi
    
    # Install dependencies unless skipped
    if [ "$no_install" != "true" ]; then
        install_dependencies "$requirements_file"
    fi
    
    # Copy lambda function
    copy_lambda_function
    
    # Validate package structure
    if ! validate_package; then
        generate_report "$output_path" "false"
        exit 1
    fi
    
    # Create ZIP package
    if ! create_zip_package "$output_path"; then
        generate_report "$output_path" "false"
        exit 1
    fi
    
    # Validate ZIP package
    if ! validate_zip_package "$output_path"; then
        generate_report "$output_path" "false"
        exit 1
    fi
    
    # Generate success report
    generate_report "$output_path" "true"
    
    print_success "Lambda package build completed successfully!"
}

# Run main function with all arguments
main "$@"