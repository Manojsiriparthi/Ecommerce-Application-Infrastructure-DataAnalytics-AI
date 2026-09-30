"""
=============================================================================
Lambda: Secrets Rotation
=============================================================================
PURPOSE:
  Rotates two types of secrets for pip-project-ecommerce:
    1. DB master password  → Secrets Manager + all 5 SSM DATABASE_URLs
    2. JWT secret          → SSM SecureString
    3. Internal service key → SSM SecureString

TRIGGER:
  EventBridge Scheduled Rule — every 30 days (configurable)
  OR manually invoked with event {"rotate": "db"} or {"rotate": "jwt"}

WHAT IT DOES:
  DB Password Rotation:
    1. Generate new strong password
    2. Connect to Aurora via boto3 and call modify-db-cluster to set new password
    3. Wait for cluster to be available
    4. Update Secrets Manager secret with new password
    5. Update all 5 SSM DATABASE_URL parameters with new password
    6. Publish SNS notification with rotation summary

  JWT / Internal Key Rotation:
    1. Generate new cryptographically random key
    2. Update SSM SecureString parameter
    3. Publish SNS notification
    NOTE: After JWT rotation, all existing tokens are immediately invalid.
          Users will need to log in again. Plan rotation during low-traffic.

SECURITY:
  - All secrets encrypted with KMS (alias/pip-project-ecommerce-kms)
  - Lambda has least-privilege IAM — only the specific actions needed
  - New password uses secrets.token_urlsafe(32) — 256 bits of entropy
  - Password is URL-encoded (%23 for #) before storing in DATABASE_URL

HOW TO INVOKE MANUALLY:
  aws lambda invoke \
    --function-name pip-project-ecommerce-secrets-rotation \
    --payload '{"rotate": "all"}' \
    --region us-east-1 \
    response.json && cat response.json

ENVIRONMENT VARIABLES (set by deploy.sh):
  PROJECT_NAME    — pip-project-ecommerce
  ENVIRONMENT     — prod
  REGION          — us-east-1
  SNS_TOPIC_ARN   — arn:aws:sns:us-east-1:497149484677:pip-project-ecommerce-*
  KMS_KEY_ALIAS   — alias/pip-project-ecommerce-kms
  DB_CLUSTER_ID   — pip-project-ecommerce-cluster
  DB_SECRET_NAME  — pip-project-ecommerce-db-credentials
=============================================================================
"""

import json
import logging
import os
import re
import secrets
import string
import time
import urllib.parse

import boto3
from botocore.exceptions import ClientError

# ── Logging ──────────────────────────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS Clients ───────────────────────────────────────────────────────────────
REGION          = os.environ.get("REGION", "us-east-1")
PROJECT         = os.environ.get("PROJECT_NAME", "pip-project-ecommerce")
ENVIRONMENT     = os.environ.get("ENVIRONMENT", "prod")
SNS_TOPIC_ARN   = os.environ.get("SNS_TOPIC_ARN", "")
KMS_KEY_ALIAS   = os.environ.get("KMS_KEY_ALIAS", f"alias/{PROJECT}-kms")
DB_CLUSTER_ID   = os.environ.get("DB_CLUSTER_ID", f"{PROJECT}-cluster")
DB_SECRET_NAME  = os.environ.get("DB_SECRET_NAME", f"{PROJECT}-db-credentials")
DB_USERNAME     = os.environ.get("DB_USERNAME", "pipadmin")

sm    = boto3.client("secretsmanager", region_name=REGION)
ssm   = boto3.client("ssm",            region_name=REGION)
rds   = boto3.client("rds",            region_name=REGION)
sns   = boto3.client("sns",            region_name=REGION)
kms   = boto3.client("kms",            region_name=REGION)

# Services that have their own DATABASE_URL in SSM
SERVICES = ["user", "product", "cart", "order", "payment"]


# =============================================================================
# Password / Key Generation
# =============================================================================

def generate_db_password(length: int = 32) -> str:
    """
    Generate a strong DB password.
    Avoids characters that cause issues in PostgreSQL connection strings:
      @ : / ? # [ ] (URL special chars)
    Uses uppercase, lowercase, digits + safe symbols only.
    """
    alphabet = string.ascii_letters + string.digits + "!$^&*()-_=+[]{}|"
    while True:
        password = "".join(secrets.choice(alphabet) for _ in range(length))
        # Ensure at least one of each required character class
        has_upper  = any(c.isupper()  for c in password)
        has_lower  = any(c.islower()  for c in password)
        has_digit  = any(c.isdigit()  for c in password)
        has_symbol = any(c in "!$^&*()-_=+[]{}|" for c in password)
        # No URL-special chars that break connection strings
        has_bad    = any(c in "@:/?#[]" for c in password)
        if has_upper and has_lower and has_digit and has_symbol and not has_bad:
            return password


