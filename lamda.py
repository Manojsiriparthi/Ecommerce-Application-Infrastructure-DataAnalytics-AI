import boto3
import json
import secrets
from datetime import datetime, timezone

sm = boto3.client("secretsmanager")

SECRET_NAME = "dev/db/password"


def lambda_handler(event, context):

    # Generate a new dummy value
    new_value = {
        "application_secret": secrets.token_hex(16),
        "rotated_at": datetime.now(timezone.utc).isoformat()
    }

    # Create a new version
    response = sm.put_secret_value(
        SecretId=SECRET_NAME,
        SecretString=json.dumps(new_value)
    )

    print("New secret version created:")
    print(response["VersionId"])

    return {
        "statusCode": 200,
        "version_id": response["VersionId"]
    }
