# S3
resource "aws_s3_bucket" "main" {
  bucket = "${var.prefix}-app-bucket-2240040"

  tags = {
    Name = "${var.prefix}-app-bucket"
  }
}

# VPCエンドポイント（S3用）
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.ap-northeast-1.s3"
  route_table_ids = [aws_route_table.private_rtb.id]
}