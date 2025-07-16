#!/usr/bin/env python3
"""
Simple webhook receiver for testing the AWS SES + Lambda email-to-HTTP bridge
Run this script to receive and verify webhook payloads from your Lambda function
"""

import json
import hmac
import hashlib
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import argparse
import datetime

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        """Handle incoming webhook POST requests"""
        try:
            # Get content length
            content_length = int(self.headers.get('Content-Length', 0))
            
            # Read the request body
            post_data = self.rfile.read(content_length)
            
            # Parse JSON payload
            try:
                payload = json.loads(post_data.decode('utf-8'))
            except json.JSONDecodeError as e:
                self.send_error(400, f"Invalid JSON: {str(e)}")
                return
            
            # Verify webhook signature if secret is provided
            webhook_secret = os.environ.get('WEBHOOK_SECRET')
            if webhook_secret:
                signature_header = self.headers.get('X-Webhook-Signature', '')
                if not self.verify_signature(post_data, signature_header, webhook_secret):
                    self.send_error(401, "Invalid signature")
                    return
                print("✅ Signature verification passed")
            
            # Process the webhook payload
            self.process_email_webhook(payload)
            
            # Send success response
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            response = {'status': 'success', 'message': 'Email processed'}
            self.wfile.write(json.dumps(response).encode('utf-8'))
            
        except Exception as e:
            print(f"❌ Error processing webhook: {str(e)}")
            self.send_error(500, str(e))
    
    def verify_signature(self, payload: bytes, signature_header: str, secret: str) -> bool:
        """Verify webhook signature"""
        if not signature_header.startswith('sha256='):
            return False
        
        received_signature = signature_header[7:]  # Remove 'sha256=' prefix
        
        # Calculate expected signature
        expected_signature = hmac.new(
            secret.encode('utf-8'),
            payload,
            hashlib.sha256
        ).hexdigest()
        
        return hmac.compare_digest(received_signature, expected_signature)
    
    def process_email_webhook(self, payload: dict):
        """Process and display the email webhook payload"""
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        print(f"\n{'='*80}")
        print(f"🔔 EMAIL WEBHOOK RECEIVED at {timestamp}")
        print(f"{'='*80}")
        
        # Basic email info
        print(f"📧 Message ID: {payload.get('message_id', 'N/A')}")
        print(f"📅 Timestamp: {payload.get('timestamp', 'N/A')}")
        print(f"👤 From: {payload.get('source', 'N/A')}")
        print(f"📨 To: {', '.join(payload.get('destination', []))}")
        print(f"📋 Subject: {payload.get('subject', 'N/A')}")
        
        # Email content
        email_data = payload.get('email', {})
        if email_data:
            print(f"\n📄 EMAIL CONTENT:")
            print(f"{'─'*40}")
            
            text_content = email_data.get('text_content', '').strip()
            html_content = email_data.get('html_content', '').strip()
            attachments = email_data.get('attachments', [])
            
            if text_content:
                print(f"📝 Text Content ({len(text_content)} chars):")
                print(f"   {text_content[:200]}{'...' if len(text_content) > 200 else ''}")
            
            if html_content:
                print(f"🌐 HTML Content ({len(html_content)} chars):")
                print(f"   {html_content[:200]}{'...' if len(html_content) > 200 else ''}")
            
            if attachments:
                print(f"📎 Attachments ({len(attachments)}):")
                for i, attachment in enumerate(attachments, 1):
                    print(f"   {i}. {attachment.get('filename', 'unnamed')} "
                          f"({attachment.get('content_type', 'unknown')} - "
                          f"{attachment.get('size', 0)} bytes)")
        
        # Headers
        headers = payload.get('headers', {})
        if headers:
            print(f"\n📋 HEADERS:")
            print(f"{'─'*40}")
            for key, value in headers.items():
                if key.lower() in ['date', 'return-path', 'message-id', 'content-type']:
                    print(f"   {key}: {value}")
        
        # Raw payload (for debugging)
        if os.environ.get('DEBUG', '').lower() == 'true':
            print(f"\n🔍 RAW PAYLOAD:")
            print(f"{'─'*40}")
            print(json.dumps(payload, indent=2))
        
        print(f"{'='*80}\n")
    
    def log_message(self, format, *args):
        """Override to customize log format"""
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{timestamp}] {format % args}")

def main():
    parser = argparse.ArgumentParser(
        description="Test webhook receiver for AWS SES + Lambda email bridge"
    )
    parser.add_argument(
        '--port', 
        type=int, 
        default=8080,
        help='Port to listen on (default: 8080)'
    )
    parser.add_argument(
        '--host', 
        default='localhost',
        help='Host to bind to (default: localhost)'
    )
    parser.add_argument(
        '--secret',
        help='Webhook secret for signature verification'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug mode (shows full payload)'
    )
    
    args = parser.parse_args()
    
    # Set environment variables
    if args.secret:
        os.environ['WEBHOOK_SECRET'] = args.secret
    if args.debug:
        os.environ['DEBUG'] = 'true'
    
    # Start the server
    server_address = (args.host, args.port)
    httpd = HTTPServer(server_address, WebhookHandler)
    
    print(f"🚀 Starting webhook receiver...")
    print(f"🌐 Listening on http://{args.host}:{args.port}")
    print(f"🔑 Signature verification: {'enabled' if args.secret else 'disabled'}")
    print(f"🔍 Debug mode: {'enabled' if args.debug else 'disabled'}")
    print(f"⏹️  Press Ctrl+C to stop\n")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n👋 Shutting down webhook receiver...")
        httpd.shutdown()

if __name__ == '__main__':
    main() 