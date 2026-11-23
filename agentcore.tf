# Bedrock AgentCore
# 通知の置き換え(webhook → AgentCore)と、調査Toolの入口(Gateway)。
# Gateway = Toolの入口。ログインした人(Cognito)だけが、MCPでToolを呼べる

data "aws_region" "current" {}

locals {
  agentcore_arn_prefix = "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------
# Gatewayのサービスロール: GatewayがLambdaやトークン保管庫を使うときの権限
# ---------------------------------------------------------------
resource "aws_iam_role" "gateway_role" {
  name = "${var.prefix}-agentcore-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "${local.agentcore_arn_prefix}:gateway/*" }
      }
    }]
  })
}

# 調査Lambdaを呼ぶ権限(呼べるのは、この1つだけ)
resource "aws_iam_role_policy" "gateway_invoke_investigate" {
  name = "gateway-invoke-investigate"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.investigate.arn
    }]
  })
}

# ---------------------------------------------------------------
# Gateway本体
# ---------------------------------------------------------------
resource "aws_bedrockagentcore_gateway" "main" {
  name          = "${var.prefix}-drift-gateway"
  description   = "構成ドリフトの通知と調査のTool"
  role_arn      = aws_iam_role.gateway_role.arn
  protocol_type = "MCP"

  # 入口の認可: Cognitoでログインしたアプリ・人だけが呼べる
  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/openid-configuration"
      allowed_clients = [
        aws_cognito_user_pool_client.drift_handler.id, // 2LO: drift-handlerが通知Toolを呼ぶ
        aws_cognito_user_pool_client.claude_code.id,   // 3LO: Claude Codeが調査Toolを呼ぶ
      ]
    }
  }
}

# ---------------------------------------------------------------
# 調査Tool: 台帳の履歴と、いまのSGの設定を返す(調査Lambdaを呼ぶ)
# ---------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "investigate" {
  gateway_identifier = aws_bedrockagentcore_gateway.main.gateway_id
  name               = "investigate"
  description        = "セキュリティグループのドリフト履歴と、現在の設定を調べる"

  # GatewayのIAMロールで、Lambdaを呼ぶ
  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.investigate.arn

        tool_schema {
          inline_payload {
            name        = "investigate_security_group"
            description = "セキュリティグループ(sg-...)のドリフト履歴を新しい順に返し、現在のインバウンドルールも返す"

            input_schema {
              type = "object"
              property {
                name        = "resource_id"
                type        = "string"
                description = "調べるセキュリティグループのID(例: sg-0ae907c5511a2f1bd)"
                required    = true
              }
              property {
                name        = "limit"
                type        = "integer"
                description = "返す履歴の件数(既定10、最大50)"
              }
            }
          }
        }
      }
    }
  }
}

# GatewayがLambdaを呼べるように、Lambda側でも許可する
resource "aws_lambda_permission" "gateway_investigate" {
  statement_id  = "AllowAgentCoreGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.investigate.function_name
  principal     = "bedrock-agentcore.amazonaws.com"
  source_arn    = aws_bedrockagentcore_gateway.main.gateway_arn
}

# ---------------------------------------------------------------
# 通知Tool(Slack): enable_slack_notify = true のときだけ作る
# ---------------------------------------------------------------

# Slackのbot tokenを、AgentCore Identity(トークンの保管庫)に登録する。
# Gatewayが、Slack APIを呼ぶときに、この保管庫のtokenを使う。Lambdaや環境変数には、tokenを置かない
resource "aws_bedrockagentcore_api_key_credential_provider" "slack" {
  count = var.enable_slack_notify ? 1 : 0

  name = "${var.prefix}-slack-bot-token"

  # write-only: 値はAWSに送られるだけで、Terraformのstateには保存されない
  api_key_wo         = var.slack_bot_token
  api_key_wo_version = var.slack_bot_token_version
}

# Gatewayが、保管庫のtokenを読む権限
resource "aws_iam_role_policy" "gateway_slack_token" {
  count = var.enable_slack_notify ? 1 : 0

  name = "gateway-read-slack-token"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetResourceApiKey", "bedrock-agentcore:GetWorkloadAccessToken"]
        Resource = [
          "${local.agentcore_arn_prefix}:token-vault/default",
          aws_bedrockagentcore_api_key_credential_provider.slack[0].credential_provider_arn,
          "${local.agentcore_arn_prefix}:workload-identity-directory/default",
          "${local.agentcore_arn_prefix}:workload-identity-directory/default/workload-identity/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_bedrockagentcore_api_key_credential_provider.slack[0].api_key_secret_arn
      },
    ]
  })
}

# Slackの chat.postMessage を、Toolとして公開する(OpenAPIの定義)
resource "aws_bedrockagentcore_gateway_target" "notify" {
  count = var.enable_slack_notify ? 1 : 0

  gateway_identifier = aws_bedrockagentcore_gateway.main.gateway_id
  name               = "notify"
  description        = "Slackのチャンネルに、ドリフトの通知を送る"

  # tokenは、Authorizationヘッダーに「Bearer 」付きで入る
  credential_provider_configuration {
    api_key {
      provider_arn              = aws_bedrockagentcore_api_key_credential_provider.slack[0].credential_provider_arn
      credential_location       = "HEADER"
      credential_parameter_name = "Authorization"
      credential_prefix         = "Bearer"
    }
  }

  target_configuration {
    mcp {
      open_api_schema {
        inline_payload {
          payload = jsonencode({
            openapi = "3.0.0"
            info    = { title = "Slack", version = "1.0.0" }
            servers = [{ url = "https://slack.com/api" }]
            paths = {
              "/chat.postMessage" = {
                post = {
                  operationId = "postMessage"
                  summary     = "Slackのチャンネルにメッセージを送る"
                  requestBody = {
                    required = true
                    content = {
                      "application/json" = {
                        schema = {
                          type     = "object"
                          required = ["channel", "text"]
                          properties = {
                            channel = { type = "string", description = "送信先のチャンネルID" }
                            text    = { type = "string", description = "メッセージの本文" }
                          }
                        }
                      }
                    }
                  }
                  responses = {
                    "200" = { description = "送信の結果" }
                  }
                }
              }
            }
          })
        }
      }
    }
  }
}
