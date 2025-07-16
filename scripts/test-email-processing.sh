#!/bin/bash

# Script to test email processing through SES + Lambda + Webhook
# This script sends a test email and validates that it's processed correctly

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
FROM_EMAIL="jdcadavid96@gmail.com"
TO_EMAIL="webhook@mail.gestioncitas.services"
AWS_PROFILE="personal"
LAMBDA_FUNCTION="prod-email-to-http-processor"
LOG_GROUP="/aws/lambda/prod-email-to-http-processor"
TIMEOUT=300  # 5 minutes timeout
CHECK_INTERVAL=5  # Check every 5 seconds

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
    echo "Test email processing through AWS SES + Lambda + Webhook"
    echo ""
    echo "Options:"
    echo "  --from EMAIL          Source email address (default: $FROM_EMAIL)"
    echo "  --to EMAIL            Destination email address (default: $TO_EMAIL)"
    echo "  --profile PROFILE     AWS profile to use (default: $AWS_PROFILE)"
    echo "  --function NAME       Lambda function name (default: $LAMBDA_FUNCTION)"
    echo "  --timeout SECONDS     Timeout for waiting (default: $TIMEOUT)"
    echo "  --webhook-url URL     Test webhook receiver URL (optional)"
    echo "  --webhook-port PORT   Start local webhook receiver on port (optional)"
    echo "  --webhook-secret SEC  Webhook secret for signature validation (optional)"
    echo "  --no-logs             Don't monitor Lambda logs"
    echo "  --dry-run             Show what would be sent without actually sending"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Basic test"
    echo "  $0 --webhook-port 8080                # Test with local webhook receiver"
    echo "  $0 --webhook-port 8080 --webhook-secret mysecret  # With signature validation"
    echo "  $0 --dry-run                          # Preview without sending"
    echo "  $0 --from test@example.com --to webhook@yourdomain.com  # Custom addresses"
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI first."
        exit 1
    fi
    
    # Check AWS profile
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "AWS profile '$AWS_PROFILE' not configured or invalid."
        exit 1
    fi
    
    # Check if Lambda function exists
    if ! aws lambda get-function --function-name "$LAMBDA_FUNCTION" --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "Lambda function '$LAMBDA_FUNCTION' not found."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to start local webhook receiver
start_webhook_receiver() {
    local port=$1
    local secret=$2
    
    print_info "Starting local webhook receiver on port $port..."
    
    # Check if port is available
    if lsof -Pi :$port -sTCP:LISTEN -t &> /dev/null; then
        print_error "Port $port is already in use"
        exit 1
    fi
    
    # Start webhook receiver in background
    local webhook_cmd="python3 $PROJECT_ROOT/testing/test-webhook-receiver.py --port $port"
    if [ -n "$secret" ]; then
        webhook_cmd="$webhook_cmd --secret $secret --debug"
    fi
    
    eval "$webhook_cmd" > /tmp/webhook-receiver.log 2>&1 &
    local webhook_pid=$!
    
    # Wait for webhook receiver to start
    sleep 2
    
    if ! kill -0 $webhook_pid 2>/dev/null; then
        print_error "Failed to start webhook receiver"
        cat /tmp/webhook-receiver.log
        exit 1
    fi
    
    print_success "Webhook receiver started (PID: $webhook_pid)"
    echo $webhook_pid
}

# Function to stop webhook receiver
stop_webhook_receiver() {
    local pid=$1
    if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
        print_info "Stopping webhook receiver (PID: $pid)..."
        kill $pid
        wait $pid 2>/dev/null || true
        print_success "Webhook receiver stopped"
    fi
}

