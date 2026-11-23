# 申告・承認の画面(フロントエンド)
# 画面(HTML)は、API Gateway + Lambda から配信する(S3やCloudFrontは使わない)。
#   GET /ui                  画面。ログイン前でも開ける(中身は、ログイン用のページだけ)
#   GET /events              最近の検知の一覧(新しい順、最大50件)。ログインした人のうち、leads か developers の人だけ
#   GET /events/{event_id}   1件の内容。同じく、leads か developers の人だけ
# ログインは Cognito のログイン画面(Authorization Code + PKCE)。ログイン後の戻り先は /ui

locals {
  # 画面のURL。Cognitoの戻り先と、Lambdaの設定の両方で使う
  ui_url = "https://${aws_api_gateway_rest_api.drift.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${local.api_stage_name}/ui"
}

# ---------------------------------------------------------------
# 画面を返すLambda(台帳には、触れない。権限はログ出力だけ)
# ---------------------------------------------------------------
resource "aws_iam_role" "ui_lambda_role" {
  name = "${var.prefix}-ui-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ui_lambda_logs" {
  role       = aws_iam_role.ui_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "ui" {
  function_name    = "${var.prefix}-ui-handler"
  role             = aws_iam_role.ui_lambda_role.arn
  handler          = "ui.ui_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = {
      COGNITO_DOMAIN_URL = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
      CLIENT_ID          = aws_cognito_user_pool_client.web.id
      REDIRECT_URI       = local.ui_url
    }
  }
}

# ---------------------------------------------------------------
# 内容を返すLambda(読み取り専用。申告・承認と同じロールで、台帳の読み取りができる)
# ---------------------------------------------------------------
resource "aws_lambda_function" "get_event" {
  function_name    = "${var.prefix}-get-event-handler"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "handlers.get_event_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = local.api_lambda_env
  }
}

# 一覧を返すLambda(読み取り専用)
resource "aws_lambda_function" "list_events" {
  function_name    = "${var.prefix}-list-events-handler"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "handlers.list_events_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = local.api_lambda_env
  }
}

# ---------------------------------------------------------------
# API Gateway: GET /ui (誰でも)、GET /events/{event_id} (Cognitoでログインした人)
# ---------------------------------------------------------------
resource "aws_api_gateway_resource" "ui" {
  rest_api_id = aws_api_gateway_rest_api.drift.id
  parent_id   = aws_api_gateway_rest_api.drift.root_resource_id
  path_part   = "ui"
}

resource "aws_api_gateway_method" "ui_get" {
  rest_api_id   = aws_api_gateway_rest_api.drift.id
  resource_id   = aws_api_gateway_resource.ui.id
  http_method   = "GET"
  authorization = "NONE" // 画面は、ログイン前に開く。内容は、APIがログインを要求する
}

resource "aws_api_gateway_integration" "ui" {
  rest_api_id             = aws_api_gateway_rest_api.drift.id
  resource_id             = aws_api_gateway_resource.ui.id
  http_method             = aws_api_gateway_method.ui_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.ui.invoke_arn
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.drift.id
  parent_id   = aws_api_gateway_rest_api.drift.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_resource" "events_id" {
  rest_api_id = aws_api_gateway_rest_api.drift.id
  parent_id   = aws_api_gateway_resource.events.id
  path_part   = "{event_id}"
}

resource "aws_api_gateway_method" "events_get" {
  rest_api_id   = aws_api_gateway_rest_api.drift.id
  resource_id   = aws_api_gateway_resource.events_id.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "events" {
  rest_api_id             = aws_api_gateway_rest_api.drift.id
  resource_id             = aws_api_gateway_resource.events_id.id
  http_method             = aws_api_gateway_method.events_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_event.invoke_arn
}

resource "aws_api_gateway_method" "events_list" {
  rest_api_id   = aws_api_gateway_rest_api.drift.id
  resource_id   = aws_api_gateway_resource.events.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "events_list" {
  rest_api_id             = aws_api_gateway_rest_api.drift.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.events_list.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.list_events.invoke_arn
}

resource "aws_lambda_permission" "apigw_list_events" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.list_events.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.drift.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_ui" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ui.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.drift.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_get_event" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_event.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.drift.execution_arn}/*/*"
}

output "ui_url" {
  description = "申告・承認の画面のURL(通知のリンクには、末尾に ?event=通知のID が付く)"
  value       = local.ui_url
}
