# ECR
resource "aws_ecr_repository" "app_repo" {
  count = var.enable_workload ? 1 : 0
  name = "${var.prefix}-app-repo"

  # イメージスキャン設定
  image_scanning_configuration {
    scan_on_push = true // イメージがプッシュされた際に自動スキャンを有効にする
  }

  tags = {
    Name = "${var.prefix}-app-repo"
  }
  
}