# Function to send test email
send_test_email() {
    local from_email=$1
    local to_email=$2
    local dry_run=$3
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local test_id=$(date +%s%N | cut -b1-13)  # Unix timestamp in milliseconds
    
    local subject="Test SES Processing - $test_id"
    local body="Email de prueba enviado el $timestamp

Test ID: $test_id
From: $from_email
To: $to_email
Purpose: Validation of SES + Lambda + Webhook processing

This is an automated test email to validate the email processing pipeline.
Please ignore if received in error."

    if [ "$dry_run" = "true" ]; then
        print_info "DRY RUN - Would send email with:"
        echo "  From: $from_email"
        echo "  To: $to_email"
        echo "  Subject: $subject"
        echo "  Body: $body"
        return 0
    fi
    
    print_info "Sending test email..."
    print_info "  From: $from_email"
    print_info "  To: $to_email"
    print_info "  Test ID: $test_id"
    
    local message_id
    message_id=$(aws ses send-email \
        --from "$from_email" \
        --to "$to_email" \
        --subject "$subject" \
        --text "$body" \
        --profile "$AWS_PROFILE" \
        --query 'MessageId' \
        --output text 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$message_id" ]; then
        print_success "Email sent successfully (Message ID: $message_id)"
        echo "$test_id"
    else
        print_error "Failed to send email"
        exit 1
    fi
}

# Function to monitor Lambda logs
monitor_lambda_logs() {
    local test_id=$1
    local timeout=$2
    local no_logs=$3
    
    if [ "$no_logs" = "true" ]; then
        print_info "Log monitoring disabled"
        return 0
    fi
    
    print_info "Monitoring Lambda logs for test ID: $test_id"
    print_info "Timeout: ${timeout}s"
    
    local start_time=$(date +%s)
    local found_processing=false
    local found_success=false
    local found_error=false
    
    # Get recent logs to establish baseline
    local since_time=$((start_time * 1000 - 60000))  # 1 minute before
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            print_warning "Timeout reached (${timeout}s) - stopping log monitoring"
            break
        fi
        
        # Get recent logs
        local logs=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --start-time $since_time \
            --profile "$AWS_PROFILE" \
            --query 'events[].message' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$logs" ]; then
            # Check for test ID in logs
            if echo "$logs" | grep -q "$test_id" && [ "$found_processing" = "false" ]; then
                print_success "Found email processing in Lambda logs"
                found_processing=true
            fi
            
            # Check for success indicators
            if echo "$logs" | grep -q -E "(successfully sent webhook|webhook sent successfully|completed successfully)" && [ "$found_success" = "false" ]; then
                print_success "Email processing completed successfully"
                found_success=true
                break
            fi
            
            # Check for error indicators
            if echo "$logs" | grep -q -E "(ERROR|FAIL|Exception|Error)" && [ "$found_error" = "false" ]; then
                print_error "Found errors in Lambda logs:"
                echo "$logs" | grep -E "(ERROR|FAIL|Exception|Error)" | head -5
                found_error=true
                break
            fi
        fi
        
        # Update progress
        local dots=$((elapsed / CHECK_INTERVAL % 4))
        local progress_indicator=$(printf "%*s" $dots | tr ' ' '.')
        printf "\r  Waiting for processing$progress_indicator   "
        
        sleep $CHECK_INTERVAL
        since_time=$((current_time * 1000))
    done
    
    echo  # New line after progress indicator
    
    if [ "$found_success" = "true" ]; then
        return 0
    elif [ "$found_error" = "true" ]; then
        return 1
    else
        print_warning "No clear success/error indication found in logs"
        return 2
    fi
}

# Function to check webhook receiver logs
check_webhook_logs() {
    local test_id=$1
    
    if [ ! -f "/tmp/webhook-receiver.log" ]; then
        print_warning "No webhook receiver logs found"
        return 1
    fi
    
    print_info "Checking webhook receiver logs..."
    
    # Check if webhook received the request
    if grep -q "$test_id" /tmp/webhook-receiver.log; then
        print_success "Webhook receiver got the request with test ID: $test_id"
        
        # Show relevant webhook logs
        print_info "Webhook receiver logs:"
        grep -A 5 -B 5 "$test_id" /tmp/webhook-receiver.log | tail -20
        return 0
    else
        print_warning "Test ID not found in webhook receiver logs"
        print_info "Recent webhook receiver logs:"
        tail -20 /tmp/webhook-receiver.log
        return 1
    fi
}

# Function to generate test report
generate_report() {
    local test_id=$1
    local email_sent=$2
    local logs_status=$3
    local webhook_status=$4
    local webhook_url=$5
    
    echo ""
    print_info "=== TEST REPORT ==="
    echo "Test ID: $test_id"
    echo "Timestamp: $(date)"
    echo ""
    
    echo "✉️  Email Sending:"
    if [ "$email_sent" = "true" ]; then
        echo "   ✅ Email sent successfully via SES"
    else
        echo "   ❌ Email sending failed"
    fi
    
    echo ""
    echo "🔍 Lambda Processing:"
    case $logs_status in
        0) echo "   ✅ Lambda processed email successfully" ;;
        1) echo "   ❌ Lambda processing failed with errors" ;;
        2) echo "   ⚠️  Lambda processing status unclear" ;;
        *) echo "   ❓ Lambda processing not checked" ;;
    esac
    
    if [ -n "$webhook_url" ]; then
        echo ""
        echo "🎯 Webhook Delivery:"
        case $webhook_status in
            0) echo "   ✅ Webhook received and processed successfully" ;;
            1) echo "   ❌ Webhook not received or processing failed" ;;
            *) echo "   ❓ Webhook status not checked" ;;
        esac
    fi
    
    echo ""
    echo "📋 Next Steps:"
    if [ "$email_sent" = "true" ] && [ "$logs_status" = "0" ]; then
        echo "   • Email processing pipeline is working correctly"
        echo "   • You can now send real emails to webhook@mail.gestioncitas.services"
    else
        echo "   • Check AWS SES settings and domain verification"
        echo "   • Review Lambda function logs for detailed error information"
        echo "   • Verify webhook endpoint is accessible and responding correctly"
    fi
}

