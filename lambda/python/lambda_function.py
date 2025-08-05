import asyncio
import json
import logging
import os
import time
import hashlib
import hmac
import fnmatch
from dataclasses import dataclass, asdict
from email import message_from_string
from typing import Dict, Any, List, Optional, Union
from uuid import uuid4
from datetime import datetime, timezone

import boto3
import httpx


# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


@dataclass
class EmailMetadata:
    """Basic email metadata structure"""
    message_id: str
    timestamp: str
    from_address: str
    to_addresses: List[str]
    subject: str
    correlation_id: str


@dataclass
class EmailContent:
    """Email content structure"""
    text: str
    html: str


@dataclass
class DomainConfig:
    """Domain-specific configuration"""
    webhook_url: str
    webhook_secret: str
    patterns: List[str]
    filters: Dict[str, Any]
    payload_format: str = "standard"
    custom_headers: Dict[str, str] = None
    retry_config: Dict[str, Any] = None
    
    def __post_init__(self):
        if self.custom_headers is None:
            self.custom_headers = {}
        if self.retry_config is None:
            self.retry_config = {}


@dataclass
class WebhookPayload:
    """Webhook payload structure"""
    event_type: str
    metadata: EmailMetadata
    content: EmailContent
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class EmailProcessingError(Exception):
    """Custom exception for email processing errors"""
    pass


class WebhookDeliveryError(Exception):
    """Custom exception for webhook delivery errors"""
    pass


