# 調査Lambda（Claude Codeから、AgentCore Gateway経由で呼ばれる）
# 台帳の履歴と、いまのSGの設定を返す。読み取り専用で、変更はできない
# Gateway の Tool として登録する作業は、AgentCore の権限が付いてから行う

resource "aws_iam_role" "investigate_lambda_role" {
  name = "${var.prefix}-investigate-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "investigate_lambda_logs" {
  role       = aws_iam_role.investigate_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 台帳の検索（SG IDごとの履歴）と、SGの現在の設定の照会だけを許可
resource "aws_iam_role_policy" "investigate_lambda_read" {
  name = "investigate-lambda-read-policy"
  role = aws_iam_role.investigate_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = "${aws_dynamodb_table.drift_events.arn}/index/*" // 履歴の検索に使うインデックス
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeSecurityGroups"]
        Resource = "*" // この操作は、リソースを指定できない
      },
    ]
  })
}

resource "aws_lambda_function" "investigate" {
  function_name    = "${var.prefix}-investigate-handler"
  role             = aws_iam_role.investigate_lambda_role.arn
  handler          = "investigate.investigate_handler"
  runtime          = "python3.9"
  timeout          = 15 // 秒。既定の3秒だと、初回の起動と、台帳・EC2への問い合わせで足りなかった
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = {
      DRIFT_TABLE_NAME = aws_dynamodb_table.drift_events.name
    }
  }
}
