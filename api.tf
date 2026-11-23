# 申告・承認API（API Gateway + Lambda）
# ログインした人（Cognito）だけが呼べる。POST /attest/{event_id}（申告）、POST /approve/{event_id}（承認）

# Lambdaのコード（api/ フォルダ。テストは含めない）
data "archive_file" "api_zip" {
  type        = "zip"
  source_dir  = "api"
  excludes    = ["test_*.py", "__pycache__"]
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

# 台帳の読み取り(取得・一覧)と更新だけを許可（新規作成・削除はできない）
resource "aws_iam_role_policy" "api_lambda_dynamodb" {
  name = "api-lambda-dynamodb-policy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Scan"] // Scan: 一覧の表示用(読み取りだけ)
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

  # 台帳を読み書きするLambda(申告・承認・内容の表示)の共通の環境変数
  api_lambda_env = {
    DRIFT_TABLE_NAME = aws_dynamodb_table.drift_events.name
    # グループ名とPrecedenceの対応。承認の権限判定と、内容を見られる人の判定に使う
    GROUP_PRECEDENCE = jsonencode({
      (aws_cognito_user_group.leads.name)      = aws_cognito_user_group.leads.precedence
      (aws_cognito_user_group.developers.name) = aws_cognito_user_group.developers.precedence
    })
  }

  # APIのステージ名(画面のURLを、ステージの作成より先に決めるため、ここで固定する)
  api_stage_name = "v1"
}

resource "aws_lambda_function" "api" {
  for_each = local.api_handlers

  function_name    = "${var.prefix}-${each.key}-handler"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = each.value
  runtime          = "python3.13"
  timeout          = 10 // 秒。既定の3秒だと、初回の起動で足りなくなることがある
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = local.api_lambda_env
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
      // 画面と内容表示のAPI(ui.tf)
      aws_api_gateway_method.ui_get.id,
      aws_api_gateway_integration.ui.id,
      aws_api_gateway_method.events_get.id,
      aws_api_gateway_integration.events.id,
      aws_api_gateway_method.events_list.id,
      aws_api_gateway_integration.events_list.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "v1" {
  rest_api_id   = aws_api_gateway_rest_api.drift.id
  deployment_id = aws_api_gateway_deployment.drift.id
  stage_name    = local.api_stage_name
}