class DomainConfigManager:
    """Manages domain configurations with caching and S3 integration"""
    
    def __init__(self, s3_bucket: str, config_key: str = "config/domains.json"):
        self.s3_bucket = s3_bucket
        self.config_key = config_key
        self.s3_client = boto3.client('s3')
        self._config_cache = None
        self._cache_timestamp = None
        self._cache_ttl = 300  # 5 minutes
        self._global_settings = {}
        
    def _is_cache_valid(self) -> bool:
        """Check if cached configuration is still valid"""
        if self._config_cache is None or self._cache_timestamp is None:
            return False
        
        cache_age = time.time() - self._cache_timestamp
        return cache_age < self._cache_ttl
    
    async def _load_config_from_s3(self) -> Dict[str, Any]:
        """Load configuration from S3"""
        try:
            logger.info(f"Loading domain config from S3: s3://{self.s3_bucket}/{self.config_key}")
            
            response = self.s3_client.get_object(Bucket=self.s3_bucket, Key=self.config_key)
            config_content = response['Body'].read().decode('utf-8')
            config_data = json.loads(config_content)
            
            logger.info(f"Loaded configuration for {len(config_data.get('domains', {}))} domains")
            return config_data
            
        except self.s3_client.exceptions.NoSuchKey:
            logger.warning(f"No configuration found at s3://{self.s3_bucket}/{self.config_key}")
            return {"domains": {}, "global_settings": {}}
        except Exception as e:
            logger.error(f"Failed to load config from S3: {str(e)}")
            return {"domains": {}, "global_settings": {}}
    
    async def _load_config_from_env(self) -> Dict[str, Any]:
        """Fallback: Load configuration from environment variables (backward compatibility)"""
        logger.info("Using fallback environment configuration")
        
        domain_name = os.environ.get('DOMAIN_NAME', '')
        webhook_url = os.environ.get('TARGET_WEBHOOK_URL', '')
        webhook_secret = os.environ.get('WEBHOOK_SECRET', '')
        allowed_domains = os.environ.get('ALLOWED_DOMAINS', '')
        
        if not domain_name or not webhook_url:
            return {"domains": {}, "global_settings": {}}
        
        # Create backward-compatible configuration
        domains = {}
        if domain_name:
            domains[domain_name] = {
                "webhook_url": webhook_url,
                "webhook_secret": webhook_secret,
                "patterns": [f"*@{domain_name}"] if domain_name else ["*"],
                "filters": {
                    "max_size_mb": int(os.environ.get('MAX_EMAIL_SIZE_MB', '10')),
                    "allowed_senders": allowed_domains.split(',') if allowed_domains else ["*"],
                    "blocked_senders": [],
                    "blocked_domains": []
                }
            }
        
        return {
            "domains": domains,
            "global_settings": {
                "default_max_retries": int(os.environ.get('MAX_RETRIES', '3')),
                "default_timeout_seconds": int(os.environ.get('TIMEOUT_SECONDS', '30')),
                "default_max_size_mb": int(os.environ.get('MAX_EMAIL_SIZE_MB', '10'))
            }
        }
    
    async def get_config(self) -> Dict[str, Any]:
        """Get configuration, using cache if valid or loading from S3/env"""
        if self._is_cache_valid():
            return self._config_cache
        
        # Try to load from S3 first
        config = await self._load_config_from_s3()
        
        # If S3 config is empty, try environment variables
        if not config.get('domains'):
            config = await self._load_config_from_env()
        
        # Cache the configuration
        self._config_cache = config
        self._cache_timestamp = time.time()
        self._global_settings = config.get('global_settings', {})
        
        return config
    
    async def get_domain_config_for_email(self, email: str) -> Optional[DomainConfig]:
        """Get domain configuration for a specific email address"""
        config = await self.get_config()
        domains = config.get('domains', {})
        
        # Find matching domain configuration
        for domain_name, domain_config in domains.items():
            patterns = domain_config.get('patterns', [])
            
            for pattern in patterns:
                if self._matches_pattern(email.lower(), pattern.lower()):
                    logger.info(f"Email {email} matches pattern {pattern} for domain {domain_name}")
                    
                    # Merge with global settings
                    merged_config = self._merge_with_global_settings(domain_config)
                    
                    return DomainConfig(
                        webhook_url=merged_config['webhook_url'],
                        webhook_secret=merged_config.get('webhook_secret', ''),
                        patterns=merged_config['patterns'],
                        filters=merged_config.get('filters', {}),
                        payload_format=merged_config.get('payload_format', 'standard'),
                        custom_headers=merged_config.get('custom_headers', {}),
                        retry_config=merged_config.get('retry_config', {})
                    )
        
        logger.info(f"No domain configuration found for email: {email}")
        return None
    
    def _matches_pattern(self, email: str, pattern: str) -> bool:
        """Check if email matches a pattern (supports wildcards)"""
        try:
            return fnmatch.fnmatch(email, pattern)
        except Exception as e:
            logger.warning(f"Pattern matching failed for {email} against {pattern}: {str(e)}")
            return False
    
    def _merge_with_global_settings(self, domain_config: Dict[str, Any]) -> Dict[str, Any]:
        """Merge domain config with global settings"""
        merged = domain_config.copy()
        
        # Apply global defaults for retry config
        if 'retry_config' not in merged:
            merged['retry_config'] = {}
        
        retry_config = merged['retry_config']
        if 'max_retries' not in retry_config:
            retry_config['max_retries'] = self._global_settings.get('default_max_retries', 3)
        if 'timeout_seconds' not in retry_config:
            retry_config['timeout_seconds'] = self._global_settings.get('default_timeout_seconds', 30)
        
        # Apply global defaults for filters
        if 'filters' not in merged:
            merged['filters'] = {}
        
        filters = merged['filters']
        if 'max_size_mb' not in filters:
            filters['max_size_mb'] = self._global_settings.get('default_max_size_mb', 10)
        
        return merged
    
    async def is_email_allowed(self, metadata: EmailMetadata) -> Optional[DomainConfig]:
        """Check if email is allowed and return matching domain config"""
        for email_addr in metadata.to_addresses:
            domain_config = await self.get_domain_config_for_email(email_addr)
            if domain_config:
                # Apply filters
                if self._passes_filters(metadata, domain_config):
                    return domain_config
                else:
                    logger.warning(f"Email {email_addr} matches domain but fails filters")
        
        return None
    
    def _passes_filters(self, metadata: EmailMetadata, config: DomainConfig) -> bool:
        """Check if email passes domain-specific filters"""
        filters = config.filters
        
        # Check sender filters
        allowed_senders = filters.get('allowed_senders', ['*'])
        blocked_senders = filters.get('blocked_senders', [])
        blocked_domains = filters.get('blocked_domains', [])
        
        sender = metadata.from_address.lower()
        sender_domain = sender.split('@')[-1] if '@' in sender else ''
        
        # Check blocked senders first
        for blocked_pattern in blocked_senders:
            if self._matches_pattern(sender, blocked_pattern.lower()):
                logger.info(f"Sender {sender} blocked by pattern {blocked_pattern}")
                return False
        
        # Check blocked domains
        if sender_domain in [d.lower() for d in blocked_domains]:
            logger.info(f"Sender domain {sender_domain} is blocked")
            return False
        
        # Check allowed senders (if not wildcard)
        if allowed_senders != ['*']:
            sender_allowed = False
            for allowed_pattern in allowed_senders:
                if self._matches_pattern(sender, allowed_pattern.lower()):
                    sender_allowed = True
                    break
            
            if not sender_allowed:
                logger.info(f"Sender {sender} not in allowed list")
                return False
        
        return True


