# VPC 
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"

    tags = {
        Name = "${var.prefix}-vpc"
    }
}

# public_1a
resource "aws_subnet" "public_1a" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.1.0/24"
    availability_zone       = "ap-northeast-1a"
    map_public_ip_on_launch = true

    tags = {
        Name = "${var.prefix}-public-1a"
    }
}

# public_1c
resource "aws_subnet" "public_1c" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.2.0/24"
    availability_zone       = "ap-northeast-1c"
    map_public_ip_on_launch = true

    tags = {
        Name = "${var.prefix}-public-1c"
    }
}

# private_1a
resource "aws_subnet" "private_1a" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.3.0/24"
    availability_zone       = "ap-northeast-1a"
    map_public_ip_on_launch = false

    tags = {
        Name = "${var.prefix}-private-1a"
    }
}

# private_1c
resource "aws_subnet" "private_1c" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.4.0/24"
    availability_zone       = "ap-northeast-1c"
    map_public_ip_on_launch = false

    tags = {
        Name = "${var.prefix}-private-1c"
    }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.prefix}-igw"
  }
}

# public Route Table
resource "aws_route_table" "public_rtb" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.prefix}-public-rtb"
  }
}

# private Route Table
resource "aws_route_table" "private_rtb" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.prefix}-private-rtb"
  }
}

# public_1aをルートテーブルに関連付ける
resource "aws_route_table_association" "public_1a_assoc" {
  subnet_id      = aws_subnet.public_1a.id
  route_table_id = aws_route_table.public_rtb.id
}

# public_1cをルートテーブルに関連付ける
resource "aws_route_table_association" "public_1c_assoc" {
  subnet_id      = aws_subnet.public_1c.id
  route_table_id = aws_route_table.public_rtb.id
}

# private_1aをルートテーブルに関連付ける
resource "aws_route_table_association" "private_1a_assoc" {
  subnet_id      = aws_subnet.private_1a.id
  route_table_id = aws_route_table.private_rtb.id
}

# private_1cをルートテーブルに関連付ける
resource "aws_route_table_association" "private_1c_assoc" {
  subnet_id      = aws_subnet.private_1c.id
  route_table_id = aws_route_table.private_rtb.id
}