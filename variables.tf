# Variables
variable "prefix" {
  description = "kane prefix"
  type        = string
  default     = "kane"
}

variable "SLACK_WEBHOOK_URL" {
  description = "Slack Webhook URL for Drift Notification"
  type        = string
  sensitive   = true # 画面にURLが表示されるのを防ぐセキュリティ設定
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
  description = "ブラウザ（申告・承認画面）のログイン後に戻るURL。画面を作るまでは仮の値"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "claude_code_callback_urls" {
  description = "Claude Codeのログイン後に戻るURL。接続方法を決めるまでは仮の値"
  type        = list(string)
  default     = ["http://localhost:8080/callback"]
}

variable "test_users" {
  description = "検証用のテストユーザー。キーはユーザーの識別名（tanaka など）。値は terraform.tfvars に書く（git の管理対象外）"
  type = map(object({
    email   = string # ログインID（実在しなくてもよい）
    group   = string # 所属グループ（leads または developers）
    iam_arn = string # 本人のIAMのARN。CloudTrailの操作者と突き合わせる
  }))
  default = {}
}

variable "test_user_password" {
  description = "テストユーザー共通の初期パスワード（8文字以上、大文字・小文字・数字・記号を含む）"
  type        = string
  sensitive   = true
  default     = null
}
