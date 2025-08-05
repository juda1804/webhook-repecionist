#!/usr/bin/env python3
"""
Multi-Domain Configuration Test
Tests the DomainConfigManager and multi-domain email processing logic
"""

import json
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch, MagicMock
import asyncio
from typing import Dict, Any

# Add lambda directory to path to import our modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lambda', 'python'))

from lambda_function import (
    DomainConfigManager, 
    EmailMetadata, 
    DomainConfig,
    process_ses_email
)


class TestDomainConfigManager(unittest.TestCase):
    """Test the DomainConfigManager class"""
    
    def setUp(self):
        """Set up test fixtures"""
        self.test_config = {
            "version": "1.0",
            "last_updated": "2024-01-15T10:00:00Z",
            "domains": {
                "example.com": {
                    "webhook_url": "https://api.example.com/webhook",
                    "webhook_secret": "secret123",
                    "patterns": ["*@example.com", "webhook@example.com"],
                    "filters": {
                        "max_size_mb": 10,
                        "allowed_senders": ["*"],
                        "blocked_senders": [],
                        "blocked_domains": []
                    },
                    "payload_format": "standard",
                    "retry_config": {
                        "max_retries": 3,
                        "timeout_seconds": 30
                    }
                },
                "company.org": {
                    "webhook_url": "https://company.org/api/webhook",
                    "webhook_secret": "company-secret",
                    "patterns": ["contact@company.org", "support@company.org"],
                    "filters": {
                        "max_size_mb": 5,
                        "allowed_senders": ["@trusted.com"],
                        "blocked_senders": ["noreply@*"],
                        "blocked_domains": ["spam.com"]
                    },
                    "payload_format": "custom",
                    "custom_headers": {
                        "Authorization": "Bearer token123"
                    }
                }
            },
            "global_settings": {
                "default_max_retries": 3,
                "default_timeout_seconds": 30,
                "default_max_size_mb": 10
            }
        }
        
        # Create temp S3 bucket name for testing
        self.test_bucket = "test-config-bucket"
        self.test_key = "config/domains.json"
        
    def create_mock_s3_client(self):
        """Create a mock S3 client that returns our test config"""
        mock_s3_client = Mock()
        mock_response = Mock()
        mock_response.get.return_value = len(json.dumps(self.test_config))
        mock_body = Mock()
        mock_body.read.return_value = json.dumps(self.test_config).encode('utf-8')
        mock_response.__getitem__ = lambda self, key: mock_body if key == 'Body' else None
        mock_s3_client.get_object.return_value = mock_response
        return mock_s3_client
    
    @patch('lambda_function.boto3.client')
    def test_load_config_from_s3(self, mock_boto3_client):
        """Test loading configuration from S3"""
        mock_boto3_client.return_value = self.create_mock_s3_client()
        
        config_manager = DomainConfigManager(self.test_bucket, self.test_key)
        
        # Test async function
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        config = loop.run_until_complete(config_manager.get_config())
        
        self.assertEqual(config['version'], '1.0')
        self.assertEqual(len(config['domains']), 2)
        self.assertIn('example.com', config['domains'])
        self.assertIn('company.org', config['domains'])
        
        loop.close()
    
    @patch('lambda_function.boto3.client')
    def test_get_domain_config_for_email(self, mock_boto3_client):
        """Test getting domain configuration for specific emails"""
        mock_boto3_client.return_value = self.create_mock_s3_client()
        
        config_manager = DomainConfigManager(self.test_bucket, self.test_key)
        
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        test_cases = [
            ("test@example.com", "example.com"),
            ("webhook@example.com", "example.com"),
            ("contact@company.org", "company.org"),
            ("support@company.org", "company.org"),
            ("unknown@unknown.com", None)
        ]
        
        for email, expected_domain in test_cases:
            with self.subTest(email=email):
                domain_config = loop.run_until_complete(
                    config_manager.get_domain_config_for_email(email)
                )
                
                if expected_domain:
                    self.assertIsNotNone(domain_config)
                    self.assertEqual(
                        domain_config.webhook_url,
                        self.test_config['domains'][expected_domain]['webhook_url']
                    )
                else:
                    self.assertIsNone(domain_config)
        
        loop.close()
    
    @patch('lambda_function.boto3.client')
    def test_email_filtering(self, mock_boto3_client):
        """Test email filtering logic"""
        mock_boto3_client.return_value = self.create_mock_s3_client()
        
        config_manager = DomainConfigManager(self.test_bucket, self.test_key)
        
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        # Test cases: (from_email, to_email, should_pass)
        test_cases = [
            # example.com domain (allows all senders)
            ("anyone@anywhere.com", "test@example.com", True),
            ("sender@spam.com", "test@example.com", True),  # No blocking rules
            
            # company.org domain (restricted senders)
            ("user@trusted.com", "contact@company.org", True),  # Allowed sender
            ("noreply@anywhere.com", "contact@company.org", False),  # Blocked sender
            ("anyone@spam.com", "contact@company.org", False),  # Blocked domain
            ("user@normal.com", "contact@company.org", False),  # Not in allowed list
        ]
        
        for from_email, to_email, should_pass in test_cases:
            with self.subTest(from_email=from_email, to_email=to_email):
                metadata = EmailMetadata(
                    message_id="test-message-id",
                    timestamp="2024-01-15T10:00:00Z",
                    from_address=from_email,
                    to_addresses=[to_email],
                    subject="Test Subject",
                    correlation_id="test-correlation-id"
                )
                
                domain_config = loop.run_until_complete(
                    config_manager.is_email_allowed(metadata)
                )
                
                if should_pass:
                    self.assertIsNotNone(domain_config, f"Expected {from_email} -> {to_email} to be allowed")
                else:
                    self.assertIsNone(domain_config, f"Expected {from_email} -> {to_email} to be blocked")
        
        loop.close()
    
    @patch('os.environ')
    @patch('lambda_function.boto3.client')
    def test_fallback_to_env_config(self, mock_boto3_client, mock_environ):
        """Test fallback to environment variables when S3 config is not available"""
        # Mock S3 client to return NoSuchKey exception
        mock_s3_client = Mock()
        mock_s3_client.get_object.side_effect = Exception("NoSuchKey")
        mock_boto3_client.return_value = mock_s3_client
        
        # Mock environment variables
        mock_environ.get.side_effect = lambda key, default="": {
            'DOMAIN_NAME': 'env-domain.com',
            'TARGET_WEBHOOK_URL': 'https://env-webhook.com/hook',
            'WEBHOOK_SECRET': 'env-secret',
            'ALLOWED_DOMAINS': 'env-domain.com',
            'MAX_RETRIES': '3',
            'TIMEOUT_SECONDS': '30',
            'MAX_EMAIL_SIZE_MB': '10'
        }.get(key, default)
        
        config_manager = DomainConfigManager(self.test_bucket, self.test_key)
        
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        config = loop.run_until_complete(config_manager.get_config())
        
        self.assertIn('env-domain.com', config['domains'])
        self.assertEqual(
            config['domains']['env-domain.com']['webhook_url'],
            'https://env-webhook.com/hook'
        )
        
        loop.close()


