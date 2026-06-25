# パラメータストアーに保存した機密情報を取得
data "aws_ssm_parameter" "database_name" {
  name = "/kane/prod/rds/database_name"
}

data "aws_ssm_parameter" "username" {
  name = "/kane/prod/rds/username"
}

data "aws_ssm_parameter" "password" {
  name = "/kane/prod/rds/password"
}