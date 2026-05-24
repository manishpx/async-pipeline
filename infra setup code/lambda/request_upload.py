import json
import os
import uuid
import boto3
from botocore.config import Config

s3 = boto3.client("s3", config=Config(signature_version="s3v4"))
BUCKET  = os.environ["UPLOADS_BUCKET"]
KMS_KEY = os.environ["KMS_KEY_ID"]

def handler(event, _ctx):
    body = json.loads(event.get("body") or "{}")
    filename = body.get("filename", "upload.csv")

    job_id = str(uuid.uuid4())
    key = f"uploads/{job_id}/{filename}"

    # Single PUT works up to 5GB. Switch to multipart for >5GB.
    url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": BUCKET,
            "Key": key,
            "ServerSideEncryption": "aws:kms",
            "SSEKMSKeyId": KMS_KEY,
        },
        ExpiresIn=3600,
        HttpMethod="PUT",
    )

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"jobId": job_id, "uploadUrl": url, "key": key}),
    }