# ALB
resource "aws_alb" "main" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]

  tags = {
    Name = "${var.prefix}-alb"
  }
}

# ターゲットグループ
resource "aws_lb_target_group" "ecs_tg" {
  name        = "${var.prefix}-ecs-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 15 // 頻度
    timeout             = 5
    healthy_threshold   = 3  // 正常
    unhealthy_threshold = 2  // 異常
    matcher             = "200"
  }

  tags = {
    Name = "${var.prefix}-ecs-tg"
  }
  
}

# リスナー
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.main.arn
  port              = 80
  protocol          = "HTTP"

    # デフォルトアクションでターゲットグループに転送
    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.ecs_tg.arn
    }   
}