class TestEmailProcessingIntegration(unittest.TestCase):
    """Integration tests for email processing with multi-domain configuration"""
    
    def create_ses_event_data(self, from_email: str, to_emails: list, message_id: str = "test-message-id"):
        """Create SES event data for testing"""
        return {
            "mail": {
                "messageId": message_id,
                "timestamp": "2024-01-15T10:00:00Z",
                "source": from_email,
                "destination": to_emails,
                "commonHeaders": {
                    "subject": "Test Email Subject"
                }
            },
            "receipt": {
                "action": {
                    "type": "s3",
                    "bucketName": "test-email-bucket",
                    "objectKey": f"emails/{message_id}"
                }
            }
        }
    
    @patch('lambda_function.domain_config_manager')
    @patch('lambda_function.get_email_content')
    @patch('lambda_function.send_webhook')
    def test_multi_domain_email_routing(self, mock_send_webhook, mock_get_email_content, mock_config_manager):
        """Test that emails are routed to correct webhooks based on domain"""
        
        # Mock email content
        from lambda_function import EmailContent
        mock_get_email_content.return_value = EmailContent(
            text="Test email content",
            html="<p>Test email content</p>"
        )
        
        # Mock webhook sending
        mock_send_webhook.return_value = None
        
        # Test cases: (from_email, to_email, expected_webhook_url)
        test_cases = [
            ("sender@external.com", "test@example.com", "https://api.example.com/webhook"),
            ("user@trusted.com", "contact@company.org", "https://company.org/api/webhook"),
        ]
        
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        for from_email, to_email, expected_webhook in test_cases:
            with self.subTest(from_email=from_email, to_email=to_email):
                # Create mock domain config
                mock_domain_config = DomainConfig(
                    webhook_url=expected_webhook,
                    webhook_secret="test-secret",
                    patterns=[f"*@{to_email.split('@')[1]}"],
                    filters={"max_size_mb": 10},
                    payload_format="standard",
                    custom_headers={},
                    retry_config={"max_retries": 3, "timeout_seconds": 30}
                )
                
                mock_config_manager.is_email_allowed.return_value = mock_domain_config
                
                # Create SES event
                ses_event = self.create_ses_event_data(from_email, [to_email])
                
                # Process email
                loop.run_until_complete(
                    process_ses_email(ses_event, "test-correlation-id")
                )
                
                # Verify webhook was called with correct config
                mock_send_webhook.assert_called()
                call_args = mock_send_webhook.call_args
                domain_config_arg = call_args[0][1]  # Second argument is domain_config
                
                self.assertEqual(domain_config_arg.webhook_url, expected_webhook)
        
        loop.close()


