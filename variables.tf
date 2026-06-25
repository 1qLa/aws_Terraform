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

variable "DATABASE_NAME" {
  description = "RDS Database Name"
  type        = string
  default     = "mydb"
}

variable "USERNAME" {
  description = "RDS Username"
  type        = string
  default     = "root"
}

variable "PASSWORD" {
  description = "RDS Password"
  type        = string
  default     = "123qwecc"
}