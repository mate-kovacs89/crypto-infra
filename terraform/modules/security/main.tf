# Brownfield import: security groups pre-exist.
# Rules match the current state from audit/eu-north-1.json.

resource "aws_security_group" "training" {
  name        = "crypto-bot-training-sg"
  description = "Training EC2"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crypto-bot-training-sg"
  }
}

resource "aws_security_group" "live" {
  name        = "crypto-bot-live-sg"
  description = "Live EC2 for node vue inference"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  ingress {
    description = "HTTP (web dashboard)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.web_cidr_blocks
  }

  ingress {
    description = "HTTPS (web dashboard)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.web_cidr_blocks
  }

  ingress {
    description = "Node.js API (3000)"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.web_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crypto-bot-live-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "crypto-bot-rds-sg"
  description = "RDS MySQL access"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from training EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.training.id]
  }

  ingress {
    description     = "MySQL from live EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.live.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crypto-bot-rds-sg"
  }
}