def generate_secret_key(length: int = 48) -> str:
    """Generate a cryptographically random secret key (URL-safe base64)."""
    return secrets.token_urlsafe(length)


def url_encode_password(password: str) -> str:
    """URL-encode the password for use in a PostgreSQL connection string."""
    return urllib.parse.quote(password, safe="")


# =============================================================================
# KMS helpers
# =============================================================================

def get_kms_key_arn(alias: str) -> str:
    """Resolve KMS alias → ARN."""
    try:
        resp = kms.describe_key(KeyId=alias)
        arn  = resp["KeyMetadata"]["Arn"]
        logger.info(f"KMS key ARN: {arn}")
        return arn
    except ClientError as e:
        logger.error(f"KMS describe_key failed: {e}")
        raise


# =============================================================================
# DB Password Rotation
# =============================================================================

def rotate_db_password() -> dict:
    """
    Rotate Aurora master password.

    Steps:
      1. Generate new password
      2. Update Aurora cluster master password via RDS API
      3. Wait for cluster to be available
      4. Update Secrets Manager secret
      5. Update all 5 SSM DATABASE_URL parameters
    """
    logger.info("=== Starting DB password rotation ===")

    # 1. Generate
    new_password = generate_db_password()
    logger.info(f"Generated new password ({len(new_password)} chars)")

    # 2. Update Aurora master password
    try:
        logger.info(f"Updating Aurora cluster: {DB_CLUSTER_ID}")
        rds.modify_db_cluster(
            DBClusterIdentifier=DB_CLUSTER_ID,
            MasterUserPassword=new_password,
            ApplyImmediately=True,
        )
        logger.info("Aurora modify_db_cluster call succeeded")
    except ClientError as e:
        logger.error(f"RDS modify_db_cluster failed: {e}")
        raise

    # 3. Wait for cluster to be available (max 10 min)
    logger.info("Waiting for Aurora cluster to be available...")
    for attempt in range(40):
        try:
            resp   = rds.describe_db_clusters(DBClusterIdentifiers=[DB_CLUSTER_ID])
            status = resp["DBClusters"][0]["Status"]
            logger.info(f"  Cluster status [{attempt+1}/40]: {status}")
            if status == "available":
                logger.info("Aurora cluster is available with new password")
                break
        except ClientError as e:
            logger.warning(f"describe_db_clusters error: {e}")
        time.sleep(15)
    else:
        raise RuntimeError("Aurora cluster did not become available after 10 minutes")

    # Get writer endpoint for DATABASE_URL
    writer_endpoint = resp["DBClusters"][0]["Endpoint"]
    logger.info(f"Writer endpoint: {writer_endpoint}")

    # 4. Update Secrets Manager
    kms_arn = get_kms_key_arn(KMS_KEY_ALIAS)
    new_secret = json.dumps({
        "engine":   "postgres",
        "host":     writer_endpoint,
        "password": new_password,
        "port":     5432,
        "username": DB_USERNAME,
    })
    try:
        sm.update_secret(
            SecretId    = DB_SECRET_NAME,
            SecretString= new_secret,
            KmsKeyId    = kms_arn,
        )
        logger.info(f"Secrets Manager updated: {DB_SECRET_NAME}")
    except ClientError as e:
        logger.error(f"Secrets Manager update failed: {e}")
        raise

    # 5. Update all 5 SSM DATABASE_URL parameters
    encoded_password = url_encode_password(new_password)
    updated_params   = []

    for svc in SERVICES:
        param_name = f"/{PROJECT}/{ENVIRONMENT}/db/{svc}-url"
        new_url    = (
            f"postgresql://{DB_USERNAME}:{encoded_password}"
            f"@{writer_endpoint}:5432/{svc}_db?sslmode=require"
        )
        try:
            ssm.put_parameter(
                Name      = param_name,
                Value     = new_url,
                Type      = "SecureString",
                KeyId     = kms_arn,
                Overwrite = True,
            )
            logger.info(f"  SSM updated: {param_name}")
            updated_params.append(param_name)
        except ClientError as e:
            logger.error(f"  SSM update failed for {param_name}: {e}")
            raise

    logger.info(f"DB rotation complete. Updated {len(updated_params)} SSM params.")
    return {
        "rotated": "db_password",
        "cluster": DB_CLUSTER_ID,
        "ssm_params_updated": updated_params,
        "action_required": (
            "Restart all backend pods to pick up new DATABASE_URL from SSM: "
            "kubectl rollout restart deployment -n ecommerce"
        ),
    }


# =============================================================================
# JWT Secret Rotation
# =============================================================================

