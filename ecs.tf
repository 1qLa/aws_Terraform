# ECS
# IAMロールの作成
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.prefix}-ecs-task-execution-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = "ecs-tasks.amazonaws.com" }
            Action    = "sts:AssumeRole"
        }]
    })
}

# IAMロールにポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  
}

# CloudWatch Logsのロググループ
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/${var.prefix}-log-group"
  retention_in_days = 7 // ログの保持期間を7日に設定
}
# ECSクラスター
resource "aws_ecs_cluster" "main" {
  name = "${var.prefix}-cluster"
}

# ECSタスク定義
resource "aws_ecs_task_definition" "app" {
  family                 = "${var.prefix}-app-task"
  network_mode           = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                    = "256"
  memory                 = "512"
  execution_role_arn     = aws_iam_role.ecs_task_execution_role.arn

    container_definitions = jsonencode([{
        name      = "app"
        image     = "nginx:latest"
        essential = true
        portMappings = [{
            containerPort = 80
            hostPort      = 80
            protocol      = "tcp"
        }]
        logConfiguration = {
            logDriver = "awslogs"
            options = {
            "awslogs-group"         = aws_cloudwatch_log_group.ecs_log_group.name
            "awslogs-region"        = "ap-northeast-1"
            "awslogs-stream-prefix" = "ecs"
            }
        }    
    }])
}

# ECSサービス
resource "aws_ecs_service" "app" {
  name            = "${var.prefix}-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"

    network_configuration {
        subnets         = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]
        security_groups = [aws_security_group.ecs_sg.id]
        assign_public_ip = true
    }

    load_balancer {
        target_group_arn = aws_lb_target_group.ecs_tg.arn
        container_name   = "app"
        container_port   = 80
    }
}