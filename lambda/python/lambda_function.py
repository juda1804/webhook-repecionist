import asyncio
import json
import logging
import os
import time
import hashlib
import hmac
from dataclasses import dataclass, asdict
from email import message_from_string
from typing import Dict, Any, List, Optional, Union
from uuid import uuid4

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


def lambda_handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """
    Main Lambda handler for processing SES emails
    """
    correlation_id = str(uuid4())
    
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
        
        # Validate email against allowed domains
        if not is_email_allowed(metadata):
            logger.warning(
                f"Email not allowed: from {metadata.from_address} to {metadata.to_addresses}",
                extra={"correlation_id": correlation_id}
            )
            return
        
        # Get email content from S3
        email_content = await get_email_content(ses_data, correlation_id)
        
        # Create webhook payload
        payload = WebhookPayload(
            event_type="email_received",
            metadata=metadata,
            content=email_content
        )
        
        # Send to webhook
        await send_webhook(payload, correlation_id)
        
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


def is_email_allowed(metadata: EmailMetadata) -> bool:
    """Check if email is from/to allowed domains"""
    
    if not config.allowed_domains:
        return True
    
    # Check if any destination domain is allowed
    for email_addr in metadata.to_addresses:
        domain = email_addr.split('@')[-1].lower()
        if domain in config.allowed_domains:
            return True
    
    return False


async def get_email_content(ses_data: Dict[str, Any], correlation_id: str) -> EmailContent:
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
        
        # Check file size
        content_length = response.get('ContentLength', 0)
        max_size_bytes = config.max_email_size_mb * 1024 * 1024
        
        if content_length > max_size_bytes:
            logger.warning(
                f"Email size {content_length} bytes exceeds limit {max_size_bytes} bytes",
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


async def send_webhook(payload: WebhookPayload, correlation_id: str) -> None:
    """Send payload to webhook endpoint with retry logic"""
    
    payload_dict = payload.to_dict()
    payload_json = json.dumps(payload_dict, sort_keys=True)
    
    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'AWS-SES-Lambda-Bridge/2.0',
        'X-Correlation-ID': correlation_id
    }
    
    # Add HMAC signature if secret is configured
    if config.webhook_secret:
        signature = hmac.new(
            config.webhook_secret.encode('utf-8'),
            payload_json.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()
        headers['X-Webhook-Signature'] = f'sha256={signature}'
    
    # Retry logic with exponential backoff
    for attempt in range(config.max_retries):
        try:
            logger.info(
                f"Sending webhook (attempt {attempt + 1}/{config.max_retries})",
                extra={
                    "correlation_id": correlation_id,
                    "webhook_url": config.webhook_url,
                    "attempt": attempt + 1
                }
            )
            
            async with httpx.AsyncClient(timeout=config.timeout_seconds) as client:
                response = await client.post(
                    config.webhook_url,
                    content=payload_json,
                    headers=headers
                )
            
            if response.status_code in [200, 201, 202]:
                logger.info(
                    f"Webhook delivered successfully with status {response.status_code}",
                    extra={
                        "correlation_id": correlation_id,
                        "status_code": response.status_code,
                        "response_size": len(response.content)
                    }
                )
                return
            else:
                logger.warning(
                    f"Webhook returned status {response.status_code}",
                    extra={
                        "correlation_id": correlation_id,
                        "status_code": response.status_code,
                        "response_text": response.text[:200]
                    }
                )
                
        except httpx.TimeoutException as e:
            logger.error(
                f"Webhook attempt {attempt + 1} timed out: {str(e)}",
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
        if attempt < config.max_retries - 1:
            wait_time = min(2 ** attempt + (time.time() % 1), 60)  # Add jitter, cap at 60s
            logger.info(
                f"Waiting {wait_time:.2f} seconds before retry",
                extra={"correlation_id": correlation_id}
            )
            await asyncio.sleep(wait_time)
    
    error_msg = f"Failed to deliver webhook after {config.max_retries} attempts"
    logger.error(error_msg, extra={"correlation_id": correlation_id})
    raise WebhookDeliveryError(error_msg)