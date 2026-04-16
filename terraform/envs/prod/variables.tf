variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "project" {
  type    = string
  default = "crypto-ai"
}

variable "environment" {
  type    = string
  default = "prod"
}

# ── Networking (brownfield import) ────────────────────────

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

# ── Compute ───────────────────────────────────────────────

variable "training_instance_type" {
  type    = string
  default = "c7g.12xlarge"
}

variable "live_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "key_name" {
  type    = string
  default = "sajat"
}

# ── Database (brownfield import) ──────────────────────────

variable "rds_instance_id" {
  type    = string
  default = "database-1"
}

# ── Storage ───────────────────────────────────────────────

variable "models_bucket_name" {
  type    = string
  default = "crypto-bot-models-eu-north-1"
}

# ── Database credentials (sensitive) ──────────────────────

variable "rds_username" {
  type      = string
  sensitive = true
}

variable "rds_password" {
  type      = string
  sensitive = true
}
