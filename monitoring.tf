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

# Lambdaに必要なIAMポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Lambda関数
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir = "src" // Lambda関数のコードファイルが含まれるディレクトリ
  output_path = "lambda_function.zip" // 出力されるZIPファイルのパス
}

resource "aws_lambda_function" "drift_handler" {
  function_name = "${var.prefix}-drift-handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "qpp.lambda_handler"
  runtime       = "python3.9"  
  filename      = "data.archive_file.lambda_zip.output_path"  // Lambda関数のコードをZIPファイルとして指定
  source_code_hash = "data.archive_file.lambda_zip.output_base64sha256" // コードの変更を検知するためのハッシュ値
}

# Lambda関数とSQSキューのトリガー設定
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.drift_queue.arn
  function_name    = aws_lambda_function.drift_handler.arn
  batch_size       = 1 // 一度に処理するメッセージの数
}

# EventBridge
# CloudFormationのドリフト検出イベントをキャッチするルール
resource "aws_cloudwatch_event_rule" "drift_rule" {
  name        = "${var.prefix}-drift-rule"
  description = "Detect infrastructure drift or changes"

  // CloudFormationのドリフト検出イベントをキャッチするためのイベントパターン
  event_pattern = jsonencode({
    source = ["aws.ecs"],
    detail-type = ["ECS Task State Change"],
  })
}

# イベントを検知したらSNSキューにメッセージを送るターゲット設定
resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.drift_rule.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.drift_alerts.arn
}