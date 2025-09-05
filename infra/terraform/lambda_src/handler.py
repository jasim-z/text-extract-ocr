import json
import os


def lambda_handler(event, context):
    message = {
        "message": "Hello from text-extract Lambda",
        "log_level": os.getenv("LOG_LEVEL", "INFO"),
        "event_preview": str(event)[:256],
    }
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(message),
    }

