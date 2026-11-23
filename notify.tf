# drift-handler がGatewayを呼ぶための、Cognito 2LOクライアントのシークレットの保管
# 環境変数には置かず、Secrets Managerに置いて、drift-handlerが実行時に読む

resource "aws_secretsmanager_secret" "drift_handler_client" {
  # 名前は bedrock-agentcore で始める(管理者に付けてもらった権限の範囲が、この名前だけのため)
  name        = "bedrock-agentcore-${var.prefix}-drift-handler-client"
  description = "drift-handlerが、Cognitoで2LOのトークンを取るためのクライアントシークレット"

  recovery_window_in_days = 0 // 削除したとき、すぐに消す(検証用。同じ名前で作り直せる)
}

resource "aws_secretsmanager_secret_version" "drift_handler_client" {
  secret_id = aws_secretsmanager_secret.drift_handler_client.id

  # write-only: 値はAWSに送られるだけで、このリソースとしては、Terraformのstateに保存されない
  secret_string_wo         = aws_cognito_user_pool_client.drift_handler.client_secret
  secret_string_wo_version = 1 // シークレットを作り直したとき、数字を1つ増やすと、再登録される
}

# drift-handlerが、このシークレット1つだけを読める権限
resource "aws_iam_role_policy" "lambda_read_client_secret" {
  name = "lambda-read-drift-handler-client-secret"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.drift_handler_client.arn
    }]
  })
}
