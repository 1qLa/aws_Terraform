output "database_name" {
  value = data.aws_ssm_parameter.database_name.value
}

output "username" {
  value = data.aws_ssm_parameter.username.value
}

output "password" {
  value = data.aws_ssm_parameter.password.value
}