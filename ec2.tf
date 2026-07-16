# resource "aws_ec2_instance_connect_endpoint" "main" {
#     subnet_id = aws_subnet.private_1a.id
#     security_group_ids = [aws_security_group.bastion_sg.id]

#     tags = {
#         Name = "${var.prefix}-eice"
#     }
# }

# --- SSM接続用のIAMロールとプロファイル ---
resource "aws_iam_role" "bastion_role" {
  name = "${var.prefix}-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm_policy" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "${var.prefix}-bastion-profile"
  role = aws_iam_role.bastion_role.name
}

# --- 踏み台EC2インスタンス ---
data "aws_ssm_parameter" "amzn2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.amzn2023_ami.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_1a.id 
  
  # すでに作成済みのSGをアタッチ
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion_profile.name

  tags = {
    Name = "${var.prefix}-bastion-ec2"
  }
}