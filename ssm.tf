# パラメータストアーに保存した機密情報を取得
data "aws_ssm_parameter" "database_name" {
  name = "DATABASE_NAME"
}

data "aws_ssm_parameter" "username" {
  name = "USERNAME"
}

data "aws_ssm_parameter" "password" {
  name = "PASSWORD"
}

# パラメータストアーに機密情報を登録
# resource "aws_ssm_parameter" "database_name" {
#   name  = "DATABASE_NAME"
#   type  = "String" 
#   value = var.aurora_database_name
# }

# resource "aws_ssm_parameter" "username" {
#   name  = "USERNAME"
#   type  = "String"
#   value = var.aurora_username
# }

# resource "aws_ssm_parameter" "password" {
#   name  = "PASSWORD"
#   type  = "String"
#   value = var.aurora_password
# }
