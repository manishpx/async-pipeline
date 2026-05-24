import json
import os
import boto3

ddb   = boto3.client("dynamodb")
TABLE = os.environ["JOBS_TABLE"]

def handler(event, _ctx):
    job_id = event["pathParameters"]["jobId"]
    resp = ddb.get_item(TableName=TABLE, Key={"jobId": {"S": job_id}})
    item = resp.get("Item")
    if not item:
        return {"statusCode": 404, "body": json.dumps({"error": "not found"})}

    flat = {k: list(v.values())[0] for k, v in item.items()}
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(flat),
    }