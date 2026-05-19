# ECR
resource "aws_ecr_repository" "app_repo" {
  name = "${var.prefix}-app-repo"

  # イメージスキャン設定
  image_scanning_configuration {
    scan_on_push = true // イメージがプッシュされた際に自動スキャンを有効にする
  }

  tags = {
    Name = "${var.prefix}-app-repo"
  }
  
}