import json
import boto3
import email
import os
import requests
import logging
from typing import Dict, Any, Optional
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import hashlib
import hmac
import base64

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
s3_client = boto3.client('s3')

# Environment variables
TARGET_WEBHOOK_URL = os.environ.get('TARGET_WEBHOOK_URL', '')
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', '')
MAX_RETRIES = int(os.environ.get('MAX_RETRIES', '3'))
TIMEOUT_SECONDS = int(os.environ.get('TIMEOUT_SECONDS', '30'))
S3_BUCKET = os.environ.get('S3_BUCKET', '')
ALLOWED_DOMAINS = os.environ.get('ALLOWED_DOMAINS', '').split(',')
MAX_EMAIL_SIZE_MB = int(os.environ.get('MAX_EMAIL_SIZE_MB', '10'))


def lambda_handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """
    Main Lambda handler for processing SES emails
    """
    logger.info(f"Received SES event: {json.dumps(event)}")
    
    try:
        # Process each SES record in the event
        for record in event.get('Records', []):
            if record.get('eventSource') == 'aws:ses':
                process_ses_mail(record['ses'])
        
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Email processed successfully'})
        }
        
    except Exception as e:
        logger.error(f"Error processing email: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }


def process_ses_mail(ses_data: Dict[str, Any]) -> None:
    """
    Process a single SES email record
    """
    mail = ses_data['mail']
    receipt = ses_data['receipt']
    
    # Extract basic email information
    message_id = mail['messageId']
    timestamp = mail['timestamp']
    source = mail['source']
    destination = mail['destination']
    
    logger.info(f"Processing email {message_id} from {source} to {destination}")
    
    # Validate email against allowed domains
    if not is_email_allowed(source, destination):
        logger.warning(f"Email from {source} to {destination} not allowed")
        return
    
    # Get email content from S3 if available
    email_content = None
    s3_action = None
    
    # SES receipt can have multiple actions - find the S3 action
    for action in receipt.get('action', []):
        if action.get('type') == 's3':
            s3_action = action
            break
    
    if s3_action:
        email_content = get_email_from_s3(s3_action['bucketName'], s3_action['objectKey'])
    
    # Parse email content
    parsed_email = parse_email_content(email_content) if email_content else None
    
    # Prepare webhook payload
    webhook_payload = prepare_webhook_payload(
        message_id=message_id,
        timestamp=timestamp,
        source=source,
        destination=destination,
        subject=mail.get('commonHeaders', {}).get('subject', ''),
        parsed_email=parsed_email,
        raw_headers=mail.get('commonHeaders', {})
    )
    
    # Send to webhook
    send_to_webhook(webhook_payload)


def is_email_allowed(source: str, destination: list) -> bool:
    """
    Check if email is from/to allowed domains
    """
    if not ALLOWED_DOMAINS or ALLOWED_DOMAINS == ['']:
        return True
    
    # Check destination domains
    for dest_email in destination:
        dest_domain = dest_email.split('@')[-1].lower()
        if dest_domain in [domain.strip().lower() for domain in ALLOWED_DOMAINS]:
            return True
    
    return False


def get_email_from_s3(bucket: str, key: str) -> Optional[str]:
    """
    Retrieve email content from S3
    """
    try:
        logger.info(f"Retrieving email from S3: s3://{bucket}/{key}")
        response = s3_client.get_object(Bucket=bucket, Key=key)
        
        # Check content length to avoid processing extremely large emails
        content_length = response.get('ContentLength', 0)
        max_size_bytes = MAX_EMAIL_SIZE_MB * 1024 * 1024
        
        if content_length > max_size_bytes:
            logger.warning(f"Email size {content_length} bytes exceeds limit {max_size_bytes} bytes")
            return None
            
        return response['Body'].read().decode('utf-8', errors='ignore')
    except Exception as e:
        logger.error(f"Error retrieving email from S3 bucket {bucket}, key {key}: {str(e)}")
        return None


def parse_email_content(raw_email: str) -> Dict[str, Any]:
    """
    Parse raw email content using Python's email library
    """
    try:
        msg = email.message_from_string(raw_email)
        
        parsed = {
            'subject': msg.get('Subject', ''),
            'from': msg.get('From', ''),
            'to': msg.get('To', ''),
            'date': msg.get('Date', ''),
            'message_id': msg.get('Message-ID', ''),
            'headers': dict(msg.items()),
            'text_content': '',
            'html_content': '',
            'attachments': []
        }
        
        # Extract body content
        if msg.is_multipart():
            for part in msg.walk():
                content_type = part.get_content_type()
                content_disposition = part.get('Content-Disposition', '')
                
                if content_type == 'text/plain' and 'attachment' not in content_disposition:
                    parsed['text_content'] = part.get_payload(decode=True).decode('utf-8', errors='ignore')
                elif content_type == 'text/html' and 'attachment' not in content_disposition:
                    parsed['html_content'] = part.get_payload(decode=True).decode('utf-8', errors='ignore')
                elif 'attachment' in content_disposition:
                    filename = part.get_filename()
                    if filename:
                        parsed['attachments'].append({
                            'filename': filename,
                            'content_type': content_type,
                            'size': len(part.get_payload(decode=True) or b'')
                        })
        else:
            # Single part message
            content_type = msg.get_content_type()
            payload = msg.get_payload(decode=True)
            if payload:
                content = payload.decode('utf-8', errors='ignore')
                if content_type == 'text/html':
                    parsed['html_content'] = content
                else:
                    parsed['text_content'] = content
        
        return parsed
        
    except Exception as e:
        logger.error(f"Error parsing email content: {str(e)}")
        return {
            'text_content': '',
            'html_content': '',
            'attachments': [],
            'headers': {},
            'error': f'Failed to parse email: {str(e)}'
        }


def prepare_webhook_payload(message_id: str, timestamp: str, source: str, 
                          destination: list, subject: str, parsed_email: Optional[Dict[str, Any]], 
                          raw_headers: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare the payload to send to the webhook endpoint
    """
    payload = {
        'event_type': 'email_received',
        'timestamp': timestamp,
        'message_id': message_id,
        'source': source,
        'destination': destination,
        'subject': subject,
        'headers': raw_headers
    }
    
    if parsed_email:
        payload['email'] = {
            'text_content': parsed_email.get('text_content', ''),
            'html_content': parsed_email.get('html_content', ''),
            'attachments': parsed_email.get('attachments', []),
            'parsed_headers': parsed_email.get('headers', {})
        }
    
    return payload


def send_to_webhook(payload: Dict[str, Any]) -> None:
    """
    Send payload to the configured webhook endpoint with retries
    """
    if not TARGET_WEBHOOK_URL:
        logger.warning("No TARGET_WEBHOOK_URL configured, skipping webhook")
        return
    
    payload_json = json.dumps(payload, sort_keys=True)
    
    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'AWS-SES-Lambda-Bridge/1.0'
    }
    
    # Add signature if webhook secret is configured
    if WEBHOOK_SECRET:
        signature = hmac.new(
            WEBHOOK_SECRET.encode('utf-8'),
            payload_json.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()
        headers['X-Webhook-Signature'] = f'sha256={signature}'
    
    # Retry logic with exponential backoff
    import time
    for attempt in range(MAX_RETRIES):
        try:
            logger.info(f"Sending webhook (attempt {attempt + 1}/{MAX_RETRIES}) to {TARGET_WEBHOOK_URL}")
            
            response = requests.post(
                TARGET_WEBHOOK_URL,
                data=payload_json,
                headers=headers,
                timeout=TIMEOUT_SECONDS
            )
            
            if response.status_code in [200, 201, 202]:
                logger.info(f"Webhook sent successfully with status {response.status_code}")
                return
            else:
                logger.warning(f"Webhook returned status {response.status_code}: {response.text[:200]}")
                
        except requests.exceptions.Timeout as e:
            logger.error(f"Webhook attempt {attempt + 1} timed out: {str(e)}")
        except requests.exceptions.RequestException as e:
            logger.error(f"Webhook attempt {attempt + 1} failed: {str(e)}")
        except Exception as e:
            logger.error(f"Unexpected error on attempt {attempt + 1}: {str(e)}")
            
        # Wait before retry (exponential backoff)
        if attempt < MAX_RETRIES - 1:
            wait_time = min(2 ** attempt, 60)  # Cap at 60 seconds
            logger.info(f"Waiting {wait_time} seconds before retry...")
            time.sleep(wait_time)
    
    logger.error(f"Failed to send webhook after {MAX_RETRIES} attempts")
    raise Exception(f"Failed to deliver webhook after {MAX_RETRIES} attempts") 