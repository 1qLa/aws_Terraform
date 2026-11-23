# Amazon SNS
resource "aws_sns_topic" "drift_alerts" {
  name = "${var.prefix}-drift-alerts"
}

# Amazon SQS
resource "aws_sqs_queue" "drift_queue" {
  name = "${var.prefix}-drift-queue"

  // メッセージを保持する期間(14日間)
  message_retention_seconds = 1209600

  // 処理中のメッセージを、他に見せない時間。Lambdaの制限時間より長くする必要がある(失敗したら、この時間のあとに再配信される)
  visibility_timeout_seconds = 180
}

# EventBridgeからSNSへのメッセージ送信を許可するアクセスポリシー
resource "aws_sns_topic_policy" "allow_eventbridge_to_sns" {
  arn = aws_sns_topic.drift_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.drift_alerts.arn
    }]
  })
}

# SNSトピックとSQSキューのサブスクリプション(SNSトピックにメッセージが送信されたときにSQSキューに配信されるようにする)
resource "aws_sns_topic_subscription" "sns_to_sqs" {
  topic_arn = aws_sns_topic.drift_alerts.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.drift_queue.arn

}

# SQSのアクセスポリシー(SNSトピックからSQSキューへのアクセスを許可する)
resource "aws_sqs_queue_policy" "allow_sns_to_sqs" {
  queue_url = aws_sqs_queue.drift_queue.id

  // SNSトピックからSQSキューへのアクセスを許可するポリシー
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.drift_queue.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.drift_alerts.arn
        }
      }
    }]
  })
}

# Lambda関数のIAMロール
resource "aws_iam_role" "lambda_role" {
  name = "${var.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lambdaが環境変数（KMS）を復号するための権限
resource "aws_iam_role_policy" "lambda_kms_decrypt" {
  name = "${var.prefix}-lambda-kms-decrypt"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "kms:Decrypt"
      # エラーログに出てきたKMSキーのARNを指定
      Resource = "arn:aws:kms:ap-northeast-1:859261896300:key/849d6ad7-cafc-4ac2-a832-309e9a38811a"
    }]
  })
}

# Lambda 探偵に CloudTrail の録画データを見る権限を付与
resource "aws_iam_role_policy" "lambda_cloudtrail_policy" {
  name = "lambda-cloudtrail-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "cloudtrail:LookupEvents"
        Resource = "*"
      }
    ]
  })
}

# LambdaにEC2のセキュリティグループ名を取得する権限を付与
resource "aws_iam_role_policy" "lambda_ec2_policy" {
  name = "lambda-ec2-describe-sg-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups"
        ]
        Resource = "*"
      },
    ]
  })
}

# Lambdaに台帳(DynamoDB)への書き込み権限を付与
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "lambda-dynamodb-put-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"] // 記録するだけなので、書き込みのみ許可
        Resource = aws_dynamodb_table.drift_events.arn
      },
    ]
  })
}

# Lambdaに必要なIAMポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Lambda関数
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "src"                        // Lambda関数のコードファイルが含まれるディレクトリ
  excludes    = ["test_*.py", "__pycache__"] // テストは、Lambdaに含めない
  output_path = "lambda_function.zip"        // 出力されるZIPファイルのパス
}

resource "aws_lambda_function" "drift_handler" {
  function_name    = "${var.prefix}-drift-handler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.9"
  filename         = data.archive_file.lambda_zip.output_path         // Lambda関数のコードをZIPファイルとして指定
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256 // コードの変更を検知するためのハッシュ値

  // Gateway経由の通知は、Cognitoのトークン取得とSlackへの送信で、数秒かかる
  timeout = 30

  # 環境変数の設定。Slackのtokenやクライアントのシークレットは、置かない
  environment {
    variables = {
      DRIFT_TABLE_NAME = aws_dynamodb_table.drift_events.name # 台帳のテーブル名
      SLACK_CHANNEL_ID = var.slack_channel_id                 # 通知先のSlackチャンネルID
      APPROVAL_API_URL = aws_api_gateway_stage.v1.invoke_url  # 申告・承認APIのURL(メッセージに載せる)

      # AgentCore Gatewayを呼ぶための設定(2LO: Lambdaが、アプリ自身の権限でトークンを取る)
      GATEWAY_URL      = aws_bedrockagentcore_gateway.main.gateway_url
      TOKEN_URL        = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/token"
      CLIENT_ID        = aws_cognito_user_pool_client.drift_handler.id
      CLIENT_SECRET_ID = aws_secretsmanager_secret.drift_handler_client.name # クライアントのシークレットは、Secrets Managerから読む
    }
  }
}

# Lambda関数とSQSキューのトリガー設定
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.drift_queue.arn
  function_name    = aws_lambda_function.drift_handler.arn
  batch_size       = 1 // 一度に処理するメッセージの数
}

# EventBridge
# config経由でインフラの手動変更（ドリフト）をキャッチするルール
resource "aws_cloudwatch_event_rule" "drift_rule" {
  name        = "${var.prefix}-drift-rule"
  description = "Detect configuration changes via AWS Config"

  // AWSコンソールからの手動変更（APIコール）を検知するためのパターン
  event_pattern = jsonencode({
    source      = ["aws.config"],
    detail-type = ["Config Configuration Item Change"],
    detail = {
      messageType = ["ConfigurationItemChangeNotification"],
      configurationItem = {
        # 監視対象を「セキュリティグループ」に限定する設定
        resourceType = ["AWS::EC2::SecurityGroup"]

        # 監視対象のセキュリティグループのIDを指定
        resourceId = [
          aws_security_group.alb_sg.id,
          aws_security_group.rds_sg.id,
          aws_security_group.bastion_sg.id,
          # aws_security_group.ecs_sg.id, # ECSは監視対象外
        ]
      }
    }
  })
}

# イベントを検知したらSNSキューにメッセージを送るターゲット設定
resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.drift_rule.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.drift_alerts.arn
}