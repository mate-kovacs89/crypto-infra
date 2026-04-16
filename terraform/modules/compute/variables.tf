variable "training_instance_type" {
  type    = string
  default = "c7g.12xlarge"
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