class Config:
    """Centralized configuration management"""
    
    def __init__(self):
        self.webhook_url = os.environ.get('TARGET_WEBHOOK_URL', '')
        self.webhook_secret = os.environ.get('WEBHOOK_SECRET', '')
        self.s3_bucket = os.environ.get('S3_BUCKET', '')
        self.allowed_domains = self._parse_domains(os.environ.get('ALLOWED_DOMAINS', ''))
        self.max_retries = int(os.environ.get('MAX_RETRIES', '3'))
        self.timeout_seconds = int(os.environ.get('TIMEOUT_SECONDS', '30'))
        self.max_email_size_mb = int(os.environ.get('MAX_EMAIL_SIZE_MB', '10'))
        
        self._validate()
    
    def _parse_domains(self, domains_str: str) -> List[str]:
        """Parse comma-separated domains"""
        if not domains_str:
            return []
        return [domain.strip().lower() for domain in domains_str.split(',') if domain.strip()]
    
    def _validate(self):
        """Validate required configuration"""
        if not self.webhook_url:
            raise ValueError("TARGET_WEBHOOK_URL is required")
        if not self.s3_bucket:
            raise ValueError("S3_BUCKET is required")


# Initialize configuration and AWS client
config = Config()
s3_client = boto3.client('s3')

# Initialize domain configuration manager
domain_config_manager = None


def lambda_handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """
    Main Lambda handler for processing SES emails
    """
    correlation_id = str(uuid4())
    
    # Initialize domain config manager if not already done
    global domain_config_manager
    if domain_config_manager is None:
        # Use config bucket if dynamic config is enabled, otherwise use email bucket
        config_bucket = os.environ.get('CONFIG_S3_BUCKET', config.s3_bucket)
        config_key = os.environ.get('CONFIG_S3_KEY', 'config/domains.json')
        domain_config_manager = DomainConfigManager(config_bucket, config_key)
    
    logger.info(
        "Processing SES event",
        extra={
            "correlation_id": correlation_id,
            "event_records_count": len(event.get('Records', []))
        }
    )
    
    try:
        # Process SES records
        for record in event.get('Records', []):
            if record.get('eventSource') == 'aws:ses':
                asyncio.run(process_ses_email(record['ses'], correlation_id))
        
        logger.info(
            "Email processing completed successfully",
            extra={"correlation_id": correlation_id}
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Email processed successfully',
                'correlation_id': correlation_id
            })
        }
        
    except Exception as e:
        logger.error(
            f"Error processing email: {str(e)}",
            extra={
                "correlation_id": correlation_id,
                "error_type": type(e).__name__
            }
        )
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'correlation_id': correlation_id
            })
        }


async def process_ses_email(ses_data: Dict[str, Any], correlation_id: str) -> None:
    """Process a single SES email record"""
    
    try:
        # Extract metadata
        metadata = extract_email_metadata(ses_data, correlation_id)
        
        logger.info(
            f"Processing email from {metadata.from_address} to {metadata.to_addresses}",
            extra={"correlation_id": correlation_id}
        )
        
        # Get domain configuration for this email
        domain_config = await domain_config_manager.is_email_allowed(metadata)
        if not domain_config:
            logger.warning(
                f"Email not allowed or no matching domain config: from {metadata.from_address} to {metadata.to_addresses}",
                extra={"correlation_id": correlation_id}
            )
            return
        
        logger.info(
            f"Using domain config - webhook: {domain_config.webhook_url}, format: {domain_config.payload_format}",
            extra={"correlation_id": correlation_id}
        )
        
        # Check email size against domain limits
        max_size_mb = domain_config.filters.get('max_size_mb', 10)
        
        # Get email content from S3
        email_content = await get_email_content(ses_data, correlation_id, max_size_mb)
        
        # Create webhook payload
        payload = WebhookPayload(
            event_type="email_received",
            metadata=metadata,
            content=email_content
        )
        
        # Send to webhook with domain-specific configuration
        await send_webhook(payload, domain_config, correlation_id)
        
    except Exception as e:
        logger.error(
            f"Failed to process email: {str(e)}",
            extra={
                "correlation_id": correlation_id,
                "error_type": type(e).__name__
            }
        )
        raise EmailProcessingError(f"Failed to process email: {str(e)}")


