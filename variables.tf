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
