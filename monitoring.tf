# Amazon SNS
resource "aws_sns_topic" "drift_alerts" {
  name = "${var.prefix}-drift-alerts"
}

# Amazon SQS
resource "aws_sqs_queue" "drift_queue" {
  name = "${var.prefix}-drift-queue"

  // メッセージを保持する期間(14日間)
  message_retention_seconds = 1209600
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
      Action = "sns:Publish"
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
        Effect = "Allow"
        Principal = "*"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.drift_queue.arn
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
        Effect = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action = "sts:AssumeRole"
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
      Effect   = "Allow"
      Action   = "kms:Decrypt"
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

# Lambdaに必要なIAMポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Lambda関数
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir = "src"                  // Lambda関数のコードファイルが含まれるディレクトリ
  output_path = "lambda_function.zip" // 出力されるZIPファイルのパス
}

resource "aws_lambda_function" "drift_handler" {
  function_name = "${var.prefix}-drift-handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.9"  
  filename      = data.archive_file.lambda_zip.output_path            // Lambda関数のコードをZIPファイルとして指定
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256 // コードの変更を検知するためのハッシュ値

  # 環境変数の設定（SlackのWebhook URLを渡す）
  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.SLACK_WEBHOOK_URL # 変数を参照する
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
    source = ["aws.config"],
    detail-type = ["Config Configuration Item Change"],
    detail = {
      messageType = ["ConfigurationItemChangeNotification"],
      configurationItem = {
        # 監視対象を「セキュリティグループ」に限定する設定
        resourceType = ["AWS::EC2::SecurityGroup"]
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