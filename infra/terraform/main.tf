terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }

  required_version = ">= 1.5.7"
}

provider "aws" {
  region = var.aws_region
}

############################################################
# Inputs
############################################################

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix/name for resources"
  type        = string
  default     = "text-extract"
}

variable "lambda_runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "python3.11"
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB"
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}

############################################################
# Package Lambda sources using archive_file (two functions)
############################################################

data "archive_file" "proxy_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../@lambda/proxy"
  output_path = "${path.module}/build/${var.project_name}-proxy.zip"
}

data "archive_file" "text_recognition_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../@lambda/text_recognition"
  output_path = "${path.module}/build/${var.project_name}-text-recognition.zip"
}

############################################################
# IAM Role & Policy for Lambda basic execution
############################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy_role" {
  name               = "${var.project_name}-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "proxy_basic_exec" {
  role       = aws_iam_role.proxy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "text_recognition_role" {
  name               = "${var.project_name}-text-recognition-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "text_recognition_basic_exec" {
  role       = aws_iam_role.text_recognition_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

############################################################
# CloudWatch Log Group (optional explicit creation)
############################################################

resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/aws/lambda/${var.project_name}-proxy"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "text_recognition" {
  name              = "/aws/lambda/${var.project_name}-text-recognition"
  retention_in_days = 14
}

############################################################
# Lambda Functions
############################################################

resource "aws_lambda_function" "proxy" {
  function_name = "${var.project_name}-proxy"
  role          = aws_iam_role.proxy_role.arn
  handler       = "handler.lambda_handler"
  runtime       = var.lambda_runtime
  filename      = data.archive_file.proxy_zip.output_path
  source_code_hash = data.archive_file.proxy_zip.output_base64sha256

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  environment {
    variables = {
      LOG_LEVEL = "INFO"
      TEXT_RECOGNITION_FUNCTION_NAME = aws_lambda_function.text_recognition.function_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.proxy_basic_exec,
    aws_cloudwatch_log_group.proxy
  ]
}

resource "aws_lambda_function" "text_recognition" {
  function_name = "${var.project_name}-text-recognition"
  role          = aws_iam_role.text_recognition_role.arn
  handler       = "handler.lambda_handler"
  runtime       = var.lambda_runtime
  filename      = data.archive_file.text_recognition_zip.output_path
  source_code_hash = data.archive_file.text_recognition_zip.output_base64sha256

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.text_recognition_basic_exec,
    aws_cloudwatch_log_group.text_recognition
  ]
}

############################################################
# IAM Policies for cross-invoke and Textract
############################################################

data "aws_iam_policy_document" "proxy_invoke_text_recognition_doc" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.text_recognition.arn]
  }
}

resource "aws_iam_role_policy" "proxy_invoke_text_recognition" {
  name   = "${var.project_name}-proxy-invoke-text-recognition"
  role   = aws_iam_role.proxy_role.id
  policy = data.aws_iam_policy_document.proxy_invoke_text_recognition_doc.json
}

data "aws_iam_policy_document" "text_recognition_textract_doc" {
  statement {
    actions   = ["textract:DetectDocumentText"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "text_recognition_textract" {
  name   = "${var.project_name}-text-recognition-textract"
  role   = aws_iam_role.text_recognition_role.id
  policy = data.aws_iam_policy_document.text_recognition_textract_doc.json
}

data "aws_iam_policy_document" "text_recognition_rekognition_doc" {
  statement {
    actions   = ["rekognition:DetectText"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "text_recognition_rekognition" {
  name   = "${var.project_name}-text-recognition-rekognition"
  role   = aws_iam_role.text_recognition_role.id
  policy = data.aws_iam_policy_document.text_recognition_rekognition_doc.json
}

############################################################
# HTTP API Gateway → Proxy Lambda
############################################################

resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "proxy_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.proxy.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "extract_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /extract"
  target    = "integrations/${aws_apigatewayv2_integration.proxy_integration.id}"
}

resource "aws_apigatewayv2_route" "extract_best_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /extract/best"
  target    = "integrations/${aws_apigatewayv2_integration.proxy_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw_invoke_proxy" {
  statement_id  = "AllowAPIGWInvokeProxy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

############################################################
# Outputs
############################################################

output "proxy_lambda_function_name" {
  description = "Proxy Lambda function name"
  value       = aws_lambda_function.proxy.function_name
}

output "proxy_lambda_invoke_arn" {
  description = "Proxy Lambda Invoke ARN"
  value       = aws_lambda_function.proxy.invoke_arn
}

output "text_recognition_lambda_function_name" {
  description = "Text recognition Lambda function name"
  value       = aws_lambda_function.text_recognition.function_name
}

output "text_recognition_lambda_invoke_arn" {
  description = "Text recognition Lambda Invoke ARN"
  value       = aws_lambda_function.text_recognition.invoke_arn
}

output "http_api_endpoint" {
  description = "HTTP API base endpoint"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

output "extract_url" {
  description = "POST URL to extract text from an image"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/extract"
}

output "extract_best_url" {
  description = "POST URL to extract using best-of-two recognizers"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/extract/best"
}

