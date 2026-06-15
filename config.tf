# Config用のIAMロール（ConfigがAWSリソースの変更を監視するための役割）
resource "aws_iam_role" "config_role" {
  name = "kane-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
}

# AWSが用意しているConfig用の基本権限をアタッチ
resource "aws_iam_role_policy_attachment" "config_policy_attach" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 録画データの保存先であるS3バケットの作成
resource "aws_s3_bucket" "config_bucket" {
  # S3バケット名は世界で一意である必要がある
  bucket        = "kane-config-bucket-2240040"
  force_destroy = true # 検証用: Terraform destroy時に中身ごと削除できるようにする
}

# ConfigがS3に録画データを書き込めるようにする許可証
resource "aws_s3_bucket_policy" "config_bucket_policy" {
  bucket = aws_s3_bucket.config_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowConfigWrite"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_bucket.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid    = "AllowConfigRead"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_bucket.arn
      }
    ]
  })
}

# 設定レコーダー（ConfigがAWSリソースの変更を記録するための役割）
resource "aws_config_configuration_recorder" "main" {
  name     = "kane-config-recorder"
  role_arn = aws_iam_role.config_role.arn

  # 全てのリソースを監視対象にする設定
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# 配信チャンネルの作成（Configが記録した変更データをS3に送るための役割）
resource "aws_config_delivery_channel" "main" {
  name           = "kane-config-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_bucket.bucket

  # カメラ本体が作られてからパイプを繋ぐという順序指定
  depends_on = [aws_config_configuration_recorder.main]
}

# 録画の開始（ConfigがAWSリソースの変更を監視し始める）
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true # ここをtrueにすることで「有効化」される

  # パイプ（配信チャンネル）が繋がる前に電源を入れるとエラーになるため、順序を指定
  depends_on = [aws_config_delivery_channel.main]
}