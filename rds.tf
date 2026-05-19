# RDS
# DBサブネットグループ
resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db-subnet-group"
  subnet_ids = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]

    tags = {
        Name = "${var.prefix}-db-subnet-group"
    }
}

# RDSインスタンス
resource "aws_db_instance" "main" {
  identifier              = "${var.prefix}-rds-instance"
  allocated_storage       = 20
  storage_type            = "gp2"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  username                = "root"
  password                = "123qwecc"
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
}