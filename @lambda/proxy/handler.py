import base64
import json
import os
import boto3


lambda_client = boto3.client("lambda")


def _response(status, body_dict):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def lambda_handler(event, context):
    # Expecting HTTP API v2.0 request with image payload.
    # Accepted forms:
    # 1) Binary upload (e.g., --data-binary @file.jpg). API marks isBase64Encoded=True; we decode.
    # 2) Raw base64 string (Content-Type: application/octet-stream or text/plain) – we try to b64-decode.
    # 3) JSON {"image_base64":"..."}
    try:
        headers = event.get("headers") or {}
        headers_l = {str(k).lower(): v for k, v in headers.items()} if isinstance(headers, dict) else {}
        content_type = str(headers_l.get("content-type", ""))

        if event.get("isBase64Encoded"):
            body_bytes = base64.b64decode(event.get("body") or b"")
        else:
            body = event.get("body")
            if body is None:
                return _response(400, {"error": "Missing body"})
            if isinstance(body, dict) or content_type.startswith("application/json"):
                parsed = body if isinstance(body, dict) else json.loads(body or "{}")
                image_b64 = parsed.get("image_base64")
                if not image_b64:
                    return _response(400, {"error": "Missing image. Provide JSON with image_base64 or send binary."})
                body_bytes = base64.b64decode(image_b64)
            else:
                # Try to interpret raw body string as base64
                body_str = body if isinstance(body, str) else str(body)
                try:
                    body_bytes = base64.b64decode(body_str, validate=True)
                except Exception:
                    return _response(400, {"error": "Body is not valid base64. Send binary (@file) or JSON image_base64."})
    except Exception as e:
        return _response(400, {"error": f"Invalid request body: {e}"})

    text_recognition_fn = os.getenv("TEXT_RECOGNITION_FUNCTION_NAME")
    if not text_recognition_fn:
        return _response(500, {"error": "TEXT_RECOGNITION_FUNCTION_NAME not configured"})

    # Invoke downstream text recognition Lambda with the image bytes
    try:
        invoke_payload = json.dumps({"image_bytes_b64": base64.b64encode(body_bytes).decode("utf-8")}).encode("utf-8")
        resp = lambda_client.invoke(
            FunctionName=text_recognition_fn,
            InvocationType="RequestResponse",
            Payload=invoke_payload,
        )
        payload_bytes = resp.get("Payload").read() if resp.get("Payload") else b"{}"
        downstream = json.loads(payload_bytes.decode("utf-8") or "{}")
        # If downstream returned a Lambda proxy response, unwrap body
        if isinstance(downstream, dict) and "statusCode" in downstream and "body" in downstream:
            # pass-through
            return _response(downstream.get("statusCode", 200), json.loads(downstream.get("body") or "{}"))
        return _response(200, {"service": "proxy", "result": downstream})
    except Exception as e:
        return _response(500, {"error": f"Downstream invocation failed: {e}"})