def extract_email_metadata(ses_data: Dict[str, Any], correlation_id: str) -> EmailMetadata:
    """Extract basic metadata from SES event"""
    
    mail = ses_data['mail']
    
    return EmailMetadata(
        message_id=mail['messageId'],
        timestamp=mail['timestamp'],
        from_address=mail['source'],
        to_addresses=mail['destination'],
        subject=mail.get('commonHeaders', {}).get('subject', ''),
        correlation_id=correlation_id
    )


# This function is deprecated and replaced by DomainConfigManager.is_email_allowed()
# Kept for backward compatibility but not used
def is_email_allowed(metadata: EmailMetadata) -> bool:
    """Check if email is from/to allowed domains (DEPRECATED)"""
    
    if not config.allowed_domains:
        return True
    
    # Check if any destination domain is allowed
    for email_addr in metadata.to_addresses:
        domain = email_addr.split('@')[-1].lower()
        if domain in config.allowed_domains:
            return True
    
    return False


async def get_email_content(ses_data: Dict[str, Any], correlation_id: str, max_size_mb: int = 10) -> EmailContent:
    """Retrieve and parse email content from S3"""
    
    try:
        # Find S3 action in receipt
        receipt = ses_data['receipt']
        s3_action = None
        
        # SES receipt action can be a dict or list
        action_data = receipt.get('action', {})
        if isinstance(action_data, dict):
            # Single action (most common case)
            if action_data.get('type') == 's3':
                s3_action = action_data
        elif isinstance(action_data, list):
            # Multiple actions
            for action in action_data:
                if action.get('type') == 's3':
                    s3_action = action
                    break
        
        # If no S3 action found in receipt, construct from environment and message ID
        if not s3_action:
            logger.info(
                "No S3 action found in receipt, constructing from environment",
                extra={"correlation_id": correlation_id}
            )
            
            # Get S3 bucket from environment
            bucket = os.environ.get('S3_BUCKET')
            if not bucket:
                logger.error(
                    "S3_BUCKET environment variable not set",
                    extra={"correlation_id": correlation_id}
                )
                return EmailContent(text="", html="")
            
            # Construct S3 key from message ID
            message_id = ses_data['mail']['messageId']
            key = f"emails/{message_id}"
            
            logger.info(
                f"Constructed S3 path: s3://{bucket}/{key}",
                extra={"correlation_id": correlation_id}
            )
        else:
            # Retrieve email from S3 action
            bucket = s3_action['bucketName']
            key = s3_action['objectKey']
        
        logger.info(
            f"Retrieving email from S3: s3://{bucket}/{key}",
            extra={"correlation_id": correlation_id}
        )
        
        response = s3_client.get_object(Bucket=bucket, Key=key)
        
        # Check file size using domain-specific limit
        content_length = response.get('ContentLength', 0)
        max_size_bytes = max_size_mb * 1024 * 1024
        
        if content_length > max_size_bytes:
            logger.warning(
                f"Email size {content_length} bytes exceeds domain limit {max_size_bytes} bytes ({max_size_mb}MB)",
                extra={"correlation_id": correlation_id}
            )
            return EmailContent(text="Email too large to process", html="")
        
        # Parse email content
        raw_email = response['Body'].read().decode('utf-8', errors='ignore')
        return parse_email_content(raw_email, correlation_id)
        
    except Exception as e:
        logger.error(
            f"Failed to get email content: {str(e)}",
            extra={
                "correlation_id": correlation_id,
                "error_type": type(e).__name__
            }
        )
        return EmailContent(text="", html="")


