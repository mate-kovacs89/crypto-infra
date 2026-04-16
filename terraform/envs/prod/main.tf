# Root module: orchestrates all infrastructure modules.
#
# Brownfield resources (VPC, subnets, SGs, RDS, S3) are imported
# via `terraform import`. New resources (ARM EC2, ECR, IAM) are
# created fresh via `terraform apply`.

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Networking (brownfield import) ────────────────────────

module "networking" {
  source = "../../modules/networking"
}

# ── Security Groups (brownfield import) ───────────────────

module "security" {
  source = "../../modules/security"
  vpc_id = module.networking.vpc_id
}

# ── IAM (instance profiles for EC2) ───────────────────────

module "iam" {
  source = "../../modules/iam"

  models_bucket_arn = module.storage.models_bucket_arn
  region            = var.region
}

# ── Compute (NEW ARM Graviton instances) ──────────────────

module "compute" {
  source = "../../modules/compute"

  training_instance_type       = var.training_instance_type
  live_instance_type           = var.live_instance_type
  key_name                     = var.key_name
  public_subnet_ids            = module.networking.public_subnet_ids
  training_sg_id               = module.security.training_sg_id
  live_sg_id                   = module.security.live_sg_id
  region                       = var.region
  training_instance_profile    = module.iam.training_instance_profile_name
  live_instance_profile        = module.iam.live_instance_profile_name
}

# ── Training Scheduler (bi-weekly auto-start) ────────────

module "training_scheduler" {
  source = "../../modules/training_scheduler"

  training_instance_id = module.compute.training_instance_id
  region               = var.region
}

# ── Database (brownfield import) ──────────────────────────

module "database" {
  source = "../../modules/database"

  rds_instance_id    = var.rds_instance_id
  rds_sg_id          = module.security.rds_sg_id
  private_subnet_ids = module.networking.private_subnet_ids
  rds_username       = var.rds_username
  rds_password       = var.rds_password
}

# ── Storage (S3 import + ECR new) ─────────────────────────

module "storage" {
  source             = "../../modules/storage"
  models_bucket_name = var.models_bucket_name
}

# ── Outputs ───────────────────────────────────────────────

output "training_public_ip" {
  value = module.compute.training_public_ip
}

output "live_public_ip" {
  value = module.compute.live_public_ip
}

output "rds_endpoint" {
  value     = module.database.rds_endpoint
  sensitive = true
}

output "ecr_bot_node_url" {
  value = module.storage.ecr_bot_node_url
}

output "ecr_ai_python_url" {
  value = module.storage.ecr_ai_python_url
}

output "ecr_web_vue_url" {
  value = module.storage.ecr_web_vue_url
}
