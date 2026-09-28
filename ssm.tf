# パラメータストアーに保存した機密情報を取得
data "aws_ssm_parameter" "database_name" {
  count = var.enable_workload ? 1 : 0
  name = "/kane/prod/rds/database_name"
}

data "aws_ssm_parameter" "username" {
  count = var.enable_workload ? 1 : 0
  name = "/kane/prod/rds/username"
}

data "aws_ssm_parameter" "password" {
  count = var.enable_workload ? 1 : 0
  name = "/kane/prod/rds/password"
}