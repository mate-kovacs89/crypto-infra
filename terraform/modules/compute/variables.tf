variable "training_instance_type" {
  type = string
  # c7g.4xlarge: 16 vCPU Graviton3, 32 GB RAM. Sufficient for the
  # weekly 5-coin retrain (36-feature × 5-seed ensemble × Optuna 30
  # trials completes in ~4-6h). The original plan sized this at
  # c7g.12xlarge (48 vCPU / 96 GB) but real utilisation never got
  # close to it — downgraded 2026-04 for ~3x cost cut while still
  # fitting the Sunday 02:00 UTC run window.
  default = "c7g.4xlarge"
}

variable "live_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "key_name" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "training_sg_id" {
  type = string
}

variable "live_sg_id" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "training_instance_profile" {
  type    = string
  default = ""
}

variable "live_instance_profile" {
  type    = string
  default = ""
}
