import base64
import json
import os
import statistics
import boto3


textract = boto3.client("textract")
rekognition = boto3.client("rekognition")


def _response(status, obj):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(obj),
    }


def lambda_handler(event, context):
    # Expects {"image_bytes_b64": "..."}
    try:
        image_b64 = None
        if isinstance(event, dict):
            image_b64 = event.get("image_bytes_b64")
        if not image_b64:
            return _response(400, {"error": "image_bytes_b64 missing"})
        image_bytes = base64.b64decode(image_b64)
    except Exception as e:
        return _response(400, {"error": f"Invalid payload: {e}"})

    try:
        # Textract DetectDocumentText
        textract_result = textract.detect_document_text(Document={"Bytes": image_bytes})
        textract_lines = []
        textract_conf = []
        for block in textract_result.get("Blocks", []):
            if block.get("BlockType") == "LINE" and block.get("Text"):
                textract_lines.append(block["Text"])
                if "Confidence" in block:
                    textract_conf.append(float(block["Confidence"]))
        textract_avg_conf = statistics.fmean(textract_conf) if textract_conf else 0.0

        # Rekognition DetectText
        rekog_result = rekognition.detect_text(Image={"Bytes": image_bytes})
        rekog_lines = []
        rekog_conf = []
        for d in rekog_result.get("TextDetections", []):
            if d.get("Type") == "LINE" and d.get("DetectedText"):
                rekog_lines.append(d["DetectedText"])
                if "Confidence" in d:
                    rekog_conf.append(float(d["Confidence"]))
        rekog_avg_conf = statistics.fmean(rekog_conf) if rekog_conf else 0.0

        best = "textract" if textract_avg_conf >= rekog_avg_conf else "rekognition"
        lines = textract_lines if best == "textract" else rekog_lines
        avg_conf = textract_avg_conf if best == "textract" else rekog_avg_conf

        return _response(200, {
            "service": "text_recognition",
            "message": "Compared Textract vs Rekognition",
            "best_engine": best,
            "avg_confidence": avg_conf,
            "textract_avg_confidence": textract_avg_conf,
            "rekognition_avg_confidence": rekog_avg_conf,
            "lines": lines,
            "num_lines": len(lines),
        })
    except Exception as e:
        return _response(500, {"error": f"Recognition failed: {e}"})

