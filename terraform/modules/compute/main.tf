# NEW ARM Graviton EC2 instances (not brownfield — created fresh).
# The old t3 x86 instances are terminated manually after these are
# verified.

data "aws_ami" "arm_ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Training EC2 ──────────────────────────────────────────
# c7g.4xlarge: 16 vCPU Graviton3, 32 GB RAM. Stopped by default;
# started by the `training.yml` GH Actions workflow (weekly cron
# `0 2 * * 0` — Sunday 02:00 UTC) via AWS CLI, and stopped at the
# end of the same workflow. The original c7g.12xlarge (48 vCPU) was
# over-provisioned for the actual 36-feature / 5-seed pipeline.

resource "aws_instance" "training" {
  ami                    = data.aws_ami.arm_ubuntu.id
  instance_type          = var.training_instance_type
  key_name               = var.key_name
  subnet_id              = var.public_subnet_ids[1] # eu-north-1b
  vpc_security_group_ids = [var.training_sg_id]
  iam_instance_profile   = var.training_instance_profile

  root_block_device {
    volume_size           = 100 # GB — models + training data + Docker images
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data_training.sh", {
    region = var.region
  }))

  tags = {
    Name        = "crypto-bot-training"
    Project     = "crypto-ai"
    Environment = "prod"
    Role        = "training"
  }
}

# ── Live EC2 ──────────────────────────────────────────────
# t4g.medium: 2 vCPU Graviton, 4 GB RAM.
# Always running — serves the trading bot + web dashboard.

resource "aws_instance" "live" {
  ami                    = data.aws_ami.arm_ubuntu.id
  instance_type          = var.live_instance_type
  key_name               = var.key_name
  subnet_id              = var.public_subnet_ids[0] # eu-north-1a
  vpc_security_group_ids = [var.live_sg_id]
  iam_instance_profile   = var.live_instance_profile

  root_block_device {
    volume_size           = 30 # GB — Docker images + logs
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data_live.sh", {
    region = var.region
  }))

  tags = {
    Name        = "crypto-bot-live"
    Project     = "crypto-ai"
    Environment = "prod"
    Role        = "live"
  }
}
