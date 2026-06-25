output "vpc_id" {
    description = "作成されたVPCのID"
    value = aws_vpc.main.id
}

output "public_subnet_ids" {
    description = "パブリックサブネットのIDリスト"
    value = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]
}

output "bastion_sg_id" {
    description = "SSM用のセキュリティグループID"
    value = aws_security_group.bastion_sg.id
}

output "drift_sqs_queue_url" {
    description = "構成ドリフトのイベントを処理するSQSキューのURL"
    value = aws_sqs_queue.drift_sqs_queue.id
}

output "rds_endpoint" {
    description = "RDSの接続エンドポイント"
    value = aws_rds_cluster.aurora.endpoint
}

output "database_name" {
    description = "データベース名"
    value = data.aws_ssm_parameter.database_name.value
}

output "username" {
    description = "ユーザー名"
    value = data.aws_ssm_parameter.username.value
}

output "password" {
    description = "パスワード"
    value = data.aws_ssm_parameter.password.name
}