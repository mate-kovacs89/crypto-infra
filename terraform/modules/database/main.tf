# Brownfield import: RDS MySQL instance + subnet group.
# Managed by Terraform after import, upgrades via plan+apply.

resource "aws_db_subnet_group" "main" {
  name       = "crypto-bot-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name    = "crypto-bot-db-subnet-group"
    Project = "crypto-ai"
  }
}

resource "aws_db_instance" "main" {
  identifier     = var.rds_instance_id
  engine         = "mysql"
  engine_version = "8.4"
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_storage_gb
  max_allocated_storage = var.rds_max_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "cryptobot_ai"
  username = var.rds_username
  password = var.rds_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  tags = {
    Name        = "crypto-bot-rds"
    Project     = "crypto-ai"
    Environment = "prod"
  }

  lifecycle {
    ignore_changes = [password]
  }
}
