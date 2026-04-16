variable "rds_instance_id" {
  type    = string
  default = "database-1"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_storage_gb" {
  type    = number
  default = 20
}

variable "rds_max_storage_gb" {
  type    = number
  default = 100
}

variable "rds_username" {
  type      = string
  sensitive = true
}

variable "rds_password" {
  type      = string
  sensitive = true
}

variable "rds_sg_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}