def rotate_jwt_secret() -> dict:
    """
    Rotate JWT signing secret in SSM.

    WARNING: After rotation, all existing JWT tokens are IMMEDIATELY INVALID.
    Users will be logged out. Plan this during low-traffic (e.g. 2am).
    """
    logger.info("=== Starting JWT secret rotation ===")

    kms_arn    = get_kms_key_arn(KMS_KEY_ALIAS)
    param_name = f"/{PROJECT}/{ENVIRONMENT}/app/jwt-secret"
    new_secret = generate_secret_key(48)

    try:
        ssm.put_parameter(
            Name      = param_name,
            Value     = new_secret,
            Type      = "SecureString",
            KeyId     = kms_arn,
            Overwrite = True,
        )
        logger.info(f"JWT secret rotated: {param_name}")
    except ClientError as e:
        logger.error(f"SSM update failed for JWT secret: {e}")
        raise

    return {
        "rotated": "jwt_secret",
        "param":   param_name,
        "action_required": (
            "Restart all backend pods to pick up new JWT_SECRET from SSM. "
            "All existing user sessions will be invalidated. "
            "kubectl rollout restart deployment -n ecommerce"
        ),
    }


# =============================================================================
# Internal Service Key Rotation
# =============================================================================

def rotate_internal_service_key() -> dict:
    """Rotate the internal service-to-service key."""
    logger.info("=== Starting internal service key rotation ===")

    kms_arn    = get_kms_key_arn(KMS_KEY_ALIAS)
    param_name = f"/{PROJECT}/{ENVIRONMENT}/app/internal-service-key"
    new_key    = generate_secret_key(32)

    try:
        ssm.put_parameter(
            Name      = param_name,
            Value     = new_key,
            Type      = "SecureString",
            KeyId     = kms_arn,
            Overwrite = True,
        )
        logger.info(f"Internal service key rotated: {param_name}")
    except ClientError as e:
        logger.error(f"SSM update failed for internal service key: {e}")
        raise

    return {
        "rotated": "internal_service_key",
        "param":   param_name,
        "action_required": (
            "Restart all backend pods to pick up new INTERNAL_SERVICE_KEY from SSM. "
            "kubectl rollout restart deployment -n ecommerce"
        ),
    }


# =============================================================================
# SNS Notification
# =============================================================================

def send_notification(results: list, errors: list) -> None:
    """Publish rotation summary to SNS."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set — skipping notification")
        return

    status  = "SUCCESS" if not errors else "PARTIAL_FAILURE"
    subject = f"[{PROJECT}] Secret Rotation {status}"

    body_lines = [
        f"Secret Rotation Report — {PROJECT} ({ENVIRONMENT})",
        f"Status: {status}",
        f"Region: {REGION}",
        "",
        "=== Rotated Secrets ===",
    ]
    for r in results:
        body_lines.append(f"  ✓ {r.get('rotated', 'unknown')}")
        if r.get("action_required"):
            body_lines.append(f"    ACTION: {r['action_required']}")

    if errors:
        body_lines.append("")
        body_lines.append("=== Errors ===")
        for e in errors:
            body_lines.append(f"  ✗ {e}")

    body_lines += [
        "",
        "Next steps if rotation succeeded:",
        "  kubectl rollout restart deployment -n ecommerce",
        "  kubectl get pods -n ecommerce -w",
    ]

    try:
        sns.publish(
            TopicArn = SNS_TOPIC_ARN,
            Subject  = subject,
            Message  = "\n".join(body_lines),
        )
        logger.info(f"SNS notification sent to {SNS_TOPIC_ARN}")
    except ClientError as e:
        logger.error(f"SNS publish failed: {e}")


# =============================================================================
# Lambda Handler
# =============================================================================

def lambda_handler(event: dict, context) -> dict:
    """
    Entry point.

    Event payload examples:
      {}                    → rotate all secrets
      {"rotate": "db"}      → rotate DB password only
      {"rotate": "jwt"}     → rotate JWT secret only
      {"rotate": "internal"} → rotate internal service key only
      {"rotate": "all"}     → rotate all secrets
    """
    logger.info(f"Event: {json.dumps(event)}")
    logger.info(f"Project: {PROJECT}, Environment: {ENVIRONMENT}, Region: {REGION}")

    rotate_target = event.get("rotate", "all").lower()
    results = []
    errors  = []

    rotation_map = {
        "db":       rotate_db_password,
        "jwt":      rotate_jwt_secret,
        "internal": rotate_internal_service_key,
    }

    targets = (
        list(rotation_map.keys())
        if rotate_target in ("all", "")
        else [rotate_target]
    )

    for target in targets:
        if target not in rotation_map:
            errors.append(f"Unknown rotation target: {target}")
            continue
        try:
            result = rotation_map[target]()
            results.append(result)
            logger.info(f"Rotation succeeded: {target}")
        except Exception as e:
            msg = f"{target} rotation failed: {str(e)}"
            logger.error(msg)
            errors.append(msg)

    # Send SNS notification regardless of success/failure
    send_notification(results, errors)

    response = {
        "statusCode": 200 if not errors else 500,
        "results":    results,
        "errors":     errors,
        "summary":    f"{len(results)} rotated, {len(errors)} failed",
    }

    logger.info(f"Rotation complete: {response['summary']}")
    return response
