variable "vpc_id" {
  type = string
}

variable "ssh_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed SSH access. Typically your home IP."
  default     = ["0.0.0.0/0"] # TIGHTEN in production!
}

variable "web_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks for web dashboard access."
  default     = ["0.0.0.0/0"] # TIGHTEN in production!
}
