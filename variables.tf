# Variables
variable "prefix" {
  description = "kane prefix"
  type        = string
  default     = "kane"
}

variable "SLACK_WEBHOOK_URL" {
  description = "(使わなくなった) Slack Webhook URL。通知は、AgentCore Gateway経由に置き換えた。tfvarsに残っていても、エラーにならないよう変数だけ残している"
  type        = string
  sensitive   = true # 画面にURLが表示されるのを防ぐセキュリティ設定
  default     = null
}

variable "slack_channel_id" {
  description = "ドリフトの通知を送るSlackチャンネルのID(C...)。terraform.tfvars に書く"
  type        = string
}

variable "enable_workload" {
  description = "アプリ側のリソース(ALB/WAF/ECS/ECR/RDS/EC2踏み台)を作成するか。検証用の既定値は作成しない"
  type        = bool
  default     = false
}

variable "enable_config_recording" {
  description = "AWS Configの記録を有効にするか。認証・認可の実装が終わるまでは停止しておく"
  type        = bool
  default     = false
}

variable "web_callback_urls" {
  description = "申告・承認の画面のほかに、ログイン後に戻るURLを足したいとき(ローカルでの確認など)。画面のURLは、自動で入る"
  type        = list(string)
  default     = []
}

variable "claude_code_callback_urls" {
  description = "Claude Codeのログイン後に戻るURL。接続方法を決めるまでは仮の値"
  type        = list(string)
  default     = ["http://localhost:8080/callback"]
}

variable "test_users" {
  description = "検証用のテストユーザー。キーはユーザーの識別名（tanaka など）。値は terraform.tfvars に書く（git の管理対象外）"
  type = map(object({
    email   = string           # ログインID（実在しなくてもよい）
    group   = optional(string) # 所属グループ（leads または developers）。省略すると、どのグループにも入らない
    iam_arn = string           # 本人のIAMのARN。CloudTrailの操作者と突き合わせる
  }))
  default = {}
}

variable "test_user_password" {
  description = "テストユーザー共通の初期パスワード（8文字以上、大文字・小文字・数字・記号を含む）"
  type        = string
  sensitive   = true
  default     = null
}

variable "slack_bot_token" {
  description = "Slackのbot token(xoxb-...)。AgentCore Identityに登録するときだけ使い、stateには保存されない。tfvarsには書かず、環境変数 TF_VAR_slack_bot_token で渡す"
  type        = string
  sensitive   = true
  ephemeral   = true // plan や state に残さない
  default     = null

  # 空文字や形の違う値が AWS に送られて、分かりにくいエラーになるのを防ぐ。
  # 未設定(null)は許可する。token を登録しない通常の plan / apply で、毎回エラーにならないようにするため
  validation {
    condition     = var.slack_bot_token == null ? true : startswith(var.slack_bot_token, "xoxb-")
    error_message = "slack_bot_token は xoxb- で始まる必要があります（空文字や、別の値ではありません）。"
  }
}

variable "slack_bot_token_version" {
  description = "bot tokenを入れ替えたときに、この数字を1つ増やすと、Terraformが新しいtokenを再登録する"
  type        = number
  default     = 1
}

variable "enable_slack_notify" {
  description = "Slackのbot tokenの登録と、Gatewayの通知Toolを作るか。登録には環境変数 TF_VAR_slack_bot_token が必要で、Secrets Managerの権限も要る。権限が付くまでは false にしておく"
  type        = bool
  default     = false
}

variable "enable_test_client" {
  description = "動作確認用のCognitoクライアント(パスワードで直接トークンを取れる)を作るか。drafts/ の確認スクリプトを実行するときだけ true にし、終わったら false に戻す"
  type        = bool
  default     = false
}