def parse_email_content(raw_email: str, correlation_id: str) -> EmailContent:
    """Parse email content to extract text and HTML body"""
    
    try:
        msg = message_from_string(raw_email)
        text_content = ""
        html_content = ""
        
        if msg.is_multipart():
            # Handle multipart messages
            for part in msg.walk():
                content_type = part.get_content_type()
                content_disposition = part.get('Content-Disposition', '')
                
                # Skip attachments
                if 'attachment' in content_disposition:
                    continue
                
                payload = part.get_payload(decode=True)
                if not payload:
                    continue
                
                content = payload.decode('utf-8', errors='ignore')
                
                if content_type == 'text/plain':
                    text_content = content
                elif content_type == 'text/html':
                    html_content = content
        else:
            # Handle single part messages
            content_type = msg.get_content_type()
            payload = msg.get_payload(decode=True)
            
            if payload:
                content = payload.decode('utf-8', errors='ignore')
                if content_type == 'text/html':
                    html_content = content
                else:
                    text_content = content
        
        logger.info(
            f"Parsed email content: text={len(text_content)} chars, html={len(html_content)} chars",
            extra={"correlation_id": correlation_id}
        )
        
        return EmailContent(text=text_content, html=html_content)
        
    except Exception as e:
        logger.error(
            f"Failed to parse email content: {str(e)}",
            extra={
                "correlation_id": correlation_id,
                "error_type": type(e).__name__
            }
        )
        return EmailContent(text="", html="")


async def send_webhook(payload: WebhookPayload, domain_config: DomainConfig, correlation_id: str) -> None:
    """Send payload to webhook endpoint with retry logic using domain-specific configuration"""
    
    payload_dict = payload.to_dict()
    payload_json = json.dumps(payload_dict, sort_keys=True)
    
    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'AWS-SES-Lambda-Bridge/2.0',
        'X-Correlation-ID': correlation_id
    }
    
    # Add custom headers from domain configuration
    headers.update(domain_config.custom_headers)
    
    # Add HMAC signature if secret is configured
    if domain_config.webhook_secret:
        signature = hmac.new(
            domain_config.webhook_secret.encode('utf-8'),
            payload_json.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()
        headers['X-Webhook-Signature'] = f'sha256={signature}'
    
    # Get retry configuration
    max_retries = domain_config.retry_config.get('max_retries', 3)
    timeout_seconds = domain_config.retry_config.get('timeout_seconds', 30)
    
    # Retry logic with exponential backoff
    for attempt in range(max_retries):
        try:
            logger.info(
                f"Sending webhook (attempt {attempt + 1}/{max_retries})",
                extra={
                    "correlation_id": correlation_id,
                    "webhook_url": domain_config.webhook_url,
                    "payload_format": domain_config.payload_format,
                    "attempt": attempt + 1
                }
            )
            
            async with httpx.AsyncClient(timeout=timeout_seconds) as client:
                response = await client.post(
                    domain_config.webhook_url,
                    content=payload_json,
                    headers=headers
                )
            
            if response.status_code in [200, 201, 202]:
                logger.info(
                    f"Webhook delivered successfully with status {response.status_code}",
                    extra={
                        "correlation_id": correlation_id,
                        "status_code": response.status_code,
                        "response_size": len(response.content),
                        "webhook_url": domain_config.webhook_url
                    }
                )
                return
            else:
                logger.warning(
                    f"Webhook returned status {response.status_code}",
                    extra={
                        "correlation_id": correlation_id,
                        "status_code": response.status_code,
                        "response_text": response.text[:200],
                        "webhook_url": domain_config.webhook_url
                    }
                )
                
        except httpx.TimeoutException as e:
            logger.error(
                f"Webhook attempt {attempt + 1} timed out after {timeout_seconds}s: {str(e)}",
                extra={"correlation_id": correlation_id, "attempt": attempt + 1}
            )
        except httpx.RequestError as e:
            logger.error(
                f"Webhook attempt {attempt + 1} failed: {str(e)}",
                extra={"correlation_id": correlation_id, "attempt": attempt + 1}
            )
        except Exception as e:
            logger.error(
                f"Unexpected error on attempt {attempt + 1}: {str(e)}",
                extra={
                    "correlation_id": correlation_id,
                    "attempt": attempt + 1,
                    "error_type": type(e).__name__
                }
            )
        
        # Wait before retry (exponential backoff with jitter)
        if attempt < max_retries - 1:
            wait_time = min(2 ** attempt + (time.time() % 1), 60)  # Add jitter, cap at 60s
            logger.info(
                f"Waiting {wait_time:.2f} seconds before retry",
                extra={"correlation_id": correlation_id}
            )
            await asyncio.sleep(wait_time)
    
    error_msg = f"Failed to deliver webhook after {max_retries} attempts to {domain_config.webhook_url}"
    logger.error(error_msg, extra={"correlation_id": correlation_id})
    raise WebhookDeliveryError(error_msg)