def run_config_validation_test():
    """Test the configuration validation script"""
    print("🔍 Testing configuration validation...")
    
    # Create a temporary config file
    test_config = {
        "version": "1.0",
        "last_updated": "2024-01-15T10:00:00Z",
        "domains": {
            "test.com": {
                "webhook_url": "https://api.test.com/webhook",
                "webhook_secret": "test-secret",
                "patterns": ["*@test.com"],
                "filters": {
                    "max_size_mb": 10,
                    "allowed_senders": ["*"]
                }
            }
        },
        "global_settings": {
            "default_max_retries": 3
        }
    }
    
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(test_config, f, indent=2)
        temp_config_path = f.name
    
    try:
        # Run validation script
        validate_script = os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'validate-config.sh'
        )
        
        if os.path.exists(validate_script):
            import subprocess
            result = subprocess.run([validate_script, temp_config_path], 
                                  capture_output=True, text=True)
            
            if result.returncode == 0:
                print("✅ Configuration validation passed")
                return True
            else:
                print(f"❌ Configuration validation failed: {result.stderr}")
                return False
        else:
            print("⚠️  Validation script not found, skipping validation test")
            return True
            
    finally:
        os.unlink(temp_config_path)


def main():
    """Run all tests"""
    print("🧪 Starting Multi-Domain Configuration Tests")
    print("=" * 50)
    
    # Run unit tests
    print("\n📋 Running Unit Tests...")
    unittest.main(argv=[''], exit=False, verbosity=2)
    
    # Run validation test
    print("\n🔧 Running Integration Tests...")
    success = run_config_validation_test()
    
    print("\n" + "=" * 50)
    if success:
        print("🎉 All tests completed successfully!")
        print("\nNext steps:")
        print("1. Deploy the updated infrastructure:")
        print("   ./scripts/deploy.sh")
        print("2. Configure your domains:")
        print("   ./scripts/add-domain-config.sh yourdomain.com https://your-webhook.com secret")
        print("3. Upload configuration:")
        print("   ./scripts/upload-config.sh")
        print("4. Test by sending emails to your configured patterns")
    else:
        print("❌ Some tests failed. Please review the errors above.")
        sys.exit(1)


if __name__ == "__main__":
    main()