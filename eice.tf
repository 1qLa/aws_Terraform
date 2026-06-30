resource "aws_ec2_instance_connect_endpoint" "main" {
    subnet_id = aws_subnet.private_1a.id
    security_group_ids = [aws_security_group.bastion_sg.id]

    tags = {
        Name = "${var.prefix}-eice"
    }
}
