terraform {
  required_providers {
    aws = ">= 2.42.0, <= 2.42.0"
  }
  required_version = ">= 0.12.8, < 0.13"
}

provider "aws" {
  region  = "eu-central-1"
  profile = "default"
}

variable "test_lambda_function_stage" {
  description = "prod or dev or whatever makes sense for you"
  default = "dev"
}

//////////////////// IAM /////////////////////////////

data "aws_iam_policy_document" "test_lambda_assume_role_policy" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "test_lambda_role" {
  name = "test-lambda-${var.test_lambda_function_stage}-eu-west-1-lambdaRole"
  assume_role_policy = "${data.aws_iam_policy_document.test_lambda_assume_role_policy.json}"

  tags = {
    STAGE = "${var.test_lambda_function_stage}"
  }
}

//////////////////// CloudWatch /////////////////////////////

locals {
  lambda_function_name = "test-lambda-${var.test_lambda_function_stage}"
}

resource "aws_cloudwatch_log_group" "test_lambda_logging" {
  name = "/aws/lambda/${local.lambda_function_name}"
}

data "aws_iam_policy_document" "cloudwatch_role_policy_document" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:CreateLogGroup",
    ]

    resources = ["${aws_cloudwatch_log_group.test_lambda_logging.arn}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.test_lambda_logging.arn}:*"]
  }
}

resource "aws_iam_role_policy" "test_lambda_cloudwatch_policy" {
  name = "test-lambda-${var.test_lambda_function_stage}-cloudwatch-policy"
  policy = "${data.aws_iam_policy_document.cloudwatch_role_policy_document.json}"
  role = "${aws_iam_role.test_lambda_role.id}"
}

///////////////// Lambda //////////////////////////////


locals {
  build_directory_path = "${path.module}/build"
  lambda_common_libs_layer_path = "${path.module}/files/layers/commonLibs"
  lambda_common_libs_layer_zip_name = "${local.build_directory_path}/commonLibs.zip"
  lambda_function_zip_name = "${local.build_directory_path}/lambda.zip"
}

resource "null_resource" "test_lambda_nodejs_layer" {
  provisioner "local-exec" {
    working_dir = "${local.lambda_common_libs_layer_path}/nodejs"
    command = "npm install"
  }

  triggers = {
    rerun_every_time = "${uuid()}"
  }
}

data "archive_file" "test_lambda_common_libs_layer_package" {
  type = "zip"
  source_dir = "${local.lambda_common_libs_layer_path}"
  output_path = "${local.lambda_common_libs_layer_zip_name}"

  depends_on = [ null_resource.test_lambda_nodejs_layer ]
}

resource "aws_lambda_layer_version" "test_lambda_nodejs_layer" {
  layer_name = "commonLibs"
  filename = "${local.lambda_common_libs_layer_zip_name}"
  source_code_hash = "${data.archive_file.test_lambda_common_libs_layer_package.output_base64sha256}"
  compatible_runtimes = ["nodejs12.x"]
}

data "archive_file" "test_lambda_package" {
  type = "zip"
  source_file = "${path.module}/files/index.js"
  output_path = "${local.lambda_function_zip_name}"
}

resource "aws_lambda_function" "test_lambda" {
  function_name = "${local.lambda_function_name}"
  filename = "${local.lambda_function_zip_name}"
  source_code_hash = "${data.archive_file.test_lambda_package.output_base64sha256}"
  handler = "index.handle"
  runtime = "nodejs12.x"
  publish = "true"
  layers = ["${aws_lambda_layer_version.test_lambda_nodejs_layer.arn}"]
  role = "${aws_iam_role.test_lambda_role.arn}"

  depends_on = [ aws_cloudwatch_log_group.test_lambda_logging ]

  tags = {
    STAGE = "${var.test_lambda_function_stage}"
  }
}

///////////// How to trigger the Lambda? Maybe API Gateway /////////////////////

resource "aws_api_gateway_rest_api" "test_lambda_api" {
  name = "${var.test_lambda_function_stage}-test-lambda"

  tags = {
    STAGE = "${var.test_lambda_function_stage}"
  }
}

resource "aws_lambda_permission" "test_lambda_api_gateway_permission" {
  function_name = "${local.lambda_function_name}"
  principal = "apigateway.amazonaws.com"
  action = "lambda:InvokeFunction"
  source_arn = "${aws_api_gateway_rest_api.test_lambda_api.execution_arn}/*/*"

  depends_on = [ aws_lambda_function.test_lambda ]
}

resource "aws_api_gateway_resource" "test_api_event_resource" {
  rest_api_id = "${aws_api_gateway_rest_api.test_lambda_api.id}"
  parent_id = "${aws_api_gateway_rest_api.test_lambda_api.root_resource_id}"
  path_part = "event"
}

resource "aws_api_gateway_resource" "test_api_event_push_resource" {
  rest_api_id = "${aws_api_gateway_rest_api.test_lambda_api.id}"
  parent_id = "${aws_api_gateway_resource.test_api_event_resource.id}"
  path_part = "push"
}

resource "aws_api_gateway_method" "test_api_event_push_method" {
  rest_api_id = "${aws_api_gateway_rest_api.test_lambda_api.id}"
  resource_id = "${aws_api_gateway_resource.test_api_event_push_resource.id}"
  http_method = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "test_api_lambda_integration" {
  rest_api_id = "${aws_api_gateway_rest_api.test_lambda_api.id}"
  resource_id = "${aws_api_gateway_resource.test_api_event_push_resource.id}"
  http_method = "${aws_api_gateway_method.test_api_event_push_method.http_method}"
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = "${aws_lambda_function.test_lambda.invoke_arn}"
}

resource "aws_api_gateway_deployment" "test_api_deployment" {
  rest_api_id = "${aws_api_gateway_rest_api.test_lambda_api.id}"
  stage_name = "${var.test_lambda_function_stage}"

  depends_on = [ aws_api_gateway_integration.test_api_lambda_integration ]
}

///////////////////////////////////////////////////////////////

output "user_message" {
  value = "Test command:     curl -d {} ${aws_api_gateway_deployment.test_api_deployment.invoke_url}/event/push"
}