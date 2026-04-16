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

  # The RDS "db_name" is the initial database created at launch —
  # NOT the application schema. The actual schema is "cryptobot_ai"
  # but the RDS was initially provisioned with db_name="cryptobot".
  # Changing this forces replacement (destroy + create) — never do.
  db_name  = "cryptobot"
  username = var.rds_username
  password = var.rds_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  backup_retention_period = 7

  tags = {
    Name        = "crypto-bot-rds"
    Project     = "crypto-ai"
    Environment = "prod"
  }

  lifecycle {
    ignore_changes = [
      password,
      backup_window,
      maintenance_window,
      engine_version,
      max_allocated_storage,
    ]
  }
}
