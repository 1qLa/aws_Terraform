# ALB用のセキュリティグループ
resource "aws_security_group" "alb_sg" {
  name        = "${var.prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

    # ALBのリスナーで使用するポート80を許可
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # egressルールはすべてのアウトバウンドトラフィックを許可
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# ECS用のセキュリティグループ（ALBからのみアクセス許可）
resource "aws_security_group" "ecs_sg" {
  name        = "${var.prefix}-ecs-sg"
  description = "Security group for ECS"
  vpc_id      = aws_vpc.main.id

  # ALBからのみアクセス許可
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # egressルールはすべてのアウトバウンドトラフィックを許可
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# RDS用のセキュリティグループ（ALBとECSからのみアクセス許可）
resource "aws_security_group" "rds_sg" {
  name        = "${var.prefix}-rds-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  # ALBとECSからのみアクセス許可
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
  
  # EICE(bastion_sg)からのアクセス許可
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  # egressルールはすべてのアウトバウンドトラフィックを許可
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 踏み台サーバー用のセキュリティグループ
resource "aws_security_group" "bastion_sg" {
  name        = "${var.prefix}-bastion-sg"
  description = "Security Group for Bastion Host"
  vpc_id      = aws_vpc.main.id 

  # EICE自体はIAMで守られているため、ingress(インバウンド)は不要

  # アウトバウンドルール（RDSなどVPC内への通信を許可）
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "bastion-sg"
  }
}