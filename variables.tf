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