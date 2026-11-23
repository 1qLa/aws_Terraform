# Cognito
# 認証基盤。人（ブラウザ・Claude Code）とシステム（drift-handler）のログインを担当する

resource "aws_cognito_user_pool" "main" {
  name = "${var.prefix}-drift-users"

  # ログインIDはメールアドレス
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # CloudTrailの操作者ARNと、ログインした人を突き合わせるための属性（申告時に一致を確認する）
  schema {
    name                = "iam_arn"
    attribute_data_type = "String"
    mutable             = true
    required            = false

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  tags = {
    Name = "${var.prefix}-drift-users"
  }
}

# 権限の上下を決めるグループ。Precedenceが小さいほど権限が上
resource "aws_cognito_user_group" "leads" {
  name         = "leads"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "承認できる上位グループ（例: 課長）"
  precedence   = 10
}

resource "aws_cognito_user_group" "developers" {
  name         = "developers"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "申告する担当者（例: 開発者）"
  precedence   = 20
}

# ログイン画面・トークン発行のドメイン
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.prefix}-drift-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

data "aws_caller_identity" "current" {}

# 2LO（client credentials）で使うスコープの定義先
resource "aws_cognito_resource_server" "gateway" {
  identifier   = "drift-gateway"
  name         = "${var.prefix}-drift-gateway"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "notify"
    scope_description = "通知Toolを呼ぶ"
  }
}

# 2LO用: drift-handler が使う。人は関わらず、アプリ自身の権限で動く
resource "aws_cognito_user_pool_client" "drift_handler" {
  name         = "${var.prefix}-drift-handler"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.gateway.identifier}/notify"]
}

# 3LO用: ブラウザでの申告・承認
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.prefix}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.web_callback_urls
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
}

# 3LO用: Claude Code（MCP接続）
resource "aws_cognito_user_pool_client" "claude_code" {
  name         = "${var.prefix}-claude-code"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.claude_code_callback_urls
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
}

# 検証用のテストユーザー（田中・佐藤・鈴木の想定）。値は variables の test_users から作る
resource "aws_cognito_user" "test" {
  for_each = var.test_users

  user_pool_id   = aws_cognito_user_pool.main.id
  username       = each.value.email
  password       = var.test_user_password // 初期パスワードを直接設定し、招待メールは送らない
  message_action = "SUPPRESS"

  attributes = {
    email            = each.value.email
    email_verified   = "true"
    "custom:iam_arn" = each.value.iam_arn
  }

  # プロバイダーが読み取り時に "custom:" を外して比較するため、値が同じでも毎回差分に見える。
  # それを避けるため、作成後の属性の変更は Terraform では反映しない。
  # メールやiam_arnを直したいときは、ここを一時的に外して apply するか、
  # aws cognito-idp admin-update-user-attributes で直接直す
  lifecycle {
    ignore_changes = [attributes]
  }
}

# ユーザーをグループに入れる（グループで権限の上下が決まる）
resource "aws_cognito_user_in_group" "test" {
  for_each = { for name, user in var.test_users : name => user if user.group != null }

  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = each.value.group
  username     = aws_cognito_user.test[each.key].username
}

# 動作確認用: CLIからパスワードでトークンを取るためのクライアント（テスト専用。確認が終わったら削除してよい）
resource "aws_cognito_user_pool_client" "test_cli" {
  name         = "${var.prefix}-test-cli"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret     = false
  explicit_auth_flows = ["ALLOW_ADMIN_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}