# Main function
main() {
    local from_email="$FROM_EMAIL"
    local to_email="$TO_EMAIL"
    local aws_profile="$AWS_PROFILE"
    local lambda_function="$LAMBDA_FUNCTION"
    local timeout="$TIMEOUT"
    local webhook_url=""
    local webhook_port=""
    local webhook_secret=""
    local no_logs=false
    local dry_run=false
    local webhook_pid=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --from)
                from_email="$2"
                shift 2
                ;;
            --to)
                to_email="$2"
                shift 2
                ;;
            --profile)
                aws_profile="$2"
                shift 2
                ;;
            --function)
                lambda_function="$2"
                shift 2
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --webhook-url)
                webhook_url="$2"
                shift 2
                ;;
            --webhook-port)
                webhook_port="$2"
                shift 2
                ;;
            --webhook-secret)
                webhook_secret="$2"
                shift 2
                ;;
            --no-logs)
                no_logs=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
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
    
    # Set up webhook URL if port specified
    if [ -n "$webhook_port" ]; then
        webhook_url="http://localhost:$webhook_port/webhook"
    fi
    
    # Trap to ensure cleanup
    trap 'stop_webhook_receiver "$webhook_pid"' EXIT
    
    print_info "Starting Email Processing Test"
    print_info "=============================="
    
    # Check prerequisites
    if [ "$dry_run" != "true" ]; then
        check_prerequisites
    fi
    
    # Start webhook receiver if requested
    if [ -n "$webhook_port" ] && [ "$dry_run" != "true" ]; then
        webhook_pid=$(start_webhook_receiver "$webhook_port" "$webhook_secret")
        print_info "Webhook receiver URL: $webhook_url"
    fi
    
    # Send test email
    local test_id
    test_id=$(send_test_email "$from_email" "$to_email" "$dry_run")
    
    if [ "$dry_run" = "true" ]; then
        print_info "Dry run completed"
        exit 0
    fi
    
    # Monitor processing
    local logs_status=99
    local webhook_status=99
    
    if [ -n "$test_id" ]; then
        monitor_lambda_logs "$test_id" "$timeout" "$no_logs"
        logs_status=$?
        
        if [ -n "$webhook_port" ]; then
            sleep 2  # Give webhook receiver time to process
            check_webhook_logs "$test_id"
            webhook_status=$?
        fi
    fi
    
    # Generate report
    local email_sent="true"
    if [ -z "$test_id" ]; then
        email_sent="false"
    fi
    
    generate_report "$test_id" "$email_sent" "$logs_status" "$webhook_status" "$webhook_url"
    
    # Exit with appropriate code
    if [ "$email_sent" = "true" ] && [ "$logs_status" = "0" ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function with all arguments
main "$@"