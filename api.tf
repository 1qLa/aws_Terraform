# 申告・承認API（API Gateway + Lambda）
# ログインした人（Cognito）だけが呼べる。POST /attest/{event_id}（申告）、POST /approve/{event_id}（承認）

# Lambdaのコード（api/ フォルダ。テストは含めない）
data "archive_file" "api_zip" {
  type        = "zip"
  source_dir  = "api"
  excludes    = ["test_handlers.py", "__pycache__"]
  output_path = "api_function.zip"
}

# 申告・承認Lambdaの実行ロール
resource "aws_iam_role" "api_lambda_role" {
  name = "${var.prefix}-api-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ログ出力（CloudWatch Logs）
resource "aws_iam_role_policy_attachment" "api_lambda_logs" {
  role       = aws_iam_role.api_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 台帳の読み取りと更新だけを許可（新規作成・削除はできない）
resource "aws_iam_role_policy" "api_lambda_dynamodb" {
  name = "api-lambda-dynamodb-policy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.drift_events.arn
    }]
  })
}

locals {
  # 申告・承認Lambdaの共通設定。ハンドラー名だけが違う
  api_handlers = {
    attest  = "handlers.attest_handler"
    approve = "handlers.approve_handler"
  }
}

resource "aws_lambda_function" "api" {
  for_each = local.api_handlers

  function_name    = "${var.prefix}-${each.key}-handler"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = each.value
  runtime          = "python3.9"
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = {
      DRIFT_TABLE_NAME = aws_dynamodb_table.drift_events.name
      # グループ名とPrecedenceの対応。承認の権限判定に使う
      GROUP_PRECEDENCE = jsonencode({
        (aws_cognito_user_group.leads.name)      = aws_cognito_user_group.leads.precedence
        (aws_cognito_user_group.developers.name) = aws_cognito_user_group.developers.precedence
      })
    }
  }
}

# API Gateway（REST API）。Cognitoで検証したログイン情報が、Lambdaにそのまま渡る
resource "aws_api_gateway_rest_api" "drift" {
  name = "${var.prefix}-drift-api"
}

# Cognitoのログインを認可に使う（IDトークンをAuthorizationヘッダーで受け取る）
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${var.prefix}-cognito"
  rest_api_id     = aws_api_gateway_rest_api.drift.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}

# /attest/{event_id}、/approve/{event_id} のパス
resource "aws_api_gateway_resource" "action" {
  for_each = local.api_handlers

  rest_api_id = aws_api_gateway_rest_api.drift.id
  parent_id   = aws_api_gateway_rest_api.drift.root_resource_id
  path_part   = each.key
}

resource "aws_api_gateway_resource" "event_id" {
  for_each = local.api_handlers

  rest_api_id = aws_api_gateway_rest_api.drift.id
  parent_id   = aws_api_gateway_resource.action[each.key].id
  path_part   = "{event_id}"
}

resource "aws_api_gateway_method" "post" {
  for_each = local.api_handlers

  rest_api_id   = aws_api_gateway_rest_api.drift.id
  resource_id   = aws_api_gateway_resource.event_id[each.key].id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "lambda" {
  for_each = local.api_handlers

  rest_api_id             = aws_api_gateway_rest_api.drift.id
  resource_id             = aws_api_gateway_resource.event_id[each.key].id
  http_method             = aws_api_gateway_method.post[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api[each.key].invoke_arn
}

# API GatewayからLambdaを呼ぶ許可
resource "aws_lambda_permission" "apigw" {
  for_each = local.api_handlers

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.drift.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "drift" {
  rest_api_id = aws_api_gateway_rest_api.drift.id

  # 設定が変わったときだけ、デプロイし直す
  triggers = {
    redeployment = sha1(jsonencode([
      [for m in aws_api_gateway_method.post : m.id],
      [for i in aws_api_gateway_integration.lambda : i.id],
      aws_api_gateway_authorizer.cognito.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "v1" {
  rest_api_id   = aws_api_gateway_rest_api.drift.id
  deployment_id = aws_api_gateway_deployment.drift.id
  stage_name    = "v1"
}
